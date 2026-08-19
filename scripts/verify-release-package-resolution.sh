#!/usr/bin/env bash

set -euo pipefail

JQ_BIN="${MAC_RELEASE_JQ_BIN:-$(command -v jq || true)}"
GIT_BIN="${MAC_RELEASE_GIT_BIN:-$(command -v git || true)}"
PLISTBUDDY_BIN="${MAC_RELEASE_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"

SOURCE_ROOT=""
DERIVED_DATA_PATH=""
APP_BUNDLE=""

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/verify-release-package-resolution.sh \
  --source-root <repo> \
  --derived-data <path> \
  --app <Peekaboo.app>
EOF
}

while (($# > 0)); do
  case "$1" in
    --source-root)
      [[ "$#" -ge 2 ]] || fail '--source-root requires a path'
      SOURCE_ROOT="$2"
      shift 2
      ;;
    --derived-data)
      [[ "$#" -ge 2 ]] || fail '--derived-data requires a path'
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    --app)
      [[ "$#" -ge 2 ]] || fail '--app requires a path'
      APP_BUNDLE="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$SOURCE_ROOT" ]] || fail '--source-root is required'
[[ -n "$DERIVED_DATA_PATH" ]] || fail '--derived-data is required'
[[ -n "$APP_BUNDLE" ]] || fail '--app is required'
[[ -x "$JQ_BIN" ]] || fail 'jq is required'
[[ -x "$GIT_BIN" ]] || fail 'git is required'
[[ -x "$PLISTBUDDY_BIN" ]] || fail "PlistBuddy is not executable: $PLISTBUDDY_BIN"

workspace_lock="$SOURCE_ROOT/Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved"
cli_lock="$SOURCE_ROOT/Apps/CLI/Package.resolved"
[[ -f "$workspace_lock" && ! -L "$workspace_lock" ]] || \
  fail "Canonical workspace package lock is missing or symlinked: $workspace_lock"
if [[ -e "$cli_lock" || -L "$cli_lock" ]]; then
  # SwiftPM tests may create this package-local lock. Xcode must still prove the selected checkout
  # against the higher-precedence workspace lock below, so only a well-formed regular file is tolerated.
  [[ -f "$cli_lock" && ! -L "$cli_lock" ]] || fail "Ignored CLI package lock is not a regular file: $cli_lock"
  "$JQ_BIN" -e '.version == 3 and (.pins | type == "array")' "$cli_lock" >/dev/null || \
    fail "Ignored CLI package lock is malformed: $cli_lock"
fi

sparkle_pin_count="$($JQ_BIN '[.pins[] | select(.identity == "sparkle")] | length' "$workspace_lock")"
[[ "$sparkle_pin_count" == 1 ]] || fail "Canonical workspace lock must contain exactly one Sparkle pin: $workspace_lock"
expected_version="$($JQ_BIN -er '.pins[] | select(.identity == "sparkle") | .state.version' "$workspace_lock")"
expected_revision="$($JQ_BIN -er '.pins[] | select(.identity == "sparkle") | .state.revision' "$workspace_lock")"
[[ "$expected_revision" =~ ^[0-9a-f]{40}$ ]] || fail "Canonical Sparkle revision is not a full commit: $expected_revision"

sparkle_info="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/Current/Resources/Info.plist"
[[ -f "$sparkle_info" && ! -L "$sparkle_info" ]] || fail "Embedded Sparkle Info.plist is missing or symlinked: $sparkle_info"
embedded_version="$($PLISTBUDDY_BIN -c 'Print :CFBundleShortVersionString' "$sparkle_info" 2>/dev/null || true)"
[[ "$embedded_version" == "$expected_version" ]] || \
  fail "Embedded Sparkle version '$embedded_version' does not match locked version '$expected_version'"

sparkle_checkout="$DERIVED_DATA_PATH/SourcePackages/checkouts/Sparkle"
[[ -d "$sparkle_checkout" && ! -L "$sparkle_checkout" ]] || \
  fail "Pinned Sparkle checkout is missing or symlinked: $sparkle_checkout"
actual_revision="$($GIT_BIN -C "$sparkle_checkout" rev-parse HEAD 2>/dev/null || true)"
[[ "$actual_revision" == "$expected_revision" ]] || \
  fail "Sparkle checkout revision '$actual_revision' does not match locked revision '$expected_revision'"

printf 'Verified release package resolution: Sparkle %s (%s)\n' "$expected_version" "$expected_revision"
