#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-lmstudio.sh — installe ou met à jour LM Studio Desktop (AppImage)
#                       sous Ubuntu, et sait l'arrêter proprement
#
#   sudo install-lmstudio.sh              installe LM Studio s'il est absent, sinon
#                                         le met à jour si une nouvelle version existe
#   sudo install-lmstudio.sh --force      retélécharge même si la version est identique
#   sudo install-lmstudio.sh --rollback   revient à la version précédente
#   sudo install-lmstudio.sh --stop       arrête proprement LM Studio, sans rien installer
#   install-lmstudio.sh --version         affiche la version du script
#
# Seule l'AppImage est installée (dans LMSTUDIO_DIR) : aucun raccourci de
# bureau ni lien dans le PATH n'est créé.
#
# Ordre des opérations :
#   1. téléchargement dans un fichier temporaire, LM Studio continue de tourner ;
#   2. vérification du fichier (taille, format AppImage) ;
#   3. arrêt de LM Studio, seulement à ce moment-là ;
#   4. l'ancienne version est gardée en .old, puis remplacement par mv.
# En cas d'échec avant l'étape 4, l'installation en place n'est pas touchée.
#
# L'arrêt de LM Studio (étape 3 et --stop) décharge d'abord les modèles et
# arrête le serveur API avec le CLI « lms » de l'utilisateur qui fait tourner
# l'application, puis envoie SIGTERM ; SIGKILL en dernier recours.
#
# Dépendances : bash, curl, util-linux (flock, runuser), coreutils, procps
# (pgrep, pkill, ps), libfuse2 pour lancer l'AppImage.
# Voir « install-lmstudio.sh --help ».

set -Eeuo pipefail
umask 022

readonly LMSTUDIO_DIR="${LMSTUDIO_DIR:-/opt/lmstudio}"
readonly LMSTUDIO_URL="${LMSTUDIO_URL:-https://lmstudio.ai/download/latest/linux/x64}"
# CLI lms utilisé pour l'arrêt propre. Vide = ~/.lmstudio/bin/lms de
# l'utilisateur qui fait tourner LM Studio.
readonly LMS_BIN="${LMS_BIN:-}"

readonly BIN="${LMSTUDIO_DIR}/LM-Studio.AppImage"
readonly OLD="${BIN}.old"
readonly VERSION_FILE="${LMSTUDIO_DIR}/VERSION"
readonly OLD_VERSION_FILE="${VERSION_FILE}.old"
# Dans /run (écriture réservée à root) et non /run/lock (1777) : un autre
# utilisateur ne peut ni créer ce verrou avant root ni le garder.
readonly LOCK_FILE="/run/install-lmstudio.lock"
# Une AppImage LM Studio pèse plusieurs centaines de Mo : en dessous de ce
# seuil, le fichier reçu est presque sûrement une page d'erreur.
readonly MIN_SIZE=$((100 * 1024 * 1024))
readonly SCRIPT_NAME="${0##*/}"
# Version du script (et non de LM Studio). À augmenter à chaque modification :
# 1.0.0 → 1.0.1 pour une correction, 1.1.0 pour une nouvelle option.
readonly SCRIPT_VERSION="1.1.1"

TMP=""   # AppImage en cours de téléchargement, supprimée en cas d'échec

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

# --- Nettoyage et erreurs ----------------------------------------------------

# Supprime le téléchargement inachevé, quelle que soit la cause de la sortie.
cleanup() {
  if [[ -n "${TMP}" && -e "${TMP}" ]]; then
    rm -f -- "${TMP}"
  fi
}
trap cleanup EXIT
# Toute commande en échec non gérée arrête le script en indiquant la ligne.
trap 'die "Échec ligne ${LINENO} : ${BASH_COMMAND}"' ERR

# --- Aide --------------------------------------------------------------------

# Affiche l'aide sur stdout.
usage() {
  cat <<EOF
${SCRIPT_NAME} ${SCRIPT_VERSION} — installe ou met à jour LM Studio Desktop (AppImage)

Usage : sudo ${SCRIPT_NAME} [option]

Options :
  (sans option)    installe LM Studio s'il est absent, sinon le met à jour
                   si une nouvelle version existe
  --force          retélécharge et réinstalle même si la version est identique
  --rollback       revient à la version précédente (${OLD}) ;
                   un second --rollback annule le premier
  --stop           arrête proprement LM Studio (modèles déchargés, serveur API
                   arrêté), sans rien installer
  -h, --help       affiche cette aide et quitte
  -V, --version    affiche la version de ce script et quitte

Variables d'environnement :
  LMSTUDIO_DIR     répertoire d'installation        (défaut : /opt/lmstudio)
  LMSTUDIO_URL     URL de téléchargement « latest »
  LMS_BIN          CLI lms pour l'arrêt propre
                   (défaut : ~/.lmstudio/bin/lms du propriétaire du processus)
  NO_COLOR         désactive les couleurs si elle est définie

Codes de sortie :
  0  installé, à jour, mis à jour, restauré ou arrêté
  1  échec (l'installation en place n'est pas modifiée avant le remplacement)

Notes :
  - LM Studio n'est arrêté qu'une fois la nouvelle AppImage téléchargée et
    vérifiée.
  - Seule l'AppImage est installée : ${BIN}.
    Aucun raccourci de bureau n'est créé.
  - L'AppImage nécessite libfuse2 (libfuse2t64 à partir d'Ubuntu 24.04).
EOF
}

# --- Vérifications ------------------------------------------------------------

# Quitte si le script n'est pas lancé en root.
require_root() {
  [[ "${EUID}" -eq 0 ]] \
    || die "Ce script doit être exécuté avec sudo. Exemple : sudo $0"
}

# Vérifie que toutes les commandes externes utilisées sont présentes.
require_cmds() {
  local cmd
  for cmd in curl flock stat head od pgrep pkill ps runuser getent timeout; do
    command -v "${cmd}" >/dev/null 2>&1 || die "Commande requise absente : ${cmd}"
  done
}

# Les AppImage de type 2 ont besoin de libfuse2. Sans elle, l'application ne
# démarre pas. Le paquet s'appelle libfuse2 jusqu'à Ubuntu 23.10, puis
# libfuse2t64 à partir de 24.04.
#
# La sortie de ldconfig est d'abord lue en entier. Un « ldconfig | grep -q »
# ne convient pas ici : grep -q s'arrête au premier résultat, ldconfig reçoit
# alors SIGPIPE (code 141), et avec pipefail la ligne entière est vue comme
# un échec, même quand la bibliothèque est présente.
check_fuse() {
  local libs pkg="libfuse2"
  libs="$(ldconfig -p 2>/dev/null)" || libs=""
  [[ "${libs}" == *libfuse.so.2* ]] && return 0

  if apt-cache show libfuse2t64 >/dev/null 2>&1; then
    pkg="libfuse2t64"
  fi
  warn "libfuse2 est absente : installe-la avec « sudo apt install ${pkg} »."
}

# Verrou exclusif : empêche deux exécutions simultanées.
lock() {
  exec 9>"${LOCK_FILE}"
  flock -n 9 || die "Une autre exécution de ${SCRIPT_NAME} est déjà en cours."
}

# --- Version ------------------------------------------------------------------

# Le lien « latest » redirige vers un fichier nommé avec la version, par
# exemple LM-Studio-0.3.30-1-x64.AppImage. Ce nom sert de numéro de version.
remote_version() {
  local url
  url="$(curl -fsSLI --proto '=https' --tlsv1.2 \
           --connect-timeout 15 --max-time 30 \
           -o /dev/null -w '%{url_effective}' "${LMSTUDIO_URL}")" || return 1
  url="${url%%\?*}"
  url="${url##*/}"
  [[ "${url}" == *.AppImage ]] || return 1
  printf '%s\n' "${url}"
}

# Version installée, lue dans VERSION_FILE (vide si inconnue).
local_version() {
  [[ -r "${VERSION_FILE}" ]] && head -n 1 "${VERSION_FILE}"
  return 0
}

# --- Fichier téléchargé -------------------------------------------------------

# Une AppImage de type 2 est un fichier ELF avec « AI\x02 » à l'octet 8.
is_appimage() {
  local file="$1" magic
  magic="$(head -c 11 -- "${file}" | od -An -tx1 | tr -d ' \n')"
  [[ "${magic}" == 7f454c46????????414902 ]]
}

# Télécharge l'AppImage dans un fichier temporaire du même répertoire
# (le mv final reste ainsi atomique), puis vérifie sa taille et son format.
download() {
  TMP="$(mktemp "${LMSTUDIO_DIR}/.LM-Studio.AppImage.XXXXXX")"

  step "⬇️  Téléchargement de LM Studio"
  curl -fL --proto '=https' --tlsv1.2 --retry 3 --retry-all-errors \
       --connect-timeout 15 --progress-bar \
       -o "${TMP}" "${LMSTUDIO_URL}" \
    || die "Téléchargement impossible."

  local size
  size="$(stat -c '%s' -- "${TMP}")"
  (( size >= MIN_SIZE )) \
    || die "Fichier reçu trop petit (${size} octets) : ce n'est pas une AppImage."
  is_appimage "${TMP}" \
    || die "Le fichier reçu n'est pas une AppImage valide."

  chmod 0755 -- "${TMP}"
  log "   Fichier vérifié : $(( size / 1024 / 1024 )) Mo"
}

# --- Arrêt de LM Studio -------------------------------------------------------

# Le motif est ancré au début de la ligne de commande : il ne reconnaît que
# l'AppImage lancée et le binaire qu'elle monte (/tmp/.mount_LM…/lm-studio),
# pas un éditeur ou un terminal dont la commande cite simplement le fichier.
readonly APP_PATTERN='^([^ ]*/)?LM-Studio[^/ ]*\.AppImage( |$)|^/tmp/\.mount_[^/ ]+/lm-studio( |$)'

# Vrai si LM Studio Desktop tourne (voir APP_PATTERN).
app_running() {
  pgrep -f "${APP_PATTERN}" >/dev/null 2>&1
}

# Utilisateur propriétaire du plus ancien processus LM Studio.
app_owner() {
  local pid
  pid="$(pgrep -o -f "${APP_PATTERN}")" || return 1
  ps -o user= -p "${pid}" | tr -d ' '
}

# Exécute « lms $@ » sous l'utilisateur $1, qui fait tourner LM Studio :
# lancé en root, lms ne trouverait pas l'instance de cet utilisateur.
# Délai borné à 30 s pour ne jamais bloquer l'arrêt ; sortie masquée.
lms_as() {
  local user="$1" home lms
  shift
  home="$(getent passwd "${user}" | cut -d: -f6)" || return 1
  lms="${LMS_BIN:-${home}/.lmstudio/bin/lms}"
  [[ -x "${lms}" ]] || return 1
  timeout 30 runuser -u "${user}" -- env HOME="${home}" "${lms}" "$@" \
    >/dev/null 2>&1 9>&-
}

# Arrête LM Studio s'il tourne : déchargement des modèles et arrêt du serveur
# API via lms (ancien kill-lms.sh), puis SIGTERM ; après 15 s, SIGKILL en
# dernier recours.
stop_app() {
  app_running || return 0
  step "🛑 Arrêt de LM Studio"

  local owner=""
  owner="$(app_owner)" || owner=""
  if [[ -n "${owner}" ]] && lms_as "${owner}" unload --all; then
    log "   Modèles déchargés"
    lms_as "${owner}" server stop && log "   Serveur API arrêté"
  else
    log "   CLI lms indisponible : arrêt par signal uniquement"
  fi

  pkill -TERM -f "${APP_PATTERN}" || true
  # Noms de processus visés par l'ancien kill-lms.sh.
  pkill -TERM -x lm-studio || true
  pkill -TERM -x lms-studio || true

  local _
  for _ in {1..15}; do
    app_running || return 0
    sleep 1
  done

  warn "LM Studio ne s'arrête pas : arrêt forcé."
  pkill -KILL -f "${APP_PATTERN}" || true
  sleep 1
  ! app_running || die "Impossible d'arrêter LM Studio."
}

# --- Commandes ----------------------------------------------------------------

# Met à jour LM Studio. $1 = « true » pour réinstaller même si la version
# distante est identique (--force).
cmd_update() {
  local force="$1" remote current installed="false"
  install -d -m 0755 "${LMSTUDIO_DIR}"
  [[ -e "${BIN}" ]] && installed="true"

  current="$(local_version)"
  if remote="$(remote_version)"; then
    info "Version disponible : ${remote}"
    log "   Version installée  : ${current:-inconnue}"
    if [[ "${force}" == "false" && "${remote}" == "${current}" && -x "${BIN}" ]]; then
      ok "LM Studio est déjà à jour. Rien à faire (--force pour réinstaller)."
      return 0
    fi
  else
    warn "Version distante inconnue : téléchargement complet."
    remote=""
  fi

  download
  local was_running="false"
  app_running && was_running="true"
  stop_app

  # L'ancienne version est gardée par un lien physique : instantané, sans
  # copie, et l'ancien fichier reste utilisable pour --rollback.
  if [[ -e "${BIN}" ]]; then
    ln -f -- "${BIN}" "${OLD}"
    if [[ -n "${current}" ]]; then
      printf '%s\n' "${current}" >"${OLD_VERSION_FILE}"
    else
      rm -f -- "${OLD_VERSION_FILE}"
    fi
  fi

  mv -f -- "${TMP}" "${BIN}"
  TMP=""
  if [[ -n "${remote}" ]]; then
    printf '%s\n' "${remote}" >"${VERSION_FILE}"
  else
    rm -f -- "${VERSION_FILE}"
  fi

  if [[ "${installed}" == "true" ]]; then
    ok "LM Studio a été mis à jour${remote:+ : ${remote}}"
  else
    ok "LM Studio a été installé${remote:+ : ${remote}}"
  fi
  log "   ${BIN}"
  [[ -e "${OLD}" ]] && log "   Version précédente gardée : ${OLD} (--rollback pour y revenir)"
  if [[ "${was_running}" == "true" ]]; then
    hint "LM Studio a été arrêté pour la mise à jour : relance-le."
  fi
  return 0
}

# Échange la version installée et la version précédente (.old).
cmd_rollback() {
  [[ -x "${OLD}" ]] || die "Aucune version précédente trouvée (${OLD})."
  local was_running="false"
  app_running && was_running="true"
  stop_app

  # Échange des deux versions : un second --rollback annule le premier.
  local swap="${BIN}.swap"
  if [[ -e "${BIN}" ]]; then
    ln -f -- "${BIN}" "${swap}"
  fi
  mv -f -- "${OLD}" "${BIN}"
  [[ -e "${swap}" ]] && mv -f -- "${swap}" "${OLD}"

  local v_cur="" v_old=""
  [[ -r "${VERSION_FILE}" ]] && v_cur="$(head -n 1 "${VERSION_FILE}")"
  [[ -r "${OLD_VERSION_FILE}" ]] && v_old="$(head -n 1 "${OLD_VERSION_FILE}")"
  if [[ -n "${v_old}" ]]; then printf '%s\n' "${v_old}" >"${VERSION_FILE}"; else rm -f -- "${VERSION_FILE}"; fi
  if [[ -n "${v_cur}" ]]; then printf '%s\n' "${v_cur}" >"${OLD_VERSION_FILE}"; else rm -f -- "${OLD_VERSION_FILE}"; fi

  step "↩️  Retour à la version précédente${v_old:+ : ${v_old}}"
  if [[ "${was_running}" == "true" ]]; then
    hint "LM Studio a été arrêté pour le retour arrière : relance-le."
  fi
}

# stop : arrête proprement LM Studio, sans rien installer.
cmd_stop() {
  if app_running; then
    stop_app
    ok "LM Studio est arrêté."
  else
    info "LM Studio ne tourne pas : rien à arrêter."
  fi
}

# Point d'entrée : lit l'option, prend le verrou et lance la commande.
main() {
  local mode="update"
  case "${1:-}" in
    "")          ;;
    --force)     mode="force" ;;
    --rollback)  mode="rollback" ;;
    --stop)      mode="stop" ;;
    -h|--help)   usage; return 0 ;;
    -V|--version) printf '%s %s\n' "${SCRIPT_NAME}" "${SCRIPT_VERSION}"; return 0 ;;
    *)           usage >&2; die "Option inconnue : $1" ;;
  esac

  require_root
  step "🔧 ${SCRIPT_NAME} ${SCRIPT_VERSION}"
  require_cmds
  lock

  case "${mode}" in
    update)   cmd_update false ;;
    force)    cmd_update true ;;
    rollback) cmd_rollback ;;
    stop)     cmd_stop; return 0 ;;
  esac
  check_fuse
}

main "$@"

