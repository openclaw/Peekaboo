#!/usr/bin/env bash

set -euo pipefail

CODESIGN_BIN="${PEEKABOO_CODESIGN_BIN:-/usr/bin/codesign}"
FILE_BIN="${PEEKABOO_FILE_BIN:-/usr/bin/file}"
GIT_BIN="${PEEKABOO_GIT_BIN:-/usr/bin/git}"
NM_BIN="${PEEKABOO_NM_BIN:-/usr/bin/nm}"
PLISTBUDDY_BIN="${PEEKABOO_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
REALPATH_BIN="${PEEKABOO_REALPATH_BIN:-$(command -v realpath || true)}"
STRINGS_BIN="${PEEKABOO_STRINGS_BIN:-/usr/bin/strings}"

# shellcheck source=scripts/native-only-policy.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/native-only-policy.sh"

SOURCE_ROOT=""
APP_BUNDLE=""

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: scripts/verify-native-only-app.sh [--source-root <repo>] [--app <bundle>]\n'
}

contains_applescript_source() {
  local path="$1"

  # Structural declarations are meaningful only at a statement boundary. Execution commands are
  # deliberately matched anywhere so assignments and leading AppleScript comments cannot hide them.
  grep -Eiq \
    '^[[:space:]]*(on[[:space:]]+(run|open|idle|quit|error)([[:space:](]|$)|script[[:space:]]+[[:alnum:]_]+([[:space:]]|$)|use[[:space:]]+(AppleScript version|framework|scripting additions))' \
    "${path}" || \
    grep -Eiq \
      '(^|[^[:alnum:]_])(tell[[:space:]]+(application|app|current application)|using[[:space:]]+terms[[:space:]]+from|do[[:space:]]+shell[[:space:]]+script|run[[:space:]]+script([[:space:]]|$)|display[[:space:]]+(dialog|alert|notification)([[:space:]]|$)|choose[[:space:]]+(file|folder|application|from list|color|URL)([[:space:]]|$)|open[[:space:]]+location([[:space:]]|$)|mount[[:space:]]+volume([[:space:]]|$)|set[[:space:]]+volume([[:space:]]|$)|say[[:space:]]+|delay[[:space:]]+[0-9]|beep([[:space:]0-9(]|$))' \
      "${path}"
}

while (($# > 0)); do
  case "$1" in
    --source-root)
      [[ "$#" -ge 2 ]] || fail '--source-root requires a path'
      SOURCE_ROOT="$2"
      shift 2
      ;;
    --app)
      [[ "$#" -ge 2 ]] || fail '--app requires a bundle path'
      APP_BUNDLE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown argument: $1"
      ;;
  esac
done

[[ -n "${SOURCE_ROOT}" || -n "${APP_BUNDLE}" ]] || fail 'Specify --source-root, --app, or both'

if [[ -n "${SOURCE_ROOT}" ]]; then
  [[ -d "${SOURCE_ROOT}/.git" || -f "${SOURCE_ROOT}/.git" ]] || fail "Not a Git checkout: ${SOURCE_ROOT}"

  while IFS= read -r -d '' relative_path; do
    if grep -Eq \
      'NSAppleEventsUsageDescription|com\.apple\.security\.(automation\.apple-events|scripting-targets|temporary-exception\.apple-events)' \
      "${SOURCE_ROOT}/${relative_path}"; then
      fail "Apple Events permission metadata remains in source: ${relative_path}"
    fi
  done < <("${GIT_BIN}" -C "${SOURCE_ROOT}" ls-files -z -- '*.plist' '*.entitlements' '*.pbxproj')

  for source_dir in Apps Core AXorcist/Sources; do
    [[ -d "${SOURCE_ROOT}/${source_dir}" ]] || continue
    while IFS= read -r -d '' source_path; do
      if grep -Eq "${NATIVE_ONLY_APPLE_EVENT_SOURCE_PATTERN}" "${source_path}"; then
        fail "Production source retains an AppleScript or Apple Events execution surface: ${source_path#"${SOURCE_ROOT}/"}"
      fi
    done < <(
      find "${SOURCE_ROOT}/${source_dir}" \
        -type d \( -name .build -o -name DerivedData -o -name Tests -o -name '*Tests' \) -prune -o \
        -type f \( -name '*.swift' -o -name '*.m' -o -name '*.mm' -o -name '*.c' -o -name '*.cc' \
          -o -name '*.cpp' -o -name '*.h' -o -name '*.hpp' \) -print0
    )

    while IFS= read -r -d '' shell_path; do
      if grep -Fq '/usr/bin/osascript' "${shell_path}" || \
         grep -Eq '(^|[^[:alnum:]_])osascript([^[:alnum:]_]|$)' "${shell_path}"; then
        fail "Production script invokes osascript: ${shell_path#"${SOURCE_ROOT}/"}"
      fi
    done < <(
      find "${SOURCE_ROOT}/${source_dir}" \
        -type d \( -name .build -o -name DerivedData -o -name Tests -o -name '*Tests' \) -prune -o \
        -type f \( -name '*.sh' -o -name '*.bash' -o -name '*.zsh' -o -name '*.command' \) -print0
    )

    forbidden_resource="$(
      find "${SOURCE_ROOT}/${source_dir}" \
        -type d \( -name .build -o -name DerivedData -o -name Tests -o -name '*Tests' \) -prune -o \
        \( -iname '*.scpt' -o -iname '*.scptd' -o -iname '*.applescript' \) -print -quit
    )"
    [[ -z "${forbidden_resource}" ]] || \
      fail "Production source contains an AppleScript resource: ${forbidden_resource#"${SOURCE_ROOT}/"}"
  done
fi

if [[ -n "${APP_BUNDLE}" ]]; then
  [[ -n "${REALPATH_BIN}" ]] || fail 'realpath is required for app symlink validation'
  [[ -d "${APP_BUNDLE}" && ! -L "${APP_BUNDLE}" ]] || fail "App bundle not found or symlinked: ${APP_BUNDLE}"
  main_info_plist="${APP_BUNDLE}/Contents/Info.plist"
  [[ -f "${main_info_plist}" && ! -L "${main_info_plist}" ]] || \
    fail "App main Info.plist is missing or symlinked: ${main_info_plist}"
  main_executable_name="$(${PLISTBUDDY_BIN} -c 'Print :CFBundleExecutable' "${main_info_plist}" 2>/dev/null || true)"
  [[ -n "${main_executable_name}" && "${main_executable_name}" != */* ]] || \
    fail "App has an invalid CFBundleExecutable: ${main_executable_name:-<missing>}"
  main_executable="${APP_BUNDLE}/Contents/MacOS/${main_executable_name}"
  [[ -f "${main_executable}" && -x "${main_executable}" && ! -L "${main_executable}" ]] || \
    fail "App main executable is missing or symlinked: ${main_executable}"
  "${FILE_BIN}" -b "${main_executable}" | grep -q 'Mach-O' || \
    fail "App main executable is not Mach-O: ${main_executable}"

  canonical_contents="$(${REALPATH_BIN} "${APP_BUNDLE}/Contents")"
  while IFS= read -r -d '' symlink_path; do
    resolved_symlink="$(${REALPATH_BIN} "${symlink_path}" 2>/dev/null || true)"
    [[ -n "${resolved_symlink}" && "${resolved_symlink}" == "${canonical_contents}/"* ]] || \
      fail "App payload symlink escapes Contents or is broken: ${symlink_path}"
  done < <(find "${APP_BUNDLE}/Contents" -type l -print0)

  while IFS= read -r -d '' info_plist; do
    if "${PLISTBUDDY_BIN}" -c 'Print :NSAppleEventsUsageDescription' \
      "${info_plist}" >/dev/null 2>&1; then
      fail "App payload embeds NSAppleEventsUsageDescription: ${info_plist}"
    fi
  done < <(find "${APP_BUNDLE}" -type f -name Info.plist -print0)

  forbidden_resource="$(
    find "${APP_BUNDLE}/Contents" \( -iname '*.scpt' -o -iname '*.scptd' -o -iname '*.applescript' \) \
      -print -quit
  )"
  [[ -z "${forbidden_resource}" ]] || \
    fail "App payload contains an AppleScript resource: ${forbidden_resource}"

  app_entitlements="$("${CODESIGN_BIN}" -d --entitlements :- "${APP_BUNDLE}" 2>/dev/null || true)"
  if grep -Eq \
    'com\.apple\.security\.(automation\.apple-events|scripting-targets|temporary-exception\.apple-events)' \
    <<<"${app_entitlements}"; then
    fail "App retains an Apple Events or scripting entitlement: ${APP_BUNDLE}"
  fi

  mach_o_count=0
  while IFS= read -r -d '' candidate; do
    file_description="$("${FILE_BIN}" -b "${candidate}" 2>/dev/null || true)"
    if grep -q 'Mach-O' <<<"${file_description}"; then
      mach_o_count=$((mach_o_count + 1))
      if ! policy_error="$(native_only_verify_macho \
        "${candidate}" "Mach-O" "${NM_BIN}" "${STRINGS_BIN}")"; then
        fail "${policy_error}: ${candidate}"
      fi
      candidate_entitlements="$("${CODESIGN_BIN}" -d --entitlements :- "${candidate}" 2>/dev/null || true)"
      if grep -Eq \
        'com\.apple\.security\.(automation\.apple-events|scripting-targets|temporary-exception\.apple-events)' \
        <<<"${candidate_entitlements}"; then
        fail "Mach-O retains an Apple Events or scripting entitlement: ${candidate}"
      fi
    elif grep -qi 'AppleScript' <<<"${file_description}"; then
      fail "Payload contains compiled AppleScript data: ${candidate}"
    elif grep -Eqi 'text|script|JSON|XML|property list' <<<"${file_description}" && \
         { grep -Eq "${NATIVE_ONLY_APPLE_EVENT_SOURCE_PATTERN}" "${candidate}" 2>/dev/null || \
           grep -Eq '(^|[^[:alnum:]_])osascript([^[:alnum:]_]|$)' "${candidate}" 2>/dev/null || \
           contains_applescript_source "${candidate}"; }; then
      fail "Text payload retains an AppleScript or Apple Events execution surface: ${candidate}"
    fi
  done < <(find "${APP_BUNDLE}/Contents" -type f -print0)
  ((mach_o_count > 0)) || fail "No Mach-O payload found in ${APP_BUNDLE}"
fi
