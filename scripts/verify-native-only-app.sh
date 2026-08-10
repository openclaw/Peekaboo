#!/usr/bin/env bash

set -euo pipefail

CODESIGN_BIN="${PEEKABOO_CODESIGN_BIN:-/usr/bin/codesign}"
FILE_BIN="${PEEKABOO_FILE_BIN:-/usr/bin/file}"
GIT_BIN="${PEEKABOO_GIT_BIN:-/usr/bin/git}"
NM_BIN="${PEEKABOO_NM_BIN:-/usr/bin/nm}"
PLISTBUDDY_BIN="${PEEKABOO_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
STRINGS_BIN="${PEEKABOO_STRINGS_BIN:-/usr/bin/strings}"

SOURCE_ROOT=""
APP_BUNDLE=""

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf 'Usage: scripts/verify-native-only-app.sh [--source-root <repo>] [--app <bundle>]\n'
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
    if grep -Eq 'NSAppleEventsUsageDescription|com\.apple\.security\.automation\.apple-events' \
      "${SOURCE_ROOT}/${relative_path}"; then
      fail "Apple Events permission metadata remains in source: ${relative_path}"
    fi
  done < <("${GIT_BIN}" -C "${SOURCE_ROOT}" ls-files -z -- '*.plist' '*.entitlements' '*.pbxproj')

  for source_dir in Apps Core AXorcist/Sources; do
    [[ -d "${SOURCE_ROOT}/${source_dir}" ]] || continue
    while IFS= read -r -d '' source_path; do
      if grep -Fq 'NSAppleScript' "${source_path}"; then
        fail "Production Swift source imports NSAppleScript: ${source_path#"${SOURCE_ROOT}/"}"
      fi
    done < <(
      find "${SOURCE_ROOT}/${source_dir}" \
        -type d \( -name .build -o -name DerivedData \) -prune -o \
        -type f -name '*.swift' -print0
    )
  done
fi

if [[ -n "${APP_BUNDLE}" ]]; then
  [[ -d "${APP_BUNDLE}" ]] || fail "App bundle not found: ${APP_BUNDLE}"
  while IFS= read -r -d '' info_plist; do
    if "${PLISTBUDDY_BIN}" -c 'Print :NSAppleEventsUsageDescription' \
      "${info_plist}" >/dev/null 2>&1; then
      fail "App payload embeds NSAppleEventsUsageDescription: ${info_plist}"
    fi
  done < <(find "${APP_BUNDLE}" -type f -name Info.plist -print0)

  app_entitlements="$("${CODESIGN_BIN}" -d --entitlements :- "${APP_BUNDLE}" 2>/dev/null || true)"
  if [[ "${app_entitlements}" == *'com.apple.security.automation.apple-events'* ]]; then
    fail "App retains the Apple Events entitlement: ${APP_BUNDLE}"
  fi

  mach_o_count=0
  while IFS= read -r -d '' candidate; do
    if "${FILE_BIN}" -b "${candidate}" | grep -q 'Mach-O'; then
      mach_o_count=$((mach_o_count + 1))
      undefined_symbols="$("${NM_BIN}" -u "${candidate}" 2>/dev/null || true)"
      if [[ "${undefined_symbols}" == *NSAppleScript* ]]; then
        fail "Mach-O imports NSAppleScript: ${candidate}"
      fi
      embedded_strings="$("${STRINGS_BIN}" "${candidate}" 2>/dev/null || true)"
      if [[ "${embedded_strings}" == *'<key>NSAppleEventsUsageDescription</key>'* ]]; then
        fail "Mach-O embeds the NSAppleEventsUsageDescription key: ${candidate}"
      fi
      candidate_entitlements="$("${CODESIGN_BIN}" -d --entitlements :- "${candidate}" 2>/dev/null || true)"
      if [[ "${candidate_entitlements}" == *'com.apple.security.automation.apple-events'* ]]; then
        fail "Mach-O retains the Apple Events entitlement: ${candidate}"
      fi
    fi
  done < <(find "${APP_BUNDLE}/Contents" -type f -print0)
  ((mach_o_count > 0)) || fail "No Mach-O payload found in ${APP_BUNDLE}"
fi
