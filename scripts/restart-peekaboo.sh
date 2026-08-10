#!/usr/bin/env bash
# Build, transactionally install, and restart a signed Peekaboo.app.
#
# The stable install path preserves Peekaboo's TCC identity. The default target is an existing
# /Applications/Peekaboo.app, then dist/Peekaboo.app. PEEKABOO_APP_BUNDLE selects an explicit target.
# Build output is never launched directly and the previous install remains recoverable until the
# replacement has launched from the stable path and its process is observed.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${WORKSPACE:-$ROOT_DIR/Apps/Peekaboo.xcworkspace}"
SCHEME="${SCHEME:-Peekaboo}"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.build/DerivedData}"
APP_NAME="${APP_NAME:-Peekaboo}"
BUILT_APP_BUNDLE="${BUILT_APP_BUNDLE:-$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}/${APP_NAME}.app}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
DIST_APP_BUNDLE="${DIST_APP_BUNDLE:-$DIST_DIR/${APP_NAME}.app}"
APPLICATIONS_DIR="${PEEKABOO_APPLICATIONS_DIR:-/Applications}"
APP_BUNDLE="${PEEKABOO_APP_BUNDLE:-}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"

BUILD_SCRIPT="${PEEKABOO_BUILD_SCRIPT:-$ROOT_DIR/scripts/build-mac-debug.sh}"
CODESIGN_BIN="${PEEKABOO_CODESIGN_BIN:-/usr/bin/codesign}"
SECURITY_BIN="${PEEKABOO_SECURITY_BIN:-/usr/bin/security}"
DITTO_BIN="${PEEKABOO_DITTO_BIN:-/usr/bin/ditto}"
MKTEMP_BIN="${PEEKABOO_MKTEMP_BIN:-/usr/bin/mktemp}"
MV_BIN="${PEEKABOO_MV_BIN:-/bin/mv}"
OPEN_BIN="${PEEKABOO_OPEN_BIN:-/usr/bin/open}"
PGREP_BIN="${PEEKABOO_PGREP_BIN:-/usr/bin/pgrep}"
KILL_BIN="${PEEKABOO_KILL_BIN:-/bin/kill}"
RM_BIN="${PEEKABOO_RM_BIN:-/bin/rm}"
SLEEP_BIN="${PEEKABOO_SLEEP_BIN:-/bin/sleep}"
LAUNCH_VERIFY_ATTEMPTS="${PEEKABOO_LAUNCH_VERIFY_ATTEMPTS:-20}"
LAUNCH_VERIFY_INTERVAL="${PEEKABOO_LAUNCH_VERIFY_INTERVAL:-0.1}"
SIGN_IDENTITY="${PEEKABOO_APP_SIGN_IDENTITY:-Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)}"
ENTITLEMENTS_PATH="${PEEKABOO_APP_ENTITLEMENTS:-$ROOT_DIR/Apps/Mac/Peekaboo/Peekaboo.entitlements}"
NATIVE_ONLY_VERIFY_SCRIPT="${PEEKABOO_NATIVE_ONLY_VERIFY_SCRIPT:-$ROOT_DIR/scripts/verify-native-only-app.sh}"
NATIVE_SOURCE_ROOT="${PEEKABOO_NATIVE_SOURCE_ROOT:-$ROOT_DIR}"

INSTALL_ROOT=""
CANDIDATE_APP_BUNDLE=""
BACKUP_APP_BUNDLE=""
BACKUP_CREATED=0
NEW_APP_INSTALLED=0
INSTALL_VERIFIED=0
TARGET_WAS_RUNNING=0
TARGET_STOPPED=0
INSTALL_STARTED=0

log() { printf '%s\n' "$*"; }

usage() {
  cat <<EOF
Usage: scripts/restart-peekaboo.sh

Build, sign, transactionally install, and restart Peekaboo.app without activating it.

Target selection:
  1. PEEKABOO_APP_BUNDLE when set
  2. Existing /Applications/Peekaboo.app
  3. ${DIST_APP_BUNDLE}

The previous installed bundle is restored if install or launch verification fails.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

choose_app_bundle() {
  if [[ -n "${APP_BUNDLE}" ]]; then
    return 0
  fi

  if [[ -d "${APPLICATIONS_DIR}/${APP_NAME}.app" ]]; then
    APP_BUNDLE="${APPLICATIONS_DIR}/${APP_NAME}.app"
  else
    APP_BUNDLE="${DIST_APP_BUNDLE}"
  fi
}

validate_app_bundle_target() {
  local target_parent

  [[ "${APP_BUNDLE}" == /* ]] || fail "PEEKABOO_APP_BUNDLE must be an absolute path: ${APP_BUNDLE}"
  if [[ "$(basename "${APP_BUNDLE}")" != "${APP_NAME}.app" ]]; then
    fail "Install target must end in ${APP_NAME}.app: ${APP_BUNDLE}"
  fi
  [[ "${APP_BUNDLE}" != "/" ]] || fail "Refusing to use / as the install target"
  [[ "${APP_BUNDLE}" != "${BUILT_APP_BUNDLE}" ]] || fail "Install target must not be the DerivedData build output"
  [[ ! -L "${APP_BUNDLE}" ]] || fail "Refusing to replace symlinked app bundle: ${APP_BUNDLE}"
  if [[ -e "${APP_BUNDLE}" && ! -d "${APP_BUNDLE}" ]]; then
    fail "Install target exists but is not an app bundle directory: ${APP_BUNDLE}"
  fi

  target_parent="$(dirname "${APP_BUNDLE}")"
  if [[ "${APP_BUNDLE}" == "${DIST_APP_BUNDLE}" ]]; then
    mkdir -p "${target_parent}"
  elif [[ ! -d "${target_parent}" ]]; then
    fail "Install target parent does not exist: ${target_parent}"
  fi
}

build_app() {
  env \
    WORKSPACE="${WORKSPACE}" \
    SCHEME="${SCHEME}" \
    CONFIGURATION="${CONFIGURATION}" \
    APP_NAME="${APP_NAME}" \
    DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" \
    DESTINATION="${DESTINATION}" \
    "${BUILD_SCRIPT}"
}

bundle_team_id() {
  local bundle="$1"
  local details team_id

  if ! details="$("${CODESIGN_BIN}" -dv --verbose=4 "${bundle}" 2>&1)"; then
    return 1
  fi
  if printf '%s\n' "${details}" | grep -Eq '^Signature=(adhoc|unsigned)$'; then
    return 1
  fi

  team_id="$(printf '%s\n' "${details}" | sed -n 's/^TeamIdentifier=//p' | head -n 1)"
  if [[ -z "${team_id}" || "${team_id}" == "not set" ]]; then
    return 1
  fi
  printf '%s\n' "${team_id}"
}

bundle_identifier() {
  local bundle="$1"
  local details identifier

  if ! details="$("${CODESIGN_BIN}" -dv --verbose=4 "${bundle}" 2>&1)"; then
    return 1
  fi
  identifier="$(printf '%s\n' "${details}" | sed -n 's/^Identifier=//p' | head -n 1)"
  [[ -n "${identifier}" ]] || return 1
  printf '%s\n' "${identifier}"
}

bundle_designated_requirement() {
  local bundle="$1"
  local details requirement

  if ! details="$("${CODESIGN_BIN}" -d -r- "${bundle}" 2>&1)"; then
    return 1
  fi
  requirement="$(printf '%s\n' "${details}" | sed -n 's/^designated => //p' | head -n 1)"
  [[ -n "${requirement}" ]] || return 1
  printf '%s\n' "${requirement}"
}

bundle_authority() {
  local bundle="$1"
  local details authority

  if ! details="$("${CODESIGN_BIN}" -dv --verbose=4 "${bundle}" 2>&1)"; then
    return 1
  fi
  authority="$(printf '%s\n' "${details}" | sed -n 's/^Authority=//p' | head -n 1)"
  [[ -n "${authority}" ]] || return 1
  printf '%s\n' "${authority}"
}

verify_signed_bundle() {
  local bundle="$1"

  if [[ ! -d "${bundle}" ]]; then
    printf 'Bundle not found: %s\n' "${bundle}" >&2
    return 1
  fi
  if ! "${CODESIGN_BIN}" --verify --deep --strict --verbose=2 "${bundle}"; then
    printf 'Code-signing verification failed: %s\n' "${bundle}" >&2
    return 1
  fi
  if ! bundle_team_id "${bundle}" >/dev/null; then
    printf 'Bundle is unsigned, ad-hoc signed, or has no Team ID: %s\n' "${bundle}" >&2
    return 1
  fi
  if ! bundle_identifier "${bundle}" >/dev/null; then
    printf 'Bundle has no readable signed identifier: %s\n' "${bundle}" >&2
    return 1
  fi
  if ! bundle_designated_requirement "${bundle}" >/dev/null; then
    printf 'Bundle has no readable designated requirement: %s\n' "${bundle}" >&2
    return 1
  fi
}

verify_build_output() {
  if ! verify_signed_bundle "${BUILT_APP_BUNDLE}"; then
    printf '%s\n' \
      'A stable Apple Development or Developer ID signature is required before restart.' \
      'Install the configured signing identity or set PEEKABOO_APP_SIGN_IDENTITY; the current app was not stopped.' >&2
    return 1
  fi
}

sign_build_if_needed() {
  local authority="" identities identity_available=0

  if verify_signed_bundle "${BUILT_APP_BUNDLE}" >/dev/null 2>&1; then
    authority="$(bundle_authority "${BUILT_APP_BUNDLE}" 2>/dev/null || true)"
    if [[ "${authority}" == "${SIGN_IDENTITY}" ]]; then
      return 0
    fi
  fi

  if identities="$("${SECURITY_BIN}" find-identity -v -p codesigning 2>/dev/null)" && \
     [[ "${identities}" == *"${SIGN_IDENTITY}"* ]]; then
    identity_available=1
  fi
  if ((identity_available == 0)); then
    if [[ -n "${authority}" ]]; then
      printf 'Built app authority (%s) does not match the required identity (%s)\n' \
        "${authority}" "${SIGN_IDENTITY}" >&2
    fi
    printf 'Signing identity not available: %s\n' "${SIGN_IDENTITY}" >&2
    return 1
  fi
  if [[ ! -f "${ENTITLEMENTS_PATH}" ]]; then
    printf 'Entitlements file not found: %s\n' "${ENTITLEMENTS_PATH}" >&2
    return 1
  fi
  log "==> Sign build with ${SIGN_IDENTITY}"
  if ! "${CODESIGN_BIN}" --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" \
    "${BUILT_APP_BUNDLE}"; then
    return 1
  fi
  "${CODESIGN_BIN}" --force --options runtime --timestamp --entitlements "${ENTITLEMENTS_PATH}" \
    --sign "${SIGN_IDENTITY}" "${BUILT_APP_BUNDLE}"
}

verify_existing_identity() {
  local built_identifier built_requirement built_team existing_identifier existing_requirement existing_team

  [[ -d "${APP_BUNDLE}" ]] || return 0
  built_team="$(bundle_team_id "${BUILT_APP_BUNDLE}")"
  built_identifier="$(bundle_identifier "${BUILT_APP_BUNDLE}")"
  built_requirement="$(bundle_designated_requirement "${BUILT_APP_BUNDLE}")"
  if existing_team="$(bundle_team_id "${APP_BUNDLE}")"; then
    if [[ "${existing_team}" != "${built_team}" ]]; then
      printf 'Existing app Team ID (%s) differs from the build (%s): %s\n' \
        "${existing_team}" "${built_team}" "${APP_BUNDLE}" >&2
      printf '%s\n' 'Refusing to replace it because that changes the app identity used by TCC.' >&2
      return 1
    fi
  else
    printf 'WARNING: Existing bundle is unsigned, ad-hoc signed, or unreadable: %s\n' "${APP_BUNDLE}" >&2
    printf '%s\n' 'The signed replacement will establish a stable TCC identity.' >&2
  fi

  if existing_identifier="$(bundle_identifier "${APP_BUNDLE}")"; then
    if [[ "${existing_identifier}" != "${built_identifier}" ]]; then
      printf 'Existing app identifier (%s) differs from the build (%s): %s\n' \
        "${existing_identifier}" "${built_identifier}" "${APP_BUNDLE}" >&2
      printf '%s\n' \
        'Refusing to replace it because the signed bundle identifier is part of the TCC identity.' \
        'Choose a matching build configuration or a different stable Peekaboo.app target.' >&2
      return 1
    fi
  fi
  if existing_requirement="$(bundle_designated_requirement "${APP_BUNDLE}")"; then
    if [[ "${existing_requirement}" != "${built_requirement}" ]]; then
      printf 'Existing app designated requirement differs from the build: %s\n' "${APP_BUNDLE}" >&2
      printf '%s\n' \
        'Refusing to replace it because certificate class and requirement are part of the TCC identity.' >&2
      return 1
    fi
  fi
}

prepare_install_candidate() {
  local target_parent built_identifier built_requirement built_team candidate_identifier candidate_requirement candidate_team

  target_parent="$(dirname "${APP_BUNDLE}")"
  if ! INSTALL_ROOT="$("${MKTEMP_BIN}" -d "${target_parent}/.${APP_NAME}.install.XXXXXX")"; then
    printf 'Cannot create an install transaction beside %s\n' "${APP_BUNDLE}" >&2
    return 1
  fi
  CANDIDATE_APP_BUNDLE="${INSTALL_ROOT}/candidate.app"
  BACKUP_APP_BUNDLE="${INSTALL_ROOT}/previous.app"

  if ! "${DITTO_BIN}" "${BUILT_APP_BUNDLE}" "${CANDIDATE_APP_BUNDLE}"; then
    printf 'Could not stage the built app beside %s\n' "${APP_BUNDLE}" >&2
    return 1
  fi
  if ! verify_signed_bundle "${CANDIDATE_APP_BUNDLE}"; then
    return 1
  fi

  built_team="$(bundle_team_id "${BUILT_APP_BUNDLE}")"
  candidate_team="$(bundle_team_id "${CANDIDATE_APP_BUNDLE}")"
  if [[ "${candidate_team}" != "${built_team}" ]]; then
    printf 'Staged app Team ID (%s) differs from the build (%s)\n' "${candidate_team}" "${built_team}" >&2
    return 1
  fi
  built_identifier="$(bundle_identifier "${BUILT_APP_BUNDLE}")"
  candidate_identifier="$(bundle_identifier "${CANDIDATE_APP_BUNDLE}")"
  if [[ "${candidate_identifier}" != "${built_identifier}" ]]; then
    printf 'Staged app identifier (%s) differs from the build (%s)\n' \
      "${candidate_identifier}" "${built_identifier}" >&2
    return 1
  fi
  built_requirement="$(bundle_designated_requirement "${BUILT_APP_BUNDLE}")"
  candidate_requirement="$(bundle_designated_requirement "${CANDIDATE_APP_BUNDLE}")"
  if [[ "${candidate_requirement}" != "${built_requirement}" ]]; then
    printf '%s\n' 'Staged app designated requirement differs from the build' >&2
    return 1
  fi
}

regex_escape() {
  printf '%s' "$1" | sed 's/[][\\.^$*+?(){}|]/\\&/g'
}

is_bundle_running() {
  bundle_pids "$1" >/dev/null 2>&1
}

bundle_pids() {
  local executable_pattern
  executable_pattern="^$(regex_escape "${1}/Contents/MacOS/${APP_NAME}")([[:space:]]|$)"
  "${PGREP_BIN}" -f "${executable_pattern}"
}

stop_peekaboo() {
  local attempt pid pids

  pids="$(bundle_pids "${APP_BUNDLE}" 2>/dev/null || true)"
  if [[ -z "${pids}" ]]; then
    return 0
  fi

  while IFS= read -r pid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    if ! "${KILL_BIN}" -TERM "${pid}"; then
      printf 'Could not stop %s process %s from %s\n' "${APP_NAME}" "${pid}" "${APP_BUNDLE}" >&2
      return 1
    fi
  done <<<"${pids}"

  for ((attempt = 0; attempt < 15; attempt += 1)); do
    if ! is_bundle_running "${APP_BUNDLE}"; then
      return 0
    fi
    "${SLEEP_BIN}" 0.2
  done
  printf 'Could not stop %s processes from %s\n' "${APP_NAME}" "${APP_BUNDLE}" >&2
  return 1
}

install_candidate() {
  local built_identifier built_requirement built_team installed_identifier installed_requirement installed_team

  if [[ -e "${APP_BUNDLE}" ]]; then
    BACKUP_CREATED=1
    if ! "${MV_BIN}" "${APP_BUNDLE}" "${BACKUP_APP_BUNDLE}"; then
      return 1
    fi
  fi

  NEW_APP_INSTALLED=1
  if ! "${MV_BIN}" "${CANDIDATE_APP_BUNDLE}" "${APP_BUNDLE}"; then
    return 1
  fi

  # Moving within the target filesystem should not alter the signature, but verify the exact launch path too.
  verify_signed_bundle "${APP_BUNDLE}" || return 1
  built_team="$(bundle_team_id "${BUILT_APP_BUNDLE}")"
  installed_team="$(bundle_team_id "${APP_BUNDLE}")"
  if [[ "${installed_team}" != "${built_team}" ]]; then
    printf 'Installed app Team ID (%s) differs from the build (%s)\n' \
      "${installed_team}" "${built_team}" >&2
    return 1
  fi
  built_identifier="$(bundle_identifier "${BUILT_APP_BUNDLE}")"
  installed_identifier="$(bundle_identifier "${APP_BUNDLE}")"
  if [[ "${installed_identifier}" != "${built_identifier}" ]]; then
    printf 'Installed app identifier (%s) differs from the build (%s)\n' \
      "${installed_identifier}" "${built_identifier}" >&2
    return 1
  fi
  built_requirement="$(bundle_designated_requirement "${BUILT_APP_BUNDLE}")"
  installed_requirement="$(bundle_designated_requirement "${APP_BUNDLE}")"
  if [[ "${installed_requirement}" != "${built_requirement}" ]]; then
    printf '%s\n' 'Installed app designated requirement differs from the build' >&2
    return 1
  fi
}

open_bundle() {
  local bundle="$1"

  # LaunchServices can inherit a huge environment from this shell; keep it minimal.
  env -i \
    HOME="${HOME}" \
    USER="${USER:-$(id -un)}" \
    LOGNAME="${LOGNAME:-$(id -un)}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    LANG="${LANG:-en_US.UTF-8}" \
    "${OPEN_BIN}" -gj "${bundle}"
}

launch_and_verify() {
  local attempt

  if ! open_bundle "${APP_BUNDLE}"; then
    return 1
  fi
  for ((attempt = 0; attempt < LAUNCH_VERIFY_ATTEMPTS; attempt += 1)); do
    if is_bundle_running "${APP_BUNDLE}"; then
      return 0
    fi
    "${SLEEP_BIN}" "${LAUNCH_VERIFY_INTERVAL}"
  done
  printf '%s launched no process from %s\n' "${APP_NAME}" "${APP_BUNDLE}" >&2
  return 1
}

rollback_install() {
  local exit_code=$?
  local restored=0
  local target_cleared=1

  trap - EXIT INT TERM HUP
  if ((exit_code == 0 && INSTALL_VERIFIED == 1)); then
    if [[ -n "${INSTALL_ROOT}" && -d "${INSTALL_ROOT}" ]]; then
      "${RM_BIN}" -rf -- "${INSTALL_ROOT}" || \
        printf 'WARNING: Could not remove completed install transaction: %s\n' "${INSTALL_ROOT}" >&2
    fi
    exit 0
  fi

  if [[ -n "${INSTALL_ROOT}" ]]; then
    if ((INSTALL_STARTED == 0)); then
      if ((TARGET_STOPPED == 1 && TARGET_WAS_RUNNING == 1)) && [[ -d "${APP_BUNDLE}" ]]; then
        if ! open_bundle "${APP_BUNDLE}"; then
          printf 'WARNING: The unchanged app could not be relaunched after restart was interrupted.\n' >&2
        fi
      fi
      "${RM_BIN}" -rf -- "${INSTALL_ROOT}" || \
        printf 'WARNING: Could not remove abandoned install transaction: %s\n' "${INSTALL_ROOT}" >&2
      exit "${exit_code}"
    fi

    printf 'Restart failed; restoring the previous app bundle.\n' >&2
    if ((NEW_APP_INSTALLED == 1)); then
      stop_peekaboo >/dev/null 2>&1 || true
      if [[ -e "${APP_BUNDLE}" ]]; then
        if ! "${MV_BIN}" "${APP_BUNDLE}" "${INSTALL_ROOT}/failed.app"; then
          target_cleared=0
          printf 'ERROR: Could not quarantine the failed replacement at %s\n' "${APP_BUNDLE}" >&2
        fi
      fi
    fi

    if ((BACKUP_CREATED == 1)) && [[ -d "${BACKUP_APP_BUNDLE}" ]]; then
      if ((target_cleared == 0)) || [[ -e "${APP_BUNDLE}" ]]; then
        printf 'ERROR: Recovery bundle remains at %s\n' "${BACKUP_APP_BUNDLE}" >&2
      elif "${MV_BIN}" "${BACKUP_APP_BUNDLE}" "${APP_BUNDLE}"; then
        restored=1
        printf 'Restored: %s\n' "${APP_BUNDLE}" >&2
      else
        printf 'ERROR: Automatic restore failed. Recovery bundle remains at %s\n' "${BACKUP_APP_BUNDLE}" >&2
      fi
    elif ((BACKUP_CREATED == 1 && NEW_APP_INSTALLED == 0)) && [[ -d "${APP_BUNDLE}" ]]; then
      # The first rename was interrupted before it moved the unchanged target.
      restored=1
    elif ((BACKUP_CREATED == 0)); then
      restored="${target_cleared}"
    fi

    if ((restored == 1 && TARGET_WAS_RUNNING == 1)) && [[ -d "${APP_BUNDLE}" ]]; then
      if ! open_bundle "${APP_BUNDLE}"; then
        printf 'WARNING: The previous app was restored but could not be relaunched.\n' >&2
      fi
    fi

    if ((restored == 1)) && [[ -d "${INSTALL_ROOT}" ]]; then
      "${RM_BIN}" -rf -- "${INSTALL_ROOT}" || \
        printf 'WARNING: Could not remove rolled-back install transaction: %s\n' "${INSTALL_ROOT}" >&2
    fi
  fi
  exit "${exit_code}"
}

case "${1:-}" in
  '')
    ;;
  -h|--help)
    [[ "$#" -eq 1 ]] || fail '--help does not accept additional arguments'
    usage
    exit 0
    ;;
  *)
    usage >&2
    fail "Unknown argument: $1"
    ;;
esac

trap rollback_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

choose_app_bundle
validate_app_bundle_target

log '==> Verify native-only source policy'
"${NATIVE_ONLY_VERIFY_SCRIPT}" --source-root "${NATIVE_SOURCE_ROOT}" || \
  fail "Native-only source policy failed; the running app was not stopped"

log "==> Build ${APP_NAME}.app (${CONFIGURATION})"
build_app || fail "Build failed; the running app was not stopped"

log '==> Verify signed build output'
sign_build_if_needed || fail "Could not sign the built app; the running app was not stopped"
verify_build_output || fail "Built app verification failed; the running app was not stopped"
"${NATIVE_ONLY_VERIFY_SCRIPT}" --app "${BUILT_APP_BUNDLE}" || \
  fail "Built app violates the native-only policy; the running app was not stopped"
verify_existing_identity || fail "Existing app identity is incompatible; the running app was not stopped"

log "==> Stage signed app beside ${APP_BUNDLE}"
prepare_install_candidate || fail "Could not prepare a verified install candidate; the running app was not stopped"

if is_bundle_running "${APP_BUNDLE}"; then
  TARGET_WAS_RUNNING=1
fi

log "==> Stop ${APP_NAME}"
stop_peekaboo || fail "Could not stop ${APP_NAME}; install was not changed"
TARGET_STOPPED=1

log "==> Install signed app at ${APP_BUNDLE}"
INSTALL_STARTED=1
install_candidate || fail "Install failed"

log "==> Launch and verify ${APP_BUNDLE}"
launch_and_verify || fail "Replacement app failed launch verification"

INSTALL_VERIFIED=1
log "OK: ${APP_NAME} is running from ${APP_BUNDLE}."
