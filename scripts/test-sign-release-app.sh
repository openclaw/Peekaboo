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
  chmod "${2:-755}" "$path"
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

if [[ "${SIGN_TEST_TERMINAL:-0}" == 1 ]]; then
  architecture=default
  previous=''
  for argument in "$@"; do
    [[ "$previous" != --arch ]] || architecture="$argument"
    previous="$argument"
  done
  case "$1" in
    --force) printf '%s\n' "$target" >> "$SIGN_TEST_STATE"; exit 0 ;;
    --verify|-dvvv) ;;
    *) exit 92 ;;
  esac
  signature_target="$target"
  case "$target" in
    */Contents/MacOS/Peekaboo|*/Contents/MacOS/Playground)
      signature_target="${target%/Contents/MacOS/*}" ;;
    */Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle)
      signature_target="${target%/Versions/B/Sparkle}" ;;
    */Contents/MacOS/Updater|*/Contents/MacOS/Downloader|*/Contents/MacOS/Installer)
      signature_target="${target%/Contents/MacOS/*}" ;;
  esac
  signature=foundation
  grep -Fxq "$signature_target" "$SIGN_TEST_STATE" || signature=adhoc
  if [[ "$target" == */Contents/MacOS/Playground.debug.dylib &&
    "$architecture" == "${SIGN_TEST_BAD_ARCH:-none}" ]]; then
    signature="$SIGN_TEST_BAD_SIGNATURE"
  fi
  # Outer deep/strict and leaf requirement checks deliberately pass except for
  # the explicit failure case; displayed slice identity is an independent gate.
  if [[ "$1" == --verify ]]; then
    [[ "$signature" != verify-failure ]]
    exit $?
  fi
  [[ "$signature" != inspect-failure ]] || exit 93
  case "${target##*/}" in
    peekaboo-certification-controller) identifier=boo.peekaboo.peekaboo-certification-controller ;;
    background-computer-use-probe) identifier=boo.peekaboo.background-computer-use-probe ;;
    node) identifier=boo.peekaboo.qualification-node ;;
    *) identifier=boo.peekaboo.peekaboo ;;
  esac
  printf 'Identifier=%s\nCDHash=0123456789abcdef0123456789abcdef01234567\n' "$identifier"
  case "$signature" in
    adhoc) printf 'Signature=adhoc\nTeamIdentifier=not set\n' ;;
    wrong-team) printf 'Authority=Developer ID Application: Other (OTHERTEAM1)\nTeamIdentifier=OTHERTEAM1\n' ;;
    *) printf 'Authority=Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)\nTeamIdentifier=FWJYW4S8P8\n' ;;
  esac
  exit 0
fi

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

# Exercise the complete terminal signing phase with inert tools and source-stage
# guards. Load its existing functions without running the credentialed entrypoint;
# no production override or exported test API is needed.
terminal_root="$TEST_DIR/terminal-owner"
mkdir -p "$terminal_root/scripts" "$terminal_root/Apps/Mac/Peekaboo"
cp "$entitlements" "$terminal_root/Apps/Mac/Peekaboo/Peekaboo.entitlements"
cp "$ROOT_DIR/scripts/sign-release-app.sh" "$ROOT_DIR/scripts/codesign-with-retry.sh" "$terminal_root/scripts/"
awk '
  /^EXPECTED_(IDENTITY|TEAM_ID|REQUIREMENT)=|^TIMESTAMP_URL=/ { print }
  /^(fail|verify_foundation_signature|architecture_cdhashes_json|node_arch_cdhashes_json|sign_leaf|sign_code_phase)\(\) \{/ {
    printing = 1
  }
  printing { print }
  printing && /^\}$/ { printing = 0 }
' "$ROOT_DIR/scripts/build-terminal-artifacts.sh" > "$TEST_DIR/terminal-functions.sh"

cat > "$terminal_root/scripts/read-macho-info-plist.sh" <<'EOF'
#!/bin/bash
printf 'fixture-source\n'
EOF
cat > "$terminal_root/scripts/verify-swift-runtime-libraries.sh" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$terminal_root/scripts/verify-native-only-app.sh" <<'EOF'
#!/bin/bash
printf 'native-only %s\n' "$2" >> "$SIGN_TEST_POLICY_LOG"
EOF
cat > "$terminal_root/scripts/atomic-rename-exclusive.rb" <<'EOF'
#!/bin/bash
[[ ! -e "$2" ]] || exit 94
exec /bin/mv "$1" "$2"
EOF
chmod 755 "$terminal_root/scripts/"*

cat > "$TEST_DIR/terminal-runner.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
source "$SIGN_TEST_REPO_ROOT/scripts/terminal-artifact-policy.sh"
source "$TEST_DIR/terminal-functions.sh"
ROOT_DIR="$TEST_DIR/terminal-owner"
STAGE_DIR="$SIGN_TEST_CASE_ROOT"
BUILD_MANIFEST="$STAGE_DIR/build.json"
SOURCE_COMMIT=fixture-source
UNSIGNED_CLI="$STAGE_DIR/unsigned/cli"
UNSIGNED_APP="$STAGE_DIR/unsigned/Peekaboo.app"
UNSIGNED_PLAYGROUND="$STAGE_DIR/unsigned/Playground.app"
UNSIGNED_NODE="$STAGE_DIR/unsigned/PeekabooQualificationNode.app"
UNSIGNED_CONTROLLER="$STAGE_DIR/unsigned/qualification/peekaboo-certification-controller"
SIGNED_ROOT="$STAGE_DIR/signed"
MAC_RELEASE_CODESIGN_IDENTITY="$EXPECTED_IDENTITY"
export MAC_RELEASE_CODESIGN_IDENTITY
# External boundaries only: no compiler, credential, native product, real
# codesign, or operator source-stage validation runs in this contract fixture.
assert_clean_phase_environment() { :; }
require_clean_source() { :; }
record_toolchain() { :; }
set_stage_paths() { :; }
verify_unsigned_stage() { :; }
tree_digest() { printf 'fixture-tree\n'; }
verify_playground_manifest() { :; }
verify_node_source_manifest() { :; }
verify_node_entitlements() { :; }
native_only_verify_macho() { :; }
terminal_artifact_assert_no_xattrs() { :; }
/usr/bin/ditto() { cp -pR "$1" "$2"; }
/usr/bin/file() { "$TEST_DIR/file" "$@"; }
/usr/bin/codesign() { "$TEST_DIR/codesign" "$@"; }
/usr/bin/lipo() {
  [[ "$1" == -archs && -f "$2" ]] || return 95
  grep -Fqx MACHO "$2" || return 95
  printf 'arm64 x86_64\n'
}
sign_code_phase
EOF
export TEST_DIR SIGN_TEST_REPO_ROOT="$ROOT_DIR" SIGN_TEST_TERMINAL=1
export SIGN_TEST_FAIL_FRAMEWORK_ONCE=0
terminal_failures=0
for library_mode in 700 644; do
  case_root="$TEST_DIR/terminal-$library_mode"
  unsigned="$case_root/unsigned"
  make_fixture "$unsigned/Peekaboo.app"
  write_macho "$unsigned/cli/peekaboo"
  write_macho "$unsigned/cli/libswiftCompatibilitySpan.dylib"
  playground="$unsigned/Playground.app"
  write_plist "$playground/Contents/Info.plist" Playground
  write_macho "$playground/Contents/MacOS/Playground" 700
  write_macho "$playground/Contents/MacOS/Playground.debug.dylib" "$library_mode"
  write_macho "$playground/Contents/MacOS/__preview.dylib" "$library_mode"
  write_macho "$playground/Contents/Frameworks/libswiftCompatibilitySpan.dylib"
  mkdir -p "$playground/Contents/Resources"
  for resource_mode in 700 644; do
    printf 'resource\n' > "$playground/Contents/Resources/plain $resource_mode.dylib"
    chmod "$resource_mode" "$playground/Contents/Resources/plain $resource_mode.dylib"
  done
  write_macho "$unsigned/PeekabooQualificationNode.app/Contents/MacOS/node"
  write_macho "$unsigned/qualification/peekaboo-certification-controller"
  write_macho "$unsigned/qualification/background-computer-use-probe"
  write_macho "$unsigned/qualification/libswiftCompatibilitySpan.dylib"
  jq -n '{build_mode:"production", unsigned_inputs: {
    cli_inventory_sha256:"fixture-tree", peekaboo_inventory_sha256:"fixture-tree",
    playground_inventory_sha256:"fixture-tree", qualification_node_inventory_sha256:"fixture-tree",
    qualification_inventory_sha256:"fixture-tree"}}' > "$case_root/build.json"

  for fault in clean wrong-team:arm64 wrong-team:x86_64 adhoc:arm64 adhoc:x86_64 \
    verify-failure:x86_64 inspect-failure:x86_64 nested.app nested.framework nested.xpc; do
    export SIGN_TEST_CASE_ROOT="$case_root" SIGN_TEST_LOG="$case_root/sign.log"
    export SIGN_TEST_STATE="$case_root/signed-targets" SIGN_TEST_POLICY_LOG="$case_root/policy.log"
    export SIGN_TEST_BAD_SIGNATURE="${fault%:*}" SIGN_TEST_BAD_ARCH="${fault#*:}"
    : > "$SIGN_TEST_LOG"
    : > "$SIGN_TEST_STATE"
    : > "$SIGN_TEST_POLICY_LOG"
    case "$fault" in nested.*) mkdir "$playground/Contents/$fault" ;; esac
    phase_exit=0
    /bin/bash --noprofile --norc "$TEST_DIR/terminal-runner.sh" > "$case_root/output" 2>&1 || phase_exit=$?
    if [[ "$fault" == clean ]]; then
      if [[ "$phase_exit" != 0 || ! -d "$case_root/signed" ]]; then
        cat "$case_root/output" >&2
        fail "terminal mode=$library_mode signing phase failed (exit=$phase_exit)"
      fi
      for relative in Contents/MacOS/Playground.debug.dylib Contents/MacOS/__preview.dylib \
        Contents/Frameworks/libswiftCompatibilitySpan.dylib; do
        leaf_line="$(grep -nF "/Playground.app/$relative"$'\t''<--force>' "$SIGN_TEST_LOG" | cut -d: -f1 || true)"
        outer_line="$(grep -nF '/Playground.app'$'\t''<--force>' "$SIGN_TEST_LOG" | cut -d: -f1)"
        if [[ -z "$leaf_line" ]]; then
          printf 'FAIL terminal mode=%s: missed Mach-O signing: %s (phase exit=%s)\n' \
            "$library_mode" "$relative" "$phase_exit" >&2
          terminal_failures=$((terminal_failures + 1))
        else
          [[ "$leaf_line" -lt "$outer_line" ]] || fail 'terminal library was not signed before its outer app'
        fi
        for architecture in arm64 x86_64; do
          if ! grep -Fq "/Playground.app/$relative"$'\t'"<-dvvv><--arch><$architecture>" "$SIGN_TEST_LOG"; then
            printf 'FAIL terminal mode=%s: missed %s identity inspection: %s\n' \
              "$library_mode" "$architecture" "$relative" >&2
            terminal_failures=$((terminal_failures + 1))
          fi
        done
      done
      if grep -F '/Playground.app/Contents/MacOS/Playground'$'\t''<--force>' "$SIGN_TEST_LOG" || \
        grep -F '/Playground.app/Contents/Resources/' "$SIGN_TEST_LOG"; then
        fail 'terminal owner separately signed its main executable or inspected/signed a non-Mach-O resource'
      fi
      while IFS= read -r -d '' original; do
        signed="$case_root/signed/Playground.app/${original#"$playground/"}"
        cmp -s "$original" "$signed" || fail 'inert signing changed source-bound payload bytes'
        [[ "$(stat -f%Lp "$original")" == "$(stat -f%Lp "$signed")" ]] || fail 'terminal signing changed payload permissions'
      done < <(find "$playground" -type f -print0)
      [[ "$(wc -l < "$SIGN_TEST_POLICY_LOG" | tr -d ' ')" == 3 ]] || fail 'terminal native-only app gate was skipped'
      printf 'terminal mode=%s clean phase exit=%s; checked signing order, slice inspections, resources, bytes and modes\n' \
        "$library_mode" "$phase_exit"
    else
      case "$fault" in
        nested.*) expected_error='unsupported Playground nested bundle:' ;;
        *) expected_error="Mach-O $SIGN_TEST_BAD_ARCH signer mismatch:" ;;
      esac
      if [[ "$phase_exit" != 1 || -e "$case_root/signed" ]] || ! grep -Fq "$expected_error" "$case_root/output"; then
        printf 'FAIL terminal mode=%s fault=%s: expected refusal before signed snapshot, actual exit=%s\n' \
          "$library_mode" "$fault" "$phase_exit" >&2
        terminal_failures=$((terminal_failures + 1))
      else
        case "$fault" in
          nested.*) ;;
          *) grep -Fq '/Playground.app'$'\t''<--verify><--deep><--strict>' "$SIGN_TEST_LOG" || \
            fail 'nested identity refusal did not follow successful outer deep/strict verification' ;;
        esac
        printf 'terminal mode=%s fault=%s refused exit=%s (%s)\n' \
          "$library_mode" "$fault" "$phase_exit" "$expected_error"
      fi
    fi
    # Only task-owned synthetic output is removed between table rows.
    rm -rf "$case_root/signed"
    case "$fault" in nested.*) rmdir "$playground/Contents/$fault" ;; esac
  done
done
[[ "$terminal_failures" == 0 ]] || fail "$terminal_failures terminal signing assertions failed"

printf 'test-sign-release-app: ok\n'
