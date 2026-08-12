#!/usr/bin/env bash

# Shared native-only policy for source and Mach-O inspection. Keep every release
# surface on the same fail-closed Apple Events and OSA boundary.
# shellcheck disable=SC2034
NATIVE_ONLY_APPLE_EVENT_SOURCE_PATTERN='NSAppleScript|NSUserAppleScriptTask|OSAKit|OSAScript|kOSAComponentType|(^|[^[:alnum:]_])(AE[A-Z][[:lower:]][[:alnum:]_]*|OSA[A-Z][[:lower:]][[:alnum:]_]*)([^[:alnum:]_]|$)|/usr/bin/osascript'
# shellcheck disable=SC2016
NATIVE_ONLY_APPLE_EVENT_IMPORT_PATTERN='(^|[[:space:]])_?(AE[A-Z][[:lower:]][[:alnum:]_]*|OSA[A-Z][[:lower:]][[:alnum:]_]*|OBJC_(CLASS|METACLASS)_\$_NSAppleScript)([^[:alnum:]_]|$)'
NATIVE_ONLY_APPLE_EVENT_STRING_PATTERN='<key>NSAppleEventsUsageDescription</key>|NSAppleScript|NSUserAppleScriptTask|OSAKit\.framework|OSAScript|kOSAComponentType|/usr/bin/osascript'
# `strings` also emits compiler metadata and symbol fragments. Match dynamic lookup names only when
# the entire string has an Apple Event Manager or OSA API shape with a documented API verb.
NATIVE_ONLY_DYNAMIC_APPLE_EVENT_STRING_PATTERN='^_?(AE(Build|Call|Check|Coerce|Compare|Count|Create|Decode|Delete|Desc|Determine|Dispose|Duplicate|Flatten|Get|Initialize|Install|Interact|Make|Manager|Object|Print|Process|Put|Remote|Remove|Replace|Reset|Resolve|Resume|Send|Set|Size|Stream|Suspend|Unflatten)[[:alnum:]_]*|OSA(Add|Available|Coerce|Compile|Component|Copy|Display|Dispose|Do|Execute|Generic|Get|Load|Make|Real|Remove|Script|Scripting|Set|Start|Stop|Store)[[:alnum:]_]*)$'

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
  if grep -Eq "${NATIVE_ONLY_APPLE_EVENT_STRING_PATTERN}" <<<"${embedded_strings}" ||
     grep -Eq "${NATIVE_ONLY_DYNAMIC_APPLE_EVENT_STRING_PATTERN}" <<<"${embedded_strings}"; then
    printf '%s embeds an AppleScript or Apple Events execution surface' "${label}"
    return 1
  fi
}
