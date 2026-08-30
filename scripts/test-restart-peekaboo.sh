#!/usr/bin/env bash

set -euo pipefail

TEST_DIR=""
LOCK_HOLDER=""
FIXTURE_COMPLETE=0

cleanup() {
  local exit_code=$?

  trap - EXIT
  if [[ -n "${LOCK_HOLDER}" ]]; then
    kill "${LOCK_HOLDER}" 2>/dev/null || true
    wait "${LOCK_HOLDER}" 2>/dev/null || true
  fi
  if [[ -n "${TEST_DIR}" ]] && ! rm -rf "${TEST_DIR}"; then
    printf 'test-restart-peekaboo: cleanup failed\n' >&2
    ((exit_code != 0)) || exit_code=1
  fi
  # Bash 3.2 can enter EXIT with status 0 after nounset aborts an if-tested function.
  if ((FIXTURE_COMPLETE != 1)); then
    printf 'test-restart-peekaboo: fixture did not complete\n' >&2
    ((exit_code != 0)) || exit_code=1
  fi
  if ((exit_code == 0)); then
    printf 'test-restart-peekaboo: ok\n'
  fi
  exit "${exit_code}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-restart-test.XXXXXX)"
canonical_test_dir="$(cd "${TEST_DIR}" && pwd -P)"
TEST_DIR="${canonical_test_dir}"
TEMPLATE_BIN="${TEST_DIR}/template-bin"
TEMPLATE_SOURCE="${TEST_DIR}/template-source"

fail() {
  printf 'test-restart-peekaboo: %s\n' "$*" >&2
  exit 1
}

assert_text() {
  local path="$1"
  local expected="$2"
  local actual

  [[ -f "${path}" ]] || fail "missing file: ${path}"
  actual="$(<"${path}")"
  [[ "${actual}" == "${expected}" ]] || fail "expected '${expected}' in ${path}, got '${actual}'"
}

write_lock_owner() {
  local parent="$1"
  local lock_dir="${parent}/.Peekaboo.install-lock"

  mkdir -p "${parent}"
  [[ -d "${lock_dir}" ]] || mkdir -m 700 "${lock_dir}"
  touch "${lock_dir}/lock"
}

test_bundle_digest() {
  local bundle="$1"
  local candidate content_digest manifest mode relative_path symlink_target

  manifest="$(mktemp -t peekaboo-test-digest.XXXXXX)"
  while IFS= read -r -d '' candidate; do
    relative_path="${candidate#"${bundle}"/}"
    if [[ -L "${candidate}" ]]; then
      symlink_target="$(readlink "${candidate}")"
      printf 'L\0%s\0%s\0' "${relative_path}" "${symlink_target}" >>"${manifest}"
    elif [[ -f "${candidate}" ]]; then
      content_digest="$(shasum -a 256 "${candidate}" | awk '{print $1}')"
      mode="$(stat -f %Lp "${candidate}")"
      printf 'F\0%s\0%s\0%s\0' "${relative_path}" "${mode}" "${content_digest}" >>"${manifest}"
    fi
  done < <(find -s "${bundle}" \( -type f -o -type l \) -print0)
  shasum -a 256 "${manifest}" | awk '{print $1}'
  rm -f "${manifest}"
}

write_journal() {
  local parent="$1"
  local target="$2"
  local install_root="$3"
  local phase="$4"
  local had_previous="$5"
  local previous_running="$6"
  local artifact_bundle artifact_digest previous_bundle previous_digest=""

  if [[ -d "${install_root}/candidate.app" ]]; then
    artifact_bundle="${install_root}/candidate.app"
  elif [[ "${phase}" == "installed" && -d "${target}" ]]; then
    artifact_bundle="${target}"
  else
    artifact_bundle=""
  fi
  if [[ -n "${artifact_bundle}" ]]; then
    artifact_digest="$(test_bundle_digest "${artifact_bundle}")"
  else
    artifact_digest='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  fi

  if [[ -d "${install_root}/previous.app" ]]; then
    previous_bundle="${install_root}/previous.app"
  elif [[ "${had_previous}" == "1" && -d "${target}" ]]; then
    previous_bundle="${target}"
  else
    previous_bundle=""
  fi
  [[ -z "${previous_bundle}" ]] || previous_digest="$(test_bundle_digest "${previous_bundle}")"

  printf '%s\n' \
    'version=2' \
    "phase=${phase}" \
    "target=${target}" \
    "install_root=${install_root}" \
    "had_previous=${had_previous}" \
    "previous_running=${previous_running}" \
    "artifact_digest=${artifact_digest}" \
    "previous_digest=${previous_digest}" \
    >"${parent}/.Peekaboo.install.journal"
}

make_bundle() {
  local path="$1"
  local build_id="$2"

  mkdir -p "${path}/Contents/MacOS"
  printf '%s\n' "${build_id}" >"${path}/build-id"
  printf '%s\n' 'TESTTEAM' >"${path}/.team-id"
  printf '%s\n' 'boo.peekaboo.mac' >"${path}/.bundle-id"
  printf '%s\n' 'developer-id' >"${path}/.requirement"
  printf '%s\n' '1111111111111111111111111111111111111111' >"${path}/.cdhash"
  touch "${path}/.trusted-anchor"
  /usr/bin/plutil -create xml1 "${path}/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string Peekaboo "${path}/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleShortVersionString -string 4.0.1 "${path}/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleVersion -string 4000199 "${path}/Contents/Info.plist"
  printf '#!/usr/bin/env bash\n' >"${path}/Contents/MacOS/Peekaboo"
  chmod +x "${path}/Contents/MacOS/Peekaboo"
}

new_case() {
  local name="$1"
  local case_dir="${TEST_DIR}/${name}"

  printf 'test-restart-peekaboo: case=%s\n' "${name}" >&2
  mkdir -p "${case_dir}"
  cp -R "${TEMPLATE_BIN}" "${case_dir}/bin"
  cp -R "${TEMPLATE_SOURCE}" "${case_dir}/source"
  printf '%s\n' "${case_dir}"
}

run_build_signing_case() {
  local name="$1"
  local output="${build_signing_dir}/${name}.log"
  local exit_code
  shift

  printf 'test-restart-peekaboo: build-signing=%s\n' "${name}"
  # Only the external child is conditional; caller assertions retain errexit.
  if "$@" >"${output}" 2>&1; then
    return 0
  else
    exit_code=$?
    cat "${output}" >&2
    printf 'test-restart-peekaboo: build-signing=%s exit=%s\n' "${name}" "${exit_code}" >&2
    return "${exit_code}"
  fi
}

run_restart() {
  local case_dir="$1"
  shift

  # Keep the command array nonempty; empty arrays are unbound under Bash 3.2 nounset.
  local -a command_args=(env
    HOME="${case_dir}/home" \
    DERIVED_DATA_PATH="${case_dir}/DerivedData" \
    DIST_DIR="${case_dir}/dist" \
    DIST_APP_BUNDLE="${case_dir}/dist/Peekaboo.app" \
    PEEKABOO_APPLICATIONS_DIR="${case_dir}/Applications" \
    PEEKABOO_BUILD_SCRIPT="${case_dir}/bin/build-app" \
    PEEKABOO_SIGN_RELEASE_APP_SCRIPT="${case_dir}/bin/sign-release-app" \
    PEEKABOO_CODESIGN_BIN="${case_dir}/bin/codesign" \
    PEEKABOO_DITTO_BIN="${case_dir}/bin/ditto" \
    PEEKABOO_FILE_BIN="${case_dir}/bin/file" \
    PEEKABOO_NM_BIN="${case_dir}/bin/nm" \
    PEEKABOO_STRINGS_BIN="${case_dir}/bin/strings" \
    PEEKABOO_SECURITY_BIN="${case_dir}/bin/security" \
    PEEKABOO_NATIVE_SOURCE_ROOT="${case_dir}/source" \
    PEEKABOO_MV_BIN="${case_dir}/bin/mv" \
    PEEKABOO_OPEN_BIN="${case_dir}/bin/open" \
    PEEKABOO_PGREP_BIN="${case_dir}/bin/pgrep" \
    PEEKABOO_KILL_BIN="${case_dir}/bin/kill" \
    PEEKABOO_LSOF_BIN="${case_dir}/bin/lsof" \
    PEEKABOO_SLEEP_BIN="${case_dir}/bin/sleep" \
    PEEKABOO_SYNC_BIN="${case_dir}/bin/sync" \
    PEEKABOO_LAUNCH_VERIFY_ATTEMPTS=2 \
    PEEKABOO_HEALTH_VERIFY_ATTEMPTS=2 \
    PEEKABOO_HEALTHCHECK_CLI="${case_dir}/bin/peekaboo-health" \
    PEEKABOO_APP_BRIDGE_SOCKET="${case_dir}/bridge.sock" \
    PEEKABOO_APP_SIGN_IDENTITY='Developer ID Application: Test (TESTTEAM)' \
    PEEKABOO_APP_EXPECTED_TEAM_ID='TESTTEAM' \
    PEEKABOO_APP_SIGN_REQUIREMENT='anchor apple generic and certificate leaf[subject.OU] = "TESTTEAM"' \
    PEEKABOO_APP_ENTITLEMENTS="${ROOT_DIR}/Apps/Mac/Peekaboo/Peekaboo.entitlements"
  )
  while (($# > 0)) && [[ "$1" != "--" ]]; do
    command_args+=("$1")
    shift
  done
  if (($# > 0)); then
    shift
  fi
  "${command_args[@]}" "${ROOT_DIR}/scripts/restart-peekaboo.sh" --deployment "$@" >"${case_dir}/stdout"
}

run_dev_restart() {
  local case_dir="$1"

  env \
    -u CONFIGURATION \
    -u DEBUG_CODE_SIGN_IDENTITY \
    -u DEBUG_DEVELOPMENT_TEAM \
    -u MAC_RELEASE_CODESIGN_IDENTITY \
    -u PEEKABOO_APP_EXPECTED_TEAM_ID \
    -u PEEKABOO_APP_SIGN_IDENTITY \
    -u SIGN_IDENTITY \
    HOME="${case_dir}/home" \
    PEEKABOO_DEV_RESTART_SCRIPT="${case_dir}/bin/dev-restart" \
    "${ROOT_DIR}/scripts/restart-peekaboo.sh" >"${case_dir}/stdout"
}

run_dev_workflow() {
  local case_dir="$1"
  local dist_dir="${2:-${case_dir}/dist}"

  mkdir -p "${case_dir}/home"
  env \
    -u CONFIGURATION \
    -u DEBUG_CODE_SIGN_IDENTITY \
    -u DEBUG_DEVELOPMENT_TEAM \
    -u MAC_RELEASE_CODESIGN_IDENTITY \
    -u PEEKABOO_APP_EXPECTED_TEAM_ID \
    -u PEEKABOO_APP_SIGN_IDENTITY \
    -u SIGN_IDENTITY \
    HOME="${case_dir}/home" \
    DERIVED_DATA_PATH="${case_dir}/DerivedData" \
    DIST_DIR="${dist_dir}" \
    PEEKABOO_DEV_BUILD_SCRIPT="${case_dir}/bin/dev-build-app" \
    PEEKABOO_DEV_DITTO_BIN="${case_dir}/bin/ditto" \
    PEEKABOO_DEV_OPEN_BIN="${case_dir}/bin/dev-open" \
    PEEKABOO_DEV_PGREP_BIN="${case_dir}/bin/pgrep" \
    PEEKABOO_DEV_PKILL_BIN="${case_dir}/bin/dev-pkill" \
    PEEKABOO_DEV_RM_BIN="/bin/rm" \
    PEEKABOO_DEV_SLEEP_BIN="${case_dir}/bin/sleep" \
    "${ROOT_DIR}/scripts/restart-peekaboo.sh" >"${case_dir}/stdout"
}

test_fixture_helpers() {
  local probe_dir="${TEST_DIR}/fixture-helpers"
  local probe exit_code expected_exit

  mkdir -p "${probe_dir}/scripts" "${probe_dir}/home" "${probe_dir}/tmp"
  cat >"${probe_dir}/scripts/restart-peekaboo.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\0' "${FORWARD_VALUE-unset}" "${FORWARD_EMPTY-unset}" "$@"
exit "${FORWARD_EXIT:-0}"
EOF
  chmod +x "${probe_dir}/scripts/restart-peekaboo.sh"
  {
    printf 'set -euo pipefail\n'
    declare -f cleanup run_restart fail
    cat <<'EOF'
ROOT_DIR="$1"
TEST_DIR="${ROOT_DIR}/work"
LOCK_HOLDER=""
FIXTURE_COMPLETE=0
trap cleanup EXIT
trap 'exit 143' TERM
mkdir -p "${TEST_DIR}/case with spaces"
case_dir="${TEST_DIR}/case with spaces"
case "$2" in
  arguments)
    for env_count in 0 1 2; do
      for cli_count in 0 1 4; do
        set -- "${case_dir}"
        value=unset
        empty=unset
        if ((env_count >= 1)); then
          value='two words'
          set -- "$@" "FORWARD_VALUE=${value}"
        fi
        if ((env_count == 2)); then
          empty=''
          set -- "$@" 'FORWARD_EMPTY='
        fi
        printf '%s\0' "${value}" "${empty}" --deployment >"${TEST_DIR}/expected"
        case "${cli_count}" in
          1)
            set -- "$@" -- ''
            printf '%s\0' '' >>"${TEST_DIR}/expected"
            ;;
          4)
            set -- "$@" -- -- 'two words' '' 'VALUE=literal'
            printf '%s\0' -- 'two words' '' 'VALUE=literal' >>"${TEST_DIR}/expected"
            ;;
        esac
        run_restart "$@"
        cmp "${TEST_DIR}/expected" "${case_dir}/stdout" || fail 'argument forwarding changed bytes'
      done
    done
    run_restart "${case_dir}" --
    printf '%s\0' unset unset --deployment >"${TEST_DIR}/expected"
    cmp "${TEST_DIR}/expected" "${case_dir}/stdout" || fail 'empty delimiter changed argv'
    run_restart "${case_dir}" FORWARD_VALUE=first FORWARD_VALUE= -- ''
    printf '%s\0' '' unset --deployment '' >"${TEST_DIR}/expected"
    cmp "${TEST_DIR}/expected" "${case_dir}/stdout" || fail 'empty override changed argv'
    ;;
  incomplete) exit 0 ;;
  nounset)
    abort_fixture() { printf '%s\n' "${UNSET_FIXTURE_VALUE}"; }
    if abort_fixture; then fail 'nounset unexpectedly continued'; fi
    fail 'nounset unexpectedly returned'
    ;;
  setup-failure)
    setup_fixture() { (exit 23); printf 'setup incorrectly continued\n'; }
    setup_fixture
    ;;
  restart-failure) run_restart "${case_dir}" FORWARD_EXIT=37 ;;
  expected-refusal)
    if run_restart "${case_dir}" FORWARD_EXIT=37; then
      fail 'expected child refusal'
    else
      [[ "$?" -eq 37 ]] || fail 'child refusal status changed'
    fi
    ;;
  assertion-failure) fail 'intentional assertion' ;;
  completed-failure) FIXTURE_COMPLETE=1; exit 41 ;;
  cleanup-failure) rm() { return 73; } ;;
  cleanup-failure-with-status) rm() { return 73; }; exit 37 ;;
  term) kill -TERM "$$" ;;
  *) fail 'unknown helper probe' ;;
esac
FIXTURE_COMPLETE=1
EOF
  } >"${probe_dir}/probe.sh"

  for probe in arguments incomplete nounset setup-failure restart-failure expected-refusal \
    assertion-failure completed-failure cleanup-failure cleanup-failure-with-status term; do
    case "${probe}" in
      arguments|expected-refusal) expected_exit=0 ;;
      setup-failure) expected_exit=23 ;;
      restart-failure|cleanup-failure-with-status) expected_exit=37 ;;
      completed-failure) expected_exit=41 ;;
      term) expected_exit=143 ;;
      *) expected_exit=1 ;;
    esac
    exit_code=0
    # An external shell keeps errexit active inside the probe despite this expected-status check.
    env -i HOME="${probe_dir}/home" TMPDIR="${probe_dir}/tmp" PATH="${PATH}" \
      "${BASH}" "${probe_dir}/probe.sh" "${probe_dir}" "${probe}" \
      >"${probe_dir}/${probe}.stdout" 2>"${probe_dir}/${probe}.stderr" || exit_code=$?
    [[ "${exit_code}" -eq "${expected_exit}" ]] || \
      fail "${probe} exited ${exit_code}, expected ${expected_exit}"
    if ((expected_exit == 0)); then
      assert_text "${probe_dir}/${probe}.stdout" 'test-restart-peekaboo: ok'
      [[ ! -s "${probe_dir}/${probe}.stderr" ]] || fail "${probe} printed unexpected diagnostics"
    else
      if grep -Fq 'test-restart-peekaboo: ok' "${probe_dir}/${probe}.stdout"; then
        fail "${probe} falsely reported completion"
      fi
    fi
    if [[ "${probe}" == cleanup-failure* ]]; then
      [[ -d "${probe_dir}/work" ]] || fail 'cleanup failure was not exercised'
      rm -rf "${probe_dir}/work"
    fi
    [[ ! -e "${probe_dir}/work" ]] || fail "${probe} did not clean up"
  done
}

test_fixture_helpers

mkdir -p "${TEMPLATE_BIN}" "${TEMPLATE_SOURCE}/Apps"
printf 'import Foundation\n' >"${TEMPLATE_SOURCE}/Apps/Good.swift"
/usr/bin/git -C "${TEMPLATE_SOURCE}" init -q
/usr/bin/git -C "${TEMPLATE_SOURCE}" add Apps/Good.swift

cat >"${TEMPLATE_BIN}/build-app" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
[[ "${PEEKABOO_BUILD_UNSIGNED:-}" == "1" ]] || exit 81
printf '%s\n' 'build' >>"${state_dir}/events"
printf '%s\n' 'build-unsigned' >>"${state_dir}/events"
mkdir -p "${bundle}/Contents/MacOS"
printf '%s\n' 'new' >"${bundle}/build-id"
printf '%s\n' '2222222222222222222222222222222222222222' >"${bundle}/.cdhash"
printf 'configuration:%s\n' "${CONFIGURATION}" >>"${state_dir}/events"
if [[ -f "${state_dir}/adhoc-build" ]]; then
  printf '%s\n' 'adhoc' >"${bundle}/.team-id"
else
  printf '%s\n' 'TESTTEAM' >"${bundle}/.team-id"
  [[ -f "${state_dir}/untrusted-anchor-build" ]] || touch "${bundle}/.trusted-anchor"
fi
if [[ -f "${state_dir}/apple-development-build" ]]; then
  printf '%s\n' 'apple-development' >"${bundle}/.requirement"
elif [[ -f "${state_dir}/other-developer-id-build" ]]; then
  printf '%s\n' 'other-developer-id' >"${bundle}/.requirement"
else
  printf '%s\n' 'developer-id' >"${bundle}/.requirement"
fi
if [[ -f "${state_dir}/different-build-identifier" ]]; then
  printf '%s\n' 'boo.peekaboo.mac.debug' >"${bundle}/.bundle-id"
elif [[ "${CONFIGURATION}" == "Debug" ]]; then
  printf '%s\n' 'boo.peekaboo.mac.debug' >"${bundle}/.bundle-id"
else
  printf '%s\n' 'boo.peekaboo.mac' >"${bundle}/.bundle-id"
fi
/usr/bin/plutil -create xml1 "${bundle}/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string Peekaboo "${bundle}/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleShortVersionString -string 4.0.1 "${bundle}/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleVersion -string 4000199 "${bundle}/Contents/Info.plist"
if [[ -f "${state_dir}/apple-events-description" ]]; then
  /usr/bin/plutil -insert NSAppleEventsUsageDescription -string 'Forbidden' "${bundle}/Contents/Info.plist"
fi
if [[ -f "${state_dir}/nested-apple-events-description" ]]; then
  nested_plist="${bundle}/Contents/Library/LoginItems/Helper.app/Contents/Info.plist"
  mkdir -p "$(dirname "${nested_plist}")"
  /usr/bin/plutil -create xml1 "${nested_plist}"
  /usr/bin/plutil -insert NSAppleEventsUsageDescription -string 'Forbidden' "${nested_plist}"
fi
[[ ! -f "${state_dir}/apple-events-entitlement" ]] || touch "${bundle}/.apple-events-entitlement"
[[ ! -f "${state_dir}/nsapplescript-import" ]] || touch "${bundle}/.nsapplescript-import"
[[ ! -f "${state_dir}/osa-api-import" ]] || touch "${bundle}/.osa-api-import"
[[ ! -f "${state_dir}/ae-create-desc-import" ]] || touch "${bundle}/.ae-create-desc-import"
[[ ! -f "${state_dir}/ae-create-apple-event-import" ]] || touch "${bundle}/.ae-create-apple-event-import"
[[ ! -f "${state_dir}/ae-send-message-import" ]] || touch "${bundle}/.ae-send-message-import"
[[ ! -f "${state_dir}/ae-determine-permission-import" ]] || touch "${bundle}/.ae-determine-permission-import"
[[ ! -f "${state_dir}/ae-dispose-desc-import" ]] || touch "${bundle}/.ae-dispose-desc-import"
[[ ! -f "${state_dir}/nm-inspection-failure" ]] || touch "${bundle}/.nm-inspection-failure"
[[ ! -f "${state_dir}/strings-inspection-failure" ]] || touch "${bundle}/.strings-inspection-failure"
[[ ! -f "${state_dir}/apple-events-string" ]] || touch "${bundle}/.apple-events-string"
[[ ! -f "${state_dir}/dynamic-applescript-string" ]] || touch "${bundle}/.dynamic-applescript-string"
if [[ -f "${state_dir}/compiled-script-resource" ]]; then
  mkdir -p "${bundle}/Contents/Resources"
  touch "${bundle}/Contents/Resources/Action.scpt"
fi
if [[ -f "${state_dir}/text-osascript-resource" ]]; then
  mkdir -p "${bundle}/Contents/Resources"
  printf '%s\n' '/usr/bin/osascript payload.applescript' >"${bundle}/Contents/Resources/Run.txt"
fi
if [[ -f "${state_dir}/executable-script-resource" ]]; then
  mkdir -p "${bundle}/Contents/Resources"
  printf '%s\n' '#!/usr/bin/env python3' 'NSAppleScript = "forbidden"' \
    >"${bundle}/Contents/Resources/Run.py"
  chmod +x "${bundle}/Contents/Resources/Run.py"
fi
if [[ -f "${state_dir}/raw-applescript-text" ]]; then
  mkdir -p "${bundle}/Contents/Resources"
  printf '%s\n' 'tell application "System Events" to keystroke "x"' \
    >"${bundle}/Contents/Resources/Action.txt"
fi
if [[ -f "${state_dir}/raw-applescript-display" ]]; then
  mkdir -p "${bundle}/Contents/Resources"
  printf '%s\n' 'display dialog "x"' >"${bundle}/Contents/Resources/Prompt.payload"
fi
if [[ -f "${state_dir}/prefixed-applescript-command" ]]; then
  mkdir -p "${bundle}/Contents/Resources"
  printf '%s\n' 'set result to (display dialog "x")' \
    >"${bundle}/Contents/Resources/Assigned.payload"
  printf '%s\n' '(* leading comment *) display alert "x"' \
    >"${bundle}/Contents/Resources/Commented.payload"
fi
if [[ -f "${state_dir}/mode-0740-resource" ]]; then
  mkdir -p "${bundle}/Contents/Resources"
  printf '%s\n' 'inert fixture' >"${bundle}/Contents/Resources/Mode.dat"
  chmod 0740 "${bundle}/Contents/Resources/Mode.dat"
fi
if [[ -f "${state_dir}/nested-wrong-signer" ]]; then
  mkdir -p "${bundle}/Contents/Frameworks"
  printf '%s\n' 'nested Mach-O fixture' >"${bundle}/Contents/Frameworks/Bad.dylib"
  chmod 644 "${bundle}/Contents/Frameworks/Bad.dylib"
fi
printf '#!/usr/bin/env bash\n' >"${bundle}/Contents/MacOS/Peekaboo"
chmod +x "${bundle}/Contents/MacOS/Peekaboo"
EOF

cat >"${TEMPLATE_BIN}/sign-release-app" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
expected_bundle="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION:-Release}/${APP_NAME:-Peekaboo}.app"
[[ "$#" -eq 8 ]] || exit 82
[[ "$1" == '--app' && "$2" == "${expected_bundle}" ]] || exit 83
[[ "$3" == '--entitlements' && "$4" == "${PEEKABOO_APP_ENTITLEMENTS}" ]] || exit 84
[[ "$5" == '--sign-identity' && "$6" == "${PEEKABOO_APP_SIGN_IDENTITY}" ]] || exit 85
[[ "$7" == '--timestamp-url' && "$8" == 'http://timestamp.apple.com/ts01' ]] || exit 86
if [[ -f "${state_dir}/fail-manual-sign" ]]; then
  printf '%s\n' 'sign-failed' >>"${state_dir}/events"
  exit 87
fi
printf '%s\n' 'sign' >>"${state_dir}/events"
EOF

cat >"${TEMPLATE_BIN}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${!#}"

if [[ "${bundle}" == */bin/peekaboo-health ]]; then
  if [[ "${1:-}" == "-dv" ]]; then
    if [[ -f "${state_dir}/untrusted-health-cli" ]]; then
      authority='Developer ID Application: Other (OTHERTEAM)'
      team_id='OTHERTEAM'
    else
      authority="${PEEKABOO_APP_SIGN_IDENTITY:-Developer ID Application: Test (TESTTEAM)}"
      team_id="${PEEKABOO_APP_EXPECTED_TEAM_ID:-TESTTEAM}"
    fi
    printf '%s\n' 'Identifier=boo.peekaboo.peekaboo' "Authority=${authority}" \
      "TeamIdentifier=${team_id}" 'CDHash=5555555555555555555555555555555555555555' >&2
    exit 0
  fi
  [[ "${1:-}" == "--verify" ]] || exit 2
  [[ ! -f "${state_dir}/untrusted-health-cli" ]] || exit 1
  exit 0
fi

if [[ "${bundle}" == */Contents/Frameworks/Bad.dylib ]]; then
  if [[ "${1:-}" == "-dv" ]]; then
    printf '%s\n' 'Identifier=bad.helper' 'Authority=Developer ID Application: Other (OTHERTEAM)' \
      'TeamIdentifier=OTHERTEAM' 'CDHash=4444444444444444444444444444444444444444' >&2
    exit 0
  fi
  [[ "${1:-}" == "--verify" ]] || exit 2
  [[ "$*" != *' -R='* ]] || exit 1
  exit 0
fi

if [[ "${1:-}" == "-d" && "${2:-}" == "--entitlements" ]]; then
  entitlement_root="${bundle%%/Contents/*}"
  [[ -d "${entitlement_root}" ]] || entitlement_root="${bundle}"
  if [[ -f "${entitlement_root}/.apple-events-entitlement" ]]; then
    printf '%s\n' '<key>com.apple.security.automation.apple-events</key>'
  fi
  exit 0
fi

if [[ "${1:-}" == "-d" && "${2:-}" == "-r-" ]]; then
  [[ -f "${bundle}/.requirement" ]] || exit 1
  printf 'designated => %s\n' "$(<"${bundle}/.requirement")" >&2
  exit 0
fi

[[ -d "${bundle}" && -f "${bundle}/.team-id" && -f "${bundle}/.bundle-id" && \
  -f "${bundle}/.requirement" ]] || exit 1
team_id="$(<"${bundle}/.team-id")"
bundle_id="$(<"${bundle}/.bundle-id")"
requirement="$(<"${bundle}/.requirement")"

if [[ "${1:-}" == "--force" ]]; then
  expected_identity="${PEEKABOO_APP_SIGN_IDENTITY:-}"
  expected_team="${PEEKABOO_APP_EXPECTED_TEAM_ID:-}"
  [[ -n "${expected_identity}" && -n "${expected_team}" ]] || exit 3
  if [[ "$*" == *' --deep '* ]]; then
    [[ "$*" == "--force --deep --options runtime --timestamp=http://timestamp.apple.com/ts01 --sign ${expected_identity} ${bundle}" ]] || exit 4
  else
    expected_entitlements="${PEEKABOO_APP_ENTITLEMENTS:-}"
    [[ -n "${expected_entitlements}" ]] || exit 5
    [[ "$*" == "--force --options runtime --timestamp=http://timestamp.apple.com/ts01 --entitlements ${expected_entitlements} --sign ${expected_identity} ${bundle}" ]] || exit 6
  fi
  printf '%s\n' 'TESTTEAM' >"${bundle}/.team-id"
  printf '%s\n' 'developer-id' >"${bundle}/.requirement"
  printf '%s\n' '2222222222222222222222222222222222222222' >"${bundle}/.cdhash"
  touch "${bundle}/.trusted-anchor"
  printf '%s\n' 'sign' >>"${state_dir}/events"
  exit 0
fi

if [[ "${1:-}" == "-dv" ]]; then
  if [[ "${team_id}" == "adhoc" ]]; then
    printf '%s\n' "Identifier=${bundle_id}" 'Signature=adhoc' 'TeamIdentifier=not set' >&2
  else
    if [[ "${requirement}" == "apple-development" ]]; then
      authority='Apple Development: Test'
    elif [[ "${requirement}" == "other-developer-id" ]]; then
      authority='Developer ID Application: Other (TESTTEAM)'
    else
      authority="${PEEKABOO_APP_SIGN_IDENTITY:-Developer ID Application: Test (TESTTEAM)}"
    fi
    printf '%s\n' "Identifier=${bundle_id}" "Authority=${authority}" \
      "TeamIdentifier=${team_id}" "CDHash=$(<"${bundle}/.cdhash")" >&2
  fi
  exit 0
fi

[[ "${1:-}" == "--verify" ]] || exit 2
if [[ "$*" == *' -R='* ]]; then
  [[ -f "${bundle}/.trusted-anchor" ]] || exit 1
  [[ "${team_id}" == "${PEEKABOO_APP_EXPECTED_TEAM_ID:-TESTTEAM}" ]] || exit 1
  [[ "${bundle_id}" == "${PEEKABOO_APP_EXPECTED_BUNDLE_ID:-${bundle_id}}" ]] || exit 1
  [[ "$*" == *'anchor apple generic'* ]] || exit 1
fi
exit 0
EOF

cat >"${TEMPLATE_BIN}/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-b" && "${2:-}" == */Contents/MacOS/Peekaboo ]]; then
  printf '%s\n' 'Mach-O 64-bit executable arm64'
elif [[ "${1:-}" == "-b" && "${2:-}" == */Contents/Frameworks/Bad.dylib ]]; then
  printf '%s\n' 'Mach-O 64-bit dynamically linked shared library arm64'
elif [[ "${1:-}" == "-b" && "${2:-}" == */Contents/Resources/Run.txt ]]; then
  printf '%s\n' 'ASCII text'
elif [[ "${1:-}" == "-b" && "${2:-}" == */Contents/Resources/Run.py ]]; then
  printf '%s\n' 'Python script text executable'
elif [[ "${1:-}" == "-b" && "${2:-}" == */Contents/Resources/*.txt ]]; then
  printf '%s\n' 'ASCII text'
elif [[ "${1:-}" == "-b" && "${2:-}" == */Contents/Resources/Mode.dat ]]; then
  printf '%s\n' 'ASCII text'
elif [[ "${1:-}" == "-b" && "${2:-}" == */Contents/Resources/Prompt.payload ]]; then
  printf '%s\n' 'ASCII text'
elif [[ "${1:-}" == "-b" && "${2:-}" == */Contents/Resources/*.payload ]]; then
  printf '%s\n' 'ASCII text'
else
  printf '%s\n' 'data'
fi
EOF

cat >"${TEMPLATE_BIN}/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
/usr/bin/ditto "$@"
candidate="${!#}"
if [[ -f "${state_dir}/mutate-staged-native" ]]; then
  mkdir -p "${candidate}/Contents/Resources"
  printf '%s\n' 'tell application "System Events" to keystroke "x"' \
    >"${candidate}/Contents/Resources/Injected.txt"
fi
EOF

cat >"${TEMPLATE_BIN}/nm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
candidate="${!#}"
bundle="${candidate%%/Contents/*}"
if [[ -f "${bundle}/.nm-inspection-failure" ]]; then
  exit 86
elif [[ -f "${bundle}/.nsapplescript-import" ]]; then
  printf '%s\n' '                 U _OBJC_CLASS_$_NSAppleScript'
elif [[ -f "${bundle}/.osa-api-import" ]]; then
  printf '%s\n' '                 U _OSADoScript'
elif [[ -f "${bundle}/.ae-create-desc-import" ]]; then
  printf '%s\n' '                 U _AECreateDesc'
elif [[ -f "${bundle}/.ae-create-apple-event-import" ]]; then
  printf '%s\n' '                 U _AECreateAppleEvent'
elif [[ -f "${bundle}/.ae-send-message-import" ]]; then
  printf '%s\n' '                 U _AESendMessage'
elif [[ -f "${bundle}/.ae-determine-permission-import" ]]; then
  printf '%s\n' '                 U _AEDeterminePermissionToAutomateTarget'
elif [[ -f "${bundle}/.ae-dispose-desc-import" ]]; then
  printf '%s\n' '                 U _AEDisposeDesc'
fi
EOF

cat >"${TEMPLATE_BIN}/strings" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
candidate="${!#}"
bundle="${candidate%%/Contents/*}"
if [[ -f "${bundle}/.strings-inspection-failure" ]]; then
  printf '%s\n' 'harmless output before inspection failure'
  exit 87
elif [[ -f "${bundle}/.apple-events-string" ]]; then
  printf '%s\n' '<key>NSAppleEventsUsageDescription</key>'
elif [[ -f "${bundle}/.dynamic-applescript-string" ]]; then
  printf '%s\n' '/usr/bin/osascript'
else
  printf '%s\n' 'NSAppleEventsUsageDescription may appear in harmless prose'
fi
EOF

cat >"${TEMPLATE_BIN}/security" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$*" == "find-identity -v -p codesigning" ]] || exit 2
if [[ -f "${state_dir}/identity-available" ]]; then
  printf '%s\n' '  1) AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA "Developer ID Application: Test (TESTTEAM)"'
fi
EOF

cat >"${TEMPLATE_BIN}/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
count=0
[[ ! -f "${state_dir}/move-count" ]] || count="$(<"${state_dir}/move-count")"
count=$((count + 1))
printf '%s\n' "${count}" >"${state_dir}/move-count"
printf 'move:%s\n' "${count}" >>"${state_dir}/events"
if [[ -f "${state_dir}/fail-second-move" && "${count}" -eq 2 ]]; then
  exit 70
fi
/bin/mv "$@"
target="${!#}"
if [[ -f "${state_dir}/fail-after-restore-move" && "${1:-}" == */previous.app && \
  "${target}" == */Peekaboo.app ]]; then
  exit 70
fi
if [[ -f "${state_dir}/mutate-final-team" && "${count}" -eq 2 ]]; then
  printf '%s\n' 'OTHERTEAM' >"${target}/.team-id"
fi
if [[ -f "${state_dir}/fail-after-first-move" && "${count}" -eq 1 ]]; then
  exit 70
fi
if [[ -f "${state_dir}/fail-after-second-move" && "${count}" -eq 2 ]]; then
  exit 70
fi
EOF

cat >"${TEMPLATE_BIN}/open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${1:-}" == "-gj" && "${3:-}" == "--args" && \
  "${4:-}" == "--background-bridge-host" && "$#" -eq 4 ]] || exit 72
bundle="$2"
build_id="$(<"${bundle}/build-id")"
printf '%s\n' "${1}" >>"${state_dir}/open-flags"
printf '%s|%s\n' "${bundle}" "${build_id}" >>"${state_dir}/open-log"
printf 'open:%s\n' "${build_id}" >>"${state_dir}/events"
if [[ -f "${state_dir}/fail-new-open" && "${build_id}" == "new" ]]; then
  exit 71
fi
printf '%s\n' "${bundle}" >"${state_dir}/running-path"
if [[ -f "${state_dir}/transient-new-process" && "${build_id}" == "new" ]]; then
  printf '%s\n' '0' >"${state_dir}/pgrep-count"
fi
if [[ -f "${state_dir}/fail-old-process" && "${build_id}" == "old" ]]; then
  rm -f "${state_dir}/running-path"
fi
EOF

cat >"${TEMPLATE_BIN}/peekaboo-health" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "${1:-}" == "app" ]]; then
  [[ "${2:-}" == "list" && "${3:-}" == "--include-hidden" && \
    "${4:-}" == "--include-background" && "${5:-}" == "--no-remote" && \
    "${6:-}" == "--json" && "$#" -eq 6 ]] || exit 72
  bundle_id='boo.peekaboo.mac'
  if [[ -f "${state_dir}/running-path" ]]; then
    bundle="$(<"${state_dir}/running-path")"
    bundle_id="$(<"${bundle}/.bundle-id")"
  fi
  query_count=0
  [[ ! -f "${state_dir}/identity-query-count" ]] || query_count="$(<"${state_dir}/identity-query-count")"
  query_count=$((query_count + 1))
  printf '%s\n' "${query_count}" >"${state_dir}/identity-query-count"
  if [[ -f "${state_dir}/empty-health-app-list" && "${query_count}" -eq 1 ]]; then
    printf '%s\n' '{"success":true,"data":{"count":0,"apps":[],"schema_capabilities":["processStartIdentityDecimal"]}}'
    exit 0
  fi
  process_start_identity=123456
  if [[ -f "${state_dir}/health-start-drift" && "${query_count}" -ge 3 ]]; then
    process_start_identity=654321
  fi
  [[ ! -f "${state_dir}/health-adjacent-large-start" ]] || process_start_identity=9007199254740993
  if [[ -f "${state_dir}/legacy-health-contract" ]]; then
    printf '{"success":true,"data":{"count":1,"apps":[{"name":"Peekaboo","bundle_id":"%s","pid":4242,"process_start_identity":%s,"is_active":false,"is_hidden":false}]}}\n' \
      "${bundle_id}" "${process_start_identity}"
  else
    printf '{"success":true,"data":{"count":1,"apps":[{"name":"Peekaboo","bundle_id":"%s","pid":4242,"process_start_identity":%s,"process_start_identity_decimal":"%s","is_active":false,"is_hidden":false}],"schema_capabilities":["processStartIdentityDecimal"]}}\n' \
      "${bundle_id}" "${process_start_identity}" "${process_start_identity}"
  fi
  exit 0
fi
[[ "${1:-}" == "bridge" && "${2:-}" == "status" && "${3:-}" == "--bridge-socket" && \
  "${4:-}" == "${state_dir}/bridge.sock" && "${5:-}" == "--json" && "$#" -eq 5 ]] || exit 72
bundle="$(<"${state_dir}/running-path")"
build_id="$(<"${bundle}/build-id")"
if [[ -f "${state_dir}/fail-health" && "${build_id}" == "new" ]]; then
  exit 71
fi
bundle_id="$(<"${bundle}/.bundle-id")"
code_hash="$(<"${bundle}/.cdhash")"
host_pid=4242
host_process_start_identity=123456
host_process_start_identity_decimal=123456
capabilities='["backgroundBridgeHost","hostGenerationIdentity","codeSignatureBuildIdentity"]'
[[ ! -f "${state_dir}/health-wrong-pid" ]] || host_pid=9999
[[ ! -f "${state_dir}/health-wrong-start" ]] || host_process_start_identity=999999
if [[ -f "${state_dir}/health-wrong-start" ]]; then
  host_process_start_identity_decimal=999999
fi
if [[ -f "${state_dir}/health-adjacent-large-start" ]]; then
  host_process_start_identity=9007199254740992
  host_process_start_identity_decimal=9007199254740992
fi
[[ ! -f "${state_dir}/health-wrong-hash" ]] || code_hash=0000000000000000000000000000000000000000
[[ ! -f "${state_dir}/health-missing-capability" ]] || capabilities='["hostGenerationIdentity","codeSignatureBuildIdentity"]'
short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "${bundle}/Contents/Info.plist")"
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
  "${bundle}/Contents/Info.plist")"
printf '{"success":true,"data":{"selected":{"source":"remote","socketPath":"%s","handshake":{"hostKind":"gui","hostIdentity":{"processIdentifier":%s,"processStartIdentity":%s,"processStartIdentityDecimal":"%s","bundleIdentifier":"%s","bundleShortVersion":"%s","bundleVersion":"%s","codeSignatureHash":"%s"},"hostCapabilities":%s}}}}\n' \
  "${state_dir}/bridge.sock" "${host_pid}" "${host_process_start_identity}" \
  "${host_process_start_identity_decimal}" "${bundle_id}" \
  "${short_version}" "${bundle_version}" "${code_hash}" "${capabilities}"
EOF

cat >"${TEMPLATE_BIN}/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "${state_dir}/running-path" ]] || exit 1
running_path="$(<"${state_dir}/running-path")"
if [[ -f "${state_dir}/pgrep-count" ]]; then
  count="$(<"${state_dir}/pgrep-count")"
  count=$((count + 1))
  printf '%s\n' "${count}" >"${state_dir}/pgrep-count"
  if ((count <= 2)); then
    exit 1
  fi
fi
case "${1:-}" in
  -f)
    executable="${running_path}/Contents/MacOS/Peekaboo"
    [[ "${executable}" =~ ${2:-nomatch} ]]
    ;;
  *)
    exit 2
    ;;
esac
printf '%s\n' '4242'
EOF

cat >"${TEMPLATE_BIN}/kill" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${1:-}" == "-TERM" && "${2:-}" == "4242" && "$#" -eq 2 ]] || exit 2
[[ ! -f "${state_dir}/refuse-stop" ]] || exit 70
if [[ -f "${state_dir}/refuse-new-stop" && -f "${state_dir}/running-path" ]]; then
  running_path="$(<"${state_dir}/running-path")"
  [[ "$(<"${running_path}/build-id")" != "new" ]] || exit 70
fi
printf '%s\n' 'stop' >>"${state_dir}/events"
rm -f "${state_dir}/running-path"
if [[ -f "${state_dir}/interrupt-during-stop" ]]; then
  /bin/kill -TERM "${PPID}"
fi
EOF

cat >"${TEMPLATE_BIN}/lsof" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${1:-}" == "-t" && "${2:-}" == "-a" && "${3:-}" == "-U" && \
  "${4:-}" == "--" && "${5:-}" == "${state_dir}/bridge.sock" && "$#" -eq 5 ]] || exit 72
[[ -f "${state_dir}/running-path" ]] || exit 1
bundle="$(<"${state_dir}/running-path")"
if [[ -f "${state_dir}/restored-bridge-never-ready" && "$(<"${bundle}/build-id")" == "old" ]]; then
  exit 1
fi
printf '%s\n' 4242
EOF

cat >"${TEMPLATE_BIN}/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"${TEMPLATE_BIN}/sync" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"${TEMPLATE_BIN}/dev-restart" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$#" -eq 0 ]] || exit 72
[[ "${CONFIGURATION:-Debug}" == "Debug" ]] || exit 73
[[ -z "${DEBUG_CODE_SIGN_IDENTITY+x}" ]] || exit 74
[[ -z "${DEBUG_DEVELOPMENT_TEAM+x}" ]] || exit 75
[[ -z "${MAC_RELEASE_CODESIGN_IDENTITY+x}" ]] || exit 76
[[ -z "${PEEKABOO_APP_EXPECTED_TEAM_ID+x}" ]] || exit 77
[[ -z "${PEEKABOO_APP_SIGN_IDENTITY+x}" ]] || exit 78
[[ -z "${SIGN_IDENTITY+x}" ]] || exit 79
printf '%s\n' 'dev-restart' >"${state_dir}/events"
EOF

cat >"${TEMPLATE_BIN}/dev-build-app" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ "${CONFIGURATION}" == "Debug" ]] || exit 72
[[ -z "${DEBUG_CODE_SIGN_IDENTITY+x}" ]] || exit 73
[[ -z "${DEBUG_DEVELOPMENT_TEAM+x}" ]] || exit 74
[[ -z "${MAC_RELEASE_CODESIGN_IDENTITY+x}" ]] || exit 75
[[ -z "${PEEKABOO_APP_EXPECTED_TEAM_ID+x}" ]] || exit 76
[[ -z "${PEEKABOO_APP_SIGN_IDENTITY+x}" ]] || exit 77
[[ -z "${SIGN_IDENTITY+x}" ]] || exit 78
bundle="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
mkdir -p "${bundle}/Contents/MacOS"
printf '%s\n' new >"${bundle}/build-id"
printf '#!/usr/bin/env bash\n' >"${bundle}/Contents/MacOS/Peekaboo"
chmod +x "${bundle}/Contents/MacOS/Peekaboo"
printf '%s\n' 'dev-build:Debug' >"${state_dir}/events"
EOF

cat >"${TEMPLATE_BIN}/dev-open" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ "$#" -eq 1 && -d "$1" ]] || exit 72
printf '%s\n' "$1" >"${state_dir}/running-path"
printf '%s\n' 'dev-open' >>"${state_dir}/events"
EOF

cat >"${TEMPLATE_BIN}/dev-pkill" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "${TEMPLATE_BIN}"/*

# Derived dependency/build sources are not shipped production source and must not poison policy checks.
mkdir -p "${TEMPLATE_SOURCE}/Apps/CLI/.build/checkouts/Dependency"
printf 'import AppKit\nlet script: NSAppleScript?\n' \
  >"${TEMPLATE_SOURCE}/Apps/CLI/.build/checkouts/Dependency/Generated.swift"

"${ROOT_DIR}/scripts/verify-native-only-app.sh" --source-root "${ROOT_DIR}"

help_output="$("${ROOT_DIR}/scripts/restart-peekaboo.sh" --help)"
[[ "${help_output}" == *'Usage: scripts/restart-peekaboo.sh'* ]] || fail '--help did not print usage'
[[ "${help_output}" == *'established Debug'* && "${help_output}" == *'--deployment'* ]] || \
  fail '--help did not distinguish contributor and deployment modes'
deployment_help_output="$("${ROOT_DIR}/scripts/restart-peekaboo.sh" --deployment --help)"
[[ "${deployment_help_output}" == *'Usage: scripts/restart-peekaboo.sh --deployment'* ]] || \
  fail 'deployment help did not print strict installer usage'
package_help_output="$(cd "${ROOT_DIR}" && pnpm --silent app:install-companion -- --help)"
[[ "${package_help_output}" == *'Usage: scripts/restart-peekaboo.sh --deployment'* ]] || \
  fail 'package installer did not forward options after the pnpm separator'
if "${ROOT_DIR}/scripts/restart-peekaboo.sh" --dry-run >/dev/null 2>&1; then
  fail 'unknown arguments must fail instead of starting a build'
fi

# Developer ID is a manual-signing identity. Passing it alongside Automatic signing makes Xcode
# reject the app and Swift-package resource targets before compilation.
build_signing_dir="${TEST_DIR}/build-signing"
mkdir -p "${build_signing_dir}/bin"
build_signing_source="${build_signing_dir}/source"
mkdir -p "${build_signing_source}/scripts" "${build_signing_source}/Apps/Peekaboo.xcworkspace"
: >"${build_signing_source}/Apps/Peekaboo.xcworkspace/contents.xcworkspacedata"
cp "${ROOT_DIR}/scripts/build-mac-debug.sh" "${build_signing_source}/scripts/build-mac-debug.sh"
cp "${ROOT_DIR}/scripts/source-provenance.sh" "${build_signing_source}/scripts/source-provenance.sh"
git -C "${build_signing_source}" init -q
git -C "${build_signing_source}" add scripts Apps
git -C "${build_signing_source}" \
  -c user.name=Peekaboo -c user.email=peekaboo@example.invalid \
  commit -q -m fixture
build_signing_commit="$(git -C "${build_signing_source}" rev-parse HEAD)"
cat >"${build_signing_dir}/bin/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
mkdir -p "${DERIVED_DATA_PATH}"
printf '%s\n' "$@" >"${PEEKABOO_TEST_XCODEBUILD_ARGS}"
EOF
chmod +x "${build_signing_dir}/bin/xcodebuild"
# Signing argv belongs to this fixture; workspace ownership has its own real-owner tests.
cat >"${build_signing_dir}/bin/python3" <<'EOF'
#!/bin/bash
set -euo pipefail
fixture_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
if [[ "$#" -lt 4 || "${1:-}" != "${fixture_dir}/source/scripts/setup-swift-workspace.py" ||
  "${2:-}" != run || "${3:-}" != -- || "${4:-}" != xcodebuild ]]; then
  printf 'test-restart-peekaboo: unexpected workspace invocation\n' >&2
  exit 64
fi
shift 4
exec "${fixture_dir}/bin/xcodebuild" "$@"
EOF
chmod +x "${build_signing_dir}/bin/python3"

if run_build_signing_case workspace-command-refusal env \
  DERIVED_DATA_PATH="${build_signing_dir}/DerivedData" \
  PEEKABOO_TEST_XCODEBUILD_ARGS="${build_signing_dir}/rejected-args" \
  "${build_signing_dir}/bin/python3" \
  "${build_signing_source}/scripts/setup-swift-workspace.py" run -- unexpected-command; then
  fail 'workspace fixture accepted an unexpected command'
else
  [[ "$?" -eq 64 ]] || fail 'workspace fixture did not return its invocation refusal'
fi
[[ ! -e "${build_signing_dir}/rejected-args" ]] || fail 'rejected workspace command reached fake xcodebuild'

run_build_signing_case developer-id env \
  PATH="${build_signing_dir}/bin:/usr/bin:/bin" \
  PEEKABOO_TEST_XCODEBUILD_ARGS="${build_signing_dir}/developer-id-args" \
  CONFIGURATION=Release \
  DERIVED_DATA_PATH="${build_signing_dir}/DerivedData" \
  DEBUG_CODE_SIGN_IDENTITY='Developer ID Application: Test (TESTTEAM)' \
  DEBUG_DEVELOPMENT_TEAM=TESTTEAM \
  "${build_signing_source}/scripts/build-mac-debug.sh"
grep -Fxq 'CODE_SIGN_STYLE=Manual' "${build_signing_dir}/developer-id-args" || \
  fail 'Developer ID build did not request manual signing'
grep -Fxq "PEEKABOO_SOURCE_COMMIT=${build_signing_commit}" \
  "${build_signing_dir}/developer-id-args" || \
  fail 'Clean debug app build did not stamp its exact source commit'
if grep -Fxq 'CODE_SIGN_STYLE=Automatic' "${build_signing_dir}/developer-id-args"; then
  fail 'Developer ID build still requested automatic signing'
fi

run_build_signing_case unsigned env \
  PATH="${build_signing_dir}/bin:/usr/bin:/bin" \
  PEEKABOO_TEST_XCODEBUILD_ARGS="${build_signing_dir}/unsigned-args" \
  PEEKABOO_BUILD_UNSIGNED=1 \
  CONFIGURATION=Release \
  DERIVED_DATA_PATH="${build_signing_dir}/DerivedData" \
  DEBUG_CODE_SIGN_IDENTITY='Developer ID Application: Test (TESTTEAM)' \
  DEBUG_DEVELOPMENT_TEAM=TESTTEAM \
  "${build_signing_source}/scripts/build-mac-debug.sh"
grep -Fxq 'CODE_SIGNING_ALLOWED=NO' "${build_signing_dir}/unsigned-args" || \
  fail 'explicit unsigned build did not disable Xcode signing'
grep -Fxq 'CODE_SIGNING_REQUIRED=NO' "${build_signing_dir}/unsigned-args" || \
  fail 'explicit unsigned build did not disable required Xcode signing'
if grep -Eq '^(CODE_SIGN_STYLE|DEVELOPMENT_TEAM)=' "${build_signing_dir}/unsigned-args"; then
  fail 'explicit unsigned build still requested Xcode identity or provisioning'
fi

run_build_signing_case development env \
  PATH="${build_signing_dir}/bin:/usr/bin:/bin" \
  PEEKABOO_TEST_XCODEBUILD_ARGS="${build_signing_dir}/development-args" \
  CONFIGURATION=Debug \
  DERIVED_DATA_PATH="${build_signing_dir}/DerivedData" \
  DEBUG_CODE_SIGN_IDENTITY='Apple Development' \
  DEBUG_DEVELOPMENT_TEAM=TESTTEAM \
  "${build_signing_source}/scripts/build-mac-debug.sh"
grep -Fxq 'CODE_SIGN_STYLE=Automatic' "${build_signing_dir}/development-args" || \
  fail 'Apple Development build did not retain automatic signing'

touch "${build_signing_source}/untracked-build-input"
run_build_signing_case dirty-source env \
  PATH="${build_signing_dir}/bin:/usr/bin:/bin" \
  PEEKABOO_TEST_XCODEBUILD_ARGS="${build_signing_dir}/dirty-args" \
  CONFIGURATION=Debug \
  DERIVED_DATA_PATH="${build_signing_dir}/DerivedData" \
  DEBUG_CODE_SIGN_IDENTITY='Apple Development' \
  DEBUG_DEVELOPMENT_TEAM=TESTTEAM \
  "${build_signing_source}/scripts/build-mac-debug.sh"
grep -Fxq 'PEEKABOO_SOURCE_COMMIT=unknown' "${build_signing_dir}/dirty-args" || \
  fail 'Dirty debug app build did not remain explicitly unstamped'

rm -f "${build_signing_dir}/strict-dirty-args"
if run_build_signing_case strict-dirty-source env \
  PATH="${build_signing_dir}/bin:/usr/bin:/bin" \
  PEEKABOO_TEST_XCODEBUILD_ARGS="${build_signing_dir}/strict-dirty-args" \
  PEEKABOO_REQUIRE_SOURCE_PROVENANCE=1 \
  CONFIGURATION=Debug \
  DERIVED_DATA_PATH="${build_signing_dir}/DerivedData" \
  DEBUG_CODE_SIGN_IDENTITY='Apple Development' \
  DEBUG_DEVELOPMENT_TEAM=TESTTEAM \
  "${build_signing_source}/scripts/build-mac-debug.sh"; then
  fail 'Strict dirty debug app build unexpectedly succeeded'
fi
[[ ! -e "${build_signing_dir}/strict-dirty-args" ]] || \
  fail 'Strict dirty debug app build reached xcodebuild before refusing'

# The public package default delegates to the contributor Debug path without injecting any
# Foundation or organization-owned signing identity.
dev_restart_dir="$(new_case dev-restart-default)"
run_dev_restart "${dev_restart_dir}"
assert_text "${dev_restart_dir}/events" dev-restart
if grep -Eq \
  'PEEKABOO_APP_SIGN_IDENTITY|PEEKABOO_APP_EXPECTED_TEAM_ID|MAC_RELEASE_CODESIGN_IDENTITY|Developer ID Application:' \
  "${ROOT_DIR}/scripts/restart-peekaboo-dev.sh"; then
  fail 'contributor restart script injects or requires an organization signing identity'
fi

# The real contributor path builds Debug, copies that new result to its dedicated dist target, and
# relaunches the copied build even when the strict deployment installer is not available.
dev_workflow_dir="$(new_case dev-workflow-default)"
run_dev_workflow "${dev_workflow_dir}"
assert_text "${dev_workflow_dir}/dist/Peekaboo.app/build-id" new
assert_text "${dev_workflow_dir}/running-path" "${dev_workflow_dir}/dist/Peekaboo.app"
grep -Fxq 'dev-build:Debug' "${dev_workflow_dir}/events" || fail 'contributor path did not build Debug'
grep -Fxq 'dev-open' "${dev_workflow_dir}/events" || fail 'contributor path did not relaunch the copied build'

# Broad or unrelated destinations fail before build/kill/delete; the sentinel must survive.
dev_unsafe_dir="$(new_case dev-unsafe-target-refusal)"
mkdir -p "${dev_unsafe_dir}/home"
printf '%s\n' keep >"${dev_unsafe_dir}/home/sentinel"
if run_dev_workflow "${dev_unsafe_dir}" "${dev_unsafe_dir}/home"; then
  fail 'expected broad contributor target refusal'
fi
assert_text "${dev_unsafe_dir}/home/sentinel" keep
[[ ! -f "${dev_unsafe_dir}/events" ]] || fail 'unsafe contributor target started build or kill work'
invalid_target_dir="$(new_case invalid-target)"
mkdir -p "${invalid_target_dir}/Explicit"
if run_restart "${invalid_target_dir}" PEEKABOO_APP_BUNDLE="${invalid_target_dir}/Explicit/Other.app" \
  2>"${invalid_target_dir}/stderr"; then
  fail 'an explicit target with another app name must be rejected'
else
  [[ "$?" -eq 1 ]] || fail 'invalid target did not return the intended refusal status'
fi
assert_text "${invalid_target_dir}/stderr" \
  "ERROR: Install target must end in Peekaboo.app: ${invalid_target_dir}/Explicit/Other.app"
[[ ! -f "${invalid_target_dir}/events" ]] || fail 'invalid target rejection started a build'

# The CLI supplying readiness evidence must itself carry the expected signed CLI identity.
untrusted_health_dir="$(new_case untrusted-health-cli-refusal)"
mkdir -p "${untrusted_health_dir}/Applications"
touch "${untrusted_health_dir}/untrusted-health-cli"
if run_restart "${untrusted_health_dir}"; then
  fail 'expected untrusted healthcheck CLI refusal'
fi
[[ ! -f "${untrusted_health_dir}/events" ]] || fail 'untrusted healthcheck CLI started a build'

# A previous-release signed CLI is rejected before the app is built, stopped, or renamed.
legacy_health_dir="$(new_case legacy-health-cli-refusal)"
mkdir -p "${legacy_health_dir}/Applications"
touch "${legacy_health_dir}/legacy-health-contract"
if run_restart "${legacy_health_dir}"; then
  fail 'expected previous-release healthcheck CLI refusal'
fi
[[ ! -f "${legacy_health_dir}/events" ]] || fail 'previous-release healthcheck CLI started a build'

# The explicit schema capability remains valid when the preflight inventory is legitimately empty.
empty_health_dir="$(new_case empty-health-app-list)"
empty_health_target="${empty_health_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${empty_health_target}")"
touch "${empty_health_dir}/empty-health-app-list"
run_restart "${empty_health_dir}" PEEKABOO_APP_BUNDLE="${empty_health_target}"
assert_text "${empty_health_target}/build-id" new

# A live canonical-target lock refuses a concurrent installer before build or mutation.
locked_dir="$(new_case live-lock-refusal)"
locked_target="${locked_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${locked_target}")"
make_bundle "${locked_target}" old
write_lock_owner "$(dirname "${locked_target}")" ignored ignored
lock_marker="${locked_dir}/lock-held"
/usr/bin/lockf -k "$(dirname "${locked_target}")/.Peekaboo.install-lock/lock" \
  /bin/sh -c "touch '${lock_marker}'; sleep 60" &
lock_holder=$!
LOCK_HOLDER="${lock_holder}"
for _ in {1..50}; do
  [[ -f "${lock_marker}" ]] && break
  /bin/sleep 0.02
done
[[ -f "${lock_marker}" ]] || fail 'test lock holder did not acquire the installer lock'
if run_restart "${locked_dir}"; then
  fail 'expected a live installer lock to refuse concurrent mutation'
fi
if run_restart "${locked_dir}" TZ=UTC LC_ALL=C; then
  fail 'expected live installer lock refusal to be independent of timezone and locale'
fi
assert_text "${locked_target}/build-id" old
[[ ! -f "${locked_dir}/events" ]] || fail 'live lock refusal started a build'
kill "${lock_holder}" 2>/dev/null || true
wait "${lock_holder}" 2>/dev/null || true
LOCK_HOLDER=""

# A dead lock is recoverable, and lock ownership is released after success.
dead_lock_dir="$(new_case dead-lock-recovery)"
dead_lock_target="${dead_lock_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${dead_lock_target}")"
make_bundle "${dead_lock_target}" old
write_lock_owner "$(dirname "${dead_lock_target}")" ignored ignored
run_restart "${dead_lock_dir}"
assert_text "${dead_lock_target}/build-id" new
[[ -f "$(dirname "${dead_lock_target}")/.Peekaboo.install-lock/lock" ]] || \
  fail 'successful unlocked-lock reuse lost its persistent lock file'

# A staged crash before the first rename recognizes the unchanged running target and cleans safely.
staged_crash_dir="$(new_case crash-before-backup-rename)"
staged_crash_parent="${staged_crash_dir}/Applications"
staged_crash_target="${staged_crash_parent}/Peekaboo.app"
staged_crash_root="${staged_crash_parent}/.Peekaboo.install.CRASH00"
mkdir -p "${staged_crash_root}"
make_bundle "${staged_crash_target}" old
make_bundle "${staged_crash_root}/candidate.app" interrupted-new
printf '%s\n' "${staged_crash_target}" >"${staged_crash_dir}/running-path"
write_journal "${staged_crash_parent}" "${staged_crash_target}" "${staged_crash_root}" staged 1 1
write_lock_owner "${staged_crash_parent}" 99999999 'dead process'
run_restart "${staged_crash_dir}"
assert_text "${staged_crash_target}/build-id" new
assert_text "${staged_crash_dir}/open-log" "${staged_crash_target}|new"
[[ ! -e "${staged_crash_root}" && ! -e "${staged_crash_parent}/.Peekaboo.install.journal" ]] || \
  fail 'staged crash recovery did not clean the unchanged transaction'

# A crash after moving the previous app is recovered from the durable sibling journal before rebuilding.
rename_crash_dir="$(new_case crash-after-backup-rename)"
rename_crash_parent="${rename_crash_dir}/Applications"
rename_crash_target="${rename_crash_parent}/Peekaboo.app"
rename_crash_root="${rename_crash_parent}/.Peekaboo.install.CRASH01"
mkdir -p "${rename_crash_root}"
make_bundle "${rename_crash_root}/previous.app" old
make_bundle "${rename_crash_root}/candidate.app" interrupted-new
write_journal "${rename_crash_parent}" "${rename_crash_target}" "${rename_crash_root}" backing-up 1 1
write_lock_owner "${rename_crash_parent}" 99999999 'dead process'
run_restart "${rename_crash_dir}"
assert_text "${rename_crash_target}/build-id" new
expected_crash_recovery_log="${rename_crash_target}|old
${rename_crash_target}|new"
assert_text "${rename_crash_dir}/open-log" "${expected_crash_recovery_log}"
[[ ! -e "${rename_crash_root}" && ! -e "${rename_crash_parent}/.Peekaboo.install.journal" ]] || \
  fail 'rename-crash recovery did not clean its completed transaction'

# Recovery never restores the backup over a live replacement; it keeps every bundle and the journal.
live_recovery_dir="$(new_case live-replacement-recovery-refusal)"
live_recovery_parent="${live_recovery_dir}/Applications"
live_recovery_target="${live_recovery_parent}/Peekaboo.app"
live_recovery_root="${live_recovery_parent}/.Peekaboo.install.CRASH02"
mkdir -p "${live_recovery_root}"
make_bundle "${live_recovery_root}/previous.app" old
make_bundle "${live_recovery_target}" interrupted-new
printf '%s\n' "${live_recovery_target}" >"${live_recovery_dir}/running-path"
write_journal "${live_recovery_parent}" "${live_recovery_target}" "${live_recovery_root}" installed 1 1
write_lock_owner "${live_recovery_parent}" 99999999 'dead process'
if run_restart "${live_recovery_dir}"; then
  fail 'expected live interrupted replacement recovery to fail closed'
fi
assert_text "${live_recovery_target}/build-id" interrupted-new
assert_text "${live_recovery_root}/previous.app/build-id" old
[[ -f "${live_recovery_parent}/.Peekaboo.install.journal" ]] || \
  fail 'live replacement recovery discarded its journal'
rm -f "${live_recovery_dir}/running-path"
run_restart "${live_recovery_dir}"
assert_text "${live_recovery_target}/build-id" new
expected_live_recovery_log="${live_recovery_target}|old
${live_recovery_target}|new"
assert_text "${live_recovery_dir}/open-log" "${expected_live_recovery_log}"

# An existing Applications-style install is the destination, never the stale launch source.
success_dir="$(new_case applications-success)"
success_target="${success_dir}/Applications/Peekaboo.app"
make_bundle "${success_target}" old
printf '%s\n' "${success_target}" >"${success_dir}/running-path"
run_restart "${success_dir}"
assert_text "${success_target}/build-id" new
grep -Fq 'configuration:Release' "${success_dir}/events" || fail 'deployment mode did not default to Release'
grep -Fxq 'build-unsigned' "${success_dir}/events" || fail 'deployment mode did not request an unsigned build'
assert_text "${success_dir}/open-log" "${success_target}|new"
assert_text "${success_dir}/open-flags" -gj
if grep -Fq '|old' "${success_dir}/open-log"; then
  fail 'success path launched the stale installed app'
fi
build_line="$(grep -n '^build$' "${success_dir}/events" | cut -d: -f1)"
sign_line="$(grep -n '^sign$' "${success_dir}/events" | cut -d: -f1)"
stop_line="$(grep -n '^stop$' "${success_dir}/events" | cut -d: -f1)"
open_line="$(grep -n '^open:new$' "${success_dir}/events" | cut -d: -f1)"
((build_line < sign_line && sign_line < stop_line && stop_line < open_line)) || \
  fail 'unsigned build/manual-sign/stop/launch ordering was not preserved'

# A failed manual signature never reaches verification, install, or the running app.
manual_sign_dir="$(new_case manual-sign-failure)"
manual_sign_target="${manual_sign_dir}/Applications/Peekaboo.app"
make_bundle "${manual_sign_target}" old
printf '%s\n' "${manual_sign_target}" >"${manual_sign_dir}/running-path"
touch "${manual_sign_dir}/fail-manual-sign"
if run_restart "${manual_sign_dir}"; then
  fail 'expected deployment manual signing failure'
fi
assert_text "${manual_sign_target}/build-id" old
grep -Fxq 'sign-failed' "${manual_sign_dir}/events" || fail 'manual signing failure was not exercised'
if grep -Eq '^(stop|open:)' "${manual_sign_dir}/events"; then
  fail 'manual signing failure stopped or relaunched the previous app'
fi

# Explicit Debug remains available when it is assigned its own stable target.
debug_dir="$(new_case explicit-debug-success)"
debug_target="${debug_dir}/Debug/Peekaboo.app"
mkdir -p "$(dirname "${debug_target}")"
run_restart "${debug_dir}" CONFIGURATION=Debug PEEKABOO_APP_BUNDLE="${debug_target}"
assert_text "${debug_target}/build-id" new
grep -Fq 'configuration:Debug' "${debug_dir}/events" || fail 'explicit Debug configuration was not preserved'

# An explicit target wins over an Applications install; launch failure restores and relaunches the prior app.
launch_dir="$(new_case launch-rollback)"
launch_target="${launch_dir}/Explicit/Peekaboo.app"
applications_decoy="${launch_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${launch_target}")"
make_bundle "${launch_target}" old
make_bundle "${applications_decoy}" applications-decoy
printf '%s\n' "${launch_target}" >"${launch_dir}/running-path"
touch "${launch_dir}/fail-new-open"
if run_restart "${launch_dir}" PEEKABOO_APP_BUNDLE="${launch_target}"; then
  fail 'expected replacement launch failure'
fi
assert_text "${launch_target}/build-id" old
assert_text "${applications_decoy}/build-id" applications-decoy
expected_launch_log="${launch_target}|new
${launch_target}|old"
assert_text "${launch_dir}/open-log" "${expected_launch_log}"
assert_text "${launch_dir}/running-path" "${launch_target}"

# Interruption after TERM but before the stop result is recorded must relaunch the unchanged app.
stop_interrupt_dir="$(new_case interrupted-during-stop)"
stop_interrupt_target="${stop_interrupt_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${stop_interrupt_target}")"
make_bundle "${stop_interrupt_target}" old
printf '%s\n' "${stop_interrupt_target}" >"${stop_interrupt_dir}/running-path"
touch "${stop_interrupt_dir}/interrupt-during-stop"
if run_restart "${stop_interrupt_dir}"; then
  fail 'expected interrupted stop to retain the nonzero signal result'
fi
assert_text "${stop_interrupt_target}/build-id" old
assert_text "${stop_interrupt_dir}/running-path" "${stop_interrupt_target}"
assert_text "${stop_interrupt_dir}/open-log" "${stop_interrupt_target}|old"
[[ ! -e "$(dirname "${stop_interrupt_target}")/.Peekaboo.install.journal" ]] || \
  fail 'interrupted pre-install stop left a completed journal after relaunch'

# A process is not committed until the explicit GUI Bridge identifies that PID, build, and launch mode.
for health_case in \
  fail-health health-wrong-pid health-wrong-start health-start-drift health-adjacent-large-start \
  health-wrong-hash health-missing-capability; do
  health_dir="$(new_case ${health_case}-rollback)"
  health_target="${health_dir}/Applications/Peekaboo.app"
  mkdir -p "$(dirname "${health_target}")"
  make_bundle "${health_target}" old
  printf '%s\n' "${health_target}" >"${health_dir}/running-path"
  touch "${health_dir}/${health_case}"
  if run_restart "${health_dir}"; then
    fail "expected ${health_case} readiness failure"
  fi
  assert_text "${health_target}/build-id" old
  expected_health_rollback_log="${health_target}|new
${health_target}|old"
  assert_text "${health_dir}/open-log" "${expected_health_rollback_log}"
  [[ ! -e "$(dirname "${health_target}")/.Peekaboo.install.journal" ]] || \
    fail "${health_case} rollback left a completed journal"
done

# A restored PID is not enough: keep recovery durable when the previous generation never owns its Bridge.
restored_health_dir="$(new_case restored-bridge-readiness-refusal)"
restored_health_target="${restored_health_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${restored_health_target}")"
make_bundle "${restored_health_target}" old
printf '%s\n' "${restored_health_target}" >"${restored_health_dir}/running-path"
touch "${restored_health_dir}/fail-health" "${restored_health_dir}/restored-bridge-never-ready"
if run_restart "${restored_health_dir}"; then
  fail 'expected restored Bridge readiness failure'
fi
assert_text "${restored_health_target}/build-id" old
[[ -f "$(dirname "${restored_health_target}")/.Peekaboo.install.journal" ]] || \
  fail 'restored Bridge readiness failure discarded its recovery journal'
find "$(dirname "${restored_health_target}")" -maxdepth 1 -type d \
  -name '.Peekaboo.install.*' | grep -q . || \
  fail 'restored Bridge readiness failure discarded its recovery bundle'

# If the replacement cannot be stopped, rollback preserves both bundles and never restores over it.
stop_refusal_dir="$(new_case rollback-stop-refusal)"
stop_refusal_target="${stop_refusal_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${stop_refusal_target}")"
make_bundle "${stop_refusal_target}" old
printf '%s\n' "${stop_refusal_target}" >"${stop_refusal_dir}/running-path"
touch "${stop_refusal_dir}/transient-new-process" "${stop_refusal_dir}/refuse-new-stop"
if run_restart "${stop_refusal_dir}"; then
  fail 'expected rollback to refuse restoring over a live replacement'
fi
assert_text "${stop_refusal_target}/build-id" new
stop_refusal_root="$(find "$(dirname "${stop_refusal_target}")" -maxdepth 1 -type d \
  -name '.Peekaboo.install.*' ! -name '*.lock' -print -quit)"
[[ -n "${stop_refusal_root}" ]] || fail 'live rollback did not preserve its transaction root'
assert_text "${stop_refusal_root}/previous.app/build-id" old
[[ -f "$(dirname "${stop_refusal_target}")/.Peekaboo.install.journal" ]] || \
  fail 'live rollback discarded its recovery journal'
rm -f "${stop_refusal_dir}/running-path" "${stop_refusal_dir}/refuse-new-stop" \
  "${stop_refusal_dir}/transient-new-process" "${stop_refusal_dir}/pgrep-count"
run_restart "${stop_refusal_dir}"
assert_text "${stop_refusal_target}/build-id" new

# Restoring a bundle is not enough: rollback keeps its journal until a new old-app process is observed.
restore_verify_dir="$(new_case restored-generation-verification)"
restore_verify_target="${restore_verify_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${restore_verify_target}")"
make_bundle "${restore_verify_target}" old
printf '%s\n' "${restore_verify_target}" >"${restore_verify_dir}/running-path"
touch "${restore_verify_dir}/fail-new-open" "${restore_verify_dir}/fail-old-process"
if run_restart "${restore_verify_dir}"; then
  fail 'expected unobserved restored process generation to keep recovery state'
fi
assert_text "${restore_verify_target}/build-id" old
grep -q '^phase=restored$' "$(dirname "${restore_verify_target}")/.Peekaboo.install.journal" || \
  fail 'unobserved restored generation did not keep a restored-phase journal'
rm -f "${restore_verify_dir}/fail-new-open" "${restore_verify_dir}/fail-old-process"
run_restart "${restore_verify_dir}"
assert_text "${restore_verify_target}/build-id" new

# A crash after the backup rename but before the restored journal write is idempotently recoverable.
restore_crash_dir="$(new_case crash-after-restore-rename)"
restore_crash_target="${restore_crash_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${restore_crash_target}")"
make_bundle "${restore_crash_target}" old
printf '%s\n' "${restore_crash_target}" >"${restore_crash_dir}/running-path"
touch "${restore_crash_dir}/fail-new-open" "${restore_crash_dir}/fail-after-restore-move"
if run_restart "${restore_crash_dir}"; then
  fail 'expected simulated crash after restore rename'
fi
assert_text "${restore_crash_target}/build-id" old
grep -q '^phase=restoring$' "$(dirname "${restore_crash_target}")/.Peekaboo.install.journal" || \
  fail 'post-restore-rename crash did not retain the restoring phase'
rm -f "${restore_crash_dir}/fail-new-open" "${restore_crash_dir}/fail-after-restore-move"
run_restart "${restore_crash_dir}"
assert_text "${restore_crash_target}/build-id" new
expected_restore_crash_log="${restore_crash_target}|new
${restore_crash_target}|old
${restore_crash_target}|new"
assert_text "${restore_crash_dir}/open-log" "${expected_restore_crash_log}"

# With no Applications install, an existing dist target is replaced transactionally; install failure restores it.
install_dir="$(new_case install-rollback)"
install_target="${install_dir}/dist/Peekaboo.app"
make_bundle "${install_target}" old
mkdir -p "${install_dir}/Applications"
printf '%s\n' "${install_target}" >"${install_dir}/running-path"
touch "${install_dir}/fail-second-move"
if run_restart "${install_dir}"; then
  fail 'expected replacement install failure'
fi
assert_text "${install_target}/build-id" old
assert_text "${install_dir}/open-log" "${install_target}|old"
assert_text "${install_dir}/running-path" "${install_target}"

# Rollback state is durable even when a move reports failure after completing the atomic rename.
for rename_number in first second; do
  rename_dir="$(new_case post-${rename_number}-rename-rollback)"
  rename_target="${rename_dir}/Applications/Peekaboo.app"
  make_bundle "${rename_target}" old
  printf '%s\n' "${rename_target}" >"${rename_dir}/running-path"
  touch "${rename_dir}/fail-after-${rename_number}-move"
  if run_restart "${rename_dir}"; then
    fail "expected failure after ${rename_number} rename"
  fi
  assert_text "${rename_target}/build-id" old
  assert_text "${rename_dir}/open-log" "${rename_target}|old"
  assert_text "${rename_dir}/running-path" "${rename_target}"
done

# Final-path verification compares the Team ID as well as the signed bundle identifier.
team_dir="$(new_case final-team-rollback)"
team_target="${team_dir}/Applications/Peekaboo.app"
make_bundle "${team_target}" old
printf '%s\n' "${team_target}" >"${team_dir}/running-path"
touch "${team_dir}/mutate-final-team"
if run_restart "${team_dir}"; then
  fail 'expected final Team ID mismatch failure'
fi
assert_text "${team_target}/build-id" old
assert_text "${team_dir}/open-log" "${team_target}|old"

# An ad-hoc result is refused if the explicit signing helper does not establish the expected identity.
sign_dir="$(new_case adhoc-build-presign-refusal)"
sign_target="${sign_dir}/Applications/Peekaboo.app"
make_bundle "${sign_target}" old
printf '%s\n' "${sign_target}" >"${sign_dir}/running-path"
touch "${sign_dir}/adhoc-build" "${sign_dir}/identity-available"
if run_restart "${sign_dir}" PEEKABOO_APP_SIGN_IDENTITY='Developer ID Application: Test (TESTTEAM)'; then
  fail 'expected ad-hoc build to require a correctly signed rebuild'
fi
assert_text "${sign_target}/build-id" old
grep -Fxq 'sign' "${sign_dir}/events" || fail 'ad-hoc build did not pass through manual signing'
if grep -q '^stop$' "${sign_dir}/events"; then
  fail 'ad-hoc build refusal stopped the previous app'
fi

# Exact-artifact mode does not build or re-sign and reports one content digest through installation.
artifact_dir="$(new_case exact-source-artifact)"
artifact_source="${artifact_dir}/Source/Peekaboo.app"
artifact_target="${artifact_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${artifact_source}")" "$(dirname "${artifact_target}")"
make_bundle "${artifact_source}" artifact
make_bundle "${artifact_target}" old
printf '%s\n' "${artifact_target}" >"${artifact_dir}/running-path"
run_restart "${artifact_dir}" -- --source-app "${artifact_source}"
assert_text "${artifact_source}/build-id" artifact
assert_text "${artifact_target}/build-id" artifact
if grep -Eq '^(build|sign)$' "${artifact_dir}/events"; then
  fail 'exact-source artifact mode rebuilt or re-signed its input'
fi
grep -Eq '^Artifact SHA-256: [0-9a-f]{64}$' "${artifact_dir}/stdout" || \
  fail 'exact-source artifact mode did not report its digest'
grep -Eq '^OK: .*\(SHA-256 [0-9a-f]{64}\)\.$' "${artifact_dir}/stdout" || \
  fail 'exact-source artifact mode did not report the installed digest'

# --no-build can reuse an explicit already-signed build output without touching it.
no_build_dir="$(new_case no-build-artifact)"
no_build_source="${no_build_dir}/Prebuilt/Peekaboo.app"
no_build_target="${no_build_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${no_build_source}")" "$(dirname "${no_build_target}")"
make_bundle "${no_build_source}" prebuilt
make_bundle "${no_build_target}" old
printf '%s\n' "${no_build_target}" >"${no_build_dir}/running-path"
run_restart "${no_build_dir}" BUILT_APP_BUNDLE="${no_build_source}" -- --no-build
assert_text "${no_build_target}/build-id" prebuilt
if grep -Eq '^(build|sign)$' "${no_build_dir}/events"; then
  fail '--no-build mode rebuilt or re-signed its input'
fi

# Textual Authority/Team metadata cannot substitute for the expected Apple trust requirement.
untrusted_source_dir="$(new_case untrusted-source-artifact)"
untrusted_source="${untrusted_source_dir}/Source/Peekaboo.app"
mkdir -p "$(dirname "${untrusted_source}")" "${untrusted_source_dir}/Applications"
make_bundle "${untrusted_source}" untrusted
rm -f "${untrusted_source}/.trusted-anchor"
if run_restart "${untrusted_source_dir}" -- --source-app "${untrusted_source}"; then
  fail 'expected same-authority artifact without the trusted requirement to fail'
fi
[[ ! -f "${untrusted_source_dir}/events" ]] || fail 'untrusted source artifact started or mutated the app'

# Existing unstable identity fails closed unless the operator explicitly accepts a TCC migration.
unstable_dir="$(new_case unstable-existing-identity)"
unstable_target="${unstable_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${unstable_target}")"
make_bundle "${unstable_target}" old
rm -f "${unstable_target}/.team-id" "${unstable_target}/.requirement" "${unstable_target}/.trusted-anchor"
printf '%s\n' "${unstable_target}" >"${unstable_dir}/running-path"
if run_restart "${unstable_dir}"; then
  fail 'expected unstable existing identity to fail closed by default'
fi
assert_text "${unstable_target}/build-id" old
if grep -q '^stop$' "${unstable_dir}/events"; then
  fail 'unstable identity refusal stopped the existing app'
fi
run_restart "${unstable_dir}" -- --allow-unstable-existing-identity
assert_text "${unstable_target}/build-id" new

# A remaining same-team development signature is refused after the explicit signing helper returns.
resign_dir="$(new_case requirement-resign-refusal)"
resign_target="${resign_dir}/Applications/Peekaboo.app"
make_bundle "${resign_target}" old
printf '%s\n' "${resign_target}" >"${resign_dir}/running-path"
touch "${resign_dir}/apple-development-build" "${resign_dir}/identity-available"
if run_restart "${resign_dir}" PEEKABOO_APP_SIGN_IDENTITY='Developer ID Application: Test (TESTTEAM)'; then
  fail 'expected development-signed build refusal'
fi
assert_text "${resign_target}/build-id" old
grep -Fxq 'sign' "${resign_dir}/events" || \
  fail 'development-signed build did not pass through manual signing'
if grep -q '^stop$' "${resign_dir}/events"; then
  fail 'development-signed build refusal stopped the previous app'
fi

# A stable signature from another Developer ID is not accepted when the required signer is unavailable.
wrong_signer_dir="$(new_case wrong-signer-refusal)"
mkdir -p "${wrong_signer_dir}/Applications"
touch "${wrong_signer_dir}/other-developer-id-build"
if run_restart "${wrong_signer_dir}"; then
  fail 'expected wrong stable signer refusal'
fi
[[ ! -e "${wrong_signer_dir}/dist/Peekaboo.app" ]] || fail 'wrong signer payload was installed'
if [[ -f "${wrong_signer_dir}/open-log" ]] || grep -q '^stop$' "${wrong_signer_dir}/events"; then
  fail 'wrong signer refusal stopped or launched the app'
fi

# Without the configured identity, same Team ID and bundle ID cannot bridge a different requirement.
requirement_dir="$(new_case requirement-refusal)"
requirement_target="${requirement_dir}/Applications/Peekaboo.app"
make_bundle "${requirement_target}" old
printf '%s\n' "${requirement_target}" >"${requirement_dir}/running-path"
touch "${requirement_dir}/apple-development-build"
if run_restart "${requirement_dir}"; then
  fail 'expected different designated requirement refusal'
fi
assert_text "${requirement_target}/build-id" old
if [[ -f "${requirement_dir}/open-log" ]] || grep -q '^stop$' "${requirement_dir}/events"; then
  fail 'designated requirement refusal stopped or launched the app'
fi

# The same signing team is insufficient when the signed bundle identifier differs.
identifier_dir="$(new_case identifier-refusal)"
identifier_target="${identifier_dir}/Applications/Peekaboo.app"
make_bundle "${identifier_target}" old
printf '%s\n' "${identifier_target}" >"${identifier_dir}/running-path"
touch "${identifier_dir}/different-build-identifier"
if run_restart "${identifier_dir}"; then
  fail 'expected different bundle identifier refusal'
fi
assert_text "${identifier_target}/build-id" old
if [[ -f "${identifier_dir}/open-log" ]] || grep -q '^stop$' "${identifier_dir}/events"; then
  fail 'bundle identifier refusal stopped or launched the app'
fi

# Native-only policy failures are all pre-stop and pre-install.
source_policy_dir="$(new_case source-policy-refusal)"
printf 'import AppKit\nlet script: NSAppleScript?\n' >"${source_policy_dir}/source/Apps/Bad.swift"
/usr/bin/git -C "${source_policy_dir}/source" add Apps/Bad.swift
if run_restart "${source_policy_dir}"; then
  fail 'expected NSAppleScript source policy refusal'
fi
[[ ! -f "${source_policy_dir}/events" ]] || fail 'source policy refusal started a build'

for apple_event_api in \
  AECreateDesc AECreateAppleEvent AESendMessage AEDeterminePermissionToAutomateTarget AEDisposeDesc \
  OSADoScript; do
  source_policy_dir="$(new_case source-${apple_event_api}-refusal)"
  printf '%s\n' "${apple_event_api}" >"${source_policy_dir}/source/Apps/Bad.swift"
  /usr/bin/git -C "${source_policy_dir}/source" add Apps/Bad.swift
  if run_restart "${source_policy_dir}"; then
    fail "expected ${apple_event_api} source policy refusal"
  fi
  [[ ! -f "${source_policy_dir}/events" ]] || \
    fail "${apple_event_api} source policy refusal started a build"
done

source_resource_dir="$(new_case source-resource-refusal)"
touch "${source_resource_dir}/source/Apps/Action.scpt"
if run_restart "${source_resource_dir}"; then
  fail 'expected production AppleScript resource policy refusal'
fi
[[ ! -f "${source_resource_dir}/events" ]] || fail 'source resource refusal started a build'

for policy_case in \
  apple-events-description nested-apple-events-description \
  apple-events-entitlement nsapplescript-import apple-events-string \
  osa-api-import ae-create-desc-import ae-create-apple-event-import ae-send-message-import \
  ae-determine-permission-import ae-dispose-desc-import nm-inspection-failure \
  strings-inspection-failure dynamic-applescript-string compiled-script-resource text-osascript-resource \
  executable-script-resource raw-applescript-text raw-applescript-display prefixed-applescript-command; do
  policy_dir="$(new_case ${policy_case}-refusal)"
  policy_target="${policy_dir}/Applications/Peekaboo.app"
  make_bundle "${policy_target}" old
  printf '%s\n' "${policy_target}" >"${policy_dir}/running-path"
  touch "${policy_dir}/${policy_case}"
  if run_restart "${policy_dir}"; then
    fail "expected ${policy_case} built-payload refusal"
  fi
  assert_text "${policy_target}/build-id" old
  if [[ -f "${policy_dir}/open-log" ]] || grep -q '^stop$' "${policy_dir}/events"; then
    fail "${policy_case} refusal stopped or launched the app"
  fi
done

# Benign signed executable resources are allowed; native-only means no AppleScript/OSA surface,
# not that every bundled helper must be a Mach-O file.
benign_executable_dir="$(new_case benign-executable-resource)"
benign_executable_target="${benign_executable_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${benign_executable_target}")"
make_bundle "${benign_executable_target}" old
printf '%s\n' "${benign_executable_target}" >"${benign_executable_dir}/running-path"
touch "${benign_executable_dir}/mode-0740-resource"
run_restart "${benign_executable_dir}"
assert_text "${benign_executable_target}/build-id" new


# The exact staged candidate is native-scanned after copying, not just its mutable source path.
staged_native_dir="$(new_case staged-native-tamper-refusal)"
staged_native_target="${staged_native_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${staged_native_target}")"
make_bundle "${staged_native_target}" old
printf '%s\n' "${staged_native_target}" >"${staged_native_dir}/running-path"
touch "${staged_native_dir}/mutate-staged-native"
if run_restart "${staged_native_dir}"; then
  fail 'expected staged native-only tamper refusal'
fi
assert_text "${staged_native_target}/build-id" old
if grep -q '^stop$' "${staged_native_dir}/events"; then
  fail 'staged native-only refusal stopped the previous app'
fi

# Every nested Mach-O must carry the expected signer even when it is not executable on disk.
nested_signer_dir="$(new_case nested-nonexecutable-signer-refusal)"
nested_signer_target="${nested_signer_dir}/Applications/Peekaboo.app"
mkdir -p "$(dirname "${nested_signer_target}")"
make_bundle "${nested_signer_target}" old
printf '%s\n' "${nested_signer_target}" >"${nested_signer_dir}/running-path"
touch "${nested_signer_dir}/nested-wrong-signer"
if run_restart "${nested_signer_dir}"; then
  fail 'expected non-executable nested Mach-O wrong-signer refusal'
fi
assert_text "${nested_signer_target}/build-id" old
if grep -q '^stop$' "${nested_signer_dir}/events"; then
  fail 'nested signer refusal stopped the previous app'
fi

# Target and exact-artifact symlinks are rejected before build, stop, or copy.
target_symlink_dir="$(new_case target-symlink-refusal)"
target_symlink_parent="${target_symlink_dir}/Applications"
mkdir -p "${target_symlink_parent}" "${target_symlink_dir}/Elsewhere"
make_bundle "${target_symlink_dir}/Elsewhere/Peekaboo.app" old
ln -s "${target_symlink_dir}/Elsewhere/Peekaboo.app" "${target_symlink_parent}/Peekaboo.app"
if run_restart "${target_symlink_dir}"; then
  fail 'expected symlinked install target refusal'
fi
[[ ! -f "${target_symlink_dir}/events" ]] || fail 'symlink target refusal started a build'

source_symlink_dir="$(new_case source-symlink-refusal)"
mkdir -p "${source_symlink_dir}/Source" "${source_symlink_dir}/Real" \
  "${source_symlink_dir}/Applications"
make_bundle "${source_symlink_dir}/Real/Peekaboo.app" source
ln -s "${source_symlink_dir}/Real/Peekaboo.app" "${source_symlink_dir}/Source/Peekaboo.app"
if run_restart "${source_symlink_dir}" -- --source-app "${source_symlink_dir}/Source/Peekaboo.app"; then
  fail 'expected symlinked source artifact refusal'
fi
[[ ! -f "${source_symlink_dir}/events" ]] || fail 'symlink source refusal mutated the app'

main_symlink_dir="$(new_case main-executable-symlink-refusal)"
main_symlink_source="${main_symlink_dir}/Source/Peekaboo.app"
mkdir -p "$(dirname "${main_symlink_source}")" "${main_symlink_dir}/Applications"
make_bundle "${main_symlink_source}" source
rm -f "${main_symlink_source}/Contents/MacOS/Peekaboo"
ln -s /usr/bin/true "${main_symlink_source}/Contents/MacOS/Peekaboo"
if run_restart "${main_symlink_dir}" -- --source-app "${main_symlink_source}"; then
  fail 'expected symlinked CFBundleExecutable refusal'
fi
[[ ! -f "${main_symlink_dir}/events" ]] || fail 'symlinked main executable mutated the app'

resource_symlink_dir="$(new_case escaping-resource-symlink-refusal)"
resource_symlink_source="${resource_symlink_dir}/Source/Peekaboo.app"
mkdir -p "$(dirname "${resource_symlink_source}")" "${resource_symlink_dir}/Applications"
make_bundle "${resource_symlink_source}" source
mkdir -p "${resource_symlink_source}/Contents/Resources"
ln -s /usr/bin/true "${resource_symlink_source}/Contents/Resources/ExternalTool"
if run_restart "${resource_symlink_dir}" -- --source-app "${resource_symlink_source}"; then
  fail 'expected payload symlink escaping Contents to fail'
fi
[[ ! -f "${resource_symlink_dir}/events" ]] || fail 'escaping resource symlink mutated the app'

# An ad-hoc build is rejected before the current target is stopped or changed.
adhoc_dir="$(new_case adhoc-refusal)"
adhoc_target="${adhoc_dir}/Applications/Peekaboo.app"
make_bundle "${adhoc_target}" old
printf '%s\n' "${adhoc_target}" >"${adhoc_dir}/running-path"
touch "${adhoc_dir}/adhoc-build"
if run_restart "${adhoc_dir}"; then
  fail 'expected ad-hoc build refusal'
fi
assert_text "${adhoc_target}/build-id" old
if [[ -f "${adhoc_dir}/open-log" ]] || grep -q '^stop$' "${adhoc_dir}/events"; then
  fail 'ad-hoc refusal stopped or launched the app'
fi

FIXTURE_COMPLETE=1
