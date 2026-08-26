#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FOUNDATION_IDENTITY='Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)'
FOUNDATION_TEAM='FWJYW4S8P8'

pushd "$ROOT_DIR" >/dev/null
NOTARYTOOL_KEYCHAIN_PROFILE=stale-inherited-profile
NOTARYTOOL_PROFILE=stale-inherited-profile
MAC_RELEASE_SPARKLE_OP_REF='op://Private/Fixture/private key'
export NOTARYTOOL_KEYCHAIN_PROFILE NOTARYTOOL_PROFILE MAC_RELEASE_SPARKLE_OP_REF
# shellcheck source=/Users/steipete/Projects/Peekaboo/.mac-release.env
source .mac-release.env
popd >/dev/null

[[ "$MAC_RELEASE_CODESIGN_IDENTITY" == "$FOUNDATION_IDENTITY" ]]
[[ "$MAC_RELEASE_CLI_CODESIGN_IDENTITY" == "$FOUNDATION_IDENTITY" ]]
[[ "$MAC_RELEASE_CLI_CODESIGN_TEAM_ID" == "$FOUNDATION_TEAM" ]]
[[ -z "${NOTARYTOOL_KEYCHAIN_PROFILE:-}" ]]
[[ -z "${NOTARYTOOL_PROFILE:-}" ]]
[[ "$MAC_RELEASE_OP_FIELDS" == *APP_STORE_CONNECT_KEY_ID* ]]
[[ "$MAC_RELEASE_OP_FIELDS" == *APP_STORE_CONNECT_ISSUER_ID* ]]
[[ "$MAC_RELEASE_OP_FIELDS" == *APP_STORE_CONNECT_API_KEY_P8* ]]
[[ "$MAC_RELEASE_SPARKLE_OP_REF" == 'op://Private/Fixture/private key' ]]
[[ "$MAC_RELEASE_SPARKLE_OP_USE_SERVICE_ACCOUNT" == 1 ]]

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
rg -Fq 'notarytool history' "$ROOT_DIR/scripts/notarize-terminal-artifact.sh"
rg -Fq -- '--no-s3-acceleration' "$ROOT_DIR/scripts/notarize-terminal-artifact.sh"
rg -Fq -- '--output-format json' "$ROOT_DIR/scripts/notarize-terminal-artifact.sh"
rg -Fq 'uv --no-config run --locked "$DMGBUILD_RUNNER"' "$ROOT_DIR/scripts/create-release-dmg.sh"
rg -Fq -- '-u APP_STORE_CONNECT_API_KEY_P8' "$ROOT_DIR/scripts/create-release-dmg.sh"
rg -Fq -- '-u NPM_TOKEN' "$ROOT_DIR/scripts/create-release-dmg.sh"
rg -Fq -- '-u OP_SERVICE_ACCOUNT_TOKEN' "$ROOT_DIR/scripts/create-release-dmg.sh"
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
rg -Fq -- '--reuse-built-cli' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'peekaboo_validate_artifact_source_commit' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq "verify_binary_artifact \\" "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'release-driver-contract.mjs' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'release-plan.json' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'github-release' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'npm-publication' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq '"repos/${GITHUB_API_REPOSITORY}/releases/tags/v${VERSION}"' \
  "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'ensure_github_release_tag' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq -- '--verify-tag' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq -- '-f "sha=${RELEASE_SOURCE_COMMIT}"' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'publication-receipt.pending.json' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'publication-receipt.final.json' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'validate_retained_pending_receipt' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'github_tag_commit' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'GITHUB_REPOSITORY=github.com/openclaw/Peekaboo' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq -- '--repo "$GITHUB_REPOSITORY"' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'NPM_REGISTRY=https://registry.npmjs.org' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'readonly GITHUB_HOST GITHUB_REPOSITORY GITHUB_API_REPOSITORY NPM_REGISTRY' \
  "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq -- '--registry "$NPM_REGISTRY"' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq '@steipete:registry=%s/' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq -- '--resume-publication' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'gh release upload "v${VERSION}" "${RELEASE_ASSETS[@]}"' \
  "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'npm_publication_exists' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'validate_npm_publish_attempt' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq -- '--retry-npm-publish' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq -- '--proof-file /path/to/reviewed-release-proof.md' "$ROOT_DIR/docs/building.md"
rg -Fq 'release/release-notes.md' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'PEEKABOO_RELEASE_SOURCE_COMMIT' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'PEEKABOO_RELEASE_SOURCE_COMMIT' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'MAC_RELEASE_EXPECTED_HELPER_EXECUTABLE_SHA256' "$ROOT_DIR/scripts/mac-release"
rg -Fq 'MAC_RELEASE_EXPECTED_HELPER_LIBRARY_SHA256' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'MAC_RELEASE_EXPECTED_HELPER_LIBRARY_SHA256="$RELEASE_HELPER_LIBRARY_SHA256"' \
  "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'appcast-entry.json' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'APPCAST_SNAPSHOT="$RELEASE_DIR/appcast.xml"' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'libswiftCompatibility*.dylib' "$ROOT_DIR/package.json"
rg -Fq 'libswiftCompatibility*.dylib' "$ROOT_DIR/homebrew/peekaboo.rb"
rg -Fq -- '--options runtime' "$ROOT_DIR/scripts/copy-swift-runtime-libraries.sh"
rg -Fq 'MAC_RELEASE_CODESIGN_TEAM_ID' "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh"
rg -Fq 'MAC_RELEASE_SPARKLE_OP_REF=${MAC_RELEASE_SPARKLE_OP_REF:-}' "$ROOT_DIR/.mac-release.env"
rg -Fq 'MAC_RELEASE_SPARKLE_OP_USE_SERVICE_ACCOUNT=${MAC_RELEASE_SPARKLE_OP_USE_SERVICE_ACCOUNT:-1}' \
  "$ROOT_DIR/.mac-release.env"
if rg -n 'Dropbox|MAC_RELEASE_SIGNING_KEY_FILE|MAC_RELEASE_SPARKLE_OP_REF=.*op://' \
  "$ROOT_DIR/.mac-release.env"; then
  printf 'Private or stale Sparkle locator remains in the public release manifest\n' >&2
  exit 1
fi
private_sparkle_item_pattern='Peekaboo Sparkle '"EdDSA"
if rg -n "$private_sparkle_item_pattern" \
  "$ROOT_DIR/.agents/skills/release-peekaboo/SKILL.md" \
  "$ROOT_DIR/docs/RELEASING.md" \
  "$ROOT_DIR/scripts/test-release-signing-policy.sh"; then
  printf 'App-specific Sparkle locator remains in a public release surface\n' >&2
  exit 1
fi

for timestamp_surface in \
  "$ROOT_DIR/scripts/build-swift-arm.sh" \
  "$ROOT_DIR/scripts/build-swift-universal.sh" \
  "$ROOT_DIR/scripts/copy-swift-runtime-libraries.sh" \
  "$ROOT_DIR/scripts/create-release-dmg.sh"; do
  rg -Fq 'http://timestamp.apple.com/ts01' "$timestamp_surface"
  rg -Fq 'codesign-with-retry.sh' "$timestamp_surface"
done
rg -Fq 'http://timestamp.apple.com/ts01' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'sign-release-app.sh' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'codesign-with-retry.sh' "$ROOT_DIR/scripts/sign-release-app.sh"
if rg -n -- 'codesign-with-retry\.sh.*--deep|--force[[:space:]]+--deep[[:space:]]+--options[[:space:]]+runtime' \
  "$ROOT_DIR/scripts/release-macos-app.sh" "$ROOT_DIR/scripts/sign-release-app.sh"; then
  printf 'Release app signing still uses deprecated retry-unsafe --deep signing\n' >&2
  exit 1
fi

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
  safe)
    printf '%s\n' \
      'AES-GCM' \
      'AESgtGG' \
      'AESgtGGGSgtGG' \
      '_AEQo__AGQo_' \
      '_AEQo__AGQo_t' \
      '_AEQo__SSQo_' \
      '_AEQo__SSQo_t' \
      'AppleScriptProbeCodingKeys' \
      '_appleScriptStatus' \
      '_appleScriptProbe' \
      'AppleScript probing is no longer supported; current operations use native macOS APIs' \
      'Avoid shell scripting or osascript pipelines during UI automation.'
    ;;
  dynamic-ae) printf '%s\n' 'AESendMessage' ;;
  dynamic-ae-create) printf '%s\n' 'AECreateDesc' ;;
  dynamic-ae-get) printf '%s\n' 'AEGetDescData' ;;
  dynamic-ae-install) printf '%s\n' 'AEInstallEventHandler' ;;
  dynamic-ae-make) printf '%s\n' 'AEMakeDesc' ;;
  dynamic-compiler-near-miss) printf '%s\n' 'AESgtGGX' 'AESgtGGGSgtGGX' ;;
  dynamic-osa-compile) printf '%s\n' 'OSACompile' ;;
  dynamic-osa) printf '%s\n' '_OSADoScript' ;;
  dynamic-osa-execute) printf '%s\n' 'OSAExecute' ;;
  dynamic-osa-show) printf '%s\n' 'OSAShowScriptingComponent' ;;
  strings-fail) printf '%s\n' 'harmless output'; exit 87 ;;
esac
EOF
chmod +x "$native_policy_test_dir/nm" "$native_policy_test_dir/strings"

export NATIVE_ONLY_TEST_MODE=safe
native_only_verify_macho \
  "$native_policy_test_dir/fixture" fixture \
  "$native_policy_test_dir/nm" "$native_policy_test_dir/strings"
for policy_case in \
  ae ae-send osa dynamic-ae dynamic-ae-create dynamic-ae-get dynamic-ae-install dynamic-ae-make \
  dynamic-compiler-near-miss dynamic-osa dynamic-osa-compile dynamic-osa-execute dynamic-osa-show \
  nm-fail strings-fail; do
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

helper_repo="$native_policy_test_dir/helper-repo"
helper_path="$helper_repo/skills/release-mac-app/scripts/mac-release"
helper_library="$helper_repo/skills/release-mac-app/scripts/lib/mac_release.sh"
mkdir -p "$(dirname "$helper_library")"
cat > "$helper_path" <<'EOF'
#!/bin/bash
printf 'fixture helper invoked\n'
EOF
printf 'fixture helper library\n' > "$helper_library"
chmod +x "$helper_path"
git -C "$helper_repo" init -q
git -C "$helper_repo" add .
git -C "$helper_repo" -c user.name=Peekaboo -c user.email=peekaboo@example.invalid \
  -c commit.gpgSign=false commit -q --no-gpg-sign -m fixture
helper_commit="$(git -C "$helper_repo" rev-parse HEAD)"
helper_sha="$(shasum -a 256 "$helper_path" | awk '{print $1}')"
helper_library_sha="$(shasum -a 256 "$helper_library" | awk '{print $1}')"
helper_output="$(MAC_RELEASE_TOOL="$helper_path" \
  MAC_RELEASE_EXPECTED_HELPER_COMMIT="$helper_commit" \
  MAC_RELEASE_EXPECTED_HELPER_EXECUTABLE_SHA256="$helper_sha" \
  MAC_RELEASE_EXPECTED_HELPER_LIBRARY_SHA256="$helper_library_sha" \
  "$ROOT_DIR/scripts/mac-release" fixture)"
[[ "$helper_output" == 'fixture helper invoked' ]]
if MAC_RELEASE_TOOL="$helper_path" \
  MAC_RELEASE_EXPECTED_HELPER_COMMIT="$helper_commit" \
  MAC_RELEASE_EXPECTED_HELPER_EXECUTABLE_SHA256="$(printf '0%.0s' {1..64})" \
  MAC_RELEASE_EXPECTED_HELPER_LIBRARY_SHA256="$helper_library_sha" \
  "$ROOT_DIR/scripts/mac-release" fixture >/dev/null 2>&1; then
  printf 'Release helper wrapper accepted a hash outside the frozen plan\n' >&2
  exit 1
fi

printf 'test-release-signing-policy: ok\n'
