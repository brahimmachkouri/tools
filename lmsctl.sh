#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# lmsctl — pilotage CLI de LM Studio en mode headless (démon llmster)
#
# Remplace l'AppImage desktop + session graphique par llmster et une unité
# systemd. Aucune dépendance à X11, Wayland ou D-Bus.
#
#   lmsctl install     installe llmster, écrit l'unité, l'active et la démarre
#   lmsctl update      met à jour llmster avec sauvegarde et rollback ciblé
#   lmsctl configure   applique la configuration avec rollback ciblé de l'unité
#   lmsctl check       valide la configuration et l'unité sans les installer
#   lmsctl start|stop|restart|status|health|logs|models
#   lmsctl uninstall   retire l'unité (llmster et les modèles restent)
#
# Configuration : /etc/default/lmstudio-headless (voir « lmsctl help »).
#
# Principes :
#   - l'installeur officiel est téléchargé et contrôlé avant l'arrêt ;
#   - ~/.lmstudio/bin est copié réellement dans /var/backups avant mutation, et
#     l'inventaire des versions du démon (~/.lmstudio/llmster/<version>) est
#     relevé : une restauration réécarte les versions apparues pendant
#     l'opération, sinon l'ancien shim se retrouverait face à un démon plus
#     récent. Les artefacts fautifs sont conservés par exécution, sans écraser
#     ceux d'un échec précédent ;
#   - toute erreur de mise à jour, de génération de l'unité, de démarrage ou de
#     santé déclenche une restauration, par une unique fonction « recover » ;
#   - la sonde de santé essaie /api/v1/models puis retombe sur /v1/models, et
#     distingue « serveur muet » de « serveur vivant qui rejette la sonde » :
#     un jeton mal réglé ne doit jamais déclencher de restauration ;
#   - aucun modèle n'est rechargé aveuglément après une mise à jour. Cela évite
#     un double chargement et un OOM. PRELOAD_MODEL fournit le chargement
#     déterministe ; sinon le prochain appel peut déclencher le JIT. Le
#     préchargement a lieu après le démarrage de l'API et n'est pas bloquant :
#     un modèle introuvable ou trop gros ne doit pas faire annuler une mise à
#     jour saine du binaire. Son échec est signalé par le code de sortie 3 ;
#   - systemd ne voit qu'un oneshot : il ne peut pas relancer llmster s'il
#     tombe. Un timer de surveillance (WATCHDOG_INTERVAL) sonde l'API et
#     redémarre le service après plusieurs sondes muettes consécutives. Il
#     s'efface devant lmsctl (même verrou) et ignore un service arrêté ;
#   - LM Link est réactivé après le serveur, avec une attente strictement bornée,
#     afin qu'un Mac hors ligne ne bloque jamais le démarrage de l'API ;
#   - l'écoute réseau est locale par défaut. Une écoute LAN doit être protégée
#     par l'authentification LM Studio et un pare-feu ;
#   - les artefacts d'échec sont conservés par exécution puis purgés au-delà de
#     FAILED_RETENTION exécutions, après chaque opération réussie ou échouée :
#     un bundle de démon pèse lourd sur une machine dédiée aux poids de
#     modèles. La quarantaine de l'échec en cours n'est jamais purgée.
#
# Dépendances : bash ≥ 4.4, systemd, util-linux (runuser, flock), coreutils,
# curl, iproute2 (ss), procps (pgrep), findutils. Voir « lmsctl help ».

# Vérifié avant « set -u » et avant toute fonction : un Bash trop ancien
# échouerait plus loin avec des erreurs incompréhensibles.
if [[ -z "${BASH_VERSINFO:-}" ]] \
  || (( BASH_VERSINFO[0] < 4 )) \
  || { (( BASH_VERSINFO[0] == 4 )) && (( BASH_VERSINFO[1] < 4 )); }; then
  printf '%s\n' \
    "Ce script requiert Bash 4.4 ou supérieur (mapfile, tableaux vides sous set -u)." >&2
  exit 1
fi

set -Eeuo pipefail
umask 022

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0-rc8"
# Surchargeable (tests, instances multiples) ; le fichier désigné subit les
# mêmes contrôles de propriétaire et de droits dans load_config.
readonly CONFIG_FILE="${LMSCTL_CONFIG:-/etc/default/lmstudio-headless}"
readonly INSTALLER_URL="https://lmstudio.ai/install.sh"

# --- Affichage ---------------------------------------------------------------
# Bloc commun à tous les scripts du projet. Les couleurs ne sont utilisées que
# si la sortie standard est un terminal et que NO_COLOR (https://no-color.org)
# n'est pas défini : un journal, un pipe ou une supervision reçoit ainsi
# exactement le même texte, sans séquences ANSI.

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

# --- Erreurs et nettoyage ----------------------------------------------------

# Toute commande en échec non gérée arrête le script en indiquant la ligne et
# en conservant son code de sortie.
on_err() {
  local exit_code=$?
  err "Échec ligne ${BASH_LINENO[0]} : ${BASH_COMMAND} (code ${exit_code})"
  exit "${exit_code}"
}
trap on_err ERR

WORK_DIR=""     # répertoire temporaire de l'exécution (mktemp -d)
RUN_ID=""       # horodatage UTC + PID, identifie la quarantaine de cet essai
FAILED_DIR=""   # ${BACKUP_DIR}/failed/${RUN_ID}

# Supprime le répertoire de travail temporaire à la sortie.
cleanup() {
  if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
    rm -rf -- "${WORK_DIR}"
  fi
}
trap cleanup EXIT

# --- Configuration -----------------------------------------------------------

# Aucune valeur par défaut arbitraire : l'utilisateur ayant invoqué sudo est le
# choix le moins surprenant, à défaut la configuration doit être explicite.
LMS_USER="${LMS_USER:-${SUDO_USER:-}}"
SERVICE_NAME="${SERVICE_NAME:-lmstudio}"
SERVER_PORT="${SERVER_PORT:-1234}"
# Local par défaut. Utiliser 0.0.0.0 uniquement avec authentification + pare-feu.
BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
# Vide = aucun préchargement. Le JIT doit être activé séparément dans LM Studio.
PRELOAD_MODEL="${PRELOAD_MODEL:-}"
# Arguments lms load, ex. "--context-length 65536 --gpu 1.0".
LOAD_ARGS="${LOAD_ARGS:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-180}"
# LM Link suppose un compte LM Studio connecté : désactivé par défaut. Une fois
# activé, une absence de connexion ne bloque jamais le démarrage de l'API.
ENABLE_LM_LINK="${ENABLE_LM_LINK:-false}"
# Fichier root:root 0600 contenant uniquement le jeton API, si auth activée.
API_TOKEN_FILE="${API_TOKEN_FILE:-}"
# Nombre de quarantaines d'échec conservées dans ${BACKUP_DIR}/failed. 0 = aucune.
FAILED_RETENTION="${FAILED_RETENTION:-3}"
# Intervalle en secondes du timer de surveillance de l'API. 0 = désactivé.
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-60}"

# Charge ${CONFIG_FILE} s'il existe, après avoir vérifié qu'il
# appartient à root et n'est modifiable que par lui (il est exécuté en root).
load_config() {
  [[ -e "${CONFIG_FILE}" ]] || return 0
  command -v stat >/dev/null 2>&1 \
    || die "La commande stat est requise pour contrôler ${CONFIG_FILE}."

  if [[ ! -f "${CONFIG_FILE}" || -L "${CONFIG_FILE}" ]]; then
    die "${CONFIG_FILE} doit être un fichier régulier, pas un lien symbolique."
  fi

  local owner mode permissions
  owner="$(stat -c '%u' "${CONFIG_FILE}")"
  mode="$(stat -c '%a' "${CONFIG_FILE}")"
  permissions="${mode: -3}"

  [[ "${owner}" == "0" ]] \
    || die "${CONFIG_FILE} doit appartenir à root."
  if (( (8#${permissions} & 022) != 0 )); then
    die "${CONFIG_FILE} ne doit pas être modifiable par le groupe ou les autres."
  fi

  # Le fichier est du shell : son propriétaire et ses droits sont donc vérifiés
  # avant de l'exécuter dans le processus root.
  # shellcheck source=/dev/null
  . "${CONFIG_FILE}"
}

load_config

UNIT_PATH=""
WATCHDOG_SERVICE_PATH=""
WATCHDOG_TIMER_PATH=""
WATCHDOG_HELPER_PATH=""
MANAGED_PATHS=()
LOCK_FILE=""
BACKUP_DIR=""
LMS_HOME=""
LMSTUDIO_HOME=""
LMS_UID=""
LMS_BIN=""
TIMEOUT_BIN=""
HEALTH_HOST=""

# Hôte que la sonde locale doit interroger pour une adresse d'écoute $1.
health_host_for() {
  case "$1" in
    0.0.0.0|127.0.0.1|localhost) printf '127.0.0.1' ;;
    ::)                          printf '[::1]' ;;
    *:*)                         printf '[%s]' "$1" ;;
    *)                           printf '%s' "$1" ;;
  esac
}

# Valide chaque variable de configuration (format, plage) et en dérive les
# chemins : unité systemd, verrou, répertoire de sauvegarde, hôte de la sonde.
validate_config() {
  if [[ -z "${LMS_USER}" ]]; then
    die "LMS_USER n'est pas défini : renseigne-le dans ${CONFIG_FILE}, ou lance le script via sudo depuis le compte concerné."
  fi
  [[ "${LMS_USER}" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] \
    || die "LMS_USER contient des caractères non autorisés."
  if [[ "${LMS_USER}" == "root" ]]; then
    warn "llmster tournera sous root : un compte dédié non privilégié est préférable."
  fi
  [[ "${SERVICE_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*$ ]] \
    || die "SERVICE_NAME contient des caractères non autorisés."

  [[ "${SERVER_PORT}" =~ ^[0-9]+$ ]] \
    || die "SERVER_PORT doit être un entier."
  if (( 10#${SERVER_PORT} < 1 || 10#${SERVER_PORT} > 65535 )); then
    die "SERVER_PORT doit être compris entre 1 et 65535."
  fi

  [[ "${HEALTH_TIMEOUT}" =~ ^[0-9]+$ ]] \
    || die "HEALTH_TIMEOUT doit être un entier."
  if (( 10#${HEALTH_TIMEOUT} < 5 || 10#${HEALTH_TIMEOUT} > 3600 )); then
    die "HEALTH_TIMEOUT doit être compris entre 5 et 3600 secondes."
  fi

  [[ "${FAILED_RETENTION}" =~ ^[0-9]+$ ]] \
    || die "FAILED_RETENTION doit être un entier."
  if (( 10#${FAILED_RETENTION} > 50 )); then
    die "FAILED_RETENTION doit être compris entre 0 et 50."
  fi

  [[ "${WATCHDOG_INTERVAL}" =~ ^[0-9]+$ ]] \
    || die "WATCHDOG_INTERVAL doit être un entier."
  WATCHDOG_INTERVAL=$((10#${WATCHDOG_INTERVAL}))
  if (( WATCHDOG_INTERVAL != 0 \
        && (WATCHDOG_INTERVAL < 15 || WATCHDOG_INTERVAL > 3600) )); then
    die "WATCHDOG_INTERVAL doit valoir 0 (désactivé) ou être compris entre 15 et 3600 secondes."
  fi

  [[ "${BIND_ADDR}" =~ ^[A-Za-z0-9_.:-]+$ ]] \
    || die "BIND_ADDR contient des caractères non autorisés."
  HEALTH_HOST="$(health_host_for "${BIND_ADDR}")"

  case "${ENABLE_LM_LINK,,}" in
    1|true|yes|on)  ENABLE_LM_LINK="true" ;;
    0|false|no|off) ENABLE_LM_LINK="false" ;;
    *) die "ENABLE_LM_LINK doit valoir true ou false." ;;
  esac

  if [[ -n "${PRELOAD_MODEL}" \
        && ! "${PRELOAD_MODEL}" =~ ^[A-Za-z0-9._/@:+-]+$ ]]; then
    die "PRELOAD_MODEL contient des caractères non autorisés."
  fi

  # LOAD_ARGS est recopié dans une ligne Exec de l'unité. systemd y interprète
  # « % » (spécificateurs), « $ » (variables), « \ » (échappements) et un « ; »
  # isolé (séparateur de commandes) : tous sont refusés, comme les contrôles.
  if [[ "${LOAD_ARGS}" == *[[:cntrl:]]* || "${LOAD_ARGS}" == *[%\$\\\;]* ]]; then
    die "LOAD_ARGS ne peut contenir ni caractère de contrôle, ni « % », « \$ », « \\ » ou « ; »."
  fi

  if [[ -n "${API_TOKEN_FILE}" ]]; then
    [[ "${API_TOKEN_FILE}" == /* ]] \
      || die "API_TOKEN_FILE doit être un chemin absolu."
    [[ "${API_TOKEN_FILE}" =~ ^/[A-Za-z0-9_./@+-]+$ ]] \
      || die "API_TOKEN_FILE contient des caractères non autorisés."
  fi

  UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
  WATCHDOG_SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}-watchdog.service"
  WATCHDOG_TIMER_PATH="/etc/systemd/system/${SERVICE_NAME}-watchdog.timer"
  WATCHDOG_HELPER_PATH="/usr/local/libexec/${SERVICE_NAME}-watchdog"
  # Fichiers gérés par lmsctl, sauvegardés et restaurés ensemble.
  MANAGED_PATHS=("${UNIT_PATH}" "${WATCHDOG_SERVICE_PATH}"
                 "${WATCHDOG_TIMER_PATH}" "${WATCHDOG_HELPER_PATH}")
  # /run et non /run/lock : ce dernier est ouvert en écriture à tous (1777),
  # n'importe quel utilisateur pourrait y créer le verrou avant root et le
  # garder indéfiniment.
  LOCK_FILE="/run/${SERVICE_NAME}-ctl.lock"
  BACKUP_DIR="/var/backups/${SERVICE_NAME}-llmster"
}

# --- Prérequis ---------------------------------------------------------------

# Quitte si le script n'est pas lancé en root.
require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Ce script doit être exécuté avec sudo. Exemple : sudo ${SCRIPT_NAME} $*"
  fi
}

# Vérifie que toutes les commandes passées en argument sont disponibles.
require_cmds() {
  local cmd
  for cmd in "$@"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      die "Commande requise absente : ${cmd}"
    fi
  done
}

# libatomic est exigé par llmster (Node.js 25+). Le test utilise
# l'environnement de l'utilisateur cible, comme l'installeur officiel.
check_runtime_libs() {
  if ! as_user sh -c 'command -v ldconfig >/dev/null 2>&1'; then
    die "ldconfig est introuvable dans le PATH de ${LMS_USER} (libc-bin sur Debian/Ubuntu, glibc ailleurs)."
  fi
  if ! as_user ldconfig -p 2>/dev/null \
    | awk '$1=="libatomic.so.1"{f=1} END{exit !f}'; then
    die "Bibliothèque manquante : libatomic (libatomic1 sur Debian/Ubuntu, libatomic sur Fedora/Arch)."
  fi
  if ! as_user ldconfig -p 2>/dev/null \
    | awk '$1=="libgomp.so.1"{f=1} END{exit !f}'; then
    warn "libgomp introuvable (libgomp1 sur Debian/Ubuntu) — à installer si llmster refuse de démarrer."
  fi
}

# --- Utilisateur et chemins --------------------------------------------------

# Exige un chemin absolu sans caractère exotique. $1 = libellé, $2 = chemin.
validate_managed_path() {
  local label="$1"
  local value="$2"

  [[ "${value}" == /* ]] || die "${label} doit être un chemin absolu."
  [[ "${value}" =~ ^/[A-Za-z0-9_./@+-]+$ ]] \
    || die "${label} contient des caractères non autorisés : ${value}"
}

# Résout le dossier personnel de LMS_USER et le dossier LM Studio
# (éventuellement redirigé par ~/.lmstudio-home-pointer), puis vérifie qu'ils
# sont sûrs : propriétaire, chemin non système, droit de création.
resolve_user() {
  local passwd_entry user_uid
  passwd_entry="$(getent passwd "${LMS_USER}")" \
    || die "L'utilisateur ${LMS_USER} n'existe pas."
  user_uid="$(id -u "${LMS_USER}")"
  LMS_UID="${user_uid}"

  IFS=: read -r _ _ _ _ _ LMS_HOME _ <<<"${passwd_entry}"
  if [[ -z "${LMS_HOME}" || ! -d "${LMS_HOME}" ]]; then
    die "Dossier personnel introuvable pour ${LMS_USER}."
  fi
  validate_managed_path "Le dossier personnel" "${LMS_HOME}"
  LMS_HOME="$(realpath -m -- "${LMS_HOME}")"

  # L'installeur officiel honore ce pointeur. Il est contrôlé strictement car
  # les opérations de sauvegarde root utiliseront ensuite ce chemin.
  local pointer="${LMS_HOME}/.lmstudio-home-pointer"
  if [[ -e "${pointer}" ]]; then
    [[ -f "${pointer}" && ! -L "${pointer}" ]] \
      || die "${pointer} doit être un fichier régulier."

    local pointer_lines=()
    mapfile -t pointer_lines <"${pointer}"
    if (( ${#pointer_lines[@]} != 1 )) || [[ -z "${pointer_lines[0]}" ]]; then
      die "${pointer} doit contenir exactement un chemin non vide."
    fi
    LMSTUDIO_HOME="${pointer_lines[0]}"
  else
    LMSTUDIO_HOME="${LMS_HOME}/.lmstudio"
  fi

  validate_managed_path "Le dossier LM Studio" "${LMSTUDIO_HOME}"
  LMSTUDIO_HOME="$(realpath -m -- "${LMSTUDIO_HOME}")"

  case "${LMSTUDIO_HOME}" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
      die "Chemin LM Studio trop large ou dangereux : ${LMSTUDIO_HOME}"
      ;;
  esac

  if [[ -e "${LMSTUDIO_HOME}" ]]; then
    [[ -d "${LMSTUDIO_HOME}" ]] \
      || die "${LMSTUDIO_HOME} existe mais n'est pas un dossier."
    [[ "$(stat -c '%u' "${LMSTUDIO_HOME}")" == "${user_uid}" ]] \
      || die "${LMSTUDIO_HOME} doit appartenir à ${LMS_USER}."
  else
    local existing_parent
    existing_parent="${LMSTUDIO_HOME}"
    while [[ ! -e "${existing_parent}" ]]; do
      existing_parent="${existing_parent%/*}"
      [[ -n "${existing_parent}" ]] || existing_parent="/"
    done
    if ! as_user test -w "${existing_parent}"; then
      die "${LMS_USER} ne peut pas créer ${LMSTUDIO_HOME}."
    fi
  fi

  LMS_BIN="${LMSTUDIO_HOME}/bin/lms"
}

# Exécute "$@" en root depuis le dossier $1 de LMS_USER, à condition que ce
# soit bien le vrai dossier, qui lui appartient. Le cd fige le dossier : si
# l'utilisateur le remplace ensuite par un lien symbolique (TOCTOU), les
# chemins relatifs passés à "$@" visent toujours le dossier vérifié, et non la
# cible du lien.
in_user_dir() {
  local dir="$1"
  shift
  (
    cd -P -- "${dir}" 2>/dev/null || exit 1
    if [[ "$(pwd -P)" != "${dir}" || "$(stat -c '%u' .)" != "${LMS_UID}" ]]; then
      warn "${dir} a changé ou n'appartient plus à ${LMS_USER} : opération refusée."
      exit 1
    fi
    "$@"
  )
}

# Exécute une commande sous LMS_USER avec un environnement minimal et maîtrisé.
as_user() {
  runuser -u "${LMS_USER}" -- env \
    HOME="${LMS_HOME}" \
    USER="${LMS_USER}" \
    LOGNAME="${LMS_USER}" \
    PATH="${LMSTUDIO_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

# Fermer le descripteur du verrou avant de lancer un démon persistant empêche
# celui-ci de conserver artificiellement le verrou de lmsctl.
lms_cli() { as_user "${LMS_BIN}" "$@" 9>&-; }

# Vrai si le CLI lms est installé et exécutable.
lms_installed() { [[ -x "${LMS_BIN}" ]]; }

# Quitte si llmster n'est pas installé.
require_installed() {
  lms_installed \
    || die "llmster n'est pas installé. Lance : sudo ${SCRIPT_NAME} install"
}

# Quitte si l'unité systemd n'a pas encore été écrite.
require_unit() {
  [[ -f "${UNIT_PATH}" ]] \
    || die "Unité absente : ${UNIT_PATH}. Lance : sudo ${SCRIPT_NAME} install"
}

# --- Authentification de la sonde locale -------------------------------------

CURL_AUTH_ARGS=()
AUTH_PREPARED="false"

# Prépare l'en-tête Authorization de la sonde à partir de API_TOKEN_FILE
# (contrôlé : root, 0600, un seul jeton). Idempotent ; renvoie 1 si invalide.
prepare_auth() {
  [[ "${AUTH_PREPARED}" == "false" ]] || return 0
  AUTH_PREPARED="true"

  [[ -n "${API_TOKEN_FILE}" ]] || return 0

  if [[ ! -f "${API_TOKEN_FILE}" || -L "${API_TOKEN_FILE}" ]]; then
    warn "API_TOKEN_FILE doit être un fichier régulier : ${API_TOKEN_FILE}"
    return 1
  fi

  local owner mode permissions token header_file
  owner="$(stat -c '%u' "${API_TOKEN_FILE}")"
  mode="$(stat -c '%a' "${API_TOKEN_FILE}")"
  permissions="${mode: -3}"

  if [[ "${owner}" != "0" || $((8#${permissions} & 077)) -ne 0 ]]; then
    warn "${API_TOKEN_FILE} doit appartenir à root et n'accorder aucun droit au groupe/aux autres."
    return 1
  fi

  token="$(<"${API_TOKEN_FILE}")"
  if [[ -z "${token}" || "${token}" == *$'\n'* || "${token}" == *$'\r'* ]]; then
    warn "${API_TOKEN_FILE} doit contenir un seul jeton non vide."
    return 1
  fi

  # Le jeton n'apparaît pas dans la ligne de commande de curl. Le fichier est
  # créé directement en 0600 : un chmod postérieur laisserait le jeton lisible
  # par tous pendant l'intervalle, WORK_DIR étant en 0755.
  header_file="${WORK_DIR}/api-header"
  install -m 0600 /dev/null "${header_file}"
  printf 'Authorization: Bearer %s\n' "${token}" >"${header_file}"
  CURL_AUTH_ARGS=(--header "@${header_file}")
}

# --- Contrôles préalables ----------------------------------------------------

# Vrai si le service systemd est actif.
service_active() {
  systemctl is-active --quiet "${SERVICE_NAME}.service"
}

# Vrai si un démon llmster tourne sous LMS_USER (même hors systemd).
# Le nom exact du processus (comm), et non sa ligne de commande : un shell ou
# un éditeur dont les arguments contiennent « llmster » ne doit pas compter.
daemon_process_running() {
  pgrep -u "${LMS_USER}" -x llmster >/dev/null 2>&1
}

# Refuse de continuer si l'application desktop tourne encore : elle
# partagerait ~/.lmstudio avec le démon.
preflight_gui() {
  if pgrep -u "${LMS_USER}" \
    -f 'LM-Studio\.AppImage|/lm-studio([[:space:]]|$)' >/dev/null 2>&1; then
    die "L'application desktop LM Studio tourne encore sous ${LMS_USER}. Ferme-la puis relance."
  fi
}

# Vrai si un processus écoute sur SERVER_PORT.
port_in_use() {
  ss -H -ltn 2>/dev/null \
    | awk -v suffix=":${SERVER_PORT}" \
      '$4 ~ (suffix "$") {found=1} END {exit !found}'
}

# Attend jusqu'à $1 secondes (défaut 10) que SERVER_PORT se libère.
wait_port_free() {
  local timeout="${1:-10}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    port_in_use || return 0
    sleep 1
  done
  ! port_in_use
}

# Avant un démarrage : le port doit être libre, sauf si c'est déjà notre service.
preflight_port() {
  service_active && return 0
  if port_in_use; then
    die "Le port ${SERVER_PORT} est déjà occupé. Diagnostic : sudo ss -ltnp 'sport = :${SERVER_PORT}'"
  fi
}

# --- Service systemd ---------------------------------------------------------

# Écrit sur stdout l'unité systemd correspondant à la configuration.
render_unit() {
  local link_line=""
  local preload_line=""

  if [[ "${ENABLE_LM_LINK}" == "true" ]]; then
    # « lms link enable » attend un pair. Le lancer après le serveur et le
    # borner évite qu'un Mac éteint retarde l'API. Le préfixe « - » rend un
    # timeout ou une absence de connexion non bloquant.
    link_line="ExecStartPost=-${TIMEOUT_BIN} --signal=TERM 20s ${LMS_BIN} link enable"
  fi
  if [[ -n "${PRELOAD_MODEL}" ]]; then
    # Après le serveur et préfixé de « - » : un échec de chargement (modèle
    # absent, mémoire insuffisante) laisse l'API active et ne doit pas être
    # confondu avec un binaire défectueux. preload_failed le détecte ensuite.
    preload_line="ExecStartPost=-${LMS_BIN} load ${PRELOAD_MODEL} --yes"
    if [[ -n "${LOAD_ARGS}" ]]; then
      preload_line+=" ${LOAD_ARGS}"
    fi
  fi

  cat <<EOF
# Généré par ${SCRIPT_NAME}. Ne pas éditer à la main :
# régler ${CONFIG_FILE} puis exécuter « ${SCRIPT_NAME} configure ».
[Unit]
Description=LM Studio headless (llmster)
Documentation=https://lmstudio.ai/docs/developer/core/headless_llmster
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${LMS_USER}
Environment="HOME=${LMS_HOME}"
Environment="PATH=${LMSTUDIO_HOME}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
UMask=0022
NoNewPrivileges=true
ExecStartPre=${LMS_BIN} daemon up
ExecStart=${LMS_BIN} server start --port ${SERVER_PORT} --bind ${BIND_ADDR}
${preload_line}
${link_line}
ExecStop=-${LMS_BIN} daemon down
TimeoutStartSec=600
TimeoutStopSec=120
Restart=no

[Install]
WantedBy=multi-user.target
EOF
}

# Script de surveillance exécuté en root par le timer. POSIX sh, sans
# dépendance à lmsctl : il continue de fonctionner si le dépôt est déplacé.
# Les valeurs injectées ont été validées (jeu de caractères sans apostrophe).
render_watchdog_helper() {
  cat <<EOF
#!/bin/sh
# Généré par ${SCRIPT_NAME} ${SCRIPT_VERSION}. Ne pas éditer à la main :
# régler WATCHDOG_INTERVAL dans ${CONFIG_FILE} puis « ${SCRIPT_NAME} configure ».
set -u
SERVICE='${SERVICE_NAME}.service'
BASE_URL='http://${HEALTH_HOST}:${SERVER_PORT}'
TOKEN_FILE='${API_TOKEN_FILE}'
LOCK_FILE='${LOCK_FILE}'
EOF
  cat <<'EOF'
ATTEMPTS=3
PAUSE=5

# lmsctl détient ce verrou pendant toute opération (installation, mise à jour,
# restauration) : la surveillance s'efface plutôt que d'interférer.
exec 9>"${LOCK_FILE}" || exit 0
flock -n 9 || exit 0

# Arrêté volontairement, en cours de démarrage ou en échec : rien à faire.
# Un service en échec n'est pas relancé en boucle.
[ "$(systemctl is-active "${SERVICE}" 2>/dev/null)" = active ] || exit 0

# Vrai si le serveur HTTP répond. Un 4xx (jeton refusé, chemin inconnu) prouve
# qu'il est vivant ; seuls l'absence de réponse et les 5xx comptent comme panne.
probe() {
  for path in /api/v1/models /v1/models; do
    if [ -n "${TOKEN_FILE}" ] && [ -r "${TOKEN_FILE}" ]; then
      code=$(printf 'Authorization: Bearer %s\n' "$(cat -- "${TOKEN_FILE}")" \
        | curl -s -o /dev/null -w '%{http_code}' --noproxy '*' \
            --connect-timeout 2 --max-time 5 --header @- \
            "${BASE_URL}${path}" 2>/dev/null) || code=000
    else
      code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' \
            --connect-timeout 2 --max-time 5 \
            "${BASE_URL}${path}" 2>/dev/null) || code=000
    fi
    case "${code}" in
      2??|3??) return 0 ;;
      4??) [ "${path}" = /v1/models ] && return 0 ;;
    esac
  done
  return 1
}

i=1
while :; do
  probe && exit 0
  [ "${i}" -ge "${ATTEMPTS}" ] && break
  i=$((i + 1))
  sleep "${PAUSE}"
done

echo "API muette après ${ATTEMPTS} sondes : redémarrage de ${SERVICE}."
exec systemctl restart "${SERVICE}"
EOF
}

# Unité oneshot lancée par le timer.
render_watchdog_service() {
  cat <<EOF
# Généré par ${SCRIPT_NAME}. Ne pas éditer à la main.
[Unit]
Description=Surveillance de l'API LM Studio (${SERVICE_NAME})
After=${SERVICE_NAME}.service

[Service]
Type=oneshot
ExecStart=/bin/sh ${WATCHDOG_HELPER_PATH}
# Un redémarrage peut durer TimeoutStopSec + TimeoutStartSec du service.
TimeoutStartSec=900
EOF
}

# Le délai court à partir de la fin de la sonde précédente : deux sondes ne se
# chevauchent jamais, même pendant un redémarrage long.
render_watchdog_timer() {
  cat <<EOF
# Généré par ${SCRIPT_NAME}. Ne pas éditer à la main.
[Unit]
Description=Surveillance périodique de l'API LM Studio (${SERVICE_NAME})

[Timer]
OnActiveSec=${WATCHDOG_INTERVAL}s
OnUnitInactiveSec=${WATCHDOG_INTERVAL}s
AccuracySec=5s
Unit=${SERVICE_NAME}-watchdog.service

[Install]
WantedBy=timers.target
EOF
}

# Génère dans WORK_DIR/units les fichiers attendus par la configuration.
render_candidates() {
  local dir="${WORK_DIR}/units"
  rm -rf -- "${dir}"
  install -d -m 0700 "${dir}" || return 1
  render_unit >"${dir}/${SERVICE_NAME}.service" || return 1
  if (( WATCHDOG_INTERVAL > 0 )); then
    render_watchdog_helper >"${dir}/${SERVICE_NAME}-watchdog" || return 1
    render_watchdog_service >"${dir}/${SERVICE_NAME}-watchdog.service" || return 1
    render_watchdog_timer >"${dir}/${SERVICE_NAME}-watchdog.timer" || return 1
  fi
}

# Fait valider les unités candidates par systemd-analyze (si disponible) et
# affiche ses remarques en cas d'échec. Le script de surveillance est contrôlé
# par sh -n.
verify_candidates() {
  local dir="${WORK_DIR}/units"
  local units=("${dir}/${SERVICE_NAME}.service")
  local line report="${WORK_DIR}/systemd-verify.log"

  if (( WATCHDOG_INTERVAL > 0 )); then
    units+=("${dir}/${SERVICE_NAME}-watchdog.service"
            "${dir}/${SERVICE_NAME}-watchdog.timer")
    if ! sh -n "${dir}/${SERVICE_NAME}-watchdog"; then
      warn "Le script de surveillance généré est invalide."
      return 1
    fi
  fi

  command -v systemd-analyze >/dev/null 2>&1 || return 0
  if systemd-analyze verify "${units[@]}" >"${report}" 2>&1; then
    return 0
  fi

  warn "Les unités systemd générées sont invalides :"
  while IFS= read -r line; do
    warn "  ${line}"
  done <"${report}"
  return 1
}

UNITS_CHANGED="false"

# Installe le candidat $1 en $2 (mode $3, root:root) s'il diffère.
sync_managed_file() {
  local candidate="$1" target="$2" mode="$3"
  if [[ -f "${target}" && ! -L "${target}" ]] && cmp -s "${candidate}" "${target}"; then
    return 0
  fi
  install -D -m "${mode}" -o root -g root "${candidate}" "${target}" || return 1
  UNITS_CHANGED="true"
  log "   Écrit : ${target}"
}

# Désactive le timer de surveillance et retire ses fichiers s'ils existent.
remove_watchdog_files() {
  if [[ -f "${WATCHDOG_TIMER_PATH}" ]]; then
    systemctl disable --now "${SERVICE_NAME}-watchdog.timer" >/dev/null 2>&1 || true
  fi
  local path
  for path in "${WATCHDOG_TIMER_PATH}" "${WATCHDOG_SERVICE_PATH}" \
              "${WATCHDOG_HELPER_PATH}"; do
    if [[ -e "${path}" || -L "${path}" ]]; then
      rm -f -- "${path}" || return 1
      UNITS_CHANGED="true"
      log "   Retiré : ${path}"
    fi
  done
}

# Génère, valide puis installe les fichiers gérés, uniquement s'ils ont changé.
# Le timer n'est pas (ré)armé ici : apply_watchdog le fait une fois le service
# vérifié.
write_units() {
  local dir="${WORK_DIR}/units"
  UNITS_CHANGED="false"
  render_candidates || return 1
  verify_candidates || return 1

  sync_managed_file "${dir}/${SERVICE_NAME}.service" "${UNIT_PATH}" 0644 \
    || return 1
  if (( WATCHDOG_INTERVAL > 0 )); then
    sync_managed_file "${dir}/${SERVICE_NAME}-watchdog" \
      "${WATCHDOG_HELPER_PATH}" 0755 || return 1
    sync_managed_file "${dir}/${SERVICE_NAME}-watchdog.service" \
      "${WATCHDOG_SERVICE_PATH}" 0644 || return 1
    sync_managed_file "${dir}/${SERVICE_NAME}-watchdog.timer" \
      "${WATCHDOG_TIMER_PATH}" 0644 || return 1
  else
    remove_watchdog_files || return 1
  fi

  if [[ "${UNITS_CHANGED}" == "true" ]]; then
    systemctl daemon-reload || return 1
  else
    log "   Unités systemd déjà à jour."
  fi
}

# Arme le timer de surveillance si la configuration le demande. Le redémarrage
# du timer applique un éventuel nouvel intervalle. Un échec ici ne justifie pas
# d'annuler une opération dont le service a été vérifié : simple avertissement.
apply_watchdog() {
  (( WATCHDOG_INTERVAL > 0 )) || return 0
  if systemctl enable "${SERVICE_NAME}-watchdog.timer" >/dev/null 2>&1 \
      && systemctl restart "${SERVICE_NAME}-watchdog.timer"; then
    log "   Surveillance de l'API toutes les ${WATCHDOG_INTERVAL}s."
    return 0
  fi
  warn "Impossible d'armer ${SERVICE_NAME}-watchdog.timer : le service tourne sans surveillance."
  return 0
}

# --- Santé -------------------------------------------------------------------

# /api/v1/* est l'API native depuis LM Studio 0.4.0 ; /v1/models reste servi
# par toutes les versions. On essaie la première, on retombe sur la seconde, et
# le chemin qui a répondu est mémorisé pour les sondes suivantes.
HEALTH_CANDIDATES=("/api/v1/models" "/v1/models")
HEALTH_PATH=""
HEALTH_LAST_CODE="000"
HEALTH_DEGRADED="false"

# Interroge http://HEALTH_HOST:SERVER_PORT$1 et affiche le code HTTP
# (000 si aucune réponse).
probe_status() {
  local path="$1" code=""
  code="$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' \
    --connect-timeout 2 --max-time 5 \
    "${CURL_AUTH_ARGS[@]}" \
    "http://${HEALTH_HOST}:${SERVER_PORT}${path}" 2>/dev/null)" || true
  printf '%s' "${code:-000}"
}

# 0 = API saine ; 1 = aucune réponse exploitable ; 2 = le serveur répond mais
# rejette la sonde (jeton absent ou invalide) — ce n'est pas une panne.
health_probe() {
  command -v curl >/dev/null 2>&1 || return 1

  local candidates=("${HEALTH_CANDIDATES[@]}")
  [[ -z "${HEALTH_PATH}" ]] || candidates=("${HEALTH_PATH}")

  local path code
  for path in "${candidates[@]}"; do
    code="$(probe_status "${path}")"
    HEALTH_LAST_CODE="${code}"
    case "${code}" in
      200)
        HEALTH_PATH="${path}"
        return 0
        ;;
      401|403)
        return 2
        ;;
    esac
  done
  return 1
}

# Répète health_probe jusqu'à HEALTH_TIMEOUT secondes ; mêmes codes de retour.
wait_health() {
  local deadline=$((SECONDS + HEALTH_TIMEOUT))
  local rc=1
  while (( SECONDS < deadline )); do
    rc=0
    health_probe || rc=$?
    if (( rc == 0 )); then
      return 0
    fi
    if (( rc == 2 )); then
      return 2
    fi
    sleep 3
  done
  return 1
}

# Verdict exploitable par les appelants : un rejet d'authentification prouve que
# le serveur est vivant, donc ne justifie aucune restauration.
interpret_health_rc() {
  local rc="$1"
  HEALTH_DEGRADED="false"

  case "${rc}" in
    0) return 0 ;;
    2)
      HEALTH_DEGRADED="true"
      warn "Le serveur répond (HTTP ${HEALTH_LAST_CODE}) mais rejette la sonde."
      warn "Ce n'est pas une panne du service : vérifie API_TOKEN_FILE, puis « ${SCRIPT_NAME} health »."
      return 0
      ;;
    *) return 1 ;;
  esac
}

# Avec attente : après un démarrage, le serveur a besoin de quelques secondes.
health_acceptable() {
  local rc=0
  wait_health || rc=$?
  interpret_health_rc "${rc}"
}

# Sans attente : pour interroger un service censé déjà tourner. Boucler
# HEALTH_TIMEOUT secondes sur un service actif mais muet ne renseigne sur rien
# et retarde d'autant le diagnostic.
health_snapshot() {
  local rc=0
  health_probe || rc=$?
  interpret_health_rc "${rc}"
}

PRELOAD_FAILED="false"

# Le préchargement est un ExecStartPost non bloquant, terminé quand
# « systemctl start » rend la main. On vérifie le résultat réel plutôt que son
# code de sortie (systemd l'oublie au premier daemon-reload) : le modèle doit
# figurer dans « lms ps --json », par clé, identifiant ou chemin. Une
# correspondance partielle est acceptée, « lms load » résolvant les noms
# approchés. Si la liste est illisible, aucun échec n'est inventé.
# À n'appeler qu'une fois l'API vérifiée : lms ne doit pas démarrer de démon.
check_preload() {
  PRELOAD_FAILED="false"
  [[ -n "${PRELOAD_MODEL}" ]] || return 0

  local listing value
  if ! listing="$(lms_cli ps --json 2>/dev/null)" || [[ "${listing}" != \[* ]]; then
    warn "Impossible de vérifier le préchargement de ${PRELOAD_MODEL} (lms ps --json)."
    return 0
  fi

  while IFS= read -r value; do
    if [[ "${value,,}" == *"${PRELOAD_MODEL,,}"* ]]; then
      return 0
    fi
  done < <(grep -oE '"(modelKey|identifier|path|indexedModelIdentifier)":"[^"]*"' \
             <<<"${listing}" | cut -d'"' -f4 || true)

  PRELOAD_FAILED="true"
  warn "Le modèle ${PRELOAD_MODEL} n'est pas en mémoire après le démarrage (API pourtant active)."
  hint "Diagnostic : sudo ${SCRIPT_NAME} logs — modèle absent ou mémoire insuffisante ?"
}

# Une réponse 401/403 prouve que le service est vivant : l'opération est donc
# conservée, mais son résultat ne doit pas être annoncé comme entièrement sain.
# De même pour un préchargement raté : l'API fonctionne, pas le modèle attendu.
# exit est volontaire : un simple return 2 sous set -e déclencherait le trap ERR.
finish_health_result() {
  if [[ "${HEALTH_DEGRADED}" == "true" ]]; then
    warn "Opération conservée, mais contrôle authentifié impossible."
    exit 2
  fi
  if [[ "${PRELOAD_FAILED}" == "true" ]]; then
    warn "Opération conservée, mais le modèle ${PRELOAD_MODEL} n'est pas chargé."
    exit 3
  fi
}

# Avertit si le serveur écoute ailleurs qu'en local.
network_warning() {
  case "${BIND_ADDR}" in
    127.0.0.1|localhost|::1) return 0 ;;
  esac

  warn "Le serveur écoute sur ${BIND_ADDR} et peut être joignable depuis le réseau."
  if [[ -z "${API_TOKEN_FILE}" ]]; then
    warn "Active « Require Authentication », puis configure API_TOKEN_FILE."
  else
    warn "Vérifie que « Require Authentication » est activé dans LM Studio."
  fi
  warn "Restreins également le port ${SERVER_PORT} avec le pare-feu."
}

# Affiche l'état de LM Link quand il est activé.
show_link_status() {
  [[ "${ENABLE_LM_LINK}" == "true" ]] || return 0
  step "── LM Link ──"
  if ! lms_cli link status; then
    warn "LM Link n'est pas connecté. Lance « sudo -u ${LMS_USER} -H ${LMS_BIN} login », puis redémarre."
  fi
}

# --- Sauvegarde et rollback ciblé --------------------------------------------

# Point unique de création des chemins privilégiés : garantit des droits
# homogènes (root:root 0700).
install_private_dir() {
  install -d -m 0700 -o root -g root "$@"
}

# Installe le fichier $1 en $2, root:root 0644.
install_root_file() {
  install -m 0644 -o root -g root "$1" "$2"
}


HAD_BIN_SNAPSHOT="false"
HAD_UNIT="false"
WAS_ENABLED="false"
DAEMON_DIR=""
DAEMON_VERSIONS_BEFORE=()
HAD_DAEMON_INVENTORY="false"

# Le démon ne vit pas dans bin/ mais dans ~/.lmstudio/llmster/<version>/.
# Sauvegarder bin/ seul restaurerait un shim ancien devant un démon récent :
# on relève donc les versions présentes avant toute mutation.
record_daemon_versions() {
  DAEMON_DIR="${LMSTUDIO_HOME}/llmster"
  DAEMON_VERSIONS_BEFORE=()
  HAD_DAEMON_INVENTORY="false"

  local inventory="${WORK_DIR}/daemon-versions.before"
  install -m 0600 /dev/null "${inventory}" || return 1

  if [[ -d "${DAEMON_DIR}" ]]; then
    if ! find "${DAEMON_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 \
        | sort -z >"${inventory}"; then
      warn "Impossible d'inventorier les versions présentes dans ${DAEMON_DIR}."
      return 1
    fi
  fi

  local entry
  while IFS= read -r -d '' entry; do
    DAEMON_VERSIONS_BEFORE+=("${entry##*/}")
  done <"${inventory}"

  # L'inventaire devient exploitable uniquement après collecte et lecture
  # réussies. Un répertoire absent correspond alors bien à un inventaire vide.
  HAD_DAEMON_INVENTORY="true"

  if (( ${#DAEMON_VERSIONS_BEFORE[@]} > 0 )); then
    log "   Versions du démon présentes : ${DAEMON_VERSIONS_BEFORE[*]}"
  else
    log "   Aucune version de démon installée avant l'opération."
  fi
}

# Vrai si la version $1 du démon existait avant l'opération.
daemon_version_known() {
  local name="$1" previous
  for previous in "${DAEMON_VERSIONS_BEFORE[@]}"; do
    if [[ "${previous}" == "${name}" ]]; then
      return 0
    fi
  done
  return 1
}

# Écarte les versions apparues pendant l'opération dans une quarantaine propre à
# cette exécution, sans écraser les artefacts d'un échec précédent.
quarantine_new_daemon_versions() {
  [[ "${HAD_DAEMON_INVENTORY}" == "true" && -d "${DAEMON_DIR}" ]] || return 0

  local quarantine="${FAILED_DIR}/llmster"
  local inventory="${WORK_DIR}/daemon-versions.current"
  local entry name destination moved=0

  install -m 0600 /dev/null "${inventory}" || return 1
  if ! find "${DAEMON_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 \
      | sort -z >"${inventory}"; then
    warn "Impossible d'inventorier les versions actuelles dans ${DAEMON_DIR}."
    return 1
  fi

  while IFS= read -r -d '' entry; do
    name="${entry##*/}"
    if daemon_version_known "${name}"; then
      continue
    fi
    install_private_dir "${FAILED_DIR:?}" "${quarantine:?}" || return 1
    destination="${quarantine:?}/${name:?}"
    if [[ -e "${destination}" || -L "${destination}" ]]; then
      warn "Quarantaine déjà occupée, déplacement refusé : ${destination}"
      return 1
    fi
    in_user_dir "${DAEMON_DIR}" mv -- "${name}" "${destination}" || return 1
    moved=$((moved + 1))
  done <"${inventory}"

  if (( moved > 0 )); then
    log "   ${moved} version(s) de démon écartée(s) dans ${quarantine}"
  fi
}

# Les quarantaines sont horodatées en UTC : l'ordre lexicographique inverse
# donne les plus récentes en tête. Celle de l'exécution en cours (FAILED_DIR)
# compte dans la rétention mais n'est jamais supprimée, même avec 0 : elle
# sert au diagnostic de l'échec qui vient d'avoir lieu.
prune_failed_artifacts() {
  local root="${BACKUP_DIR}/failed"
  [[ -d "${root}" ]] || return 0

  local listing="${WORK_DIR}/failed-runs"
  install -m 0600 /dev/null "${listing}" || return 1
  if ! find "${root}" -mindepth 1 -maxdepth 1 -type d -print0 \
      | sort -zr >"${listing}"; then
    warn "Impossible d'inventorier ${root}."
    return 1
  fi

  local entry index=0 removed=0
  while IFS= read -r -d '' entry; do
    index=$((index + 1))
    if (( index <= FAILED_RETENTION )) || [[ "${entry}" == "${FAILED_DIR}" ]]; then
      continue
    fi
    rm -rf -- "${entry:?}" || return 1
    removed=$((removed + 1))
  done <"${listing}"

  if (( removed > 0 )); then
    log "   ${removed} quarantaine(s) ancienne(s) purgée(s) dans ${root}"
  fi
}

# Taille occupée par BACKUP_DIR (« vide » s'il n'existe pas).
backup_disk_usage() {
  if [[ -d "${BACKUP_DIR}" ]] && command -v du >/dev/null 2>&1; then
    du -sh "${BACKUP_DIR}" 2>/dev/null | awk 'NR==1{print $1}'
  else
    printf 'vide'
  fi
}

# Déplace le bin/ actuel (fautif) dans la quarantaine de cette exécution.
quarantine_current_bin() {
  local failed="${FAILED_DIR}/bin"

  install_private_dir "${FAILED_DIR:?}" || return 1
  if [[ -e "${failed}" || -L "${failed}" ]]; then
    warn "Quarantaine déjà occupée, déplacement refusé : ${failed}"
    return 1
  fi
  in_user_dir "${LMSTUDIO_HOME}" mv -- bin "${failed}" || return 1
  log "   Binaire fautif écarté dans ${failed}"
}

# Copie bin/ dans ${BACKUP_DIR}/bin.previous avant toute mutation.
snapshot_bin() {
  local source_dir="${LMSTUDIO_HOME}/bin"
  local snapshot="${BACKUP_DIR}/bin.previous"
  HAD_BIN_SNAPSHOT="false"

  [[ -d "${source_dir}" ]] || return 0

  install_private_dir "${BACKUP_DIR}" || return 1
  rm -rf -- "${snapshot}" || return 1
  in_user_dir "${LMSTUDIO_HOME}" cp -a --reflink=auto -- bin "${snapshot}" \
    || return 1
  [[ -x "${snapshot}/lms" ]] || {
    warn "La sauvegarde ne contient pas de CLI lms exécutable."
    return 1
  }

  HAD_BIN_SNAPSHOT="true"
  log "   Sauvegarde indépendante : ${snapshot}"
}

# Remet en place la copie de bin/ après avoir écarté la version fautive.
restore_bin() {
  local current="${LMSTUDIO_HOME}/bin"
  local snapshot="${BACKUP_DIR}/bin.previous"

  [[ -d "${snapshot}" && -x "${snapshot}/lms" ]] || {
    warn "Aucune sauvegarde binaire exploitable dans ${snapshot}."
    return 1
  }

  step "↩️  Restauration de la version précédente"
  if [[ -e "${current}" || -L "${current}" ]]; then
    quarantine_current_bin || return 1
  fi
  # Root n'écrit pas lui-même dans l'arborescence de LMS_USER : il archive sa
  # sauvegarde (sûre, dans un dossier root 0700) et c'est LMS_USER qui la
  # déballe, avec ses seuls droits, avant de la renommer en bin/.
  # shellcheck disable=SC2016  # variables développées par le sh de LMS_USER
  tar -C "${snapshot}" -cf - . \
    | as_user sh -c '
        tmp="$(mktemp -d "$1/.bin-restore.XXXXXX")" || exit 1
        if tar -xpf - -C "${tmp}" && mv -T -- "${tmp}" "$1/bin"; then
          exit 0
        fi
        rm -rf -- "${tmp}"
        exit 1
      ' sh "${LMSTUDIO_HOME}" \
    || return 1
  log "   Copie sauvegardée restaurée dans ${current}"
}

HAD_FILES=()
WAS_TIMER_ENABLED="false"
WAS_TIMER_ACTIVE="false"

# Mémorise les fichiers gérés (unité, surveillance) et l'état
# enabled/active du service et du timer.
backup_unit_state() {
  local dir="${WORK_DIR}/managed.previous" i
  HAD_UNIT="false"
  WAS_ENABLED="false"
  WAS_TIMER_ENABLED="false"
  WAS_TIMER_ACTIVE="false"
  HAD_FILES=()

  install -d -m 0700 "${dir}" || return 1
  for i in "${!MANAGED_PATHS[@]}"; do
    HAD_FILES[i]="false"
    if [[ -f "${MANAGED_PATHS[i]}" ]]; then
      cp -a -- "${MANAGED_PATHS[i]}" "${dir}/${i}" || return 1
      HAD_FILES[i]="true"
    fi
  done
  HAD_UNIT="${HAD_FILES[0]}"

  if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    WAS_ENABLED="true"
  fi
  if systemctl is-enabled --quiet "${SERVICE_NAME}-watchdog.timer" 2>/dev/null; then
    WAS_TIMER_ENABLED="true"
  fi
  if systemctl is-active --quiet "${SERVICE_NAME}-watchdog.timer" 2>/dev/null; then
    WAS_TIMER_ACTIVE="true"
  fi
}

# Restaure les fichiers gérés et l'état enabled/active mémorisés.
restore_unit_state() {
  local dir="${WORK_DIR}/managed.previous" i path mode

  # Un timer apparu pendant l'opération est désarmé avant d'être retiré.
  if [[ "${HAD_FILES[2]:-false}" == "false" && -f "${WATCHDOG_TIMER_PATH}" ]]; then
    systemctl disable --now "${SERVICE_NAME}-watchdog.timer" >/dev/null 2>&1 || true
  fi

  for i in "${!MANAGED_PATHS[@]}"; do
    path="${MANAGED_PATHS[i]}"
    mode="0644"
    if [[ "${path}" == "${WATCHDOG_HELPER_PATH}" ]]; then
      mode="0755"
    fi
    if [[ "${HAD_FILES[i]:-false}" == "true" ]]; then
      install -D -m "${mode}" -o root -g root "${dir}/${i}" "${path}" || return 1
    else
      rm -f -- "${path}" || return 1
    fi
  done

  systemctl daemon-reload || return 1
  if [[ "${WAS_ENABLED}" == "true" ]]; then
    systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1 || return 1
  else
    systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  fi

  [[ "${HAD_FILES[2]:-false}" == "true" ]] || return 0
  if [[ "${WAS_TIMER_ENABLED}" == "true" ]]; then
    systemctl enable "${SERVICE_NAME}-watchdog.timer" >/dev/null 2>&1 || return 1
  else
    systemctl disable "${SERVICE_NAME}-watchdog.timer" >/dev/null 2>&1 || true
  fi
  if [[ "${WAS_TIMER_ACTIVE}" == "true" ]]; then
    systemctl restart "${SERVICE_NAME}-watchdog.timer" || return 1
  else
    systemctl stop "${SERVICE_NAME}-watchdog.timer" >/dev/null 2>&1 || true
  fi
}

# Après restauration, le service écoute selon l'ancienne unité, pas selon la
# nouvelle configuration : la sonde doit viser son port et son adresse, relus
# dans la ligne ExecStart sauvegardée (« server start --port N --bind A »).
restore_health_target() {
  [[ "${HAD_UNIT}" == "true" ]] || return 0
  local line port="" bind=""
  line="$(grep -m1 '^ExecStart=' "${WORK_DIR}/managed.previous/0" 2>/dev/null)" \
    || return 0
  if [[ "${line}" =~ --port[[:space:]]+([0-9]+) ]]; then
    port="${BASH_REMATCH[1]}"
  fi
  if [[ "${line}" =~ --bind[[:space:]]+([A-Za-z0-9_.:-]+) ]]; then
    bind="${BASH_REMATCH[1]}"
  fi
  [[ -n "${port}" && -n "${bind}" ]] || return 0

  SERVER_PORT="${port}"
  BIND_ADDR="${bind}"
  HEALTH_HOST="$(health_host_for "${bind}")"
  HEALTH_PATH=""
}

# Unique chemin de restauration ciblée, partagé par install, update et
# configure. Il couvre bin/, les nouvelles versions llmster et l'unité systemd,
# mais ne prétend pas restaurer l'intégralité de ~/.lmstudio (dont .internal).
# Termine toujours par « die » : tous les appelants sortaient de toute façon en
# erreur, et trois fonctions quasi identiques étaient trois fois plus de code
# non testable.
#
#   scope = binaries  restaure bin/ + écarte les démons apparus + l'unité
#   scope = unit      restaure la seule unité systemd
recover() {
  local scope="$1"
  local was_active="$2"
  local reason="$3"
  local restored="true"

  warn "${reason}"
  warn "Restauration ciblée des éléments sauvegardés."

  systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  if lms_installed; then
    lms_cli daemon down >/dev/null 2>&1 || true
  fi

  if [[ "${scope}" == "binaries" ]]; then
    quarantine_new_daemon_versions || restored="false"

    if [[ "${HAD_BIN_SNAPSHOT}" == "true" ]]; then
      restore_bin || restored="false"
    elif [[ -e "${LMSTUDIO_HOME}/bin" || -L "${LMSTUDIO_HOME}/bin" ]]; then
      # Première installation : il n'existe pas d'état antérieur à restaurer,
      # on se contente d'écarter ce qui vient d'être posé.
      quarantine_current_bin || restored="false"
    fi
  fi

  restore_unit_state || restored="false"
  restore_health_target
  systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  # Sans purge ici, des échecs répétés accumuleraient un bundle de démon
  # (plusieurs Go) par tentative jusqu'à la prochaine réussite.
  prune_failed_artifacts || warn "Purge des quarantaines impossible."

  if [[ "${was_active}" == "true" && "${HAD_UNIT}" == "true" \
        && "${restored}" == "true" ]]; then
    if systemctl start "${SERVICE_NAME}.service" && health_acceptable; then
      if [[ "${HEALTH_DEGRADED}" == "true" ]]; then
        die "Opération annulée : éléments sauvegardés restaurés ; le serveur répond, mais rejette la sonde authentifiée."
      fi
      die "Opération annulée : éléments sauvegardés restaurés, API de nouveau opérationnelle."
    fi
    restored="false"
  fi

  if [[ "${restored}" == "true" ]]; then
    die "Opération annulée : éléments sauvegardés restaurés ; le service reste arrêté comme avant."
  fi

  die "Opération et restauration ciblée en échec. Voir : journalctl -u ${SERVICE_NAME} -n 100"
}

# --- Installeur officiel ------------------------------------------------------

INSTALLER_PATH=""
INSTALLER_VERSION=""

# Vrai si $1 a la forme d'un numéro de version llmster.
valid_installer_version() {
  local version="${1:-}"
  [[ "${version}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

# Vrai si la version $1 est déjà installée et exécutable : la mise à
# jour peut alors s'arrêter sans toucher au service.
daemon_version_installed() {
  local version="${1:-}"
  valid_installer_version "${version}" || return 1
  [[ "${HAD_DAEMON_INVENTORY}" == "true" ]] || return 1
  daemon_version_known "${version}" || return 1
  [[ -x "${LMSTUDIO_HOME}/llmster/${version}/llmster" ]]
}

INSTALLER_SHELL=""

# Extrait la valeur de l'affectation « $2=… » du fichier $1 (première
# occurrence en début de ligne), guillemets simples ou doubles retirés.
installer_assignment() {
  awk -v key="$2" '
    index($0, key "=") == 1 {
      value = substr($0, length(key) + 2)
      sub(/[[:space:]]*(#.*)?$/, "", value)
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
      }
      print value
      exit
    }' "$1"
}

# Vérifie que $1 ressemble bien à l'installeur de llmster : taille plausible,
# shebang sh ou bash, APP_NAME=llmster et APP_VERSION valide. Renseigne
# INSTALLER_VERSION et INSTALLER_SHELL (interpréteur à utiliser).
validate_installer() {
  local file="$1" size first_line=""

  [[ -s "${file}" ]] || {
    warn "Installeur vide."
    return 1
  }
  size="$(wc -c <"${file}")"
  if (( size > 1048576 )); then
    warn "Installeur anormalement gros (${size} octets) : ce n'est pas le script attendu."
    return 1
  fi

  read -r first_line <"${file}" || true
  first_line="${first_line%$'\r'}"
  case "${first_line}" in
    '#!/bin/sh'|'#!/usr/bin/env sh')     INSTALLER_SHELL="sh" ;;
    '#!/bin/bash'|'#!/usr/bin/env bash') INSTALLER_SHELL="bash" ;;
    *)
      warn "L'installeur téléchargé n'a pas de shebang sh ou bash reconnu."
      return 1
      ;;
  esac

  if [[ "$(installer_assignment "${file}" APP_NAME)" != "llmster" ]]; then
    warn "L'installeur téléchargé ne correspond pas à llmster (APP_NAME)."
    return 1
  fi

  INSTALLER_VERSION="$(installer_assignment "${file}" APP_VERSION)"
  if ! valid_installer_version "${INSTALLER_VERSION}"; then
    warn "Version absente ou invalide dans l'installeur officiel (APP_VERSION)."
    return 1
  fi
}

# Télécharge l'installeur officiel et vérifie qu'il ressemble bien à celui
# de llmster (shebang, APP_NAME, version) avant tout arrêt du service.
fetch_installer() {
  local dest="${WORK_DIR}/install.sh"

  step "⬇️  Téléchargement préalable de l'installeur llmster"
  curl -fsSL --proto '=https' --tlsv1.2 --retry 3 \
    --retry-all-errors --connect-timeout 15 --max-time 180 \
    "${INSTALLER_URL}" -o "${dest}" || return 1

  validate_installer "${dest}" || {
    hint "Le format de ${INSTALLER_URL} a peut-être changé : rien n'a été arrêté ni modifié."
    return 1
  }
  log "   Version proposée : ${INSTALLER_VERSION}"

  install -m 0755 -o "${LMS_USER}" -g "$(id -gn "${LMS_USER}")" \
    "${dest}" "${dest}.run" || return 1
  INSTALLER_PATH="${dest}.run"
}

# Exécute l'installeur déjà contrôlé sous LMS_USER.
run_installer() {
  step "📦 Installation de llmster pour ${LMS_USER}"
  # Le service emploie un chemin absolu : inutile de modifier .bashrc/.profile
  # à chaque installation ou mise à jour.
  as_user env LMS_NO_MODIFY_PATH=1 "${INSTALLER_SHELL}" "${INSTALLER_PATH}"
}

# --- Commandes ---------------------------------------------------------------

# install : (ré)installe llmster, écrit et active l'unité, démarre et vérifie.
# Toute erreur après l'arrêt du service déclenche recover.
cmd_install() {
  require_cmds curl awk grep cp cmp ss find sort
  prepare_auth || die "Impossible de préparer l'authentification de la sonde."
  check_runtime_libs
  preflight_gui

  # L'installeur officiel est disponible avant toute interruption. L'artefact
  # llmster sera téléchargé par l'installeur officiel, qui vérifie son hash
  # lorsque le manifeste de sommes de contrôle est disponible.
  fetch_installer || die "Téléchargement ou validation de l'installeur impossible."
  backup_unit_state || die "Sauvegarde de l'unité systemd impossible."
  snapshot_bin || die "Sauvegarde de ${LMSTUDIO_HOME}/bin impossible."
  record_daemon_versions || die "Inventaire des versions du démon impossible."

  local was_active="false"
  service_active && was_active="true"

  if [[ "${was_active}" == "true" ]]; then
    step "🛑 Arrêt du service ${SERVICE_NAME}"
    systemctl stop "${SERVICE_NAME}.service" \
      || recover binaries "${was_active}" "Impossible d'arrêter le service."
  else
    if daemon_process_running; then
      step "🛑 Arrêt du démon llmster lancé hors systemd"
    fi
  fi
  if lms_installed; then
    lms_cli daemon down >/dev/null 2>&1 || true
  fi

  if ! wait_port_free 15; then
    recover binaries "${was_active}" "Le port ${SERVER_PORT} reste occupé après l'arrêt."
  fi

  if ! run_installer; then
    recover binaries "${was_active}" "L'installeur officiel a échoué."
  fi
  if ! lms_installed; then
    recover binaries "${was_active}" "Installation terminée mais ${LMS_BIN} est absent."
  fi

  step "🧩 Configuration du service systemd"
  if ! write_units; then
    recover binaries "${was_active}" "Impossible de valider ou d'écrire les unités systemd."
  fi
  if ! systemctl enable "${SERVICE_NAME}.service"; then
    recover binaries "${was_active}" "Impossible d'activer le service systemd."
  fi
  systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true

  step "🚀 Démarrage du service"
  if ! systemctl start "${SERVICE_NAME}.service"; then
    recover binaries "${was_active}" "Le service ne démarre pas."
  fi
  if ! health_acceptable; then
    recover binaries "${was_active}" \
      "Le service démarre, mais l'API ne répond pas après ${HEALTH_TIMEOUT}s."
  fi

  if [[ "${HEALTH_DEGRADED}" == "false" ]]; then
    ok "Serveur opérationnel sur http://${BIND_ADDR}:${SERVER_PORT}"
  else
    log "⚠️  Service démarré ; le serveur HTTP répond, sans validation authentifiée."
  fi
  check_preload
  apply_watchdog
  network_warning
  if [[ "${ENABLE_LM_LINK}" == "true" ]]; then
    show_link_status
  fi
  prune_failed_artifacts || warn "Purge des quarantaines impossible."
  finish_health_result
}

# update : met à jour llmster si une nouvelle version existe, avec
# sauvegarde préalable et restauration ciblée en cas d'échec.
cmd_update() {
  require_cmds curl awk grep cp cmp ss find sort
  require_installed
  require_unit

  # Le petit installeur annonce la dernière version avant de télécharger
  # l'archive llmster. Cela permet un arrêt anticipé sans toucher au service.
  fetch_installer || die "Téléchargement ou validation de l'installeur impossible."
  record_daemon_versions || die "Inventaire des versions du démon impossible."

  if daemon_version_installed "${INSTALLER_VERSION}"; then
    ok "llmster ${INSTALLER_VERSION} est déjà installé et exécutable."
    log "   Aucun téléchargement de l'archive llmster ni arrêt du service."
    return 0
  fi

  if [[ -d "${LMSTUDIO_HOME}/llmster/${INSTALLER_VERSION}" ]]; then
    warn "La version ${INSTALLER_VERSION} est présente mais son exécutable llmster est absent ou inutilisable ; réinstallation."
  fi

  prepare_auth || die "Impossible de préparer l'authentification de la sonde."
  check_runtime_libs
  preflight_gui

  if ! service_active && daemon_process_running; then
    die "Un démon llmster tourne hors systemd. Arrête-le ou lance d'abord « ${SCRIPT_NAME} install »."
  fi
  preflight_port

  # Préparer le filet de sécurité avant l'arrêt.
  backup_unit_state || die "Sauvegarde de l'unité systemd impossible."
  snapshot_bin || die "Sauvegarde de la version actuelle impossible."

  local was_active="false"
  service_active && was_active="true"

  if [[ "${was_active}" == "true" ]]; then
    step "🛑 Arrêt du service ${SERVICE_NAME}"
    if ! systemctl stop "${SERVICE_NAME}.service"; then
      recover binaries "${was_active}" "Impossible d'arrêter le service."
    fi
  fi
  lms_cli daemon down >/dev/null 2>&1 || true

  if ! wait_port_free 15; then
    recover binaries "${was_active}" "Le port ${SERVER_PORT} reste occupé après l'arrêt."
  fi

  # L'installeur a déjà été téléchargé et contrôlé avant l'arrêt. L'utiliser
  # directement évite une seconde résolution/téléchargement par
  # « lms daemon update » et les différences de PATH de son processus interne.
  step "🔄 Mise à jour de llmster avec l'installeur officiel"
  if ! run_installer; then
    recover binaries "${was_active}" "L'installeur officiel a échoué."
  fi

  if [[ ! -x "${LMS_BIN}" ]]; then
    recover binaries "${was_active}" \
      "Mise à jour terminée mais ${LMS_BIN} est absent."
  fi

  # Une mise à jour applique également les évolutions de l'unité générée par ce
  # script, tout en conservant son état enabled/disabled.
  if ! write_units; then
    recover binaries "${was_active}" "Les nouvelles unités systemd sont invalides."
  fi

  step "🚀 Vérification de la nouvelle version"
  systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
  if ! systemctl start "${SERVICE_NAME}.service"; then
    recover binaries "${was_active}" "La nouvelle version ne démarre pas."
  fi
  if ! health_acceptable; then
    recover binaries "${was_active}" \
      "L'API ne répond pas après ${HEALTH_TIMEOUT}s avec la nouvelle version."
  fi
  # Lu avant un éventuel retour à l'arrêt, tant que le résultat est frais.
  check_preload

  if [[ "${was_active}" == "false" ]]; then
    systemctl stop "${SERVICE_NAME}.service" \
      || die "Mise à jour validée, mais impossible de remettre le service à l'arrêt."
    if [[ "${HEALTH_DEGRADED}" == "false" ]]; then
      ok "Mise à jour validée ; le service reste arrêté comme avant."
    else
      log "⚠️  Mise à jour conservée ; le serveur a répondu avant le retour à l'arrêt."
    fi
  else
    if [[ "${HEALTH_DEGRADED}" == "false" ]]; then
      ok "Mise à jour appliquée, API opérationnelle."
    else
      log "⚠️  Mise à jour appliquée ; le serveur répond, sans validation authentifiée."
    fi
  fi

  if [[ -z "${PRELOAD_MODEL}" ]]; then
    log "   Aucun modèle rechargé de force ; le prochain appel pourra utiliser le JIT."
  fi
  apply_watchdog
  prune_failed_artifacts || warn "Purge des quarantaines impossible."
  finish_health_result
}

# configure : réécrit l'unité depuis la configuration, puis redémarre le
# service s'il était actif ; restaure l'ancienne unité en cas d'échec.
cmd_configure() {
  require_cmds curl cp cmp
  require_installed
  require_unit
  prepare_auth || die "Impossible de préparer l'authentification de la sonde."
  preflight_gui
  backup_unit_state || die "Sauvegarde de l'unité systemd impossible."

  local was_active="false"
  service_active && was_active="true"

  step "🧩 Application de ${CONFIG_FILE}"
  if ! write_units; then
    recover unit "${was_active}" \
      "Impossible de valider ou d'écrire les nouvelles unités."
  fi

  if [[ "${was_active}" == "false" ]]; then
    # Aucune sonde n'a tourné ici : pas de verdict de santé à rendre. Le timer
    # peut être armé sans risque : il ignore un service arrêté.
    ok "Configuration appliquée ; le service reste arrêté comme avant."
    apply_watchdog
    network_warning
    return 0
  fi

  step "🔄 Redémarrage avec la nouvelle configuration"
  if ! systemctl restart "${SERVICE_NAME}.service"; then
    recover unit "${was_active}" \
      "Le service ne démarre pas avec la nouvelle configuration."
  fi
  if ! health_acceptable; then
    recover unit "${was_active}" \
      "L'API ne répond pas après ${HEALTH_TIMEOUT}s avec la nouvelle configuration."
  fi

  if [[ "${HEALTH_DEGRADED}" == "false" ]]; then
    ok "Configuration appliquée et API opérationnelle."
  else
    log "⚠️  Configuration appliquée ; le serveur répond, sans validation authentifiée."
  fi
  check_preload
  apply_watchdog
  network_warning
  finish_health_result
}

# start : démarre le service et attend que l'API réponde.
cmd_start() {
  require_cmds curl ss awk
  require_installed
  require_unit
  prepare_auth || die "Impossible de préparer l'authentification de la sonde."
  preflight_gui

  if service_active; then
    # Sonde immédiate : le service tourne déjà, rien ne justifie d'attendre.
    if health_snapshot; then
      if [[ "${HEALTH_DEGRADED}" == "false" ]]; then
        ok "Service déjà actif et API opérationnelle sur le port ${SERVER_PORT}"
      else
        log "⚠️  Service déjà actif ; le serveur répond, sans validation authentifiée."
      fi
      network_warning
      finish_health_result
      return 0
    fi
    die "Le service est déjà actif mais l'API est muette. Utilise « ${SCRIPT_NAME} restart »."
  fi

  if ! wait_port_free 10; then
    die "Le port ${SERVER_PORT} est encore occupé. Diagnostic : sudo ss -ltnp 'sport = :${SERVER_PORT}'"
  fi

  if ! systemctl start "${SERVICE_NAME}.service"; then
    die "Le service ${SERVICE_NAME} ne démarre pas. Voir : journalctl -u ${SERVICE_NAME} -n 100"
  fi
  if health_acceptable; then
    if [[ "${HEALTH_DEGRADED}" == "false" ]]; then
      ok "Serveur opérationnel sur le port ${SERVER_PORT}"
    else
      log "⚠️  Service démarré ; le serveur répond, sans validation authentifiée."
    fi
    check_preload
    network_warning
    finish_health_result
  else
    die "Service démarré mais API muette. Voir : journalctl -u ${SERVICE_NAME} -n 100"
  fi
}

# stop : arrête le service et le démon. Le timer de surveillance reste armé :
# il ignore un service arrêté, et « start » suffit à retrouver la protection.
# N'annonce l'arrêt que s'il est constaté.
cmd_stop() {
  if [[ -f "${UNIT_PATH}" ]]; then
    if ! systemctl stop "${SERVICE_NAME}.service"; then
      warn "systemd n'a pas pu arrêter proprement le service."
    fi
  fi
  if lms_installed; then
    lms_cli daemon down >/dev/null 2>&1 || true
  fi

  if service_active; then
    die "Le service ${SERVICE_NAME} est toujours actif. Voir : journalctl -u ${SERVICE_NAME} -n 100"
  fi
  local deadline=$((SECONDS + 5))
  while daemon_process_running && (( SECONDS < deadline )); do
    sleep 1
  done
  if daemon_process_running; then
    warn "Un processus llmster tourne encore sous ${LMS_USER} : pgrep -a -u ${LMS_USER} -x llmster"
  fi
  step "🛑 Service ${SERVICE_NAME} arrêté."
}

# restart : stop puis start.
cmd_restart() {
  cmd_stop
  cmd_start
}

# status : état du service, du démon, du serveur, des modèles et de LM Link.
# N'appelle lms que si l'API répond, pour ne jamais démarrer le démon.
cmd_status() {
  local auth_ok="true"
  local health_rc=1
  local api_available="false"
  prepare_auth || auth_ok="false"

  # Certaines sous-commandes lms créent un client local et peuvent tenter de
  # démarrer llmster. La sonde HTTP, passive, décide donc si le CLI peut être
  # interrogé sans transformer « status » en commande de démarrage implicite.
  if [[ "${auth_ok}" == "true" ]]; then
    health_rc=0
    health_probe || health_rc=$?
    case "${health_rc}" in
      0|2) api_available="true" ;;
    esac
  fi

  if [[ -f "${UNIT_PATH}" ]]; then
    systemctl status "${SERVICE_NAME}.service" --no-pager || true
  else
    warn "Unité absente : ${UNIT_PATH}"
  fi

  log ""
  step "── Surveillance ──"
  if [[ -f "${WATCHDOG_TIMER_PATH}" ]]; then
    systemctl list-timers "${SERVICE_NAME}-watchdog.timer" --all --no-pager \
      2>/dev/null | sed -n '1,2p' || true
    if ! systemctl is-active --quiet "${SERVICE_NAME}-watchdog.timer"; then
      warn "Timer de surveillance installé mais inactif : sudo ${SCRIPT_NAME} configure"
    fi
  elif (( WATCHDOG_INTERVAL > 0 )); then
    warn "Surveillance demandée mais non installée : sudo ${SCRIPT_NAME} configure"
  else
    log "   Désactivée (WATCHDOG_INTERVAL=0)."
  fi

  if lms_installed && [[ "${api_available}" == "true" ]]; then
    log ""
    step "── Démon ──"
    lms_cli daemon status || true
    log ""
    step "── Serveur ──"
    lms_cli server status || true
    log ""
    step "── Modèles en mémoire ──"
    lms_cli ps || true
    if [[ "${ENABLE_LM_LINK}" == "true" ]]; then
      log ""
      show_link_status
    fi
  elif lms_installed; then
    log ""
    step "── Détails LM Studio ──"
    log "   Non interrogés : API indisponible ; aucun appel lms n'est effectué."
  fi

  log ""
  if [[ "${auth_ok}" == "false" ]]; then
    log "❌ API : sonde non exécutée, configuration du jeton invalide."
    return 0
  fi

  case "${health_rc}" in
    0) ok "API : http://${HEALTH_HOST}:${SERVER_PORT}${HEALTH_PATH} répond." ;;
    2) log "⚠️  API : le serveur répond (HTTP ${HEALTH_LAST_CODE}) mais rejette la sonde ; vérifie API_TOKEN_FILE." ;;
    *) log "❌ API : aucune réponse sur le port ${SERVER_PORT} (dernier code : ${HEALTH_LAST_CODE})." ;;
  esac
}

# health : sonde unique, codes 0/1/2 exploitables en supervision.
cmd_health() {
  require_cmds curl
  prepare_auth || die "Impossible de préparer l'authentification de la sonde."
  local rc=0
  health_probe || rc=$?
  case "${rc}" in
    0)
      ok "OK (${HEALTH_PATH})"
      return 0
      ;;
    2)
      warn "Le serveur répond (HTTP ${HEALTH_LAST_CODE}) mais rejette la sonde : vérifie API_TOKEN_FILE."
      exit 2
      ;;
  esac
  die "API injoignable sur le port ${SERVER_PORT} (dernier code : ${HEALTH_LAST_CODE})."
}

# logs [N] : N dernières lignes du journal systemd (défaut : 100).
cmd_logs() {
  require_cmds journalctl
  local lines="${1:-100}"
  [[ "${lines}" =~ ^[1-9][0-9]*$ ]] \
    || die "Le nombre de lignes doit être un entier strictement positif."
  (( 10#${lines} <= 100000 )) \
    || die "Le nombre de lignes demandé est trop grand."

  journalctl -u "${SERVICE_NAME}.service" -n "${lines}" --no-pager
  log ""
  log "Flux des requêtes : sudo -u ${LMS_USER} -H ${LMS_BIN} log stream"
}

# models : modèles chargés en mémoire et présents sur disque. Comme status,
# n'appelle lms que si l'API répond : sinon le CLI démarrerait un démon hors
# systemd, qui bloquerait ensuite « update ».
cmd_models() {
  require_cmds curl
  require_installed
  prepare_auth || die "Impossible de préparer l'authentification de la sonde."
  local rc=0
  health_probe || rc=$?
  if (( rc != 0 && rc != 2 )); then
    die "API indisponible sur le port ${SERVER_PORT} : démarre d'abord le service (sudo ${SCRIPT_NAME} start)."
  fi

  step "── En mémoire ──"
  lms_cli ps || true
  log ""
  step "── Sur disque ──"
  lms_cli ls || true
}

# check : valide la configuration et l'unité générée sans rien installer.
cmd_check() {
  require_cmds cmp
  if [[ -n "${API_TOKEN_FILE}" ]]; then
    prepare_auth || die "Configuration API_TOKEN_FILE invalide."
  fi

  render_candidates || die "Génération des unités impossible."
  if lms_installed; then
    verify_candidates \
      || die "Les unités systemd générées ne sont pas valides."
  else
    warn "llmster n'est pas encore installé : contrôle systemd approfondi ignoré."
  fi

  ok "Configuration valide (${SCRIPT_NAME} ${SCRIPT_VERSION})"
  log "   Utilisateur : ${LMS_USER}"
  log "   CLI         : ${LMS_BIN}"
  log "   Service     : ${SERVICE_NAME}.service"
  log "   API         : ${BIND_ADDR}:${SERVER_PORT}"
  log "   Sonde       : ${HEALTH_CANDIDATES[*]}"
  if (( WATCHDOG_INTERVAL > 0 )); then
    log "   Surveillance: toutes les ${WATCHDOG_INTERVAL}s (${WATCHDOG_HELPER_PATH})"
  else
    log "   Surveillance: désactivée"
  fi
  log "   Sauvegarde  : ${BACKUP_DIR} — $(backup_disk_usage), rétention ${FAILED_RETENTION}"
  if [[ -z "${PRELOAD_MODEL}" ]]; then
    warn "Aucun préchargement. Active le JIT dans LM Studio si tu le souhaites."
  fi
  network_warning
}

# uninstall [--purge] : retire l'unité ; --purge supprime aussi BACKUP_DIR.
cmd_uninstall() {
  local purge="false"
  if [[ "${1:-}" == "--purge" ]]; then
    purge="true"
  elif [[ -n "${1:-}" ]]; then
    die "Option inconnue pour uninstall : ${1}"
  fi

  cmd_stop
  systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true

  UNITS_CHANGED="false"
  remove_watchdog_files
  if [[ -f "${UNIT_PATH}" ]]; then
    rm -f -- "${UNIT_PATH}"
    UNITS_CHANGED="true"
  fi
  if [[ "${UNITS_CHANGED}" == "true" ]]; then
    systemctl daemon-reload
  fi

  ok "Service ${SERVICE_NAME} retiré."

  if [[ "${purge}" == "true" ]]; then
    # Volontairement limité à ${BACKUP_DIR} : les modèles et l'installation
    # llmster appartiennent à l'utilisateur, ce script ne les supprime jamais.
    if [[ -d "${BACKUP_DIR}" ]]; then
      rm -rf -- "${BACKUP_DIR:?}"
      log "   Sauvegardes et quarantaines supprimées : ${BACKUP_DIR}"
    fi
  else
    log "   Sauvegardes et versions écartées restent dans ${BACKUP_DIR} ($(backup_disk_usage))."
    log "   « uninstall --purge » les supprime."
  fi

  log "   llmster et les modèles sont conservés dans ${LMSTUDIO_HOME} : à retirer à la main si besoin."
}

# Affiche l'aide, avec les valeurs de configuration effectives.
usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} — LM Studio headless (llmster) piloté en CLI

Usage : sudo ${SCRIPT_NAME} <commande> [arguments]

Commandes :
  install             installe/réinstalle llmster, écrit et active l'unité
  update              met à jour llmster si nécessaire, avec rollback ciblé
  configure           applique le fichier de configuration et redémarre si actif
  check               valide la configuration et l'unité, sans installation
  start | stop | restart
  status              état passif du service, du démon, du serveur, des modèles et Link
  health              sonde HTTP authentifiable, exploitable en supervision
  logs [N]            N dernières lignes du journal (défaut : 100)
  models              modèles en mémoire et sur disque
  uninstall [--purge] retire l'unité (llmster et modèles conservés ; --purge
                      supprime aussi les sauvegardes et quarantaines)
  help, -h, --help    affiche cette aide et quitte (sans sudo)
  version, -V, --version
                      affiche la version et quitte (sans sudo)

Configuration — ${CONFIG_FILE} (root:root, mode 0644 ou plus restrictif) :

  LMS_USER=${LMS_USER:-<requis>}
  SERVICE_NAME=${SERVICE_NAME}
  SERVER_PORT=${SERVER_PORT}
  BIND_ADDR=${BIND_ADDR}              # défaut sûr : local uniquement
  PRELOAD_MODEL=${PRELOAD_MODEL:-<vide>}
  LOAD_ARGS=${LOAD_ARGS:-<vide>}       # ex. "--context-length 65536 --gpu 1.0"
  HEALTH_TIMEOUT=${HEALTH_TIMEOUT}
  ENABLE_LM_LINK=${ENABLE_LM_LINK}
  API_TOKEN_FILE=${API_TOKEN_FILE:-<vide>}
  FAILED_RETENTION=${FAILED_RETENTION}          # quarantaines d'échec conservées
  WATCHDOG_INTERVAL=${WATCHDOG_INTERVAL}        # surveillance de l'API (s), 0 = désactivée

  Ces variables peuvent aussi être passées par l'environnement ; le fichier
  de configuration, chargé ensuite, a priorité.

Si l'authentification LM Studio est activée :

  sudo install -m 0600 -o root -g root /dev/null /etc/lmstudio-api-token
  sudoedit /etc/lmstudio-api-token
  API_TOKEN_FILE=/etc/lmstudio-api-token

Variables d'environnement :
  NO_COLOR            désactive les couleurs si elle est définie
  LMSCTL_CONFIG       autre fichier de configuration (mêmes contrôles de droits)

Codes de sortie :
  0  opération réussie et vérifiée
  1  échec (une restauration ciblée a pu être tentée : lire les messages)
  2  opération conservée, mais contrôle authentifié impossible (HTTP 401/403)
  3  opération conservée, API saine, mais le préchargement de PRELOAD_MODEL a échoué

Notes :
  - PRELOAD_MODEL vide ne suffit pas à activer le JIT : règle-le dans LM Studio.
  - PRELOAD_MODEL est chargé après le démarrage de l'API, sans bloquer : un
    échec de chargement n'annule jamais une mise à jour (code 3).
  - LOAD_ARGS est lu depuis un fichier root ; contrôles, « % », « \$ », « \\ » et
    « ; » sont refusés (systemd les interpréterait).
  - Le timer ${SERVICE_NAME}-watchdog.timer redémarre le service après 3 sondes
    muettes. Il ignore un service arrêté ou en échec, et s'efface devant lmsctl.
  - Avec 0.0.0.0, active Require Authentication et filtre le port au pare-feu.
  - Un rejet HTTP 401/403 conserve l'opération mais renvoie le code 2 : corrige
    API_TOKEN_FILE avant de considérer le contrôle comme sain.
  - Le rollback couvre bin/, les nouvelles versions llmster et l'unité systemd ;
    il ne constitue pas un instantané complet de ~/.lmstudio (dont .internal).
  - Les quarantaines d'échec sont purgées après chaque install, update ou
    échec, au-delà de FAILED_RETENTION ; celle de l'échec en cours est
    toujours gardée. Surveille leur volume avec « ${SCRIPT_NAME} check ».
EOF
}

# --- Point d'entrée ----------------------------------------------------------

# Point d'entrée : les commandes d'information passent sans root ; les autres
# exigent root, valident la configuration, prennent le verrou puis sont
# dispatchées vers la fonction cmd_* correspondante.
main() {
  local command="${1:-help}"
  shift || true

  case "${command}" in
    help|-h|--help)
      usage
      return 0
      ;;
    version|-V|--version)
      printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"
      return 0
      ;;
  esac

  require_root "${command}"
  require_cmds runuser systemctl flock id getent stat realpath pgrep mktemp \
    install chmod rm mv env sleep timeout date tar cp
  TIMEOUT_BIN="$(command -v timeout)"
  [[ "${TIMEOUT_BIN}" == /* ]] \
    || die "timeout doit être une commande externe accessible par chemin absolu."
  validate_config
  resolve_user

  WORK_DIR="$(mktemp -d)"
  chmod 0755 "${WORK_DIR}"

  install -d -m 0755 "${LOCK_FILE%/*}"
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    die "Une autre instance de ${SCRIPT_NAME}, ou la surveillance de l'API, est en cours. Réessaie dans un instant."
  fi

  RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  FAILED_DIR="${BACKUP_DIR}/failed/${RUN_ID}"

  case "${command}" in
    install)   cmd_install ;;
    update)    cmd_update ;;
    configure) cmd_configure ;;
    check)     cmd_check ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_restart ;;
    status)    cmd_status ;;
    health)    cmd_health ;;
    logs)      cmd_logs "$@" ;;
    models)    cmd_models ;;
    uninstall) cmd_uninstall "$@" ;;
    *)
      usage >&2
      die "Commande inconnue : ${command}"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi

