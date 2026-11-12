#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-dockhand.sh — installe Dockhand (interface web de gestion Docker)
#                       sur Ubuntu 24.04, via Docker Compose
#
# Le script est idempotent : relancé, il ne réécrit compose.yaml que si son
# contenu change (avec sauvegarde horodatée) et redéploie le conteneur.
# Étapes :
#   1. validation des paramètres et de l'utilisateur propriétaire des données ;
#   2. vérification de Docker (installation optionnelle via
#      DOCKER_INSTALL_SCRIPT), du service et du groupe docker ;
#   3. création des répertoires et écriture de compose.yaml ;
#   4. démarrage, attente du conteneur et détection d'un crash-loop ;
#   5. résumé : URL, chemins, commandes utiles et rappels de sécurité.
#
# Par défaut, Dockhand n'écoute que sur 127.0.0.1 : il monte le socket Docker,
# donc quiconque atteint son interface contrôle l'hôte comme root.
#
# Toute la sortie est aussi enregistrée dans un journal (sans couleurs).
# Fonctionne en root « pur » (LXC sans sudo) comme depuis un compte sudoer.
#
# Dépendances : bash, Docker + plugin compose, sudo (sauf en root), coreutils,
# iproute2 (ss, optionnel). Voir « install-dockhand.sh --help ».

set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="2.0.1"
readonly APP_NAME="dockhand"

# --- Valeurs par défaut (surchargées par l'env puis par les options) --------

BASE_DIR="${BASE_DIR:-/opt/dockhand}"
DOCKHAND_IMAGE="${DOCKHAND_IMAGE:-fnsys/dockhand:latest}"
DOCKHAND_PORT="${DOCKHAND_PORT:-3000}"
DOCKHAND_BIND="${DOCKHAND_BIND:-127.0.0.1}"
DOCKHAND_USER="${DOCKHAND_USER:-}"
CONTAINER_TZ="${CONTAINER_TZ:-Europe/Paris}"
DOCKER_INSTALL_SCRIPT="${DOCKER_INSTALL_SCRIPT:-}"
DO_UPDATE=false

# État partagé entre les étapes.
GROUP_JUST_ADDED=false   # l'utilisateur vient d'entrer dans le groupe docker
TMP_FILES=()             # fichiers temporaires supprimés à la sortie

# --- Affichage ---------------------------------------------------------------
# Bloc commun à tous les scripts du projet. Les couleurs ne sont utilisées que
# si la sortie standard est un terminal et que NO_COLOR (https://no-color.org)
# n'est pas défini.
# Le test [[ -t 1 ]] DOIT être fait avant la redirection globale vers le
# journal, sinon stdout n'est plus un tty et les couleurs disparaissent.

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

# Quitte avec un message clair si la commande $1 est introuvable.
need_cmd() {
  command -v "$1" &>/dev/null || die "'$1' introuvable — installe-le avant de relancer ce script."
}

# Enregistre un fichier temporaire à supprimer par cleanup().
add_tmp() { TMP_FILES+=("$1"); }

# --- Aide --------------------------------------------------------------------

# Affiche l'aide sur stdout.
usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} — installe Dockhand (gestion Docker web) via Docker Compose

Usage : ${SCRIPT_NAME} [options]

Options :
  --dir <chemin>      répertoire d'installation             (défaut : /opt/dockhand)
  --port <n>          port publié sur l'hôte                (défaut : 3000)
  --bind <adresse>    adresse d'écoute sur l'hôte           (défaut : 127.0.0.1)
  --user <login>      propriétaire des données              (défaut : détection auto)
  --image <ref>       image Docker                          (défaut : fnsys/dockhand:latest)
  --tz <zone>         fuseau horaire du conteneur           (défaut : Europe/Paris)
  --update            'docker compose pull' avant démarrage
  -h, --help          affiche cette aide et quitte
  -V, --version       affiche la version et quitte

Variables d'environnement :
  BASE_DIR, DOCKHAND_PORT, DOCKHAND_BIND, DOCKHAND_USER, DOCKHAND_IMAGE,
  CONTAINER_TZ        équivalents des options ci-dessus (les options priment)
  DOCKER_INSTALL_SCRIPT
                      script à exécuter si Docker est absent
                      (par exemple ./install-docker.sh)
  LOG_FILE            chemin du journal (défaut : /tmp/install-dockhand-*.log)
  NO_COLOR            désactive les couleurs si elle est définie

Codes de sortie :
  0    Dockhand est installé et le conteneur tourne
  1    échec, option inconnue ou conteneur instable (voir le journal)
  130  interruption (Ctrl+C, SIGTERM)

Sécurité — à lire avant d'exposer le service :
  Dockhand monte /var/run/docker.sock. Quiconque atteint l'interface obtient
  un contrôle équivalent à root sur l'hôte. L'authentification n'est PAS active
  par défaut : crée le compte admin dès le premier accès.
  D'où le bind sur 127.0.0.1 — passe par un tunnel SSH ou un reverse proxy
  authentifié pour y accéder à distance.
  Rappel : les ports publiés par Docker contournent UFW (chaîne DOCKER-USER),
  un 'ufw deny ${DOCKHAND_PORT}' ne protégera rien.

Notes :
  - Pour une écoute IPv6 explicite : --bind '[::1]'
  - Pour figer l'image : --image fnsys/dockhand@sha256:<digest>
EOF
}

# --- Options -----------------------------------------------------------------

# Lit les options de la ligne de commande ; elles priment sur l'environnement.
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dir)    [[ $# -ge 2 ]] || die "--dir attend une valeur.";    BASE_DIR="$2";        shift 2 ;;
      --port)   [[ $# -ge 2 ]] || die "--port attend une valeur.";   DOCKHAND_PORT="$2";   shift 2 ;;
      --bind)   [[ $# -ge 2 ]] || die "--bind attend une valeur.";   DOCKHAND_BIND="$2";   shift 2 ;;
      --user)   [[ $# -ge 2 ]] || die "--user attend une valeur.";   DOCKHAND_USER="$2";   shift 2 ;;
      --image)  [[ $# -ge 2 ]] || die "--image attend une valeur.";  DOCKHAND_IMAGE="$2";  shift 2 ;;
      --tz)     [[ $# -ge 2 ]] || die "--tz attend une valeur.";     CONTAINER_TZ="$2";    shift 2 ;;
      --update) DO_UPDATE=true; shift ;;
      -h|--help) usage; exit 0 ;;
      -V|--version) printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; exit 0 ;;
      *) usage >&2; echo >&2; die "Option inconnue : $1" ;;
    esac
  done
}

parse_args "$@"

# --- Dépendances minimales (avant toute redirection) -------------------------

if [[ "$(id -u)" -eq 0 ]]; then IS_ROOT=true; else IS_ROOT=false; fi
readonly IS_ROOT

# En root pur (LXC minimal), sudo n'est pas forcément présent : on le remplace.
if [[ "${IS_ROOT}" == true ]] && ! command -v sudo &>/dev/null; then
  sudo() { "$@"; }
  SUDO_IS_SHIM=true
else
  SUDO_IS_SHIM=false
fi
readonly SUDO_IS_SHIM

[[ "${SUDO_IS_SHIM}" == true ]] || need_cmd sudo
for c in id getent mkdir cp cmp mktemp stat awk sed grep tr cut tee date sleep; do
  need_cmd "${c}"
done
unset c
# groupadd / usermod vivent dans /usr/sbin : pas de need_cmd, ils sont
# appelés via sudo et un échec est déjà attrapé par errexit.

# --- Chemins dérivés (figés après le parsing) --------------------------------

[[ "${BASE_DIR}" = /* ]] || die "BASE_DIR doit être un chemin absolu (reçu : '${BASE_DIR}')."
BASE_DIR="${BASE_DIR%/}"
# BASE_DIR est écrit dans compose.yaml : un caractère de contrôle, « : » ou
# « # » y casserait (ou détournerait) la ligne du volume.
[[ "${BASE_DIR}" != *[[:cntrl:]:#]* ]] \
  || die "BASE_DIR contient un caractère interdit (contrôle, « : » ou « # ») : '${BASE_DIR}'."

# Vrai si $1 est un répertoire système ou se trouve dans une arborescence
# système : prepare_dirs donnerait alors ce répertoire à l'utilisateur.
is_system_dir() {
  case "$1" in
    ""|/|/opt|/srv|/home|/root|/mnt|/media|/tmp|/snap) return 0 ;;
    /etc|/etc/*|/usr|/usr/*|/boot|/boot/*|/bin|/bin/*|/sbin|/sbin/*|/lib*) return 0 ;;
    /proc|/proc/*|/sys|/sys/*|/dev|/dev/*|/run|/run/*) return 0 ;;
    /var|/var/tmp|/var/opt|/var/lib|/var/lib/docker|/var/lib/docker/*) return 0 ;;
    /var/log|/var/log/*|/var/spool|/var/spool/*|/var/cache|/var/cache/*) return 0 ;;
    /var/backups|/var/backups/*|/var/mail|/var/mail/*|/var/run|/var/run/*) return 0 ;;
  esac
  return 1
}

# Affiche le compte dont $1 est le dossier personnel (/home/autre,
# /var/lib/postgresql…) ; faux si $1 n'est le dossier d'aucun compte.
home_dir_owner() {
  local name home
  while IFS=: read -r name _ _ _ _ home _; do
    if [[ -n "${home}" && "${1}" == "${home%/}" ]]; then
      printf '%s\n' "${name}"
      return 0
    fi
  done < <(getent passwd 2>/dev/null)
  return 1
}

# Le chemin est contrôlé tel quel et une fois résolu (liens symboliques,
# « .. ») : « /opt/../etc » ou un lien vers /etc sont refusés aussi.
# Le dossier personnel d'un autre compte est refusé dans prepare_dirs, une
# fois l'utilisateur cible connu.
BASE_DIR_REAL="$(realpath -m -- "${BASE_DIR}" 2>/dev/null)" || BASE_DIR_REAL="${BASE_DIR}"
for p in "${BASE_DIR}" "${BASE_DIR_REAL}"; do
  if is_system_dir "${p}"; then
    die "BASE_DIR refusé : '${p}' est un répertoire système." \
        "Choisis un sous-répertoire dédié, par exemple /opt/dockhand."
  fi
done
unset p
readonly BASE_DIR_REAL

readonly BASE_DIR
readonly APP_DIR="${BASE_DIR}"
readonly DATA_DIR="${BASE_DIR}/data"
readonly COMPOSE_FILE="${BASE_DIR}/compose.yaml"

# --- Journalisation globale --------------------------------------------------
# mktemp évite le nom prédictible dans /tmp ; le log est débarrassé
# des séquences ANSI, le terminal les garde.

if [[ -n "${LOG_FILE:-}" ]]; then
  # Un lien symbolique ferait tronquer (puis réécrire) sa cible, peut-être en root.
  [[ ! -L "${LOG_FILE}" ]] \
    || die "LOG_FILE ne doit pas être un lien symbolique : ${LOG_FILE}"
  : > "${LOG_FILE}" || die "Impossible d'écrire dans ${LOG_FILE}."
else
  LOG_FILE="$(mktemp "/tmp/install-dockhand-$(date +%Y%m%d-%H%M%S)-XXXXXX.log")"
fi
readonly LOG_FILE

# On garde les descripteurs d'origine pour pouvoir les restaurer et attendre
# la fin du 'tee' : sans ça, le script rend la main avant que tee n'ait vidé
# son tampon et les sorties s'entrelacent avec le shell appelant.
exec 3>&1 4>&2
exec > >(tee -a "${LOG_FILE}") 2>&1
LOG_TEE_PID=$!

# --- Nettoyage ---------------------------------------------------------------

# Exécuté à la sortie : arrête le keep-alive sudo, supprime les fichiers
# temporaires et finalise le journal.
cleanup() {
  if [[ -n "${SUDO_LOOP_PID:-}" ]]; then
    kill "${SUDO_LOOP_PID}" 2>/dev/null || true
  fi
  if (( ${#TMP_FILES[@]} > 0 )); then
    rm -f "${TMP_FILES[@]}" 2>/dev/null || true
  fi

  # Rendre stdout/stderr d'origine, laisser tee finir, puis nettoyer les
  # séquences ANSI du journal (le terminal, lui, les a bien reçues).
  if [[ -n "${LOG_TEE_PID:-}" ]]; then
    exec 1>&3 2>&4
    wait "${LOG_TEE_PID}" 2>/dev/null || true
    sed -i -e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' -e 's/\r//g' "${LOG_FILE}" 2>/dev/null || true
  fi
}

# Ctrl+C ou SIGTERM : sortie propre avec le code conventionnel 130.
on_signal() {
  echo
  warn "Interruption reçue — arrêt."
  exit 130
}

trap cleanup EXIT
trap on_signal INT TERM

# --- Validation des paramètres -----------------------------------------------

# Contrôle le port, l'image, le fuseau horaire et l'adresse d'écoute ;
# avertit bruyamment si le service est exposé sur toutes les interfaces.
validate_params() {
  [[ "${DOCKHAND_PORT}" =~ ^0*[0-9]{1,5}$ ]] \
    || die "Le port doit être un nombre de 1 à 65535 (reçu : '${DOCKHAND_PORT}')."
  # 10# : sans lui, bash lit « 08 » comme de l'octal invalide et « 0070 »
  # comme 56. Le port est normalisé (0070 → 70), compose reçoit la même valeur.
  DOCKHAND_PORT=$(( 10#${DOCKHAND_PORT} ))
  (( DOCKHAND_PORT >= 1 && DOCKHAND_PORT <= 65535 )) \
    || die "Port hors plage 1-65535 (reçu : ${DOCKHAND_PORT})."
  (( DOCKHAND_PORT >= 1024 )) || [[ "${IS_ROOT}" == true ]] \
    || warn "Port privilégié (${DOCKHAND_PORT}) — Docker s'en charge, mais vérifie l'absence de conflit."

  [[ -n "${DOCKHAND_IMAGE}" ]] || die "DOCKHAND_IMAGE ne peut pas être vide."
  [[ -n "${CONTAINER_TZ}" ]]   || die "CONTAINER_TZ ne peut pas être vide."

  # Ces valeurs sont recopiées dans compose.yaml : seuls les caractères
  # légitimes sont admis, pour qu'aucune ne puisse y ajouter une ligne.
  [[ "${DOCKHAND_IMAGE}" =~ ^[A-Za-z0-9._/:@-]+$ ]] \
    || die "DOCKHAND_IMAGE contient des caractères non autorisés : '${DOCKHAND_IMAGE}'."
  [[ "${CONTAINER_TZ}" =~ ^[A-Za-z0-9._/+-]+$ ]] \
    || die "CONTAINER_TZ contient des caractères non autorisés : '${CONTAINER_TZ}'."
  local bind_re='^[][A-Za-z0-9.:-]*$'   # « ] » et « [ » en tête de classe
  [[ "${DOCKHAND_BIND}" =~ ${bind_re} ]] \
    || die "DOCKHAND_BIND contient des caractères non autorisés : '${DOCKHAND_BIND}'."

  case "${DOCKHAND_BIND}" in
    127.*|localhost|'[::1]') : ;;
    0.0.0.0|'[::]'|'')
      warn "Écoute sur TOUTES les interfaces (${DOCKHAND_BIND:-0.0.0.0})."
      warn "Dockhand a un accès complet au socket Docker et démarre sans authentification :"
      warn "toute machine du réseau peut prendre la main sur l'hôte tant que le compte admin n'existe pas."
      warn "Rappel : Docker publie ses ports en contournant UFW."
      ;;
    *)
      info "Écoute restreinte à ${DOCKHAND_BIND}."
      warn "Dockhand sera joignable par toutes les machines qui atteignent ${DOCKHAND_BIND}."
      ;;
  esac
}

# --- Utilisateur cible -------------------------------------------------------

# Devine l'utilisateur « humain » derrière sudo : SUDO_USER, puis logname,
# puis USER. Refuse de choisir root par défaut.
get_real_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"; return
  fi

  local lname
  if lname="$(logname 2>/dev/null)" && [[ -n "${lname}" && "${lname}" != "root" ]]; then
    echo "${lname}"; return
  fi

  if [[ "${USER:-root}" == "root" ]]; then
    die \
      "Impossible de déterminer un utilisateur non-root." \
      "Lance ce script via sudo depuis un compte normal," \
      "ou précise la cible : ${SCRIPT_NAME} --user <login>"
  fi

  echo "${USER}"
}

# Fixe REAL_USER / REAL_UID / REAL_GID (option --user ou détection auto).
resolve_user() {
  REAL_USER="${DOCKHAND_USER:-$(get_real_user)}"
  id "${REAL_USER}" &>/dev/null || die "L'utilisateur '${REAL_USER}' n'existe pas."
  REAL_UID="$(id -u "${REAL_USER}")"
  REAL_GID="$(id -g "${REAL_USER}")"
  readonly REAL_USER REAL_UID REAL_GID
  info "Utilisateur cible : ${REAL_USER} (${REAL_UID}:${REAL_GID})"
}

# --- Sudo keep-alive ---------------------------------------------------------

# Garde le ticket sudo valide pendant toute l'installation (inutile en root).
start_sudo_keepalive() {
  [[ "${SUDO_IS_SHIM}" == true ]] && return 0
  [[ "${IS_ROOT}" == true ]] && return 0

  sudo -v || die "Impossible d'obtenir les droits sudo."

  # '|| true' indispensable : le sous-shell hérite de errexit et mourrait
  # silencieusement au premier 'sudo -n true' en échec.
  ( while true; do sudo -n true 2>/dev/null || true; sleep 50; done ) &
  SUDO_LOOP_PID=$!
}

# --- Docker ------------------------------------------------------------------

# Vérifie la présence de Docker et du plugin compose ; lance
# DOCKER_INSTALL_SCRIPT si Docker est absent et que ce script est fourni.
ensure_docker() {
  if command -v docker &>/dev/null; then
    ok "Docker déjà installé : $(docker --version)"
  else
    warn "Docker n'est pas installé."

    [[ -n "${DOCKER_INSTALL_SCRIPT}" ]] \
      || die "Docker absent. Définis DOCKER_INSTALL_SCRIPT ou installe Docker avant."
    [[ -f "${DOCKER_INSTALL_SCRIPT}" ]] \
      || die "Script Docker introuvable : ${DOCKER_INSTALL_SCRIPT}"
    [[ -x "${DOCKER_INSTALL_SCRIPT}" ]] || chmod +x "${DOCKER_INSTALL_SCRIPT}"

    info "Exécution du script Docker fourni : ${DOCKER_INSTALL_SCRIPT}"
    "${DOCKER_INSTALL_SCRIPT}"

    command -v docker &>/dev/null \
      || die "Docker est toujours introuvable après l'installation."
  fi

  docker compose version &>/dev/null \
    || die "Le plugin 'docker compose' est introuvable."
  ok "Plugin Docker Compose disponible."
}

# S'assure que le démon Docker tourne (via systemd si disponible).
ensure_docker_running() {
  if command -v systemctl &>/dev/null && [[ -d /run/systemd/system ]]; then
    if ! systemctl is-active --quiet docker; then
      info "Le service Docker n'est pas actif, tentative de démarrage…"
      sudo systemctl start docker
      sudo systemctl enable docker
    fi
    systemctl is-active --quiet docker || die "Impossible de démarrer le service Docker."
    ok "Service Docker actif."
  else
    sudo docker info &>/dev/null \
      || die "Le démon Docker ne répond pas et systemd n'est pas disponible." \
             "Démarre Docker manuellement avant de relancer ce script."
    ok "Démon Docker accessible."
  fi
}

# Ajoute REAL_USER au groupe docker si besoin et mémorise le GID du groupe,
# transmis au conteneur pour qu'il puisse lire le socket.
ensure_docker_group() {
  if ! getent group docker &>/dev/null; then
    info "Création du groupe docker"
    sudo groupadd docker
  fi

  if id -nG "${REAL_USER}" | tr ' ' '\n' | grep -qx docker; then
    info "${REAL_USER} est déjà dans le groupe docker."
  else
    info "Ajout de ${REAL_USER} au groupe docker"
    sudo usermod -aG docker "${REAL_USER}"
    ok "${REAL_USER} ajouté au groupe docker."
    GROUP_JUST_ADDED=true
  fi

  DOCKER_GID="$(getent group docker | cut -d: -f3)"
  [[ -n "${DOCKER_GID}" ]] || die "Impossible de déterminer le GID du groupe docker."
  readonly DOCKER_GID
}

# --- Répertoires — chown ciblé, jamais récursif sur le contenu ---------------

# Crée APP_DIR et DATA_DIR, ou corrige uniquement leur propriétaire :
# le contenu existant n'est jamais modifié.
prepare_dirs() {
  local d cur owner
  # Donner à REAL_USER le dossier personnel d'un autre compte lui en
  # remettrait les clés (~/.ssh, ~/.bashrc…).
  for d in "${BASE_DIR}" "${BASE_DIR_REAL}"; do
    if owner="$(home_dir_owner "${d}")" && [[ "${owner}" != "${REAL_USER}" ]]; then
      die "BASE_DIR refusé : '${d}' est le dossier personnel de ${owner}." \
          "Choisis un sous-répertoire dédié, par exemple /opt/dockhand."
    fi
  done

  for d in "${APP_DIR}" "${DATA_DIR}"; do
    if [[ ! -d "${d}" ]]; then
      info "Création de ${d}"
      sudo mkdir -p "${d}"
      sudo chown "${REAL_UID}:${REAL_GID}" "${d}"
      continue
    fi

    cur="$(stat -c '%u:%g' "${d}")"
    if [[ "${cur}" != "${REAL_UID}:${REAL_GID}" ]]; then
      info "Correction du propriétaire de ${d} (${cur} → ${REAL_UID}:${REAL_GID})"
      sudo chown "${REAL_UID}:${REAL_GID}" "${d}"
    fi
  done
}

# --- Port --------------------------------------------------------------------

# Vrai si le conteneur « dockhand » existe et est en cours d'exécution.
dockhand_container_running() {
  sudo docker ps \
    --filter "name=^/${APP_NAME}$" \
    --filter "status=running" \
    --format '{{.Names}}' 2>/dev/null | grep -qx "${APP_NAME}"
}

# Vrai si un processus écoute déjà en TCP sur DOCKHAND_PORT.
port_is_listening() {
  local addr
  while read -r addr; do
    case "${addr}" in
      *:"${DOCKHAND_PORT}") return 0 ;;
    esac
  done < <(ss -ltnH 2>/dev/null | awk '{print $4}')
  return 1
}

# Refuse de continuer si le port est pris par autre chose que Dockhand
# lui-même (une relance sur une installation existante reste possible).
check_port_available() {
  if ! command -v ss &>/dev/null; then
    warn "Commande 'ss' absente — contrôle du port ignoré."
    return 0
  fi

  port_is_listening || return 0

  if dockhand_container_running; then
    info "Port ${DOCKHAND_PORT} occupé par le conteneur ${APP_NAME} existant — relance idempotente."
    return 0
  fi

  die "Le port ${DOCKHAND_PORT} est déjà utilisé par un autre processus." \
      "Identifie-le avec : sudo ss -ltnp | grep ':${DOCKHAND_PORT}'" \
      "puis relance avec --port <autre_port>."
}

# --- Compose -----------------------------------------------------------------

# Génère compose.yaml dans un fichier temporaire, puis ne remplace le fichier
# en place que s'il diffère (l'ancien est sauvegardé avec un horodatage).
write_compose() {
  local tmpfile backup
  tmpfile="$(mktemp)"
  add_tmp "${tmpfile}"

  cat > "${tmpfile}" <<EOF
services:
  ${APP_NAME}:
    image: ${DOCKHAND_IMAGE}
    container_name: ${APP_NAME}
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "${DOCKHAND_BIND}:${DOCKHAND_PORT}:3000"
    environment:
      PUID: "${REAL_UID}"
      PGID: "${REAL_GID}"
      TZ: "${CONTAINER_TZ}"
    group_add:
      - "${DOCKER_GID}"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ${DATA_DIR}:/app/data
EOF

  if [[ -f "${COMPOSE_FILE}" ]]; then
    if cmp -s "${tmpfile}" "${COMPOSE_FILE}"; then
      info "${COMPOSE_FILE} est déjà à jour."
      return 0
    fi

    backup="${COMPOSE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
    warn "${COMPOSE_FILE} existe déjà et va être mis à jour."
    warn "Sauvegarde : ${backup}"
    sudo cp -p "${COMPOSE_FILE}" "${backup}"
    sudo chown "${REAL_UID}:${REAL_GID}" "${backup}"
  fi

  info "Écriture de ${COMPOSE_FILE}"
  sudo cp "${tmpfile}" "${COMPOSE_FILE}"
  sudo chown "${REAL_UID}:${REAL_GID}" "${COMPOSE_FILE}"
  sudo chmod 640 "${COMPOSE_FILE}"
}

# Raccourci : docker compose sur le fichier généré, sans couleurs ANSI.
compose() {
  sudo docker compose --ansi never -f "${COMPOSE_FILE}" "$@"
}

# Récupère l'image si --update, puis (re)démarre le conteneur.
start_dockhand() {
  if [[ "${DO_UPDATE}" == true ]]; then
    info "Récupération de la dernière image (${DOCKHAND_IMAGE})"
    compose pull
  fi
  info "Démarrage de Dockhand"
  compose up -d
}

# --- Vérification ------------------------------------------------------------

# Attend jusqu'à 30 s que le conteneur soit « running ».
wait_running() {
  local retries=15 delay=2 i

  info "Attente du conteneur ${APP_NAME}…"
  for (( i = 1; i <= retries; i++ )); do
    if dockhand_container_running; then
      ok "Conteneur ${APP_NAME} en cours d'exécution."
      return 0
    fi
    sleep "${delay}"
  done

  err "Le conteneur ${APP_NAME} n'est pas actif après $(( retries * delay ))s."
  err "Diagnostic : sudo docker logs ${APP_NAME}"
  return 1
}

# Détecte un crash-loop : un conteneur qui redémarre en boucle peut
# apparaître « running » à un instant donné.
check_stability() {
  # 'restart: unless-stopped' peut masquer un crash-loop derrière un statut "running".
  local restarts
  sleep 3
  restarts="$(sudo docker inspect -f '{{.RestartCount}}' "${APP_NAME}" 2>/dev/null || echo 0)"

  if [[ "${restarts}" =~ ^[0-9]+$ ]] && (( restarts > 0 )); then
    warn "Le conteneur a déjà redémarré ${restarts} fois — probable crash-loop."
    warn "Inspecte : sudo docker logs ${APP_NAME}"
    warn "Si l'échec vient de 'no-new-privileges', retire cette ligne de ${COMPOSE_FILE}."
    return 1
  fi

  dockhand_container_running || {
    err "Le conteneur s'est arrêté juste après le démarrage."
    return 1
  }
  return 0
}

# --- Résumé ------------------------------------------------------------------

# Affiche le résumé final. $1 = « ok » ou « failed ».
show_status() {
  local status="$1" host_ip url_net

  echo
  if [[ "${status}" == "ok" ]]; then
    ok "Dockhand installé et opérationnel."
  else
    err "Installation incomplète — voir les messages ci-dessus."
  fi

  local url_local="http://127.0.0.1:${DOCKHAND_PORT}"
  case "${DOCKHAND_BIND}" in
    0.0.0.0|'[::]'|'')
      host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
      url_net="http://${host_ip:-<IP_DU_SERVEUR>}:${DOCKHAND_PORT}"
      ;;
    127.*|localhost|'[::1]')
      url_local="http://${DOCKHAND_BIND/localhost/127.0.0.1}:${DOCKHAND_PORT}"
      url_net="(non exposé — bind sur ${DOCKHAND_BIND})"
      ;;
    *)
      # Écoute sur une seule adresse : rien sur 127.0.0.1, mais le service
      # est exposé à tout le réseau de cette interface.
      url_local="(aucune — bind sur ${DOCKHAND_BIND})"
      url_net="http://${DOCKHAND_BIND}:${DOCKHAND_PORT} (exposé sur ce réseau)"
      ;;
  esac

  printf '%s\n' "${CYAN}URL locale           : ${BOLD}${url_local}${RESET}"
  printf '%s\n' "${CYAN}URL réseau           : ${BOLD}${url_net}${RESET}"
  printf '%s\n' "${CYAN}Compose              : ${BOLD}${COMPOSE_FILE}${RESET}"
  printf '%s\n' "${CYAN}Données              : ${BOLD}${DATA_DIR}${RESET}"
  printf '%s\n' "${CYAN}Image                : ${BOLD}${DOCKHAND_IMAGE}${RESET}"
  printf '%s\n' "${CYAN}Fuseau horaire       : ${BOLD}${CONTAINER_TZ}${RESET}"
  printf '%s\n' "${CYAN}Journal              : ${BOLD}${LOG_FILE}${RESET}"
  echo

  echo "Commandes utiles :"
  echo "  sudo docker logs -f ${APP_NAME}"
  echo "  sudo docker compose -f ${COMPOSE_FILE} pull && sudo docker compose -f ${COMPOSE_FILE} up -d"
  echo "  sudo docker compose -f ${COMPOSE_FILE} down"
  echo "  ${SCRIPT_NAME} --update        # met à jour l'image et redéploie"
  echo

  if [[ "${status}" == "ok" ]]; then
    case "${DOCKHAND_BIND}" in
      0.0.0.0|'[::]'|'') : ;;
      *)
        echo "Accès distant recommandé (tunnel SSH depuis ton poste) :"
        printf '%s\n' "  ${BOLD}ssh -N -L ${DOCKHAND_PORT}:${DOCKHAND_BIND}:${DOCKHAND_PORT} ${REAL_USER}@<serveur>${RESET}"
        echo
        ;;
    esac
    warn "Première action à faire MAINTENANT : ouvrir l'interface et créer le compte admin."
    warn "Tant qu'aucun compte n'existe, l'accès est libre — et le socket Docker monté"
    warn "donne un contrôle équivalent à root sur l'hôte."
    echo
  fi

  if [[ "${GROUP_JUST_ADDED}" == true ]]; then
    warn "Le groupe docker vient d'être ajouté à ${REAL_USER}."
    hint "Pour utiliser docker sans sudo : ${BOLD}newgrp docker"
    hint "Ou déconnecte-toi et reconnecte-toi."
  elif [[ "${IS_ROOT}" == false ]] && id -nG | tr ' ' '\n' | grep -qx docker; then
    ok "Docker est utilisable sans sudo dans ce shell."
  fi
}

# --- Main --------------------------------------------------------------------

# Enchaîne les étapes de l'installation.
main() {
  info "Début de l'installation de ${APP_NAME}"
  info "Journal : ${LOG_FILE}"
  echo

  validate_params
  resolve_user
  start_sudo_keepalive
  ensure_docker
  ensure_docker_running
  ensure_docker_group
  prepare_dirs
  check_port_available
  write_compose
  start_dockhand

  if ! wait_running; then
    show_status failed
    exit 1
  fi

  if ! check_stability; then
    show_status failed
    exit 1
  fi

  show_status ok
}

main

