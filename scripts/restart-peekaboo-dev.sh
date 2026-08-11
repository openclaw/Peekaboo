#!/usr/bin/env bash
# Reset the contributor Peekaboo.app: rebuild Debug, repackage to a stable bundle, relaunch, verify.
#
# This preserves the repository's ordinary Debug/Xcode signing configuration and never injects or
# requires the OpenClaw Foundation release identity. Foundation-signed transactional deployment is
# a separate, explicit mode in restart-peekaboo.sh.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="${WORKSPACE:-$ROOT_DIR/Apps/Peekaboo.xcworkspace}"
SCHEME="${SCHEME:-Peekaboo}"
CONFIGURATION="${CONFIGURATION:-Debug}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.build/DerivedData}"
APP_NAME="${APP_NAME:-Peekaboo}"
BUILT_APP_BUNDLE="${BUILT_APP_BUNDLE:-$DERIVED_DATA_PATH/Build/Products/${CONFIGURATION}/${APP_NAME}.app}"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
DIST_APP_BUNDLE="${DIST_APP_BUNDLE:-$DIST_DIR/${APP_NAME}.app}"
APP_BUNDLE="${DIST_APP_BUNDLE}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"

BUILD_SCRIPT="${PEEKABOO_DEV_BUILD_SCRIPT:-}"
DITTO_BIN="${PEEKABOO_DEV_DITTO_BIN:-/usr/bin/ditto}"
OPEN_BIN="${PEEKABOO_DEV_OPEN_BIN:-/usr/bin/open}"
PGREP_BIN="${PEEKABOO_DEV_PGREP_BIN:-/usr/bin/pgrep}"
PKILL_BIN="${PEEKABOO_DEV_PKILL_BIN:-/usr/bin/pkill}"
RM_BIN="${PEEKABOO_DEV_RM_BIN:-/bin/rm}"
SLEEP_BIN="${PEEKABOO_DEV_SLEEP_BIN:-/bin/sleep}"

APP_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${APP_NAME}"
DERIVED_PROCESS_PATTERN="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app/Contents/MacOS/${APP_NAME}"

log() { printf '%s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run_step() {
  local label="$1"
  shift
  log "==> ${label}"
  if ! "$@"; then
    fail "${label} failed"
  fi
}

kill_peekaboo() {
  for _ in {1..15}; do
    "${PKILL_BIN}" -f "${DERIVED_PROCESS_PATTERN}" 2>/dev/null || true
    "${PKILL_BIN}" -f "${APP_PROCESS_PATTERN}" 2>/dev/null || true
    "${PKILL_BIN}" -x "${APP_NAME}" 2>/dev/null || true

    if ! "${PGREP_BIN}" -f "${DERIVED_PROCESS_PATTERN}" >/dev/null 2>&1 \
       && ! "${PGREP_BIN}" -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1 \
       && ! "${PGREP_BIN}" -x "${APP_NAME}" >/dev/null 2>&1; then
      return 0
    fi
    "${SLEEP_BIN}" 0.2
  done
  fail "Could not stop running Peekaboo processes"
}

xc_pipe() {
  if command -v xcbeautify >/dev/null 2>&1; then
    xcbeautify
  else
    cat
  fi
}

build_app() {
  if [[ -n "${BUILD_SCRIPT}" ]]; then
    env \
      WORKSPACE="${WORKSPACE}" \
      SCHEME="${SCHEME}" \
      CONFIGURATION="${CONFIGURATION}" \
      DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" \
      APP_NAME="${APP_NAME}" \
      DESTINATION="${DESTINATION}" \
      "${BUILD_SCRIPT}"
    return
  fi
  xcodebuild \
    -workspace "${WORKSPACE}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA_PATH}" \
    -destination "${DESTINATION}" \
    build \
    | xc_pipe
}

choose_app_bundle() {
  local allowed_tmp_root canonical_home canonical_parent root_dist target_parent
  local component
  local -a components

  [[ "${APP_BUNDLE}" == /* && "${APP_BUNDLE}" != *$'\n'* ]] || \
    fail "Development app target must be an absolute path: ${APP_BUNDLE}"
  [[ "$(basename "${APP_BUNDLE}")" == "${APP_NAME}.app" ]] || \
    fail "Development app target must end in ${APP_NAME}.app: ${APP_BUNDLE}"
  [[ "${APP_BUNDLE}" != "${BUILT_APP_BUNDLE}" ]] || \
    fail "Development app target must not be the DerivedData build output"
  [[ ! -L "${APP_BUNDLE}" ]] || fail "Refusing symlinked development app target: ${APP_BUNDLE}"

  IFS='/' read -r -a components <<<"${APP_BUNDLE#/}"
  for component in "${components[@]}"; do
    [[ "${component}" != .. ]] || fail "Refusing development target containing '..': ${APP_BUNDLE}"
  done

  root_dist="$(cd "${ROOT_DIR}" && pwd -P)/dist"
  target_parent="$(dirname "${APP_BUNDLE}")"
  case "${target_parent}/" in
    "${root_dist}/"|/private/tmp/*|/tmp/*) ;;
    *) fail "Development app target must live under ${root_dist} or a temporary directory: ${APP_BUNDLE}" ;;
  esac

  mkdir -p "${target_parent}"
  canonical_parent="$(cd "${target_parent}" && pwd -P)"
  canonical_home="$(cd "${HOME}" && pwd -P)"
  [[ "${canonical_parent}" != "${canonical_home}" ]] || \
    fail "Development app target must not use the home directory: ${APP_BUNDLE}"
  allowed_tmp_root="$(cd /private/tmp && pwd -P)"
  case "${canonical_parent}/" in
    "${root_dist}/"|"${allowed_tmp_root}/"*) ;;
    *) fail "Development app target escapes its allowed directory: ${APP_BUNDLE}" ;;
  esac
  APP_BUNDLE="${canonical_parent}/${APP_NAME}.app"
}

verify_built_bundle() {
  [[ -d "${BUILT_APP_BUNDLE}" ]] || fail "Built app bundle not found at ${BUILT_APP_BUNDLE}"
}

package_to_target() {
  choose_app_bundle
  "${RM_BIN}" -rf -- "${APP_BUNDLE}"
  "${DITTO_BIN}" "${BUILT_APP_BUNDLE}" "${APP_BUNDLE}"
}

verify_launch_bundle() {
  [[ -d "${APP_BUNDLE}" ]] || fail "App bundle not found at ${APP_BUNDLE}"
}

launch_app() {
  env -i \
    HOME="${HOME}" \
    USER="${USER:-$(id -un)}" \
    LOGNAME="${LOGNAME:-$(id -un)}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    LANG="${LANG:-en_US.UTF-8}" \
    "${OPEN_BIN}" "${APP_BUNDLE}"
  "${SLEEP_BIN}" 1
  if "${PGREP_BIN}" -f "${APP_PROCESS_PATTERN}" >/dev/null 2>&1 || \
     "${PGREP_BIN}" -x "${APP_NAME}" >/dev/null 2>&1; then
    log "OK: ${APP_NAME} is running."
  else
    fail "App exited immediately. Check crash logs."
  fi
}

run_step "Choose safe development app target" choose_app_bundle
log "==> Killing existing Peekaboo instances"
kill_peekaboo
run_step "Build ${APP_NAME}.app (${CONFIGURATION})" build_app
run_step "Locate build output" verify_built_bundle
run_step "Package app to stable development target" package_to_target
run_step "Locate app bundle" verify_launch_bundle
run_step "Launch app" launch_app
