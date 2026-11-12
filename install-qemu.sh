#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-qemu.sh — installe QEMU/KVM et libvirt sur Ubuntu 24.04 et ses
#                   dérivées (Pop!_OS 24.04, Linux Mint 22, Zorin OS 18…)
#
#   sudo install-qemu.sh             installation complète, avec virt-manager
#   sudo install-qemu.sh --server    sans outils graphiques
#   install-qemu.sh --dry-run        simulation, sans rien modifier (sans sudo)
#
# Le script est idempotent : il peut être relancé sans risque. Il :
#   1. vérifie la distribution (base Ubuntu 24.04 « noble ») ;
#   2. vérifie que l'accélération KVM est disponible (sauf --force) ;
#   3. installe QEMU, libvirt, OVMF (UEFI) et swtpm (TPM virtuel) ;
#   4. active libvirtd et ajoute l'utilisateur aux groupes libvirt et kvm ;
#   5. active et démarre le réseau NAT « default » de libvirt.
#
# ⚠️  Les groupes libvirt et kvm permettent de piloter les VM du système :
#    réserve-les aux comptes de confiance.
#
# Dépendances : bash, apt-get, systemd, sudo (sauf si lancé en root).
# Voir « install-qemu.sh --help ».

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
# Version du script. À augmenter à chaque modification :
# 1.1.3 → 1.1.4 pour une correction, 1.2.0 pour une nouvelle option.
readonly SCRIPT_VERSION="1.2.1"

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

# Toute commande en échec non gérée arrête le script en indiquant la ligne.
trap 'err "Échec ligne ${LINENO} : ${BASH_COMMAND}"' ERR

# --- Aide --------------------------------------------------------------------

# Affiche l'aide sur stdout.
usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} — installe QEMU/KVM et libvirt (Ubuntu 24.04 et dérivées)

Usage : sudo ${SCRIPT_NAME} [options]

Options :
  --server         sans outils graphiques (ni virt-manager, ni virt-viewer)
  --force          installe même si l'accélération KVM est indisponible
  --dry-run        simule l'installation sans rien modifier (sudo non requis)
  -h, --help       affiche cette aide et quitte
  -V, -v, --version
                   affiche la version de ce script et quitte

Variables d'environnement :
  NO_COLOR         désactive les couleurs si elle est définie

Codes de sortie :
  0  installation terminée, ou simulation réussie
  1  échec : distribution non supportée, KVM indisponible sans --force,
     option inconnue, libvirtd inactif…

Notes :
  - Le test KVM utilise « kvm-ok » (paquet cpu-checker, installé au besoin).
    En --dry-run, il n'est fait que si cpu-checker est déjà présent.
  - La simulation APT utilise l'index local, sans « apt-get update ».
  - L'utilisateur qui a lancé sudo est ajouté aux groupes libvirt et kvm :
    il doit se déconnecter puis se reconnecter pour en profiter.
  - Connexion libvirt : qemu:///system.
EOF
}

# --- Options -----------------------------------------------------------------

SERVER_MODE=false
FORCE=false
DRY_RUN=false

for arg in "$@"; do
  case "${arg}" in
    --server)  SERVER_MODE=true ;;
    --force)   FORCE=true ;;
    --dry-run) DRY_RUN=true ;;
    -V|-v|--version)
      printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
      exit 0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "Option inconnue : ${arg} (voir --help)" ;;
  esac
done
unset arg

# --- Vérification du système -------------------------------------------------

[[ -r /etc/os-release ]] || die "/etc/os-release introuvable."

# Lu dans un sous-shell : /etc/os-release définit des variables (VERSION, ID,
# NAME…) qui ne doivent pas écraser celles du script.
#
# Distributions acceptées : Ubuntu 24.04 et ses dérivées. Une dérivée déclare
# « ubuntu » dans ID_LIKE et la base Ubuntu dans UBUNTU_CODENAME. On teste le
# nom de code (noble) plutôt que VERSION_ID, car les dérivées ont leur propre
# numéro de version.
{ read -r OS_ID; read -r OS_ID_LIKE; read -r OS_CODENAME; read -r OS_NAME; } < <(
  # shellcheck source=/dev/null
  . /etc/os-release
  printf '%s\n' "${ID:-}" "${ID_LIKE:-}" \
    "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" "${PRETTY_NAME:-inconnu}"
)

if [[ "${OS_ID}" != "ubuntu" && " ${OS_ID_LIKE} " != *" ubuntu "* ]]; then
  die "Ubuntu 24.04 ou dérivée requise (détecté : ${OS_NAME})."
fi

if [[ "${OS_CODENAME}" != "noble" ]]; then
  die "Base Ubuntu 24.04 (noble) requise (détecté : ${OS_NAME}, base : ${OS_CODENAME:-inconnue})."
fi

if [[ "${OS_ID}" != "ubuntu" ]]; then
  info "Dérivée d'Ubuntu détectée : ${OS_NAME} (base noble)."
fi

# --- Paquets -----------------------------------------------------------------

PACKAGES=(
  qemu-system-x86
  qemu-utils
  libvirt-daemon-system
  libvirt-clients
  virtinst
  ovmf
  swtpm
  swtpm-tools
)

if [[ "${SERVER_MODE}" != true ]]; then
  PACKAGES+=(
    qemu-system-gui
    virt-manager
    virt-viewer
  )
fi

# --- Simulation (sans root) --------------------------------------------------

if [[ "${DRY_RUN}" == true ]]; then
  step "🧪 Simulation de l'installation QEMU/KVM (${SCRIPT_NAME} ${SCRIPT_VERSION})"
  log "   Mode serveur    : ${SERVER_MODE}"
  log "   Forcer sans KVM : ${FORCE}"
  log
  log "Paquets concernés :"
  printf '  - %s\n' cpu-checker "${PACKAGES[@]}"
  log

  step "🔍 Vérification KVM"
  if command -v kvm-ok >/dev/null; then
    if kvm-ok; then
      ok "KVM disponible : l'installation réelle continuerait."
    elif [[ "${FORCE}" == true ]]; then
      warn "KVM indisponible : l'installation réelle continuerait (--force)."
    else
      warn "KVM indisponible : l'installation réelle s'arrêterait (sauf --force)."
    fi
  else
    info "kvm-ok absent (paquet cpu-checker) : test KVM non effectué."
  fi
  log

  step "📦 Simulation APT"
  info "Simulation faite avec l'index APT local, sans « apt-get update »."
  apt-get -s install cpu-checker "${PACKAGES[@]}"
  log
  ok "Aucune modification effectuée."
  exit 0
fi

# --- Droits root -------------------------------------------------------------

[[ "${EUID}" -eq 0 ]] \
  || die "Lance ce script avec sudo (ou utilise --dry-run)."

export DEBIAN_FRONTEND=noninteractive

# --- Mise à jour des dépôts --------------------------------------------------

step "🔄 Mise à jour des dépôts"
apt-get update

# --- Vérification KVM --------------------------------------------------------

step "🔍 Vérification de la virtualisation"

apt-get install -y cpu-checker

if kvm-ok; then
  ok "Accélération KVM disponible."
else
  if systemd-detect-virt --quiet; then
    warn "Environnement virtualisé détecté."
    hint "Vérifie la virtualisation imbriquée sur l'hôte."
  else
    hint "Vérifie VT-x / AMD-V dans le BIOS/UEFI."
  fi

  if [[ "${FORCE}" != true ]]; then
    die "Arrêt : KVM indisponible." \
        "Utilise --force pour installer sans accélération."
  fi

  warn "Installation sans KVM : les VM seront très lentes."
fi

# --- Installation ------------------------------------------------------------

step "📦 Installation de QEMU/KVM"
apt-get install -y "${PACKAGES[@]}"

# --- Activation de libvirt ---------------------------------------------------
# Sur Ubuntu 24.04, libvirtd est lancé à la demande et s'arrête après
# 2 minutes sans activité : le test ci-dessous n'est valable qu'ici.

step "🧩 Activation de libvirt"

systemctl enable --now libvirtd.service

if systemctl is-active --quiet libvirtd.service; then
  ok "Service libvirtd actif."
else
  die "libvirtd ne fonctionne pas."
fi

# --- Configuration utilisateur -----------------------------------------------

step "👤 Configuration utilisateur"

TARGET_USER="${SUDO_USER:-}"

if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]]; then
  if id "${TARGET_USER}" &>/dev/null; then
    usermod -aG libvirt,kvm "${TARGET_USER}"
    ok "Utilisateur ${TARGET_USER} ajouté aux groupes libvirt et kvm."
  else
    warn "Utilisateur ${TARGET_USER} introuvable."
  fi
else
  info "Aucun utilisateur non-root détecté."
fi

# --- Réseau NAT --------------------------------------------------------------

step "🌐 Configuration du réseau NAT"

if NET_INFO="$(LC_ALL=C virsh -c qemu:///system net-info default 2>/dev/null)"; then

  virsh -c qemu:///system net-autostart default

  # La sortie est lue en entier avant le test : avec « virsh … | grep -q »,
  # grep s'arrête à la première ligne trouvée, virsh reçoit SIGPIPE (code 141)
  # et pipefail fait échouer le test alors que le réseau est actif.
  if grep -qE '^Active:[[:space:]]+yes' <<<"${NET_INFO}"; then
    info "Réseau NAT default déjà actif."
  elif virsh -c qemu:///system net-start default; then
    ok "Réseau NAT default démarré."
  else
    warn "Impossible de démarrer le réseau NAT."
  fi

else
  warn "Réseau default absent."
  hint "Une configuration réseau manuelle peut être nécessaire."
fi

# --- Vérifications finales ---------------------------------------------------

log
step "✔️  Vérifications finales"

log
log "Version QEMU :"
qemu-system-x86_64 --version | sed -n 1p

log
log "Machines virtuelles :"
virsh -c qemu:///system list --all

log
log "Accélération matérielle :"

if [[ -e /dev/kvm ]]; then
  ls -l /dev/kvm
  ok "Périphérique KVM présent."
else
  warn "/dev/kvm absent."
fi

log
ok "Installation terminée (${SCRIPT_NAME} ${SCRIPT_VERSION})."

if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]]; then
  hint "Déconnecte-toi puis reconnecte-toi pour appliquer les groupes."
fi

if [[ "${SERVER_MODE}" != true ]]; then
  info "Interface graphique : virt-manager"
fi

info "CLI : virsh, virt-install, qemu-img"
info "Connexion libvirt : qemu:///system"
