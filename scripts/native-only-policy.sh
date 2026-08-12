#!/usr/bin/env bash

# Shared native-only policy for source and Mach-O inspection. Keep every release
# surface on the same fail-closed Apple Events and OSA boundary.
# shellcheck disable=SC2034
NATIVE_ONLY_APPLE_EVENT_SOURCE_PATTERN='NSAppleScript|NSUserAppleScriptTask|OSAKit|OSAScript|kOSAComponentType|(^|[^[:alnum:]_])(AE[A-Z][[:lower:]][[:alnum:]_]*|OSA[A-Z][[:lower:]][[:alnum:]_]*)([^[:alnum:]_]|$)|/usr/bin/osascript'
# shellcheck disable=SC2016
NATIVE_ONLY_APPLE_EVENT_IMPORT_PATTERN='(^|[[:space:]])_?(AE[A-Z][[:lower:]][[:alnum:]_]*|OSA[A-Z][[:lower:]][[:alnum:]_]*|OBJC_(CLASS|METACLASS)_\$_NSAppleScript)([^[:alnum:]_]|$)'
NATIVE_ONLY_APPLE_EVENT_STRING_PATTERN='<key>NSAppleEventsUsageDescription</key>|NSAppleScript|NSUserAppleScriptTask|OSAKit\.framework|OSAScript|kOSAComponentType|/usr/bin/osascript'
# Exact Swift compiler metadata observed in signed Release artifacts. Keep this closed: every entry
# must be reproduced by an artifact fixture before it can bypass the dynamic API-name matcher.
NATIVE_ONLY_COMPILER_METADATA_STRING_PATTERN='^(AESgtGG|AESgtGGGSgtGG)$'
# `strings` also emits compiler metadata and symbol fragments. Match dynamic lookup names only when
# the entire string has an API shape. Apple Event APIs have a multi-letter verb (apart from Is/Do),
# while OSA names keep the original CamelCase boundary because the Release app has no OSA collision.
NATIVE_ONLY_DYNAMIC_APPLE_EVENT_STRING_PATTERN='^_?(AE([A-Z][[:lower:]]{2}[[:alnum:]_]*|(Is|Do)[A-Z][[:alnum:]_]*)|OSA[A-Z][[:lower:]][[:alnum:]_]*)$'

native_only_verify_macho() {
  local binary_path="$1"
  local label="$2"
  local nm_bin="$3"
  local strings_bin="$4"
  local undefined_symbols
  local embedded_strings

  if ! undefined_symbols="$("${nm_bin}" -u "${binary_path}" 2>/dev/null)"; then
    printf 'Could not inspect %s imports' "${label}"
    return 1
  fi
  if grep -Eq "${NATIVE_ONLY_APPLE_EVENT_IMPORT_PATTERN}" <<<"${undefined_symbols}"; then
    printf '%s imports an AppleScript or Apple Events execution API' "${label}"
    return 1
  fi

  if ! embedded_strings="$("${strings_bin}" -a "${binary_path}" 2>/dev/null)"; then
    printf 'Could not inspect %s embedded strings' "${label}"
    return 1
  fi
  if grep -Eq "${NATIVE_ONLY_APPLE_EVENT_STRING_PATTERN}" <<<"${embedded_strings}"; then
    printf '%s embeds an AppleScript or Apple Events execution surface' "${label}"
    return 1
  fi
  local inspected_strings
  inspected_strings="$(grep -Ev "${NATIVE_ONLY_COMPILER_METADATA_STRING_PATTERN}" <<<"${embedded_strings}" || true)"
  if grep -Eq "${NATIVE_ONLY_DYNAMIC_APPLE_EVENT_STRING_PATTERN}" <<<"${inspected_strings}"; then
    printf '%s embeds an AppleScript or Apple Events execution surface' "${label}"
    return 1
  fi
}
