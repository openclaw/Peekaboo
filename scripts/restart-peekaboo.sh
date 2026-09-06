#!/usr/bin/env bash
# Build, transactionally install, and restart a signed Peekaboo.app.
#
# The stable install path preserves Peekaboo's TCC identity. The default target is an existing
# /Applications/Peekaboo.app, then dist/Peekaboo.app. PEEKABOO_APP_BUNDLE selects an explicit target.
# Build output is never launched directly and the previous install remains recoverable until the
# replacement has launched from the stable path and its process is observed. A sibling lock and journal
# serialize installers and make interrupted renames recoverable on the next invocation.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-}" in
  --deployment)
    shift
    ;;
  -h|--help)
    cat <<'EOF'
Usage: scripts/restart-peekaboo.sh [--deployment [options]]

Modes:
  scripts/restart-peekaboo.sh
  scripts/restart-peekaboo.sh --deployment [options]

With no arguments, rebuild and restart the contributor app using the established Debug/local
signing workflow. This path never injects the OpenClaw Foundation release identity.

Use --deployment for the strict transactional stable-path installer. That mode requires an
explicitly trusted signed app and current signed healthcheck CLI; run
`scripts/restart-peekaboo.sh --deployment --help` for its options.
EOF
    exit 0
    ;;
  '')
    exec "${PEEKABOO_DEV_RESTART_SCRIPT:-${SCRIPT_DIR}/restart-peekaboo-dev.sh}"
    ;;
  *)
    printf 'ERROR: Deployment installer options require an explicit --deployment mode.\n' >&2
    exit 64
    ;;
esac

ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
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
SIGN_RELEASE_APP_SCRIPT="${PEEKABOO_SIGN_RELEASE_APP_SCRIPT:-$ROOT_DIR/scripts/sign-release-app.sh}"
CODESIGN_BIN="${PEEKABOO_CODESIGN_BIN:-/usr/bin/codesign}"
DITTO_BIN="${PEEKABOO_DITTO_BIN:-/usr/bin/ditto}"
FILE_BIN="${PEEKABOO_FILE_BIN:-/usr/bin/file}"
FIND_BIN="${PEEKABOO_FIND_BIN:-/usr/bin/find}"
ID_BIN="${PEEKABOO_ID_BIN:-/usr/bin/id}"
JQ_BIN="${PEEKABOO_JQ_BIN:-$(command -v jq || true)}"
LOCKF_BIN="/usr/bin/lockf"
LSOF_BIN="${PEEKABOO_LSOF_BIN:-/usr/sbin/lsof}"
MKTEMP_BIN="${PEEKABOO_MKTEMP_BIN:-/usr/bin/mktemp}"
MV_BIN="${PEEKABOO_MV_BIN:-/bin/mv}"
OPEN_BIN="${PEEKABOO_OPEN_BIN:-/usr/bin/open}"
PGREP_BIN="${PEEKABOO_PGREP_BIN:-/usr/bin/pgrep}"
PLISTBUDDY_BIN="${PEEKABOO_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
KILL_BIN="${PEEKABOO_KILL_BIN:-/bin/kill}"
RM_BIN="${PEEKABOO_RM_BIN:-/bin/rm}"
SHASUM_BIN="${PEEKABOO_SHASUM_BIN:-/usr/bin/shasum}"
SLEEP_BIN="${PEEKABOO_SLEEP_BIN:-/bin/sleep}"
STAT_BIN="${PEEKABOO_STAT_BIN:-/usr/bin/stat}"
SYNC_BIN="${PEEKABOO_SYNC_BIN:-/bin/sync}"
LAUNCH_VERIFY_ATTEMPTS="${PEEKABOO_LAUNCH_VERIFY_ATTEMPTS:-20}"
LAUNCH_VERIFY_INTERVAL="${PEEKABOO_LAUNCH_VERIFY_INTERVAL:-0.1}"
HEALTH_VERIFY_ATTEMPTS="${PEEKABOO_HEALTH_VERIFY_ATTEMPTS:-40}"
HEALTH_VERIFY_INTERVAL="${PEEKABOO_HEALTH_VERIFY_INTERVAL:-0.25}"
HEALTHCHECK_CLI="${PEEKABOO_HEALTHCHECK_CLI:-$(command -v peekaboo || true)}"
HEALTHCHECK_CLI_BUNDLE_ID="${PEEKABOO_HEALTHCHECK_CLI_BUNDLE_ID:-boo.peekaboo.peekaboo}"
BRIDGE_SOCKET="${PEEKABOO_APP_BRIDGE_SOCKET:-${HOME}/Library/Application Support/Peekaboo/bridge.sock}"
SIGN_IDENTITY="${PEEKABOO_APP_SIGN_IDENTITY:-Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)}"
APP_ENTITLEMENTS="${PEEKABOO_APP_ENTITLEMENTS:-$ROOT_DIR/Apps/Mac/Peekaboo/Peekaboo.entitlements}"
CODESIGN_TIMESTAMP_URL="http://timestamp.apple.com/ts01"
EXPECTED_TEAM_ID="${PEEKABOO_APP_EXPECTED_TEAM_ID:-FWJYW4S8P8}"
if [[ "${CONFIGURATION}" == "Debug" ]]; then
  DEFAULT_BUNDLE_ID="boo.peekaboo.mac.debug"
else
  DEFAULT_BUNDLE_ID="boo.peekaboo.mac"
fi
EXPECTED_BUNDLE_ID="${PEEKABOO_APP_EXPECTED_BUNDLE_ID:-${DEFAULT_BUNDLE_ID}}"
EXPECTED_ANCHOR_REQUIREMENT="${PEEKABOO_APP_ANCHOR_REQUIREMENT:-anchor apple generic and certificate leaf[subject.OU] = \"${EXPECTED_TEAM_ID}\"}"
EXPECTED_SIGN_REQUIREMENT="${PEEKABOO_APP_SIGN_REQUIREMENT:-anchor apple generic and identifier \"${EXPECTED_BUNDLE_ID}\" and certificate leaf[subject.OU] = \"${EXPECTED_TEAM_ID}\"}"
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
TARGET_STOP_ATTEMPTED=0
INSTALL_STARTED=0
LOCK_FILE=""
LOCK_DIR=""
LOCK_OWNED=0
JOURNAL_FILE=""
SOURCE_APP_BUNDLE=""
NO_BUILD=0
ALLOW_UNSTABLE_EXISTING=0
ARTIFACT_DIGEST=""
PREVIOUS_DIGEST=""
HAD_PREVIOUS_APP=0
LAUNCHED_PID=""
LAUNCHED_PROCESS_START_IDENTITY=""

log() { printf '%s\n' "$*"; }

usage() {
  cat <<EOF
Usage: scripts/restart-peekaboo.sh --deployment [options]

Build or reuse, verify, transactionally install, and restart Peekaboo.app without activating it.

Options:
  --source-app <bundle>              Install this exact already-signed app; implies --no-build.
  --no-build                         Reuse BUILT_APP_BUNDLE without building or re-signing it.
  --healthcheck-cli <path>           Current signed Peekaboo CLI used for exact GUI Bridge readiness.
  --allow-unstable-existing-identity Replace an unsigned/ad-hoc/unreadable existing app, accepting
                                     that its TCC grants cannot be preserved.
  -h, --help                         Show this help.

Target selection:
  1. PEEKABOO_APP_BUNDLE when set
  2. Existing /Applications/Peekaboo.app
  3. ${DIST_APP_BUNDLE}

The previous installed bundle is restored if install or launch verification fails.
The installed content-manifest SHA-256 is printed on success.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

reject_unsafe_path_syntax() {
  local input_path="$1"
  local component
  local -a components

  [[ "${input_path}" == /* ]] || return 1
  [[ "${input_path}" != *$'\n'* ]] || fail "Paths containing newlines are not supported: ${input_path}"
  IFS='/' read -r -a components <<<"${input_path#/}"
  for component in "${components[@]}"; do
    case "${component}" in
      ''|.) continue ;;
      ..) fail "Refusing a path containing '..': ${input_path}" ;;
    esac
  done
}

bundle_digest() {
  local bundle="$1"
  local candidate content_digest manifest mode relative_path symlink_target

  manifest="$(${MKTEMP_BIN} -t peekaboo-app-digest.XXXXXX)" || return 1
  while IFS= read -r -d '' candidate; do
    relative_path="${candidate#"${bundle}"/}"
    if [[ -L "${candidate}" ]]; then
      symlink_target="$(readlink "${candidate}")"
      printf 'L\0%s\0%s\0' "${relative_path}" "${symlink_target}" >>"${manifest}"
    elif [[ -f "${candidate}" ]]; then
      content_digest="$(${SHASUM_BIN} -a 256 "${candidate}" | awk '{print $1}')" || {
        "${RM_BIN}" -f -- "${manifest}"
        return 1
      }
      mode="$("${STAT_BIN}" -f %Lp "${candidate}")" || {
        "${RM_BIN}" -f -- "${manifest}"
        return 1
      }
      printf 'F\0%s\0%s\0%s\0' "${relative_path}" "${mode}" "${content_digest}" >>"${manifest}"
    fi
  done < <("${FIND_BIN}" -s "${bundle}" \( -type f -o -type l \) -print0)
  content_digest="$(${SHASUM_BIN} -a 256 "${manifest}" | awk '{print $1}')" || {
    "${RM_BIN}" -f -- "${manifest}"
    return 1
  }
  "${RM_BIN}" -f -- "${manifest}"
  printf '%s\n' "${content_digest}"
}

acquire_install_lock() {
  local lock_mode lock_owner

  if [[ ! -e "${LOCK_DIR}" ]]; then
    mkdir -m 700 "${LOCK_DIR}" 2>/dev/null || true
  fi
  [[ -d "${LOCK_DIR}" && ! -L "${LOCK_DIR}" ]] || fail "Unsafe installer lock directory: ${LOCK_DIR}"
  lock_owner="$("${STAT_BIN}" -f %u "${LOCK_DIR}")"
  lock_mode="$("${STAT_BIN}" -f %Lp "${LOCK_DIR}")"
  [[ "${lock_owner}" == "$("${ID_BIN}" -u)" && "${lock_mode}" == "700" ]] || \
    fail "Installer lock directory must be private and owned by the current user: ${LOCK_DIR}"
  if [[ -e "${LOCK_FILE}" ]]; then
    [[ -f "${LOCK_FILE}" && ! -L "${LOCK_FILE}" ]] || fail "Unsafe installer lock file: ${LOCK_FILE}"
    [[ "$("${STAT_BIN}" -f %u "${LOCK_FILE}")" == "$("${ID_BIN}" -u)" ]] || \
      fail "Installer lock file is owned by another user: ${LOCK_FILE}"
  fi

  # macOS lockf's descriptor form locks this inherited open-file description. The shell's fd 9
  # keeps that BSD lock alive after the lockf child exits, until release_install_lock closes it.
  exec 9>"${LOCK_FILE}"
  if ! "${LOCKF_BIN}" -s -t 0 9; then
    exec 9>&-
    fail "Another installer owns ${APP_BUNDLE} (lock: ${LOCK_FILE})"
  fi
  LOCK_OWNED=1
}

release_install_lock() {
  ((LOCK_OWNED == 1)) || return 0
  exec 9>&-
  LOCK_OWNED=0
}

choose_app_bundle() {
  if [[ -n "${APP_BUNDLE}" ]]; then
    return 0
  fi

  if [[ -d "${APPLICATIONS_DIR}/${APP_NAME}.app" ||
        -f "${APPLICATIONS_DIR}/.${APP_NAME}.install.journal" ]]; then
    APP_BUNDLE="${APPLICATIONS_DIR}/${APP_NAME}.app"
  else
    APP_BUNDLE="${DIST_APP_BUNDLE}"
  fi
}

validate_app_bundle_target() {
  local target_name target_parent canonical_parent

  [[ "${APP_BUNDLE}" == /* ]] || fail "PEEKABOO_APP_BUNDLE must be an absolute path: ${APP_BUNDLE}"
  if [[ "$(basename "${APP_BUNDLE}")" != "${APP_NAME}.app" ]]; then
    fail "Install target must end in ${APP_NAME}.app: ${APP_BUNDLE}"
  fi
  [[ "${APP_BUNDLE}" != "/" ]] || fail "Refusing to use / as the install target"
  reject_unsafe_path_syntax "${APP_BUNDLE}"
  [[ ! -L "${APP_BUNDLE}" ]] || fail "Refusing to replace symlinked app bundle: ${APP_BUNDLE}"
  if [[ -e "${APP_BUNDLE}" && ! -d "${APP_BUNDLE}" ]]; then
    fail "Install target exists but is not an app bundle directory: ${APP_BUNDLE}"
  fi

  target_parent="$(dirname "${APP_BUNDLE}")"
  target_name="$(basename "${APP_BUNDLE}")"
  if [[ "${APP_BUNDLE}" == "${DIST_APP_BUNDLE}" ]]; then
    mkdir -p "${target_parent}"
  elif [[ ! -d "${target_parent}" ]]; then
    fail "Install target parent does not exist: ${target_parent}"
  fi
  reject_unsafe_path_syntax "${target_parent}"
  canonical_parent="$(cd "${target_parent}" && pwd -P)"
  APP_BUNDLE="${canonical_parent}/${target_name}"
  LOCK_DIR="${canonical_parent}/.${APP_NAME}.install-lock"
  LOCK_FILE="${LOCK_DIR}/lock"
  JOURNAL_FILE="${canonical_parent}/.${APP_NAME}.install.journal"
}

journal_value() {
  local key="$1"
  local journal="$2"
  local count

  count="$(grep -c "^${key}=" "${journal}" || true)"
  [[ "${count}" == "1" ]] || return 1
  sed -n "s/^${key}=//p" "${journal}"
}

write_journal_state() {
  local phase="$1"
  local install_root="$2"
  local had_previous="$3"
  local previous_running="$4"
  local artifact_digest="$5"
  local previous_digest="${6:-${PREVIOUS_DIGEST}}"
  local temporary_journal

  case "${phase}" in
    staged|backing-up|backed-up|installing|installed|restoring|verified|restored) ;;
    *) fail "Refusing to write unknown install phase: ${phase}" ;;
  esac
  [[ "${artifact_digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  if [[ "${had_previous}" == "1" ]]; then
    [[ "${previous_digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
  else
    [[ -z "${previous_digest}" ]] || return 1
  fi
  validated_recovery_root "${install_root}" || return 1
  temporary_journal="$(${MKTEMP_BIN} "${install_root}/journal.XXXXXX")" || return 1
  if ! printf '%s\n' \
    'version=2' \
    "phase=${phase}" \
    "target=${APP_BUNDLE}" \
    "install_root=${install_root}" \
    "had_previous=${had_previous}" \
    "previous_running=${previous_running}" \
    "artifact_digest=${artifact_digest}" \
    "previous_digest=${previous_digest}" >"${temporary_journal}" || \
     ! chmod 600 "${temporary_journal}" || \
     ! /bin/mv "${temporary_journal}" "${JOURNAL_FILE}" || \
     ! "${SYNC_BIN}"
  then
    "${RM_BIN}" -f -- "${temporary_journal}" >/dev/null 2>&1 || true
    return 1
  fi
}

remove_journal() {
  [[ -e "${JOURNAL_FILE}" ]] || return 0
  [[ -f "${JOURNAL_FILE}" && ! -L "${JOURNAL_FILE}" ]] || return 1
  "${RM_BIN}" -f -- "${JOURNAL_FILE}" || return 1
  "${SYNC_BIN}"
}

validated_recovery_root() {
  local install_root="$1"
  local target_parent expected_prefix suffix

  target_parent="$(dirname "${APP_BUNDLE}")"
  expected_prefix="${target_parent}/.${APP_NAME}.install."
  [[ "${install_root}" == "${expected_prefix}"* ]] || return 1
  suffix="${install_root#"${expected_prefix}"}"
  [[ -n "${suffix}" && "${suffix}" != */* && "${install_root}" != *$'\n'* ]] || return 1
  [[ -d "${install_root}" && ! -L "${install_root}" ]] || return 1
  [[ "$("${STAT_BIN}" -f %u "${install_root}")" == "$("${ID_BIN}" -u)" ]] || return 1
  [[ "$(cd "${install_root}/.." && pwd -P)" == "${target_parent}" ]] || return 1
}

recover_interrupted_install() {
  local artifact_digest had_previous install_root phase previous_digest previous_running recovered_digest target
  local backup candidate failed

  [[ -e "${JOURNAL_FILE}" ]] || return 0
  [[ -f "${JOURNAL_FILE}" && ! -L "${JOURNAL_FILE}" ]] || \
    fail "Unsafe install journal; preserving it for inspection: ${JOURNAL_FILE}"
  [[ "$("${STAT_BIN}" -f %u "${JOURNAL_FILE}")" == "$("${ID_BIN}" -u)" ]] || \
    fail "Install journal is owned by another user; preserving it: ${JOURNAL_FILE}"
  [[ "$(journal_value version "${JOURNAL_FILE}")" == "2" ]] || \
    fail "Unsupported install journal; preserving it for inspection: ${JOURNAL_FILE}"
  phase="$(journal_value phase "${JOURNAL_FILE}")" || \
    fail "Install journal has no unique phase: ${JOURNAL_FILE}"
  target="$(journal_value target "${JOURNAL_FILE}")" || \
    fail "Install journal has no unique target: ${JOURNAL_FILE}"
  install_root="$(journal_value install_root "${JOURNAL_FILE}")" || \
    fail "Install journal has no unique transaction root: ${JOURNAL_FILE}"
  had_previous="$(journal_value had_previous "${JOURNAL_FILE}")" || \
    fail "Install journal has no previous-app state: ${JOURNAL_FILE}"
  previous_running="$(journal_value previous_running "${JOURNAL_FILE}")" || \
    fail "Install journal has no previous-running state: ${JOURNAL_FILE}"
  artifact_digest="$(journal_value artifact_digest "${JOURNAL_FILE}")" || \
    fail "Install journal has no artifact digest: ${JOURNAL_FILE}"
  previous_digest="$(journal_value previous_digest "${JOURNAL_FILE}")" || \
    fail "Install journal has no previous digest: ${JOURNAL_FILE}"
  [[ "${target}" == "${APP_BUNDLE}" ]] || \
    fail "Install journal targets ${target}, not ${APP_BUNDLE}; preserving it"
  [[ "${had_previous}" =~ ^[01]$ && "${previous_running}" =~ ^[01]$ ]] || \
    fail "Install journal contains invalid state: ${JOURNAL_FILE}"
  [[ "${artifact_digest}" =~ ^[0-9a-f]{64}$ ]] || \
    fail "Install journal contains an invalid artifact digest: ${JOURNAL_FILE}"
  if [[ "${had_previous}" == "1" ]]; then
    [[ "${previous_digest}" =~ ^[0-9a-f]{64}$ ]] || \
      fail "Install journal contains an invalid previous-app digest: ${JOURNAL_FILE}"
  else
    [[ -z "${previous_digest}" ]] || \
      fail "First-install journal unexpectedly records a previous-app digest: ${JOURNAL_FILE}"
  fi
  case "${phase}" in
    staged|backing-up|backed-up|installing|installed|restoring|verified|restored) ;;
    *) fail "Unknown install journal phase '${phase}'; preserving ${JOURNAL_FILE}" ;;
  esac
  backup="${install_root}/previous.app"
  candidate="${install_root}/candidate.app"
  failed="${install_root}/recovered-failed.app"
  log "==> Recover interrupted install (${phase})"

  if [[ "${phase}" == "verified" ]]; then
    [[ -d "${APP_BUNDLE}" && ! -L "${APP_BUNDLE}" ]] || \
      fail "Verified transaction lost its installed app; preserving ${install_root}"
    verify_expected_signer "${APP_BUNDLE}" || \
      fail "Verified transaction has an invalid installed signature; preserving ${install_root}"
    recovered_digest="$(bundle_digest "${APP_BUNDLE}")" || \
      fail "Could not digest recovered installed app: ${APP_BUNDLE}"
    [[ "${recovered_digest}" == "${artifact_digest}" ]] || \
      fail "Verified transaction digest changed; preserving ${install_root}"
    if [[ -e "${install_root}" ]]; then
      validated_recovery_root "${install_root}" || \
        fail "Unsafe transaction root; preserving journal: ${JOURNAL_FILE}"
      "${RM_BIN}" -rf -- "${install_root}" || \
        fail "Could not finish verified transaction cleanup: ${install_root}"
    fi
    remove_journal || fail "Could not remove completed install journal: ${JOURNAL_FILE}"
    return 0
  fi

  if [[ "${phase}" == "restored" ]]; then
    [[ -d "${APP_BUNDLE}" && ! -L "${APP_BUNDLE}" ]] || \
      fail "Restored transaction lost its previous app; preserving ${install_root}"
    recovered_digest="$(bundle_digest "${APP_BUNDLE}")" || \
      fail "Could not digest restored previous app: ${APP_BUNDLE}"
    [[ -n "${previous_digest}" && "${recovered_digest}" == "${previous_digest}" ]] || \
      fail "Restored target no longer matches the previous bundle; preserving ${install_root}"
    if [[ "${previous_running}" == "1" ]]; then
      ensure_restored_bundle_ready "${APP_BUNDLE}" || \
        fail "Previous app is restored but did not regain its Bridge; preserving ${install_root}"
    fi
    if [[ -e "${install_root}" ]]; then
      validated_recovery_root "${install_root}" || \
        fail "Unsafe restored transaction root; preserving journal: ${JOURNAL_FILE}"
      "${RM_BIN}" -rf -- "${install_root}" || \
        fail "Could not finish restored transaction cleanup: ${install_root}"
    fi
    remove_journal || fail "Could not remove restored install journal: ${JOURNAL_FILE}"
    return 0
  fi

  validated_recovery_root "${install_root}" || \
    fail "Unsafe or missing transaction root; preserving journal: ${JOURNAL_FILE}"

  if [[ "${phase}" == "restoring" ]]; then
    if [[ -d "${backup}" && ! -e "${APP_BUNDLE}" ]]; then
      "${MV_BIN}" "${backup}" "${APP_BUNDLE}" || \
        fail "Could not resume previous-app restoration from ${backup}"
    elif [[ ! -e "${backup}" && -d "${APP_BUNDLE}" ]]; then
      recovered_digest="$(bundle_digest "${APP_BUNDLE}")" || \
        fail "Could not digest potentially restored app: ${APP_BUNDLE}"
      [[ -n "${previous_digest}" && "${recovered_digest}" == "${previous_digest}" ]] || \
        fail "Restoring transaction cannot identify the stable target; preserving ${install_root}"
    else
      fail "Restoring transaction has ambiguous backup/target state; preserving ${install_root}"
    fi
    recovered_digest="$(bundle_digest "${APP_BUNDLE}")" || \
      fail "Could not verify restored app digest: ${APP_BUNDLE}"
    [[ "${recovered_digest}" == "${previous_digest}" ]] || \
      fail "Restored app digest does not match the recorded previous bundle; preserving ${install_root}"
    write_journal_state restored "${install_root}" "${had_previous}" "${previous_running}" \
      "${artifact_digest}" "${previous_digest}" || \
      fail "Could not record resumed restoration; preserving ${install_root}"
    if [[ "${previous_running}" == "1" ]]; then
      ensure_restored_bundle_ready "${APP_BUNDLE}" || \
        fail "Previous app was restored but did not regain its Bridge; preserving ${install_root}"
    fi
    "${RM_BIN}" -rf -- "${install_root}" || \
      fail "Could not finish resumed restoration cleanup: ${install_root}"
    remove_journal || fail "Could not clear resumed restoration journal: ${JOURNAL_FILE}"
    return 0
  fi

  # In these phases the first rename may not have happened yet. If the stable target is still
  # present and no backup appeared, it is the unchanged previous bundle and can be resumed safely.
  if [[ "${phase}" == "staged" || "${phase}" == "backing-up" ]] && \
     [[ "${had_previous}" == "1" && -d "${APP_BUNDLE}" && ! -e "${backup}" ]]; then
    recovered_digest="$(bundle_digest "${APP_BUNDLE}")" || \
      fail "Could not digest unchanged app: ${APP_BUNDLE}"
    [[ -n "${previous_digest}" && "${recovered_digest}" == "${previous_digest}" ]] || \
      fail "Pre-rename target no longer matches the previous bundle; preserving ${install_root}"
    if [[ "${previous_running}" == "1" ]]; then
      write_journal_state restored "${install_root}" "${had_previous}" \
        "${previous_running}" "${artifact_digest}" "${previous_digest}" || \
        fail "Could not record unchanged-app recovery; preserving ${install_root}"
      ensure_restored_bundle_ready "${APP_BUNDLE}" || \
        fail "Unchanged app did not regain its Bridge; preserving interrupted transaction at ${install_root}"
    fi
    if [[ -e "${install_root}" ]]; then
      validated_recovery_root "${install_root}" || \
        fail "Unsafe pre-rename transaction root; preserving journal: ${JOURNAL_FILE}"
      "${RM_BIN}" -rf -- "${install_root}" || \
        fail "Could not remove pre-rename interrupted transaction: ${install_root}"
    fi
    remove_journal || fail "Could not clear pre-rename install journal: ${JOURNAL_FILE}"
    return 0
  fi

  if is_bundle_running "${APP_BUNDLE}"; then
    fail "A process is still running from an interrupted target; preserving recovery at ${install_root}"
  fi

  if [[ -d "${backup}" && ! -L "${backup}" ]]; then
    if [[ -e "${APP_BUNDLE}" ]]; then
      [[ ! -e "${failed}" ]] || fail "Recovery quarantine already exists: ${failed}"
      "${MV_BIN}" "${APP_BUNDLE}" "${failed}" || \
        fail "Could not preserve interrupted replacement at ${failed}"
    fi
    write_journal_state restoring "${install_root}" "${had_previous}" "${previous_running}" \
      "${artifact_digest}" "${previous_digest}" || \
      fail "Could not record pending restoration; preserving ${install_root}"
    "${MV_BIN}" "${backup}" "${APP_BUNDLE}" || \
      fail "Could not restore previous app from ${backup}"
    recovered_digest="$(bundle_digest "${APP_BUNDLE}")" || \
      fail "Could not verify restored previous app: ${APP_BUNDLE}"
    [[ "${recovered_digest}" == "${previous_digest}" ]] || \
      fail "Restored previous app does not match its recorded digest; preserving ${install_root}"
    write_journal_state restored "${install_root}" "${had_previous}" "${previous_running}" \
      "${artifact_digest}" "${previous_digest}" || \
      fail "Could not record restored transaction; preserving ${install_root}"
    if [[ "${previous_running}" == "1" ]]; then
      ensure_restored_bundle_ready "${APP_BUNDLE}" || \
        fail "Previous app is restored but did not regain its Bridge; preserving ${install_root}"
    fi
    "${RM_BIN}" -rf -- "${install_root}" || \
      fail "Could not finish recovered transaction cleanup: ${install_root}"
    remove_journal || fail "Could not remove recovered install journal: ${JOURNAL_FILE}"
    return 0
  fi

  if [[ "${had_previous}" == "1" ]]; then
    fail "Previous app backup is missing; preserving ambiguous transaction: ${install_root}"
  fi
  if [[ -e "${APP_BUNDLE}" ]]; then
    [[ ! -e "${failed}" ]] || fail "Recovery quarantine already exists: ${failed}"
    "${MV_BIN}" "${APP_BUNDLE}" "${failed}" || \
      fail "Could not preserve interrupted first install at ${failed}"
  fi
  if [[ -e "${candidate}" || -e "${failed}" ]]; then
    log "Preserved interrupted first-install payload at ${install_root}"
  else
    "${RM_BIN}" -rf -- "${install_root}" || \
      fail "Could not remove empty interrupted transaction: ${install_root}"
  fi
  remove_journal || fail "Could not clear recovered first-install journal: ${JOURNAL_FILE}"
}

build_app() {
  env \
    WORKSPACE="${WORKSPACE}" \
    SCHEME="${SCHEME}" \
    CONFIGURATION="${CONFIGURATION}" \
    APP_NAME="${APP_NAME}" \
    DERIVED_DATA_PATH="${DERIVED_DATA_PATH}" \
    DESTINATION="${DESTINATION}" \
    PEEKABOO_BUILD_UNSIGNED=1 \
    "${BUILD_SCRIPT}" || return 1

  log '==> Sign deployment app with the configured Developer ID identity'
  "${SIGN_RELEASE_APP_SCRIPT}" \
    --app "${BUILT_APP_BUNDLE}" \
    --entitlements "${APP_ENTITLEMENTS}" \
    --sign-identity "${SIGN_IDENTITY}" \
    --timestamp-url "${CODESIGN_TIMESTAMP_URL}"
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

bundle_code_signature_hash() {
  local bundle="$1"
  local code_hash details

  if ! details="$("${CODESIGN_BIN}" -dv --verbose=4 "${bundle}" 2>&1)"; then
    return 1
  fi
  code_hash="$(printf '%s\n' "${details}" | sed -n 's/^CDHash=//p' | head -n 1 | \
    tr '[:upper:]' '[:lower:]')"
  [[ "${code_hash}" =~ ^[0-9a-f]+$ ]] || return 1
  printf '%s\n' "${code_hash}"
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
  if ! verify_expected_signer "${BUILT_APP_BUNDLE}"; then
    printf '%s\n' \
      'The app must match the configured Apple-anchored signer, Team ID, and bundle identifier.' \
      'Install the configured identity or supply an already-signed --source-app; the current app was not stopped.' >&2
    return 1
  fi
}

verify_expected_signer() {
  local bundle="$1"
  local authority identifier team_id

  verify_signed_bundle "${bundle}" || return 1
  team_id="$(bundle_team_id "${bundle}")" || return 1
  identifier="$(bundle_identifier "${bundle}")" || return 1
  authority="$(bundle_authority "${bundle}")" || return 1
  if [[ "${team_id}" != "${EXPECTED_TEAM_ID}" ]]; then
    printf 'Bundle Team ID (%s) does not match expected Team ID (%s): %s\n' \
      "${team_id}" "${EXPECTED_TEAM_ID}" "${bundle}" >&2
    return 1
  fi
  if [[ "${identifier}" != "${EXPECTED_BUNDLE_ID}" ]]; then
    printf 'Bundle identifier (%s) does not match expected identifier (%s): %s\n' \
      "${identifier}" "${EXPECTED_BUNDLE_ID}" "${bundle}" >&2
    return 1
  fi
  if [[ "${authority}" != "${SIGN_IDENTITY}" ]]; then
    printf 'Bundle authority (%s) does not match expected identity (%s): %s\n' \
      "${authority}" "${SIGN_IDENTITY}" "${bundle}" >&2
    return 1
  fi
  if ! "${CODESIGN_BIN}" --verify --strict "-R=${EXPECTED_SIGN_REQUIREMENT}" "${bundle}"; then
    printf 'Bundle does not satisfy the Apple-anchored signing requirement: %s\n' "${bundle}" >&2
    return 1
  fi
  verify_nested_signers "${bundle}"
}

verify_expected_code_authority() {
  local code_path="$1"
  local authority team_id

  "${CODESIGN_BIN}" --verify --strict "${code_path}" || return 1
  team_id="$(bundle_team_id "${code_path}")" || return 1
  authority="$(bundle_authority "${code_path}")" || return 1
  [[ "${team_id}" == "${EXPECTED_TEAM_ID}" && "${authority}" == "${SIGN_IDENTITY}" ]] || {
    printf 'Nested code signer does not match the expected identity: %s\n' "${code_path}" >&2
    return 1
  }
  "${CODESIGN_BIN}" --verify --strict "-R=${EXPECTED_ANCHOR_REQUIREMENT}" "${code_path}"
}

verify_nested_signers() {
  local bundle="$1"
  local candidate main_executable main_executable_name

  main_executable_name="$("${PLISTBUDDY_BIN}" -c 'Print :CFBundleExecutable' \
    "${bundle}/Contents/Info.plist" 2>/dev/null)" || return 1
  main_executable="${bundle}/Contents/MacOS/${main_executable_name}"

  while IFS= read -r -d '' candidate; do
    [[ "${candidate}" != "${main_executable}" ]] || continue
    if "${FILE_BIN}" -b "${candidate}" | grep -q 'Mach-O'; then
      verify_expected_code_authority "${candidate}" || return 1
    fi
  done < <("${FIND_BIN}" "${bundle}/Contents" -type f -print0)
}

verify_existing_identity() {
  local built_identifier built_requirement built_team existing_identifier existing_requirement existing_team

  [[ -d "${APP_BUNDLE}" ]] || return 0
  if ! verify_signed_bundle "${APP_BUNDLE}" >/dev/null 2>&1; then
    if ((ALLOW_UNSTABLE_EXISTING == 1)); then
      printf 'WARNING: Replacing an unsigned, ad-hoc, or unreadable existing app by explicit request: %s\n' \
        "${APP_BUNDLE}" >&2
      printf '%s\n' 'Its existing TCC grants cannot be preserved and may need to be granted again.' >&2
      return 0
    fi
    printf 'Existing app has no trustworthy stable code identity: %s\n' "${APP_BUNDLE}" >&2
    printf '%s\n' \
      'Refusing to replace it by default because its TCC identity cannot be preserved.' \
      'Pass --allow-unstable-existing-identity only for an intentional identity migration.' >&2
    return 1
  fi
  built_team="$(bundle_team_id "${BUILT_APP_BUNDLE}")"
  built_identifier="$(bundle_identifier "${BUILT_APP_BUNDLE}")"
  built_requirement="$(bundle_designated_requirement "${BUILT_APP_BUNDLE}")"
  existing_team="$(bundle_team_id "${APP_BUNDLE}")" || return 1
  if [[ "${existing_team}" != "${built_team}" ]]; then
    printf 'Existing app Team ID (%s) differs from the build (%s): %s\n' \
      "${existing_team}" "${built_team}" "${APP_BUNDLE}" >&2
    printf '%s\n' 'Refusing to replace it because that changes the app identity used by TCC.' >&2
    return 1
  fi

  existing_identifier="$(bundle_identifier "${APP_BUNDLE}")" || return 1
  if [[ "${existing_identifier}" != "${built_identifier}" ]]; then
    printf 'Existing app identifier (%s) differs from the build (%s): %s\n' \
      "${existing_identifier}" "${built_identifier}" "${APP_BUNDLE}" >&2
    printf '%s\n' \
      'Refusing to replace it because the signed bundle identifier is part of the TCC identity.' \
      'Choose a matching build configuration or a different stable Peekaboo.app target.' >&2
    return 1
  fi
  existing_requirement="$(bundle_designated_requirement "${APP_BUNDLE}")" || return 1
  if [[ "${existing_requirement}" != "${built_requirement}" ]]; then
    printf 'Existing app designated requirement differs from the build: %s\n' "${APP_BUNDLE}" >&2
    printf '%s\n' \
      'Refusing to replace it because certificate class and requirement are part of the TCC identity.' >&2
    return 1
  fi
}

prepare_install_candidate() {
  local target_parent candidate_digest

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
  if ! verify_expected_signer "${CANDIDATE_APP_BUNDLE}"; then
    return 1
  fi
  if ! "${NATIVE_ONLY_VERIFY_SCRIPT}" --app "${CANDIDATE_APP_BUNDLE}"; then
    printf 'Staged app violates the native-only policy: %s\n' "${CANDIDATE_APP_BUNDLE}" >&2
    return 1
  fi
  candidate_digest="$(bundle_digest "${CANDIDATE_APP_BUNDLE}")" || return 1
  if [[ "${candidate_digest}" != "${ARTIFACT_DIGEST}" ]]; then
    printf 'Staged app digest (%s) differs from the source artifact (%s)\n' \
      "${candidate_digest}" "${ARTIFACT_DIGEST}" >&2
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
  local installed_digest

  if [[ -e "${APP_BUNDLE}" ]]; then
    BACKUP_CREATED=1
    write_journal_state backing-up "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
      "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}" || return 1
    if ! "${MV_BIN}" "${APP_BUNDLE}" "${BACKUP_APP_BUNDLE}"; then
      return 1
    fi
    write_journal_state backed-up "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
      "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}" || return 1
  fi

  write_journal_state installing "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
    "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}" || return 1
  NEW_APP_INSTALLED=1
  if ! "${MV_BIN}" "${CANDIDATE_APP_BUNDLE}" "${APP_BUNDLE}"; then
    return 1
  fi
  write_journal_state installed "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
    "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}" || return 1

  # Moving within the target filesystem should not alter the signature, but verify the exact launch path too.
  verify_expected_signer "${APP_BUNDLE}" || return 1
  installed_digest="$(bundle_digest "${APP_BUNDLE}")" || return 1
  if [[ "${installed_digest}" != "${ARTIFACT_DIGEST}" ]]; then
    printf 'Installed app digest (%s) differs from the source artifact (%s)\n' \
      "${installed_digest}" "${ARTIFACT_DIGEST}" >&2
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
    "${OPEN_BIN}" -gj "${bundle}" --args --background-bridge-host
}

launch_and_verify_bundle() {
  local bundle="$1"
  local attempt pid pids seen_pid="" seen_pid_count=0

  if is_bundle_running "${bundle}"; then
    printf 'Refusing to treat an already-running process as a newly launched generation: %s\n' \
      "${bundle}" >&2
    return 1
  fi
  if ! open_bundle "${bundle}"; then
    return 1
  fi
  for ((attempt = 0; attempt < LAUNCH_VERIFY_ATTEMPTS; attempt += 1)); do
    pids="$(bundle_pids "${bundle}" 2>/dev/null || true)"
    if [[ -n "${pids}" ]]; then
      seen_pid=""
      seen_pid_count=0
      while IFS= read -r pid; do
        [[ "${pid}" =~ ^[0-9]+$ ]] || continue
        seen_pid="${pid}"
        seen_pid_count=$((seen_pid_count + 1))
      done <<<"${pids}"
      if ((seen_pid_count == 1)); then
        LAUNCHED_PID="${seen_pid}"
        LAUNCHED_PROCESS_START_IDENTITY="$(query_process_start_identity "${seen_pid}")" || return 1
        [[ "${LAUNCHED_PROCESS_START_IDENTITY}" =~ ^[0-9]+$ ]] || return 1
        [[ "${LAUNCHED_PROCESS_START_IDENTITY}" != "0" ]] || return 1
        return 0
      fi
      printf 'Expected one new %s process from %s, found %s\n' \
        "${APP_NAME}" "${bundle}" "${seen_pid_count}" >&2
      return 1
    fi
    "${SLEEP_BIN}" "${LAUNCH_VERIFY_INTERVAL}"
  done
  printf '%s launched no process from %s\n' "${APP_NAME}" "${bundle}" >&2
  return 1
}

query_process_start_identity() {
  local pid="$1"
  local output process_start_identity

  output="$(
    env -i \
      HOME="${HOME}" \
      USER="${USER:-$(id -un)}" \
      LOGNAME="${LOGNAME:-$(id -un)}" \
      TMPDIR="${TMPDIR:-/tmp}" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      LANG="${LANG:-en_US.UTF-8}" \
      "${HEALTHCHECK_CLI}" app list --include-hidden --include-background --no-remote --json 2>/dev/null
  )" || return 1
  # shellcheck disable=SC2016
  process_start_identity="$("${JQ_BIN}" -er --argjson pid "${pid}" '
    select(.success == true) |
    [.data.apps[] | select(.pid == $pid) | .process_start_identity_decimal] |
    if length == 1 then .[0] else empty end
  ' <<<"${output}")" || return 1
  [[ "${process_start_identity}" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "${process_start_identity}"
}

validate_healthcheck_configuration() {
  local healthcheck_identifier output

  [[ -n "${HEALTHCHECK_CLI}" && "${HEALTHCHECK_CLI}" == /* && -x "${HEALTHCHECK_CLI}" ]] || \
    fail 'A current signed Peekaboo CLI is required; pass --healthcheck-cli <absolute-path>'
  [[ -n "${JQ_BIN}" && "${JQ_BIN}" == /* && -x "${JQ_BIN}" ]] || \
    fail 'jq is required for exact GUI Bridge readiness verification'
  [[ "${LSOF_BIN}" == /* && -x "${LSOF_BIN}" ]] || \
    fail 'lsof is required to bind legacy restored Bridge readiness to the exact process'
  [[ "${BRIDGE_SOCKET}" == /* && "${BRIDGE_SOCKET}" != *$'\n'* ]] || \
    fail "PEEKABOO_APP_BRIDGE_SOCKET must be an absolute path: ${BRIDGE_SOCKET}"
  verify_expected_code_authority "${HEALTHCHECK_CLI}" || \
    fail "Healthcheck CLI does not satisfy the expected Apple-anchored signer policy: ${HEALTHCHECK_CLI}"
  healthcheck_identifier="$(bundle_identifier "${HEALTHCHECK_CLI}")" || \
    fail "Healthcheck CLI has no signed identifier: ${HEALTHCHECK_CLI}"
  [[ "${healthcheck_identifier}" == "${HEALTHCHECK_CLI_BUNDLE_ID}" ]] || \
    fail "Healthcheck CLI identifier is ${healthcheck_identifier}; expected ${HEALTHCHECK_CLI_BUNDLE_ID}"

  # This installer depends on lossless process-generation receipts added alongside the GUI host
  # identity handshake. Reject an older signed CLI before building, stopping, or renaming anything;
  # accepting it here would make the ordinary first upgrade fail only after installation.
  output="$(
    env -i \
      HOME="${HOME}" \
      USER="${USER:-$(id -un)}" \
      LOGNAME="${LOGNAME:-$(id -un)}" \
      TMPDIR="${TMPDIR:-/tmp}" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
      LANG="${LANG:-en_US.UTF-8}" \
      "${HEALTHCHECK_CLI}" app list --include-hidden --include-background --no-remote --json 2>/dev/null
  )" || fail "Healthcheck CLI could not prove the current installer contract: ${HEALTHCHECK_CLI}"
  "${JQ_BIN}" -e '
    .success == true and
    (.data.apps | type == "array") and
    (.data.schema_capabilities | type == "array") and
    (.data.schema_capabilities | index("processStartIdentityDecimal") != null)
  ' <<<"${output}" >/dev/null || fail \
    "Healthcheck CLI predates exact host-generation readiness; build and sign this checkout's CLI or pass --healthcheck-cli <absolute-current-path>"
}

verify_exact_bridge_health() {
  local attempt code_hash current_pids current_start_identity_after current_start_identity_before
  local output short_version bundle_version
  local require_background_host="$1"

  [[ "${LAUNCHED_PID}" =~ ^[0-9]+$ && "${LAUNCHED_PROCESS_START_IDENTITY}" =~ ^[0-9]+$ ]] || return 1
  code_hash="$(bundle_code_signature_hash "${APP_BUNDLE}")" || return 1
  short_version="$("${PLISTBUDDY_BIN}" -c 'Print :CFBundleShortVersionString' \
    "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null)" || return 1
  bundle_version="$("${PLISTBUDDY_BIN}" -c 'Print :CFBundleVersion' \
    "${APP_BUNDLE}/Contents/Info.plist" 2>/dev/null)" || return 1

  for ((attempt = 0; attempt < HEALTH_VERIFY_ATTEMPTS; attempt += 1)); do
    # shellcheck disable=SC2016
    if output="$(
      env -i \
        HOME="${HOME}" \
        USER="${USER:-$(id -un)}" \
        LOGNAME="${LOGNAME:-$(id -un)}" \
        TMPDIR="${TMPDIR:-/tmp}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        LANG="${LANG:-en_US.UTF-8}" \
        "${HEALTHCHECK_CLI}" bridge status --bridge-socket "${BRIDGE_SOCKET}" --json 2>/dev/null
    )" && "${JQ_BIN}" -e \
      --arg socket "${BRIDGE_SOCKET}" \
      --argjson pid "${LAUNCHED_PID}" \
      --arg process_start_identity "${LAUNCHED_PROCESS_START_IDENTITY}" \
      --arg bundle_id "${EXPECTED_BUNDLE_ID}" \
      --arg short_version "${short_version}" \
      --arg bundle_version "${bundle_version}" \
      --argjson require_background_host "${require_background_host}" \
      --arg code_hash "${code_hash}" '
        .success == true and
        .data.selected.source == "remote" and
        .data.selected.socketPath == $socket and
        .data.selected.handshake.hostKind == "gui" and
        .data.selected.handshake.hostIdentity.processIdentifier == $pid and
        .data.selected.handshake.hostIdentity.processStartIdentityDecimal == $process_start_identity and
        .data.selected.handshake.hostIdentity.bundleIdentifier == $bundle_id and
        .data.selected.handshake.hostIdentity.bundleShortVersion == $short_version and
        .data.selected.handshake.hostIdentity.bundleVersion == $bundle_version and
        .data.selected.handshake.hostIdentity.codeSignatureHash == $code_hash and
        ($require_background_host == false or
          (.data.selected.handshake.hostCapabilities | index("backgroundBridgeHost")) != null) and
        (.data.selected.handshake.hostCapabilities | index("hostGenerationIdentity")) != null and
        (.data.selected.handshake.hostCapabilities | index("codeSignatureBuildIdentity")) != null
      ' <<<"${output}" >/dev/null
    then
      current_start_identity_before="$(query_process_start_identity "${LAUNCHED_PID}")" || return 1
      current_pids="$(bundle_pids "${APP_BUNDLE}" 2>/dev/null || true)"
      current_start_identity_after="$(query_process_start_identity "${LAUNCHED_PID}")" || return 1
      if [[ "${current_start_identity_before}" == "${LAUNCHED_PROCESS_START_IDENTITY}" &&
            "${current_start_identity_after}" == "${LAUNCHED_PROCESS_START_IDENTITY}" &&
            "${current_pids}" == "${LAUNCHED_PID}" ]]; then
        return 0
      fi
      return 1
    fi
    "${SLEEP_BIN}" "${HEALTH_VERIFY_INTERVAL}"
  done
  printf 'Process %s did not expose matching GUI Bridge readiness at %s\n' \
    "${LAUNCHED_PID}" "${BRIDGE_SOCKET}" >&2
  return 1
}

verify_restored_bridge_health() {
  local attempt current_pids_after current_pids_before current_start_identity_after
  local current_start_identity_before output socket_pids_after socket_pids_before

  [[ "${LAUNCHED_PID}" =~ ^[0-9]+$ && "${LAUNCHED_PROCESS_START_IDENTITY}" =~ ^[0-9]+$ ]] || return 1
  for ((attempt = 0; attempt < HEALTH_VERIFY_ATTEMPTS; attempt += 1)); do
    current_start_identity_before="$(query_process_start_identity "${LAUNCHED_PID}")" || {
      "${SLEEP_BIN}" "${HEALTH_VERIFY_INTERVAL}"
      continue
    }
    current_pids_before="$(bundle_pids "${APP_BUNDLE}" 2>/dev/null || true)"
    socket_pids_before="$("${LSOF_BIN}" -t -a -U -- "${BRIDGE_SOCKET}" 2>/dev/null | awk '!seen[$0]++')"
    if output="$(
      env -i \
        HOME="${HOME}" \
        USER="${USER:-$(id -un)}" \
        LOGNAME="${LOGNAME:-$(id -un)}" \
        TMPDIR="${TMPDIR:-/tmp}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        LANG="${LANG:-en_US.UTF-8}" \
        "${HEALTHCHECK_CLI}" bridge status --bridge-socket "${BRIDGE_SOCKET}" --json 2>/dev/null
    )" && "${JQ_BIN}" -e \
      --arg socket "${BRIDGE_SOCKET}" '
        .success == true and
        .data.selected.source == "remote" and
        .data.selected.socketPath == $socket and
        .data.selected.handshake.hostKind == "gui"
      ' <<<"${output}" >/dev/null
    then
      # Atomic socket publication leaves lsof reporting the temporary bind path. Modern hosts
      # provide an authenticated process/build receipt; never downgrade a mismatched receipt.
      if "${JQ_BIN}" -e '.data.selected.handshake | has("hostIdentity")' <<<"${output}" >/dev/null; then
        verify_exact_bridge_health false
        return $?
      fi
      if current_start_identity_after="$(query_process_start_identity "${LAUNCHED_PID}")" &&
       current_pids_after="$(bundle_pids "${APP_BUNDLE}" 2>/dev/null || true)" &&
       socket_pids_after="$("${LSOF_BIN}" -t -a -U -- "${BRIDGE_SOCKET}" 2>/dev/null | awk '!seen[$0]++')" &&
       [[ "${current_start_identity_before}" == "${LAUNCHED_PROCESS_START_IDENTITY}" &&
          "${current_start_identity_after}" == "${LAUNCHED_PROCESS_START_IDENTITY}" &&
          "${current_pids_before}" == "${LAUNCHED_PID}" &&
          "${current_pids_after}" == "${LAUNCHED_PID}" &&
          "${socket_pids_before}" == "${LAUNCHED_PID}" &&
          "${socket_pids_after}" == "${LAUNCHED_PID}" ]]
      then
        return 0
      fi
    fi
    "${SLEEP_BIN}" "${HEALTH_VERIFY_INTERVAL}"
  done
  printf 'Restored process %s did not regain exact GUI Bridge ownership at %s\n' \
    "${LAUNCHED_PID}" "${BRIDGE_SOCKET}" >&2
  return 1
}

observe_running_bundle_generation() {
  local bundle="$1" pid pids seen_pid="" seen_pid_count=0

  pids="$(bundle_pids "${bundle}" 2>/dev/null || true)"
  while IFS= read -r pid; do
    [[ "${pid}" =~ ^[0-9]+$ ]] || continue
    seen_pid="${pid}"
    seen_pid_count=$((seen_pid_count + 1))
  done <<<"${pids}"
  ((seen_pid_count == 1)) || return 1
  LAUNCHED_PID="${seen_pid}"
  LAUNCHED_PROCESS_START_IDENTITY="$(query_process_start_identity "${seen_pid}")" || return 1
  [[ "${LAUNCHED_PROCESS_START_IDENTITY}" =~ ^[1-9][0-9]*$ ]]
}

ensure_restored_bundle_ready() {
  local bundle="$1"

  if is_bundle_running "${bundle}"; then
    observe_running_bundle_generation "${bundle}" || return 1
  else
    launch_and_verify_bundle "${bundle}" || return 1
  fi
  verify_restored_bridge_health
}

launch_and_verify() {
  launch_and_verify_bundle "${APP_BUNDLE}" || return 1
  verify_exact_bridge_health true
}

rollback_install() {
  local exit_code=$?
  local restored=0 restored_digest=""
  local target_cleared=1
  local cleanup_ok=1

  trap - EXIT INT TERM HUP
  if ((exit_code == 0 && INSTALL_VERIFIED == 1)); then
    if [[ -n "${INSTALL_ROOT}" && -d "${INSTALL_ROOT}" ]]; then
      if ! "${RM_BIN}" -rf -- "${INSTALL_ROOT}"; then
        printf 'ERROR: Could not remove completed install transaction: %s\n' "${INSTALL_ROOT}" >&2
        cleanup_ok=0
      elif ! remove_journal; then
        printf 'ERROR: Could not remove completed install journal: %s\n' "${JOURNAL_FILE}" >&2
        cleanup_ok=0
      fi
    fi
    if ! release_install_lock; then
      cleanup_ok=0
    fi
    ((cleanup_ok == 1)) && exit 0
    exit 1
  fi

  if [[ -n "${INSTALL_ROOT}" ]]; then
    if ((INSTALL_STARTED == 0)); then
      if ((TARGET_WAS_RUNNING == 1)) && [[ -d "${APP_BUNDLE}" ]]; then
        if ((TARGET_STOP_ATTEMPTED == 1)); then
          if stop_peekaboo >/dev/null 2>&1; then
            TARGET_STOPPED=1
          else
            printf 'ERROR: Could not stabilize the interrupted previous process; recovery remains at %s\n' \
              "${INSTALL_ROOT}" >&2
            release_install_lock || true
            exit "${exit_code}"
          fi
        elif ! is_bundle_running "${APP_BUNDLE}"; then
          TARGET_STOPPED=1
        fi
      fi
      if ((TARGET_STOPPED == 1 && TARGET_WAS_RUNNING == 1)) && [[ -d "${APP_BUNDLE}" ]]; then
        if ! write_journal_state restored "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
          "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}"; then
          printf 'ERROR: Could not record preserved unchanged app; recovery remains at %s\n' \
            "${INSTALL_ROOT}" >&2
          release_install_lock || true
          exit "${exit_code}"
        fi
        if ! ensure_restored_bundle_ready "${APP_BUNDLE}"; then
          printf 'ERROR: The unchanged app was preserved but its Bridge did not recover.\n' >&2
          release_install_lock || true
          exit "${exit_code}"
        fi
      fi
      if ! remove_journal || ! "${RM_BIN}" -rf -- "${INSTALL_ROOT}"; then
        printf 'ERROR: Could not remove abandoned install transaction: %s\n' "${INSTALL_ROOT}" >&2
      fi
      release_install_lock || true
      exit "${exit_code}"
    fi

    printf 'Restart failed; restoring the previous app bundle.\n' >&2
    if ((NEW_APP_INSTALLED == 1)); then
      if ! stop_peekaboo >/dev/null 2>&1 || is_bundle_running "${APP_BUNDLE}"; then
        printf 'ERROR: Replacement is still running; recovery remains at %s\n' "${INSTALL_ROOT}" >&2
        printf '%s\n' 'Refusing to restore over a live replacement.' >&2
        release_install_lock || true
        exit "${exit_code}"
      fi
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
      else
        if ! write_journal_state restoring "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
          "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}"; then
          printf 'ERROR: Could not record pending restoration; recovery remains at %s\n' \
            "${INSTALL_ROOT}" >&2
          release_install_lock || true
          exit "${exit_code}"
        fi
        if "${MV_BIN}" "${BACKUP_APP_BUNDLE}" "${APP_BUNDLE}"; then
          restored_digest="$(bundle_digest "${APP_BUNDLE}")" || restored_digest=""
          if [[ "${restored_digest}" != "${PREVIOUS_DIGEST}" ]]; then
            printf 'ERROR: Restored app does not match the recorded previous bundle; preserving %s\n' \
              "${INSTALL_ROOT}" >&2
            release_install_lock || true
            exit "${exit_code}"
          fi
          restored=1
          if ! write_journal_state restored "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
            "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}"; then
            printf 'ERROR: Previous app was restored but its journal could not be updated; preserving %s\n' \
              "${INSTALL_ROOT}" >&2
            release_install_lock || true
            exit "${exit_code}"
          fi
          printf 'Restored: %s\n' "${APP_BUNDLE}" >&2
        else
          printf 'ERROR: Automatic restore failed. Recovery bundle remains at %s\n' "${BACKUP_APP_BUNDLE}" >&2
        fi
      fi
    elif ((BACKUP_CREATED == 1 && NEW_APP_INSTALLED == 0)) && [[ -d "${APP_BUNDLE}" ]]; then
      # The first rename was interrupted before it moved the unchanged target.
      restored=1
      if ! write_journal_state restored "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
        "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}"; then
        printf 'ERROR: Unchanged app survived but its journal could not be updated; preserving %s\n' \
          "${INSTALL_ROOT}" >&2
        release_install_lock || true
        exit "${exit_code}"
      fi
    elif ((BACKUP_CREATED == 0)); then
      restored="${target_cleared}"
    fi

    if ((restored == 1 && TARGET_WAS_RUNNING == 1)) && [[ -d "${APP_BUNDLE}" ]]; then
      if ! ensure_restored_bundle_ready "${APP_BUNDLE}"; then
        printf 'ERROR: The previous app was restored but its Bridge did not recover.\n' >&2
        release_install_lock || true
        exit "${exit_code}"
      fi
    fi

    if ((restored == 1)) && [[ -d "${INSTALL_ROOT}" ]]; then
      if ((BACKUP_CREATED == 0)) && [[ -d "${INSTALL_ROOT}/failed.app" ]]; then
        printf 'Preserved failed first-install payload at %s\n' "${INSTALL_ROOT}/failed.app" >&2
        remove_journal || \
          printf 'WARNING: Could not clear first-install journal: %s\n' "${JOURNAL_FILE}" >&2
      elif ! "${RM_BIN}" -rf -- "${INSTALL_ROOT}" || ! remove_journal; then
        printf 'WARNING: Could not remove rolled-back install transaction: %s\n' "${INSTALL_ROOT}" >&2
      fi
    fi
  fi
  release_install_lock || true
  exit "${exit_code}"
}

while (($# > 0)); do
  case "$1" in
    --)
      # pnpm forwards its explicit script separator to the command itself.
      shift
      ;;
    --source-app)
      [[ "$#" -ge 2 ]] || fail '--source-app requires a bundle path'
      [[ -z "${SOURCE_APP_BUNDLE}" ]] || fail '--source-app may be specified only once'
      SOURCE_APP_BUNDLE="$2"
      NO_BUILD=1
      shift 2
      ;;
    --no-build)
      NO_BUILD=1
      shift
      ;;
    --healthcheck-cli)
      [[ "$#" -ge 2 ]] || fail '--healthcheck-cli requires a path'
      HEALTHCHECK_CLI="$2"
      shift 2
      ;;
    --allow-unstable-existing-identity)
      ALLOW_UNSTABLE_EXISTING=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "Unknown argument: $1"
      ;;
  esac
done

if [[ -n "${SOURCE_APP_BUNDLE}" ]]; then
  [[ "${SOURCE_APP_BUNDLE}" == /* ]] || fail "--source-app must be an absolute path: ${SOURCE_APP_BUNDLE}"
  reject_unsafe_path_syntax "${SOURCE_APP_BUNDLE}"
  [[ -d "${SOURCE_APP_BUNDLE}" && ! -L "${SOURCE_APP_BUNDLE}" ]] || \
    fail "Source app is not a regular bundle directory: ${SOURCE_APP_BUNDLE}"
  [[ "$(basename "${SOURCE_APP_BUNDLE}")" == "${APP_NAME}.app" ]] || \
    fail "Source app must end in ${APP_NAME}.app: ${SOURCE_APP_BUNDLE}"
  SOURCE_APP_BUNDLE="$(cd "$(dirname "${SOURCE_APP_BUNDLE}")" && pwd -P)/${APP_NAME}.app"
  BUILT_APP_BUNDLE="${SOURCE_APP_BUNDLE}"
fi

choose_app_bundle
validate_app_bundle_target
if [[ -d "${BUILT_APP_BUNDLE}" ]]; then
  reject_unsafe_path_syntax "${BUILT_APP_BUNDLE}"
  BUILT_APP_BUNDLE="$(cd "$(dirname "${BUILT_APP_BUNDLE}")" && pwd -P)/$(basename "${BUILT_APP_BUNDLE}")"
fi
[[ "${APP_BUNDLE}" != "${BUILT_APP_BUNDLE}" ]] || fail 'Install target must not be the build/source app'

acquire_install_lock
trap rollback_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
recover_interrupted_install
validate_healthcheck_configuration

if ((NO_BUILD == 0)); then
  log '==> Verify native-only source policy'
  "${NATIVE_ONLY_VERIFY_SCRIPT}" --source-root "${NATIVE_SOURCE_ROOT}" || \
    fail "Native-only source policy failed; the running app was not stopped"

  log "==> Build ${APP_NAME}.app (${CONFIGURATION})"
  build_app || fail "Build failed; the running app was not stopped"
else
  log "==> Reuse exact signed app ${BUILT_APP_BUNDLE}"
fi

log '==> Verify signed build output'
verify_build_output || fail "Built app verification failed; the running app was not stopped"
"${NATIVE_ONLY_VERIFY_SCRIPT}" --app "${BUILT_APP_BUNDLE}" || \
  fail "Built app violates the native-only policy; the running app was not stopped"
ARTIFACT_DIGEST="$(bundle_digest "${BUILT_APP_BUNDLE}")" || \
  fail "Could not compute source artifact digest; the running app was not stopped"
log "Artifact SHA-256: ${ARTIFACT_DIGEST}"
verify_existing_identity || fail "Existing app identity is incompatible; the running app was not stopped"

if [[ -e "${APP_BUNDLE}" ]]; then
  HAD_PREVIOUS_APP=1
  PREVIOUS_DIGEST="$(bundle_digest "${APP_BUNDLE}")" || \
    fail "Could not record the previous app digest; the running app was not stopped"
fi
log "==> Stage signed app beside ${APP_BUNDLE}"
prepare_install_candidate || fail "Could not prepare a verified install candidate; the running app was not stopped"

if is_bundle_running "${APP_BUNDLE}"; then
  TARGET_WAS_RUNNING=1
fi
write_journal_state staged "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
  "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}"

log "==> Stop ${APP_NAME}"
TARGET_STOP_ATTEMPTED=1
stop_peekaboo || fail "Could not stop ${APP_NAME}; install was not changed"
TARGET_STOPPED=1

log "==> Install signed app at ${APP_BUNDLE}"
INSTALL_STARTED=1
install_candidate || fail "Install failed"

log "==> Launch and verify ${APP_BUNDLE}"
launch_and_verify || fail "Replacement app failed launch verification"

write_journal_state verified "${INSTALL_ROOT}" "${HAD_PREVIOUS_APP}" \
  "${TARGET_WAS_RUNNING}" "${ARTIFACT_DIGEST}"
INSTALL_VERIFIED=1
log "OK: ${APP_NAME} is running from ${APP_BUNDLE} (SHA-256 ${ARTIFACT_DIGEST})."
