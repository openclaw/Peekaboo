#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE_BIN="${MAC_RELEASE_FILE_BIN:-/usr/bin/file}"
PLISTBUDDY_BIN="${MAC_RELEASE_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
REALPATH_BIN="${MAC_RELEASE_REALPATH_BIN:-$(command -v realpath || true)}"

APP_BUNDLE=""
ENTITLEMENTS_PATH=""
SIGN_IDENTITY=""
TIMESTAMP_URL=""

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/sign-release-app.sh \
  --app <Peekaboo.app> \
  --entitlements <path> \
  --sign-identity <identity> \
  --timestamp-url <url>
EOF
}

while (($# > 0)); do
  case "$1" in
    --app)
      [[ "$#" -ge 2 ]] || fail '--app requires a path'
      APP_BUNDLE="$2"
      shift 2
      ;;
    --entitlements)
      [[ "$#" -ge 2 ]] || fail '--entitlements requires a path'
      ENTITLEMENTS_PATH="$2"
      shift 2
      ;;
    --sign-identity)
      [[ "$#" -ge 2 ]] || fail '--sign-identity requires a value'
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --timestamp-url)
      [[ "$#" -ge 2 ]] || fail '--timestamp-url requires a URL'
      TIMESTAMP_URL="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) fail "Unknown argument: $1" ;;
  esac
done

[[ -n "$APP_BUNDLE" ]] || fail '--app is required'
[[ -n "$ENTITLEMENTS_PATH" ]] || fail '--entitlements is required'
[[ -n "$SIGN_IDENTITY" ]] || fail '--sign-identity is required'
[[ -n "$TIMESTAMP_URL" ]] || fail '--timestamp-url is required'
[[ -n "$REALPATH_BIN" && -x "$REALPATH_BIN" ]] || fail 'realpath is required'
[[ -x "$FILE_BIN" ]] || fail "file tool is not executable: $FILE_BIN"
[[ -x "$PLISTBUDDY_BIN" ]] || fail "PlistBuddy is not executable: $PLISTBUDDY_BIN"
[[ -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || fail "App bundle is missing, not a directory, or symlinked: $APP_BUNDLE"
[[ -f "$ENTITLEMENTS_PATH" && ! -L "$ENTITLEMENTS_PATH" ]] || \
  fail "Entitlements are missing, not a regular file, or symlinked: $ENTITLEMENTS_PATH"
APP_BUNDLE="$($REALPATH_BIN "$APP_BUNDLE")"
ENTITLEMENTS_PATH="$($REALPATH_BIN "$ENTITLEMENTS_PATH")"

bundle_executable() {
  local bundle="$1"
  local info_plist="$2"
  local executable_name

  [[ -d "$bundle" && ! -L "$bundle" ]] || fail "Code bundle is missing, not a directory, or symlinked: $bundle"
  [[ -f "$info_plist" && ! -L "$info_plist" ]] || fail "Info.plist is missing or symlinked: $info_plist"
  executable_name="$($PLISTBUDDY_BIN -c 'Print :CFBundleExecutable' "$info_plist" 2>/dev/null || true)"
  [[ -n "$executable_name" && "$executable_name" != */* && "$executable_name" != '.' && "$executable_name" != '..' ]] || \
    fail "Invalid CFBundleExecutable in $info_plist"
  printf '%s/%s\n' "$bundle/Contents/MacOS" "$executable_name"
}

require_macho() {
  local path="$1"

  [[ -f "$path" && -x "$path" && ! -L "$path" ]] || \
    fail "Executable code is missing, not executable, or symlinked: $path"
  "$FILE_BIN" -b "$path" | grep -q 'Mach-O' || fail "Executable code is not Mach-O: $path"
}

require_only_match() {
  local root="$1"
  local kind="$2"
  local name="$3"
  local expected="$4"
  local -a matches=()
  local candidate

  while IFS= read -r -d '' candidate; do
    matches+=("$candidate")
  done < <(find -P "$root" -type "$kind" -name "$name" -print0)

  ((${#matches[@]} == 1)) || \
    fail "Expected exactly one physical $name under $root; found ${#matches[@]}"
  [[ "${matches[0]}" == "$expected" ]] || \
    fail "Unexpected physical $name location: ${matches[0]}"
}

require_link_target() {
  local link_path="$1"
  local expected="$2"
  local actual

  [[ -L "$link_path" ]] || fail "Expected Sparkle topology symlink: $link_path"
  actual="$($REALPATH_BIN "$link_path" 2>/dev/null || true)"
  [[ "$actual" == "$expected" ]] || fail "Sparkle topology symlink has an unexpected target: $link_path"
}

framework="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
[[ -d "$framework" && ! -L "$framework" ]] || fail "Sparkle.framework is missing, not a directory, or symlinked: $framework"
require_only_match "$APP_BUNDLE/Contents/Frameworks" d Sparkle.framework "$framework"

current_link="$framework/Versions/Current"
[[ -L "$current_link" ]] || fail "Sparkle current-version link is missing: $current_link"
version_root="$($REALPATH_BIN "$current_link" 2>/dev/null || true)"
[[ -d "$version_root" && ! -L "$version_root" ]] || fail "Sparkle current version is missing or symlinked: $version_root"
[[ "$version_root" == "$framework/Versions/"* && "$(dirname "$version_root")" == "$framework/Versions" ]] || \
  fail "Sparkle current version escapes its framework: $current_link"

autoupdate="$version_root/Autoupdate"
updater="$version_root/Updater.app"
downloader="$version_root/XPCServices/Downloader.xpc"
installer="$version_root/XPCServices/Installer.xpc"
sparkle_binary_name="$($PLISTBUDDY_BIN -c 'Print :CFBundleExecutable' "$version_root/Resources/Info.plist" 2>/dev/null || true)"
[[ -n "$sparkle_binary_name" && "$sparkle_binary_name" != */* && "$sparkle_binary_name" != '.' && \
  "$sparkle_binary_name" != '..' ]] || fail "Invalid Sparkle CFBundleExecutable: $version_root/Resources/Info.plist"
sparkle_binary="$version_root/$sparkle_binary_name"
compatibility_dylib="$APP_BUNDLE/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
main_executable="$(bundle_executable "$APP_BUNDLE" "$APP_BUNDLE/Contents/Info.plist")"
updater_executable="$(bundle_executable "$updater" "$updater/Contents/Info.plist")"
downloader_executable="$(bundle_executable "$downloader" "$downloader/Contents/Info.plist")"
installer_executable="$(bundle_executable "$installer" "$installer/Contents/Info.plist")"

require_only_match "$framework/Versions" f Autoupdate "$autoupdate"
require_only_match "$framework/Versions" d Updater.app "$updater"
require_only_match "$framework/Versions" d Downloader.xpc "$downloader"
require_only_match "$framework/Versions" d Installer.xpc "$installer"
require_only_match "$framework/Versions" f "$sparkle_binary_name" "$sparkle_binary"
require_only_match "$APP_BUNDLE/Contents/Frameworks" f libswiftCompatibilitySpan.dylib "$compatibility_dylib"

require_link_target "$framework/Autoupdate" "$autoupdate"
require_link_target "$framework/Updater.app" "$updater"
require_link_target "$framework/XPCServices" "$version_root/XPCServices"
require_link_target "$framework/Sparkle" "$sparkle_binary"

expected_macho_paths=(
  "$main_executable"
  "$autoupdate"
  "$updater_executable"
  "$downloader_executable"
  "$installer_executable"
  "$sparkle_binary"
  "$compatibility_dylib"
)
for expected_macho in "${expected_macho_paths[@]}"; do
  require_macho "$expected_macho"
done

mach_o_count=0
while IFS= read -r -d '' candidate; do
  file_description="$($FILE_BIN -b "$candidate" 2>/dev/null || true)"
  if grep -q 'Mach-O' <<<"$file_description"; then
    known=false
    for expected_macho in "${expected_macho_paths[@]}"; do
      if [[ "$candidate" == "$expected_macho" ]]; then
        known=true
        break
      fi
    done
    [[ "$known" == true ]] || fail "Unknown Mach-O payload refuses release signing: $candidate"
    mach_o_count=$((mach_o_count + 1))
  elif [[ -x "$candidate" ]]; then
    fail "Unknown executable payload refuses release signing: $candidate"
  fi
done < <(find -P "$APP_BUNDLE/Contents" -type f -print0)
((mach_o_count == ${#expected_macho_paths[@]})) || \
  fail "Executable-code inventory mismatch: expected ${#expected_macho_paths[@]}, found $mach_o_count"

sign_leaf() {
  "$ROOT_DIR/scripts/codesign-with-retry.sh" \
    --force \
    --options runtime \
    --timestamp="$TIMESTAMP_URL" \
    --sign "$SIGN_IDENTITY" \
    "$1"
}

# Sparkle's standalone tool and bundles must be sealed before their containing framework.
# Each call owns its own timestamp retry so a transient leaf failure cannot invalidate or re-sign siblings.
sign_leaf "$autoupdate"
sign_leaf "$updater"
sign_leaf "$downloader"
sign_leaf "$installer"
sign_leaf "$framework"
sign_leaf "$compatibility_dylib"

"$ROOT_DIR/scripts/codesign-with-retry.sh" \
  --force \
  --options runtime \
  --timestamp="$TIMESTAMP_URL" \
  --entitlements "$ENTITLEMENTS_PATH" \
  --sign "$SIGN_IDENTITY" \
  "$APP_BUNDLE"
