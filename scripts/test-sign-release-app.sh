#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/peekaboo-release-app-signing-test.XXXXXX")"
TEST_DIR="$(realpath "$TEST_DIR")"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'test-sign-release-app: %s\n' "$*" >&2
  exit 1
}

write_plist() {
  local path="$1"
  local executable="$2"

  mkdir -p "$(dirname "$path")"
  cat >"$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>$executable</string></dict></plist>
EOF
}

write_macho() {
  local path="$1"

  mkdir -p "$(dirname "$path")"
  printf 'MACHO\n' >"$path"
  chmod 755 "$path"
}

make_fixture() {
  local app="$1"
  local version_root="$app/Contents/Frameworks/Sparkle.framework/Versions/B"

  mkdir -p \
    "$app/Contents/MacOS" \
    "$app/Contents/Resources" \
    "$version_root/Resources" \
    "$version_root/Updater.app/Contents/MacOS" \
    "$version_root/XPCServices/Downloader.xpc/Contents/MacOS" \
    "$version_root/XPCServices/Installer.xpc/Contents/MacOS"
  write_plist "$app/Contents/Info.plist" Peekaboo
  write_plist "$version_root/Resources/Info.plist" Sparkle
  write_plist "$version_root/Updater.app/Contents/Info.plist" Updater
  write_plist "$version_root/XPCServices/Downloader.xpc/Contents/Info.plist" Downloader
  write_plist "$version_root/XPCServices/Installer.xpc/Contents/Info.plist" Installer
  write_macho "$app/Contents/MacOS/Peekaboo"
  write_macho "$version_root/Autoupdate"
  write_macho "$version_root/Updater.app/Contents/MacOS/Updater"
  write_macho "$version_root/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
  write_macho "$version_root/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  write_macho "$version_root/Sparkle"
  write_macho "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
  printf 'resource\n' >"$app/Contents/Resources/plain resource.txt"
  ln -s B "$app/Contents/Frameworks/Sparkle.framework/Versions/Current"
  ln -s Versions/Current/Autoupdate "$app/Contents/Frameworks/Sparkle.framework/Autoupdate"
  ln -s Versions/Current/Updater.app "$app/Contents/Frameworks/Sparkle.framework/Updater.app"
  ln -s Versions/Current/XPCServices "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
  ln -s Versions/Current/Sparkle "$app/Contents/Frameworks/Sparkle.framework/Sparkle"
}

cat >"$TEST_DIR/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${!#}"
if [[ -f "$path" ]] && grep -Fqx MACHO "$path"; then
  printf 'Mach-O 64-bit executable arm64\n'
else
  printf 'data\n'
fi
EOF
chmod 755 "$TEST_DIR/file"

cat >"$TEST_DIR/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target="${!#}"
printf '%s\t' "$target" >>"$SIGN_TEST_LOG"
printf '<%s>' "$@" >>"$SIGN_TEST_LOG"
printf '\n' >>"$SIGN_TEST_LOG"

if [[ "${SIGN_TEST_FAIL_FRAMEWORK_ONCE:-0}" == 1 && "$target" == */Sparkle.framework ]]; then
  count=0
  [[ ! -f "$SIGN_TEST_FRAMEWORK_COUNT" ]] || count="$(<"$SIGN_TEST_FRAMEWORK_COUNT")"
  count=$((count + 1))
  printf '%s\n' "$count" >"$SIGN_TEST_FRAMEWORK_COUNT"
  if [[ "$count" == 1 ]]; then
    printf 'fixture: A timestamp was expected but was not found.\n' >&2
    exit 1
  fi
fi
EOF
chmod 755 "$TEST_DIR/codesign"

export MAC_RELEASE_FILE_BIN="$TEST_DIR/file"
export MAC_RELEASE_CODESIGN_BIN="$TEST_DIR/codesign"
export CODESIGN_TIMESTAMP_RETRY_ATTEMPTS=2
export CODESIGN_TIMESTAMP_RETRY_DELAY_SECONDS=0
export SIGN_TEST_LOG="$TEST_DIR/sign.log"
export SIGN_TEST_FRAMEWORK_COUNT="$TEST_DIR/framework-count"

identity='Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)'
timestamp_url='http://timestamp.apple.com/ts01'
entitlements="$TEST_DIR/release entitlements.plist"
printf '<plist version="1.0"><dict/></plist>\n' >"$entitlements"

app="$TEST_DIR/Product With Spaces/Peekaboo.app"
make_fixture "$app"
export SIGN_TEST_FAIL_FRAMEWORK_ONCE=1
"$ROOT_DIR/scripts/sign-release-app.sh" \
  --app "$app" \
  --entitlements "$entitlements" \
  --sign-identity "$identity" \
  --timestamp-url "$timestamp_url"

[[ "$(wc -l <"$SIGN_TEST_LOG" | tr -d ' ')" == 8 ]] || fail 'unexpected codesign invocation count'
count_target() {
  local target="$1"

  awk -F '\t' -v target="$target" '$1 == target { count += 1 } END { print count + 0 }' "$SIGN_TEST_LOG"
}

[[ "$(count_target "$app/Contents/Frameworks/Sparkle.framework")" == 2 ]] || \
  fail 'Sparkle.framework did not retry independently'
for target in \
  "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate" \
  "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
  "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc" \
  "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" \
  "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib" \
  "$app"; do
  [[ "$(count_target "$target")" == 1 ]] || fail "successful sibling was re-signed: $target"
done

cut -f1 "$SIGN_TEST_LOG" >"$TEST_DIR/actual-order"
cat >"$TEST_DIR/expected-order" <<EOF
$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate
$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc
$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc
$app/Contents/Frameworks/Sparkle.framework
$app/Contents/Frameworks/Sparkle.framework
$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib
$app
EOF
cmp -s "$TEST_DIR/expected-order" "$TEST_DIR/actual-order" || fail 'leaf-first signing order changed'

if grep -Fq '<--deep>' "$SIGN_TEST_LOG"; then
  fail 'signing still uses deprecated --deep'
fi
[[ "$(grep -Fc "<--timestamp=$timestamp_url>" "$SIGN_TEST_LOG")" == 8 ]] || fail 'timestamp URL changed'
[[ "$(grep -Fc '<--options><runtime>' "$SIGN_TEST_LOG")" == 8 ]] || fail 'hardened runtime option changed'
[[ "$(grep -Fc "<--sign><$identity>" "$SIGN_TEST_LOG")" == 8 ]] || fail 'Foundation signing identity changed'
[[ "$(grep -Fc "<--entitlements><$entitlements>" "$SIGN_TEST_LOG")" == 1 ]] || \
  fail 'entitlements must be applied exactly once'
tail -1 "$SIGN_TEST_LOG" | grep -Fq "<--entitlements><$entitlements>" || fail 'outer app was not signed with entitlements last'

assert_refused_without_signing() {
  local label="$1"
  local expected_error="$2"
  shift 2

  : >"$SIGN_TEST_LOG"
  if "$ROOT_DIR/scripts/sign-release-app.sh" "$@" >"$TEST_DIR/$label.out" 2>"$TEST_DIR/$label.err"; then
    fail "$label unexpectedly signed"
  fi
  grep -Fq "$expected_error" "$TEST_DIR/$label.err" || fail "$label returned the wrong refusal"
  [[ ! -s "$SIGN_TEST_LOG" ]] || fail "$label reached codesign before refusal"
}

symlink_source="$TEST_DIR/symlink source/Peekaboo.app"
make_fixture "$symlink_source"
symlink_app="$TEST_DIR/symlink input/Peekaboo.app"
mkdir -p "$(dirname "$symlink_app")"
ln -s "$symlink_source" "$symlink_app"
assert_refused_without_signing app-symlink 'symlinked' \
  --app "$symlink_app" --entitlements "$entitlements" --sign-identity "$identity" --timestamp-url "$timestamp_url"

file_app="$TEST_DIR/not an app.app"
printf 'not a directory\n' >"$file_app"
assert_refused_without_signing app-type 'not a directory' \
  --app "$file_app" --entitlements "$entitlements" --sign-identity "$identity" --timestamp-url "$timestamp_url"

leaf_symlink_app="$TEST_DIR/leaf symlink/Peekaboo.app"
make_fixture "$leaf_symlink_app"
leaf_autoupdate="$leaf_symlink_app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
mv "$leaf_autoupdate" "$leaf_autoupdate.real"
ln -s Autoupdate.real "$leaf_autoupdate"
assert_refused_without_signing leaf-symlink 'Expected exactly one physical Autoupdate' \
  --app "$leaf_symlink_app" --entitlements "$entitlements" --sign-identity "$identity" --timestamp-url "$timestamp_url"

duplicate_app="$TEST_DIR/duplicate/Peekaboo.app"
make_fixture "$duplicate_app"
mkdir -p "$duplicate_app/Contents/Frameworks/Sparkle.framework/Versions/A"
write_macho "$duplicate_app/Contents/Frameworks/Sparkle.framework/Versions/A/Autoupdate"
assert_refused_without_signing duplicate 'found 2' \
  --app "$duplicate_app" --entitlements "$entitlements" --sign-identity "$identity" --timestamp-url "$timestamp_url"

missing_app="$TEST_DIR/missing/Peekaboo.app"
make_fixture "$missing_app"
rm -rf "$missing_app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc"
assert_refused_without_signing missing 'Code bundle is missing' \
  --app "$missing_app" --entitlements "$entitlements" --sign-identity "$identity" --timestamp-url "$timestamp_url"

unknown_app="$TEST_DIR/unknown/Peekaboo.app"
make_fixture "$unknown_app"
write_macho "$unknown_app/Contents/Resources/rogue executable"
assert_refused_without_signing unknown 'Unknown Mach-O payload' \
  --app "$unknown_app" --entitlements "$entitlements" --sign-identity "$identity" --timestamp-url "$timestamp_url"

printf 'test-sign-release-app: ok\n'
