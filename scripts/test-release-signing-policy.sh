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
[[ "$NOTARYTOOL_KEYCHAIN_PROFILE" == "openclaw-foundation-release-20260714" ]]

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
