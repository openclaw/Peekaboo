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
rg -Fq 'embeds NSAppleEventsUsageDescription' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'imports NSAppleScript' "$ROOT_DIR/scripts/release-binaries.sh"
rg -Fq 'embeds NSAppleEventsUsageDescription' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'imports NSAppleScript' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'verify-swift-runtime-libraries.sh' "$ROOT_DIR/scripts/release-binaries.sh"
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

if rg -n 'NSAppleScript' \
  "$ROOT_DIR/Apps" \
  "$ROOT_DIR/Core" \
  "$ROOT_DIR/AXorcist/Sources" \
  --glob '*.swift'; then
  printf 'Production Swift source still compiles NSAppleScript\n' >&2
  exit 1
fi

for obsolete_binary in Apps/peekaboo; do
  if git -C "$ROOT_DIR" ls-files --error-unmatch "$obsolete_binary" >/dev/null 2>&1; then
    printf 'Stale built binary remains tracked: %s\n' "$obsolete_binary" >&2
    exit 1
  fi
done

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
