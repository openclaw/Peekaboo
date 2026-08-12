#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FOUNDATION_IDENTITY='Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)'
FOUNDATION_TEAM='FWJYW4S8P8'

pushd "$ROOT_DIR" >/dev/null
# shellcheck source=/Users/steipete/Projects/Peekaboo/.mac-release.env
source .mac-release.env
popd >/dev/null

[[ "$MAC_RELEASE_CODESIGN_IDENTITY" == "$FOUNDATION_IDENTITY" ]]
[[ "$MAC_RELEASE_CLI_CODESIGN_IDENTITY" == "$FOUNDATION_IDENTITY" ]]
[[ "$MAC_RELEASE_CLI_CODESIGN_TEAM_ID" == "$FOUNDATION_TEAM" ]]
[[ "$NOTARYTOOL_KEYCHAIN_PROFILE" == "openclaw-release" ]]

policy_files=(
  "$ROOT_DIR/.mac-release.env"
  "$ROOT_DIR/scripts/release-binaries.sh"
  "$ROOT_DIR/scripts/release-macos-app.sh"
  "$ROOT_DIR/scripts/create-release-dmg.sh"
  "$ROOT_DIR/Apps/Mac/Peekaboo.xcodeproj/project.pbxproj"
  "$ROOT_DIR/Apps/PeekabooInspector/Inspector.xcodeproj/project.pbxproj"
  "$ROOT_DIR/Apps/Playground/Playground.xcodeproj/project.pbxproj"
)

if rg -n 'Y5PE65HELJ|Developer ID Application: Peter Steinberger' "${policy_files[@]}"; then
  printf 'Personal signing identity remains in an active release-signing surface\n' >&2
  exit 1
fi

rg -Fq 'scripts/mac-release" codesign-run' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'NOTARYTOOL_KEYCHAIN_PROFILE' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'NOTARYTOOL_KEYCHAIN_PROFILE' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'NOTARYTOOL_KEYCHAIN_PROFILE' "$ROOT_DIR/scripts/create-release-dmg.sh"
rg -Fq -- '--check-notarization -R=notarized' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq -- '--check-notarization -R=notarized' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq -- '--check-notarization -R=notarized' "$ROOT_DIR/scripts/create-release-dmg.sh"
rg -Fq 'com.apple.security.get-task-allow' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'com.apple.security.automation.apple-events' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'native_only_verify_macho' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'native_only_verify_macho' "$ROOT_DIR/scripts/verify-native-only-app.sh"
rg -Fq 'verify-native-only-app.sh' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'verify-swift-runtime-libraries.sh' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq "grep -Fq 'unknown'" "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'libswiftCompatibility*.dylib' "$ROOT_DIR/package.json"
rg -Fq 'libswiftCompatibility*.dylib' "$ROOT_DIR/homebrew/peekaboo.rb"
rg -Fq -- '--options runtime' "$ROOT_DIR/scripts/copy-swift-runtime-libraries.sh"
rg -Fq 'MAC_RELEASE_CODESIGN_TEAM_ID' "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh"

for release_build in \
  "$ROOT_DIR/scripts/build-swift-arm.sh" \
  "$ROOT_DIR/scripts/build-swift-universal.sh"; do
  if rg -Fq -- '--entitlements' "$release_build"; then
    printf 'Release CLI build must not reuse debug entitlements: %s\n' "$release_build" >&2
    exit 1
  fi
done
rg -Fq -- '--entitlements "$ENTITLEMENTS_PATH"' "$ROOT_DIR/scripts/build-swift-debug.sh"
rg -Fq 'unexpectedly retains the AppleEvents entitlement' "$ROOT_DIR/scripts/release-macos-app.sh"

while IFS= read -r native_only_surface; do
  if rg -n 'NSAppleEventsUsageDescription|com\.apple\.security\.automation\.apple-events' \
    "$ROOT_DIR/$native_only_surface"; then
    printf 'Apple Events permission metadata remains in native-only surface: %s\n' "$native_only_surface" >&2
    exit 1
  fi
done < <(git -C "$ROOT_DIR" ls-files '*.plist' '*.entitlements' '*.pbxproj')

"$ROOT_DIR/scripts/verify-native-only-app.sh" --source-root "$ROOT_DIR"

# shellcheck source=scripts/native-only-policy.sh
source "$ROOT_DIR/scripts/native-only-policy.sh"
native_policy_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/peekaboo-native-policy-test.XXXXXX")"
trap 'rm -rf "$native_policy_test_dir"' EXIT
touch "$native_policy_test_dir/fixture"
cat >"$native_policy_test_dir/nm" <<'EOF'
#!/usr/bin/env bash
case "${NATIVE_ONLY_TEST_MODE:-safe}" in
  safe) printf '%s\n' '                 U _AES_cbc_encrypt' ;;
  ae) printf '%s\n' '                 U _AECreateDesc' ;;
  ae-send) printf '%s\n' '                 U _AESendMessage' ;;
  osa) printf '%s\n' '                 U _OSADoScript' ;;
  nm-fail) printf '%s\n' '                 U _harmless'; exit 86 ;;
esac
EOF
cat >"$native_policy_test_dir/strings" <<'EOF'
#!/usr/bin/env bash
case "${NATIVE_ONLY_TEST_MODE:-safe}" in
  safe) printf '%s\n' 'AES-GCM' ;;
  dynamic) printf '%s\n' 'AESendMessage' ;;
  strings-fail) printf '%s\n' 'harmless output'; exit 87 ;;
esac
EOF
chmod +x "$native_policy_test_dir/nm" "$native_policy_test_dir/strings"

export NATIVE_ONLY_TEST_MODE=safe
native_only_verify_macho \
  "$native_policy_test_dir/fixture" fixture \
  "$native_policy_test_dir/nm" "$native_policy_test_dir/strings"
for policy_case in ae ae-send osa dynamic nm-fail strings-fail; do
  export NATIVE_ONLY_TEST_MODE="$policy_case"
  if native_only_verify_macho \
    "$native_policy_test_dir/fixture" fixture \
    "$native_policy_test_dir/nm" "$native_policy_test_dir/strings" >/dev/null; then
    printf 'Native-only Mach-O policy allowed fixture case: %s\n' "$policy_case" >&2
    exit 1
  fi
done
unset NATIVE_ONLY_TEST_MODE

obsolete_binary=Apps/peekaboo
if git -C "$ROOT_DIR" ls-files --error-unmatch "$obsolete_binary" >/dev/null 2>&1; then
  printf 'Stale built binary remains tracked: %s\n' "$obsolete_binary" >&2
  exit 1
fi

for project in \
  "$ROOT_DIR/Apps/Mac/Peekaboo.xcodeproj/project.pbxproj" \
  "$ROOT_DIR/Apps/PeekabooInspector/Inspector.xcodeproj/project.pbxproj" \
  "$ROOT_DIR/Apps/Playground/Playground.xcodeproj/project.pbxproj"; do
  rg -Fq "DEVELOPMENT_TEAM = $FOUNDATION_TEAM;" "$project"
done

rg -Fq 'PRODUCT_BUNDLE_IDENTIFIER = boo.peekaboo.mac;' \
  "$ROOT_DIR/Apps/Mac/Peekaboo.xcodeproj/project.pbxproj"
rg -Fq 'PRODUCT_BUNDLE_IDENTIFIER = boo.peekaboo.inspector;' \
  "$ROOT_DIR/Apps/PeekabooInspector/Inspector.xcodeproj/project.pbxproj"
rg -Fq 'PRODUCT_BUNDLE_IDENTIFIER = boo.peekaboo.playground;' \
  "$ROOT_DIR/Apps/Playground/Playground.xcodeproj/project.pbxproj"

printf 'test-release-signing-policy: ok\n'
