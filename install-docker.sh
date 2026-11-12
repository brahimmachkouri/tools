#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-docker.sh — installe Docker CE sur Ubuntu et ses dérivées
#                     (Linux Mint, Pop!_OS…)
#
# Le script est idempotent : il peut être relancé sans risque. Il :
#   1. vérifie la distribution et l'absence d'un Docker installé via snap ;
#   2. désinstalle les paquets en conflit (après confirmation, sauf --yes) ;
#   3. ajoute le dépôt APT officiel de Docker (format deb822) ;
#   4. installe Docker CE, buildx et le plugin compose ;
#   5. active le service, le teste avec hello-world ;
#   6. ajoute l'utilisateur courant au groupe « docker ».
#
# ⚠️  Le groupe « docker » donne des droits ÉQUIVALENTS À ROOT. Ce script ne
#    configure pas le mode « Docker rootless ».
#
# Dépendances : bash, curl, dpkg, apt-get, sudo (sauf si lancé en root).
# Voir « install-docker.sh --help ».

set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.0.3"

# Aucune question posée par debconf pendant les installations APT.
export DEBIAN_FRONTEND=noninteractive

# --- Affichage ---------------------------------------------------------------
# Bloc commun à tous les scripts du projet. Les couleurs ne sont utilisées que
# si la sortie standard est un terminal et que NO_COLOR (https://no-color.org)
# n'est pas défini : un journal ou un pipe reste ainsi lisible.

# shellcheck disable=SC2034  # toutes les couleurs ne servent pas partout
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'; BLUE=$'\e[34m'
  CYAN=$'\e[36m'; BOLD=$'\e[1m'; RESET=$'\e[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''
fi

log()  { printf '%s\n' "$*"; }                          # message brut
step() { printf '%s\n' "${BOLD}$*${RESET}"; }           # titre d'étape
info() { printf '%s\n' "${BLUE}ℹ️  $*${RESET}"; }        # information
ok()   { printf '%s\n' "${GREEN}✅ $*${RESET}"; }        # succès
hint() { printf '%s\n' "${CYAN}   👉 $*${RESET}"; }      # conseil, commande à lancer
warn() { printf '%s\n' "${YELLOW}⚠️  $*${RESET}" >&2; }  # avertissement (stderr)
err()  { printf '%s\n' "${RED}❌ $*${RESET}" >&2; }      # erreur (stderr)

# Affiche chaque argument comme une ligne d'erreur, puis quitte avec le code 1.
die() {
  local line
  for line in "$@"; do err "${line}"; done
  exit 1
}

# --- Aide --------------------------------------------------------------------

# Affiche l'aide sur stdout.
usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} — installe Docker CE sur Ubuntu et ses dérivées

Usage : ${SCRIPT_NAME} [options]

Options :
  -y, --yes        ne pas demander de confirmation avant de désinstaller
                   les paquets en conflit
  -h, --help       affiche cette aide et quitte
  -V, --version    affiche la version et quitte

Variables d'environnement :
  NO_COLOR         désactive les couleurs si elle est définie

Codes de sortie :
  0  Docker est installé et fonctionne
  1  échec (voir le message d'erreur)
  2  option inconnue

Notes :
  - Idempotent : peut être relancé sans risque.
  - Ajoute l'utilisateur au groupe « docker », ce qui donne des droits
    ÉQUIVALENTS À ROOT. Ce n'est pas le mode « Docker rootless ».
  - Les données de /var/lib/docker sont conservées lors de la désinstallation
    des paquets en conflit.
EOF
}

# --- Options -----------------------------------------------------------------

ASSUME_YES=0
for arg in "$@"; do
  case "${arg}" in
    -y|--yes) ASSUME_YES=1 ;;
    -V|--version) printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Option inconnue : ${arg}"; exit 2 ;;
  esac
done

info "${SCRIPT_NAME} v${SCRIPT_VERSION}"

# --- Nettoyage ---------------------------------------------------------------
# Arrête le keep-alive sudo et supprime la clé GPG temporaire, quelle que soit
# la façon dont le script se termine.

SUDO_LOOP_PID=""   # PID de la boucle keep-alive sudo
TMP_KEY=""         # clé GPG téléchargée, avant installation

# Exécuté à la sortie, même en cas d'erreur.
cleanup() {
  if [[ -n "${SUDO_LOOP_PID}" ]]; then kill "${SUDO_LOOP_PID}" 2>/dev/null || true; fi
  if [[ -n "${TMP_KEY}" ]]; then rm -f "${TMP_KEY}"; fi
}
trap cleanup EXIT

# --- Prérequis ---------------------------------------------------------------

# Quitte avec un message clair si la commande $1 est introuvable.
need_cmd() {
  command -v "$1" &>/dev/null || die "'$1' introuvable — installe-le avant de relancer ce script."
}

need_cmd curl
need_cmd dpkg
need_cmd apt-get

# Exécute une commande en root (directement si on est déjà root).
as_root() {
  if (( EUID == 0 )); then "$@"; else sudo "$@"; fi
}

# Utilisateur à ajouter au groupe docker : celui qui lance le script, ou celui
# qui a appelé sudo. Lancé en root « pur », personne n'est ajouté.
if (( EUID == 0 )); then
  TARGET_USER="${SUDO_USER:-}"
  [[ "${TARGET_USER}" == "root" ]] && TARGET_USER=""
else
  need_cmd sudo
  TARGET_USER="$(id -un)"
  sudo -v || die "Impossible d'obtenir les droits sudo."
  # Keep-alive sudo : s'arrête tout seul si le script meurt (même via SIGKILL).
  # « || true » indispensable : le sous-shell hérite de errexit et mourrait
  # silencieusement au premier « sudo -n true » en échec.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || true; sleep 50; done ) &
  SUDO_LOOP_PID=$!
fi

# --- Détection de la distribution --------------------------------------------

[[ -r /etc/os-release ]] || die "/etc/os-release introuvable."

# Lu dans un sous-shell pour ne pas polluer l'environnement du script.
# UBUNTU_CODENAME est prioritaire : sur Mint, VERSION_CODENAME vaut « wilma »…
{ read -r OS_ID; read -r OS_ID_LIKE; read -r CODENAME; } < <(
  # shellcheck source=/dev/null
  . /etc/os-release
  printf '%s\n' "${ID:-}" "${ID_LIKE:-}" "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
)

if [[ "${OS_ID}" != "ubuntu" && " ${OS_ID_LIKE} " != *" ubuntu "* ]]; then
  die "Distribution non supportée (ID=${OS_ID}, ID_LIKE=${OS_ID_LIKE}). Ce script cible Ubuntu et ses dérivées."
fi

if [[ -z "${CODENAME}" ]] && command -v lsb_release &>/dev/null; then
  CODENAME="$(lsb_release -cs)"
fi
[[ -n "${CODENAME}" ]] || die "Impossible de déterminer le codename Ubuntu."

ARCH="$(dpkg --print-architecture)"

# Vrai si le paquet $1 est installé (et pas seulement « connu » de dpkg).
pkg_installed() {
  dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'
}

# Empreinte publiée par Docker (docs.docker.com/engine/install/ubuntu).
readonly DOCKER_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88"

# Vérifie que la clé $1 est bien la clé de signature de Docker : sans ce
# contrôle, la seule garantie serait TLS. Sans gpg, avertit seulement.
verify_docker_key() {
  local key="$1" gpg_home fprs
  if ! command -v gpg &>/dev/null; then
    warn "gpg absent : empreinte de la clé Docker non vérifiée (apt install gnupg)."
    return 0
  fi
  gpg_home="$(mktemp -d)"
  fprs="$(GNUPGHOME="${gpg_home}" gpg --batch --quiet --with-colons --show-keys "${key}" 2>/dev/null \
            | awk -F: '$1 == "fpr" { print $10 }')" || fprs=""
  rm -rf -- "${gpg_home}"
  grep -qx "${DOCKER_KEY_FPR}" <<<"${fprs}" \
    || die "La clé GPG téléchargée n'a pas l'empreinte attendue (${DOCKER_KEY_FPR})."
  ok "Clé GPG Docker vérifiée (empreinte ${DOCKER_KEY_FPR})."
}

# --- Docker via snap ? -------------------------------------------------------
# Le paquet snap « docker » entre en conflit avec Docker CE : on s'arrête.

if command -v snap &>/dev/null && snap list docker &>/dev/null; then
  err "Docker est installé via snap, ce qui entre en conflit avec Docker CE."
  hint "Désinstalle-le d'abord : sudo snap remove --purge docker" >&2
  exit 1
fi

# --- Installation ------------------------------------------------------------

if pkg_installed docker-ce; then
  info "Docker CE déjà installé : $(docker --version)"
else
  info "Installation de Docker CE – Ubuntu ${CODENAME} (${ARCH})"

  # Paquets en conflit (cf. doc officielle Docker)
  CONFLICTS=()
  for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
    pkg_installed "${pkg}" && CONFLICTS+=("${pkg}")
  done

  if (( ${#CONFLICTS[@]} > 0 )); then
    warn "Paquets en conflit détectés : ${CONFLICTS[*]}"
    hint "Ils vont être désinstallés (les données dans /var/lib/docker sont conservées)."
    if (( ! ASSUME_YES )); then
      [[ -t 0 ]] || die "Pas de terminal pour confirmer — relance avec --yes."
      read -rp "   Continuer ? [o/N] " answer
      [[ "${answer}" =~ ^[oOyY]$ ]] || die "Annulé."
    fi
    # Arrêter d'abord le socket : sinon il reste actif pendant que docker-ce
    # remplace son fichier d'unité, et systemd le déclare inutilisable
    # (« Socket unit configuration has changed while unit has been running »).
    # dockerd ne reçoit alors aucun socket et échoue en boucle.
    if [[ -d /run/systemd/system ]]; then
      as_root systemctl stop docker.socket docker.service 2>/dev/null || true
    fi
    as_root apt-get remove -yqq "${CONFLICTS[@]}"
    ok "Paquets en conflit désinstallés."
  fi

  as_root apt-get update -qq
  as_root apt-get install -yqq ca-certificates

  # Clé GPG : téléchargée d'abord, puis mise en place (pas d'état cassé si curl échoue)
  TMP_KEY="$(mktemp)"
  curl -fsSL --proto '=https' --tlsv1.2 https://download.docker.com/linux/ubuntu/gpg -o "${TMP_KEY}" \
    || die "Téléchargement de la clé GPG Docker impossible."
  verify_docker_key "${TMP_KEY}"
  as_root install -m 0755 -d /etc/apt/keyrings
  as_root install -m 0644 "${TMP_KEY}" /etc/apt/keyrings/docker.asc

  # Supprime les anciennes définitions (sinon apt râle : « Conflicting values set for option Signed-By »)
  as_root rm -f /etc/apt/sources.list.d/docker.list /etc/apt/keyrings/docker.gpg

  # Source APT au format deb822
  as_root tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  as_root apt-get update -qq
  as_root apt-get install -yqq \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin

  ok "$(docker --version) installé."
fi

# --- Service -----------------------------------------------------------------
# Seulement si systemd est le gestionnaire actif (pas dans un conteneur, WSL1…).

if [[ -d /run/systemd/system ]]; then
  # Réparation d'une machine laissée en panne (par exemple par une version
  # précédente de ce script) : un docker.socket en échec ou devenu inutilisable
  # empêche dockerd de démarrer, et « enable --now » ne le relance pas.
  if ! as_root systemctl is-active --quiet docker.service; then
    as_root systemctl reset-failed docker.socket docker.service &>/dev/null || true
    as_root systemctl restart docker.socket &>/dev/null || true
  fi
  as_root systemctl enable --now docker.service containerd.service &>/dev/null \
    || warn "Impossible d'activer le service docker via systemd."
fi

# --- Test de fonctionnement --------------------------------------------------

LOG_FILE="$(mktemp -t install-docker.XXXXXX)"
info "Test avec hello-world…"
if as_root docker run --rm hello-world >> "${LOG_FILE}" 2>&1; then
  ok "Docker fonctionne (détails dans ${LOG_FILE})."
else
  die "Échec du test Docker. Consulte ${LOG_FILE} pour les détails."
fi

# --- Groupe docker -----------------------------------------------------------

if [[ -z "${TARGET_USER}" ]]; then
  warn "Script lancé en root sans utilisateur sudo d'origine : aucun utilisateur ajouté au groupe docker."
  hint "Pour le faire à la main : ${BOLD}sudo usermod -aG docker <utilisateur>"
  exit 0
fi

# `id -nG <user>` lit la base des groupes (état persistant)
if id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qx docker; then
  info "${TARGET_USER} est déjà dans le groupe docker."
else
  as_root usermod -aG docker "${TARGET_USER}"
  ok "${TARGET_USER} ajouté au groupe docker."
fi

# --- Résumé ------------------------------------------------------------------

echo
warn "Le groupe docker donne des droits équivalents à root sur cette machine."

# `id -nG` sans argument donne les groupes actifs du processus courant
if (( EUID != 0 )) && id -nG | tr ' ' '\n' | grep -qx docker; then
  ok "Docker est prêt — tu peux l'utiliser sans sudo."
else
  warn "Le groupe docker n'est pas encore actif dans ta session."
  hint "Déconnecte-toi/reconnecte-toi, ou lance : ${BOLD}newgrp docker"
fi
