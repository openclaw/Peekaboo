#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-restart-test.XXXXXX)"
TEMPLATE_BIN="${TEST_DIR}/template-bin"
TEMPLATE_SOURCE="${TEST_DIR}/template-source"
trap 'rm -rf "$TEST_DIR"' EXIT

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

make_bundle() {
  local path="$1"
  local build_id="$2"

  mkdir -p "${path}/Contents/MacOS"
  printf '%s\n' "${build_id}" >"${path}/build-id"
  printf '%s\n' 'TESTTEAM' >"${path}/.team-id"
  printf '%s\n' 'boo.peekaboo.mac' >"${path}/.bundle-id"
  printf '%s\n' 'developer-id' >"${path}/.requirement"
  /usr/bin/plutil -create xml1 "${path}/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string Peekaboo "${path}/Contents/Info.plist"
  printf '#!/usr/bin/env bash\n' >"${path}/Contents/MacOS/Peekaboo"
  chmod +x "${path}/Contents/MacOS/Peekaboo"
}

new_case() {
  local name="$1"
  local case_dir="${TEST_DIR}/${name}"

  mkdir -p "${case_dir}"
  cp -R "${TEMPLATE_BIN}" "${case_dir}/bin"
  cp -R "${TEMPLATE_SOURCE}" "${case_dir}/source"
  printf '%s\n' "${case_dir}"
}

run_restart() {
  local case_dir="$1"
  shift

  env \
    HOME="${case_dir}/home" \
    DERIVED_DATA_PATH="${case_dir}/DerivedData" \
    DIST_DIR="${case_dir}/dist" \
    DIST_APP_BUNDLE="${case_dir}/dist/Peekaboo.app" \
    PEEKABOO_APPLICATIONS_DIR="${case_dir}/Applications" \
    PEEKABOO_BUILD_SCRIPT="${case_dir}/bin/build-app" \
    PEEKABOO_CODESIGN_BIN="${case_dir}/bin/codesign" \
    PEEKABOO_FILE_BIN="${case_dir}/bin/file" \
    PEEKABOO_NM_BIN="${case_dir}/bin/nm" \
    PEEKABOO_STRINGS_BIN="${case_dir}/bin/strings" \
    PEEKABOO_SECURITY_BIN="${case_dir}/bin/security" \
    PEEKABOO_NATIVE_SOURCE_ROOT="${case_dir}/source" \
    PEEKABOO_MV_BIN="${case_dir}/bin/mv" \
    PEEKABOO_OPEN_BIN="${case_dir}/bin/open" \
    PEEKABOO_PGREP_BIN="${case_dir}/bin/pgrep" \
    PEEKABOO_KILL_BIN="${case_dir}/bin/kill" \
    PEEKABOO_SLEEP_BIN="${case_dir}/bin/sleep" \
    PEEKABOO_LAUNCH_VERIFY_ATTEMPTS=2 \
    PEEKABOO_APP_SIGN_IDENTITY='Developer ID Application: Test (TESTTEAM)' \
    "$@" \
    "${ROOT_DIR}/scripts/restart-peekaboo.sh" >/dev/null
}

mkdir -p "${TEMPLATE_BIN}" "${TEMPLATE_SOURCE}/Apps"
printf 'import Foundation\n' >"${TEMPLATE_SOURCE}/Apps/Good.swift"
/usr/bin/git -C "${TEMPLATE_SOURCE}" init -q
/usr/bin/git -C "${TEMPLATE_SOURCE}" add Apps/Good.swift

cat >"${TEMPLATE_BIN}/build-app" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
printf '%s\n' 'build' >>"${state_dir}/events"
mkdir -p "${bundle}/Contents/MacOS"
printf '%s\n' 'new' >"${bundle}/build-id"
printf 'configuration:%s\n' "${CONFIGURATION}" >>"${state_dir}/events"
if [[ -f "${state_dir}/adhoc-build" ]]; then
  printf '%s\n' 'adhoc' >"${bundle}/.team-id"
else
  printf '%s\n' 'TESTTEAM' >"${bundle}/.team-id"
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
else
  printf '%s\n' 'boo.peekaboo.mac' >"${bundle}/.bundle-id"
fi
/usr/bin/plutil -create xml1 "${bundle}/Contents/Info.plist"
/usr/bin/plutil -insert CFBundleExecutable -string Peekaboo "${bundle}/Contents/Info.plist"
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
[[ ! -f "${state_dir}/apple-events-string" ]] || touch "${bundle}/.apple-events-string"
printf '#!/usr/bin/env bash\n' >"${bundle}/Contents/MacOS/Peekaboo"
chmod +x "${bundle}/Contents/MacOS/Peekaboo"
EOF

cat >"${TEMPLATE_BIN}/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle="${!#}"

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
  printf '%s\n' 'TESTTEAM' >"${bundle}/.team-id"
  printf '%s\n' 'developer-id' >"${bundle}/.requirement"
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
      authority='Developer ID Application: Test (TESTTEAM)'
    fi
    printf '%s\n' "Identifier=${bundle_id}" "Authority=${authority}" "TeamIdentifier=${team_id}" >&2
  fi
  exit 0
fi

[[ "${1:-}" == "--verify" ]] || exit 2
exit 0
EOF

cat >"${TEMPLATE_BIN}/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-b" && "${2:-}" == */Contents/MacOS/Peekaboo ]]; then
  printf '%s\n' 'Mach-O 64-bit executable arm64'
else
  printf '%s\n' 'data'
fi
EOF

cat >"${TEMPLATE_BIN}/nm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
candidate="${!#}"
bundle="${candidate%%/Contents/*}"
if [[ -f "${bundle}/.nsapplescript-import" ]]; then
  printf '%s\n' '                 U _OBJC_CLASS_$_NSAppleScript'
fi
EOF

cat >"${TEMPLATE_BIN}/strings" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
candidate="${!#}"
bundle="${candidate%%/Contents/*}"
if [[ -f "${bundle}/.apple-events-string" ]]; then
  printf '%s\n' '<key>NSAppleEventsUsageDescription</key>'
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
[[ "${1:-}" == "-gj" ]] || exit 72
bundle="${!#}"
build_id="$(<"${bundle}/build-id")"
printf '%s\n' "${1}" >>"${state_dir}/open-flags"
printf '%s|%s\n' "${bundle}" "${build_id}" >>"${state_dir}/open-log"
printf 'open:%s\n' "${build_id}" >>"${state_dir}/events"
if [[ -f "${state_dir}/fail-new-open" && "${build_id}" == "new" ]]; then
  exit 71
fi
printf '%s\n' "${bundle}" >"${state_dir}/running-path"
EOF

cat >"${TEMPLATE_BIN}/pgrep" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state_dir="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "${state_dir}/running-path" ]] || exit 1
running_path="$(<"${state_dir}/running-path")"
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
printf '%s\n' 'stop' >>"${state_dir}/events"
rm -f "${state_dir}/running-path"
EOF

cat >"${TEMPLATE_BIN}/sleep" <<'EOF'
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
if "${ROOT_DIR}/scripts/restart-peekaboo.sh" --dry-run >/dev/null 2>&1; then
  fail 'unknown arguments must fail instead of starting a build'
fi
invalid_target_dir="$(new_case invalid-target)"
mkdir -p "${invalid_target_dir}/Explicit"
if run_restart "${invalid_target_dir}" PEEKABOO_APP_BUNDLE="${invalid_target_dir}/Explicit/Other.app"; then
  fail 'an explicit target with another app name must be rejected'
fi
[[ ! -f "${invalid_target_dir}/events" ]] || fail 'invalid target rejection started a build'

# An existing Applications-style install is the destination, never the stale launch source.
success_dir="$(new_case applications-success)"
success_target="${success_dir}/Applications/Peekaboo.app"
make_bundle "${success_target}" old
printf '%s\n' "${success_target}" >"${success_dir}/running-path"
run_restart "${success_dir}"
assert_text "${success_target}/build-id" new
grep -Fq 'configuration:Release' "${success_dir}/events" || fail 'normal restart did not default to Release'
assert_text "${success_dir}/open-log" "${success_target}|new"
assert_text "${success_dir}/open-flags" -gj
if grep -Fq '|old' "${success_dir}/open-log"; then
  fail 'success path launched the stale installed app'
fi
build_line="$(grep -n '^build$' "${success_dir}/events" | cut -d: -f1)"
stop_line="$(grep -n '^stop$' "${success_dir}/events" | cut -d: -f1)"
open_line="$(grep -n '^open:new$' "${success_dir}/events" | cut -d: -f1)"
((build_line < stop_line && stop_line < open_line)) || fail 'build/stop/launch ordering was not preserved'

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

# A build produced unsigned by Xcode can be Developer ID signed before the current app is stopped.
sign_dir="$(new_case post-sign-success)"
sign_target="${sign_dir}/Applications/Peekaboo.app"
make_bundle "${sign_target}" old
printf '%s\n' "${sign_target}" >"${sign_dir}/running-path"
touch "${sign_dir}/adhoc-build" "${sign_dir}/identity-available"
run_restart "${sign_dir}" PEEKABOO_APP_SIGN_IDENTITY='Developer ID Application: Test (TESTTEAM)'
assert_text "${sign_target}/build-id" new
[[ "$(grep -c '^sign$' "${sign_dir}/events")" == "2" ]] || fail 'expected nested and top-level signing passes'
first_sign_line="$(grep -n '^sign$' "${sign_dir}/events" | head -n 1 | cut -d: -f1)"
sign_stop_line="$(grep -n '^stop$' "${sign_dir}/events" | cut -d: -f1)"
((first_sign_line < sign_stop_line)) || fail 'app was stopped before signing completed'

# A same-team Apple Development build is re-signed when the configured Developer ID is available.
resign_dir="$(new_case requirement-resign-success)"
resign_target="${resign_dir}/Applications/Peekaboo.app"
make_bundle "${resign_target}" old
printf '%s\n' "${resign_target}" >"${resign_dir}/running-path"
touch "${resign_dir}/apple-development-build" "${resign_dir}/identity-available"
run_restart "${resign_dir}" PEEKABOO_APP_SIGN_IDENTITY='Developer ID Application: Test (TESTTEAM)'
assert_text "${resign_target}/build-id" new
[[ "$(grep -c '^sign$' "${resign_dir}/events")" == "2" ]] || fail 'expected Developer ID re-signing passes'

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

for policy_case in \
  apple-events-description nested-apple-events-description \
  apple-events-entitlement nsapplescript-import apple-events-string; do
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

printf 'test-restart-peekaboo: ok\n'
