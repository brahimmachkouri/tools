#!/usr/bin/env bats
# SPDX-License-Identifier: MIT
#
# Tests unitaires de lmsctl.sh : validation, génération des unités, sonde,
# installeur, préchargement et script de surveillance. Aucun accès réseau,
# root ou systemd : curl, systemctl, flock et sleep sont remplacés par des
# doublures placées en tête du PATH.
#
#   bats tests/

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../lmsctl.sh"
  FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${FAKE_BIN}"
  export SCRIPT FAKE_BIN
  export PATH="${FAKE_BIN}:${PATH}"
  export LMS_USER="tester"
  export NO_COLOR=1
  # Jamais la configuration de la machine qui exécute les tests.
  export LMSCTL_CONFIG="${BATS_TEST_TMPDIR}/absent"
}

# Exécute du code Bash après avoir sourcé le script, dans un processus séparé :
# set -e et le trap ERR du script ne touchent pas bats.
in_script() {
  run bash -c 'source "${SCRIPT}"; '"$1"
}

# Valeurs que resolve_user calculerait, pour les fonctions de rendu.
FIXTURE='
  LMS_HOME=/home/tester
  LMSTUDIO_HOME=/home/tester/.lmstudio
  LMS_BIN=/home/tester/.lmstudio/bin/lms
  TIMEOUT_BIN=/usr/bin/timeout
  WORK_DIR="${BATS_TEST_TMPDIR}/work"; mkdir -p "${WORK_DIR}"
'

fake() {
  printf '#!/bin/sh\n%s\n' "$2" >"${FAKE_BIN}/$1"
  chmod +x "${FAKE_BIN}/$1"
}

# Doublure de curl : code HTTP choisi par chemin, 000 = pas de réponse.
fake_curl() {
  fake curl '
for a; do url="$a"; done
case "$url" in
  */api/v1/models) code="${CODE_API:-000}" ;;
  */v1/models)     code="${CODE_V1:-000}" ;;
  *)               code=000 ;;
esac
printf "%s" "$code"
[ "$code" != 000 ] || exit 7'
}

# --- Validation de la configuration -----------------------------------------

@test "configuration par défaut valide" {
  in_script 'validate_config && echo "${UNIT_PATH} ${HEALTH_HOST} ${#MANAGED_PATHS[@]}"'
  [ "$status" -eq 0 ]
  [ "$output" = "/etc/systemd/system/lmstudio.service 127.0.0.1 4" ]
}

@test "LMS_USER invalide refusé" {
  LMS_USER='bad;user' in_script validate_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"LMS_USER contient"* ]]
}

@test "SERVER_PORT hors plage refusé" {
  SERVER_PORT=70000 in_script validate_config
  [ "$status" -eq 1 ]
  [[ "$output" == *"entre 1 et 65535"* ]]
}

@test "WATCHDOG_INTERVAL : 0 et 15 acceptés, 5 et texte refusés" {
  WATCHDOG_INTERVAL=0 in_script validate_config
  [ "$status" -eq 0 ]
  WATCHDOG_INTERVAL=015 in_script 'validate_config; echo "${WATCHDOG_INTERVAL}"'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "15" ]
  WATCHDOG_INTERVAL=5 in_script validate_config
  [ "$status" -eq 1 ]
  WATCHDOG_INTERVAL=abc in_script validate_config
  [ "$status" -eq 1 ]
}

@test "LOAD_ARGS : caractères interprétés par systemd refusés" {
  local bad
  for bad in '--gpu $HOME' '--x %n' '--a ; --b' '--a \x' $'--a\n--b' $'--a\t--b'; do
    LOAD_ARGS="${bad}" in_script validate_config
    [ "$status" -eq 1 ]
    [[ "$output" == *"LOAD_ARGS ne peut"* ]]
  done
}

@test "LOAD_ARGS ordinaires acceptés" {
  LOAD_ARGS='--context-length 65536 --gpu 1.0 --identifier "mon modèle"' \
    in_script validate_config
  [ "$status" -eq 0 ]
}

@test "health_host_for : adresses d'écoute vers hôte de sonde" {
  in_script 'for a in 0.0.0.0 localhost :: ::1 192.168.1.5; do health_host_for "$a"; echo; done'
  [ "$status" -eq 0 ]
  [ "$output" = $'127.0.0.1\n127.0.0.1\n[::1]\n[::1]\n192.168.1.5' ]
}

# --- Génération des unités ---------------------------------------------------

@test "le préchargement suit le serveur et n'est pas bloquant" {
  PRELOAD_MODEL=qwen/qwen3-8b LOAD_ARGS='--gpu 1.0' \
    in_script "validate_config; ${FIXTURE} render_unit"
  [ "$status" -eq 0 ]
  [[ "$output" != *"ExecStartPre=/home/tester/.lmstudio/bin/lms load"* ]]
  local server_line preload_line
  server_line="$(grep -n '^ExecStart=' <<<"$output" | cut -d: -f1)"
  preload_line="$(grep -n '^ExecStartPost=-/home/tester/.lmstudio/bin/lms load qwen/qwen3-8b --yes --gpu 1.0$' <<<"$output" | cut -d: -f1)"
  [ -n "$preload_line" ]
  (( preload_line > server_line ))
}

@test "WATCHDOG_INTERVAL=0 : seule l'unité principale est générée" {
  WATCHDOG_INTERVAL=0 in_script "validate_config; ${FIXTURE} render_candidates; ls \"\${WORK_DIR}/units\""
  [ "$status" -eq 0 ]
  [ "$output" = "lmstudio.service" ]
}

@test "surveillance : script valide et timer à l'intervalle demandé" {
  WATCHDOG_INTERVAL=45 SERVER_PORT=4321 in_script "validate_config; ${FIXTURE}
    render_candidates
    sh -n \"\${WORK_DIR}/units/lmstudio-watchdog\" && echo SH_OK
    cat \"\${WORK_DIR}/units/lmstudio-watchdog.timer\"
    grep -E '^(BASE_URL|LOCK_FILE)=' \"\${WORK_DIR}/units/lmstudio-watchdog\""
  [ "$status" -eq 0 ]
  [[ "$output" == *SH_OK* ]]
  [[ "$output" == *"OnUnitInactiveSec=45s"* ]]
  [[ "$output" == *"BASE_URL='http://127.0.0.1:4321'"* ]]
  [[ "$output" == *"LOCK_FILE='/run/lmstudio-ctl.lock'"* ]]
}

# --- Script de surveillance --------------------------------------------------

# Génère le script de surveillance, avec un verrou et un journal d'appels
# dans le répertoire temporaire du test.
make_watchdog() {
  in_script "validate_config; ${FIXTURE}
    LOCK_FILE=\"\${BATS_TEST_TMPDIR}/lock\"
    render_watchdog_helper >\"\${BATS_TEST_TMPDIR}/watchdog\""
  [ "$status" -eq 0 ]
  fake sleep 'exit 0'
  fake flock 'exit "${FLOCK_RC:-0}"'
  fake systemctl '
case "$1" in
  is-active) echo "${SVC_STATE:-active}" ;;
  *) echo "$*" >>"${BATS_TEST_TMPDIR}/calls" ;;
esac'
  fake_curl
}

@test "surveillance : API muette → redémarrage" {
  make_watchdog
  run sh "${BATS_TEST_TMPDIR}/watchdog"
  [ "$status" -eq 0 ]
  [[ "$output" == *"API muette après 3 sondes"* ]]
  [ "$(cat "${BATS_TEST_TMPDIR}/calls")" = "restart lmstudio.service" ]
}

@test "surveillance : API saine ou jeton refusé → aucune action" {
  make_watchdog
  CODE_API=200 run sh "${BATS_TEST_TMPDIR}/watchdog"
  [ "$status" -eq 0 ]
  CODE_API=401 CODE_V1=401 run sh "${BATS_TEST_TMPDIR}/watchdog"
  [ "$status" -eq 0 ]
  CODE_API=404 CODE_V1=200 run sh "${BATS_TEST_TMPDIR}/watchdog"
  [ "$status" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/calls" ]
}

@test "surveillance : erreur 5xx persistante → redémarrage" {
  make_watchdog
  CODE_API=503 CODE_V1=503 run sh "${BATS_TEST_TMPDIR}/watchdog"
  [ "$(cat "${BATS_TEST_TMPDIR}/calls")" = "restart lmstudio.service" ]
}

@test "surveillance : service arrêté ou lmsctl en cours → aucune action" {
  make_watchdog
  SVC_STATE=inactive run sh "${BATS_TEST_TMPDIR}/watchdog"
  [ "$status" -eq 0 ]
  SVC_STATE=failed run sh "${BATS_TEST_TMPDIR}/watchdog"
  [ "$status" -eq 0 ]
  FLOCK_RC=1 run sh "${BATS_TEST_TMPDIR}/watchdog"
  [ "$status" -eq 0 ]
  [ ! -e "${BATS_TEST_TMPDIR}/calls" ]
}

# --- Sonde de santé ----------------------------------------------------------

@test "health_probe : 200 sur l'API native, chemin mémorisé" {
  fake_curl
  CODE_API=200 in_script 'validate_config; rc=0; health_probe || rc=$?; echo "$rc ${HEALTH_PATH}"'
  [ "$output" = "0 /api/v1/models" ]
}

@test "health_probe : repli sur /v1/models pour une ancienne version" {
  fake_curl
  CODE_API=404 CODE_V1=200 in_script 'validate_config; rc=0; health_probe || rc=$?; echo "$rc ${HEALTH_PATH}"'
  [ "$output" = "0 /v1/models" ]
}

@test "health_probe : 401 = vivant mais sonde rejetée (2), 000 = muet (1)" {
  fake_curl
  CODE_API=401 in_script 'validate_config; rc=0; health_probe || rc=$?; echo "$rc"'
  [ "$output" = "2" ]
  in_script 'validate_config; rc=0; health_probe || rc=$?; echo "$rc ${HEALTH_LAST_CODE}"'
  [ "$output" = "1 000" ]
}

# --- Installeur officiel -----------------------------------------------------

write_installer() {
  printf '%s\n' "$@" >"${BATS_TEST_TMPDIR}/install.sh"
}

@test "installeur au format actuel accepté" {
  write_installer '#!/bin/sh' '# shellcheck shell=dash' 'set -u' \
    'APP_NAME="llmster"' 'APP_VERSION="0.1.1-2"'
  in_script 'validate_installer "${BATS_TEST_TMPDIR}/install.sh"; echo "${INSTALLER_VERSION} ${INSTALLER_SHELL}"'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0.1.1-2 sh" ]
}

@test "installeur : variantes tolérées (bash, apostrophes, commentaire, CRLF)" {
  write_installer $'#!/usr/bin/env bash\r' "APP_NAME='llmster'" \
    'APP_VERSION=0.2.0  # dernière version'
  in_script 'validate_installer "${BATS_TEST_TMPDIR}/install.sh"; echo "${INSTALLER_VERSION} ${INSTALLER_SHELL}"'
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "0.2.0 bash" ]
}

@test "installeur : nom, version ou shebang inattendus refusés" {
  write_installer '#!/bin/sh' 'APP_NAME="autre"' 'APP_VERSION="1.0"'
  in_script 'validate_installer "${BATS_TEST_TMPDIR}/install.sh"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"APP_NAME"* ]]

  write_installer '#!/bin/sh' 'APP_NAME="llmster"' 'APP_VERSION="$(rm -rf /)"'
  in_script 'validate_installer "${BATS_TEST_TMPDIR}/install.sh"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"APP_VERSION"* ]]

  write_installer '<!doctype html>' 'APP_NAME="llmster"' 'APP_VERSION="1.0"'
  in_script 'validate_installer "${BATS_TEST_TMPDIR}/install.sh"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"shebang"* ]]
}

@test "installeur anormalement gros refusé" {
  write_installer '#!/bin/sh' 'APP_NAME="llmster"' 'APP_VERSION="1.0"'
  head -c 2000000 /dev/zero >>"${BATS_TEST_TMPDIR}/install.sh"
  in_script 'validate_installer "${BATS_TEST_TMPDIR}/install.sh"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"anormalement gros"* ]]
}

# --- Préchargement -----------------------------------------------------------

@test "check_preload : modèle présent, par clé ou par chemin partiel" {
  local json='[{"modelKey":"qwen/qwen3-8b","identifier":"qwen/qwen3-8b","path":"Qwen/Qwen3-8B-GGUF/qwen3-8b-q4.gguf"}]'
  PRELOAD_MODEL=qwen/qwen3-8b in_script "lms_cli() { printf '%s' '${json}'; }; check_preload; echo \"\${PRELOAD_FAILED}\""
  [ "${lines[-1]}" = "false" ]
  PRELOAD_MODEL=Qwen3-8B-GGUF in_script "lms_cli() { printf '%s' '${json}'; }; check_preload; echo \"\${PRELOAD_FAILED}\""
  [ "${lines[-1]}" = "false" ]
}

@test "check_preload : modèle absent signalé" {
  PRELOAD_MODEL=modele/inexistant in_script "lms_cli() { printf '[]'; }; check_preload; echo \"\${PRELOAD_FAILED}\""
  [ "${lines[-1]}" = "true" ]
  [[ "$output" == *"n'est pas en mémoire"* ]]
}

@test "check_preload : sortie illisible, aucun échec inventé" {
  PRELOAD_MODEL=x in_script "lms_cli() { echo 'Error: daemon'; return 1; }; check_preload; echo \"\${PRELOAD_FAILED}\""
  [ "${lines[-1]}" = "false" ]
  [[ "$output" == *"Impossible de vérifier"* ]]
}

@test "finish_health_result : codes 2 puis 3" {
  in_script 'HEALTH_DEGRADED=true; finish_health_result'
  [ "$status" -eq 2 ]
  in_script 'PRELOAD_MODEL=x; PRELOAD_FAILED=true; finish_health_result'
  [ "$status" -eq 3 ]
  in_script 'finish_health_result; echo fin'
  [ "$status" -eq 0 ]
}

# --- Restauration ------------------------------------------------------------

@test "après restauration, la sonde vise le port et l'adresse de l'ancienne unité" {
  SERVER_PORT=9999 BIND_ADDR=10.9.9.9 in_script "validate_config; ${FIXTURE}
    mkdir -p \"\${WORK_DIR}/managed.previous\"
    printf '%s\n' '[Service]' 'ExecStart=/x/lms server start --port 1234 --bind 0.0.0.0' \
      >\"\${WORK_DIR}/managed.previous/0\"
    HAD_UNIT=true; HEALTH_PATH=/v1/models
    restore_health_target
    echo \"\${SERVER_PORT} \${BIND_ADDR} \${HEALTH_HOST} [\${HEALTH_PATH}]\""
  [ "$status" -eq 0 ]
  [ "$output" = "1234 0.0.0.0 127.0.0.1 []" ]
}

@test "aide et version accessibles sans root" {
  run bash "${SCRIPT}" --version
  [ "$status" -eq 0 ]
  [[ "$output" == lmsctl.sh\ * ]]
  run bash "${SCRIPT}" help
  [ "$status" -eq 0 ]
  [[ "$output" == *WATCHDOG_INTERVAL* ]]
}
