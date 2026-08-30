#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"
for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do unset "$secret_name"; done
TEST_DIR="$(mktemp -d /tmp/peekaboo-playground-artifact-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
FIXTURE_ROOT="$TEST_DIR/repo"
OUTPUT_APP="$TEST_DIR/output/Playground.app"
ARG_LOG="$TEST_DIR/xcodebuild.args"

fail() {
  printf 'test-build-playground-artifact: %s\n' "$*" >&2
  exit 1
}

mkdir -p \
  "$FIXTURE_ROOT/scripts" \
  "$FIXTURE_ROOT/Apps/Playground/Fixture" \
  "$FIXTURE_ROOT/Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm"
cp "$ROOT_DIR/scripts/build-playground-artifact.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/source-provenance.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/test-background-computer-use.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/terminal-artifact-env.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/package.json" "$FIXTURE_ROOT/"
printf '<Workspace version="1.0"/>\n' > "$FIXTURE_ROOT/Apps/Peekaboo.xcworkspace/contents.xcworkspacedata"
printf 'fixture\n' > "$FIXTURE_ROOT/Apps/Playground/Fixture/source.txt"
cat > "$FIXTURE_ROOT/Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved" <<'EOF'
{"pins":[{"identity":"fixture","kind":"remoteSourceControl","location":"https://example.invalid/fixture","state":{"revision":"0123456789abcdef0123456789abcdef01234567","version":"1.0.0"}}],"version":3}
EOF

git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" config user.name 'Peekaboo Test'
git -C "$FIXTURE_ROOT" config user.email 'peekaboo-test@example.invalid'
git -C "$FIXTURE_ROOT" add .
git -C "$FIXTURE_ROOT" commit -qm fixture

cat > "$TEST_DIR/xcodebuild" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${FIXTURE_ROOT:?}/scripts/terminal-artifact-env.sh"
terminal_artifact_assert_build_env_is_clean
if [[ "${1:-}" == -version ]]; then
  printf 'Xcode Fixture\nBuild version Fixture\n'
  exit 0
fi
if [[ "${FIXTURE_VERIFY_ONLY:-0}" == 1 ]]; then
  echo 'unexpected build' >> "${FIXTURE_FORBIDDEN_LOG:?}"
  exit 90
fi
printf '%s\n' "$@" > "${ARG_LOG:?}"
derived_data=
configuration=Debug
while (($# > 0)); do
  case "$1" in
    -derivedDataPath) derived_data="$2"; shift 2 ;;
    -configuration) configuration="$2"; shift 2 ;;
    *) shift ;;
  esac
done
app="$derived_data/Build/Products/$configuration/Playground.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/_CodeSignature"
printf 'synthetic signature resource seal\n' > "$app/Contents/_CodeSignature/CodeResources"
printf 'fixture resource\n' > "$app/Contents/Resources/fixture.txt"
ln -s fixture.txt "$app/Contents/Resources/fixture-link"
/usr/bin/xattr -w boo.peekaboo.fixture synthetic "$app/Contents/Resources/fixture.txt"
cp /usr/bin/true "$app/Contents/MacOS/Playground"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Playground</string>
<key>CFBundleIdentifier</key><string>boo.peekaboo.playground.debug</string>
<key>CFBundleShortVersionString</key><string>$(/usr/bin/plutil -extract version raw -o - "$FIXTURE_ROOT/package.json")</string>
</dict></plist>
PLIST
EOF
chmod 755 "$TEST_DIR/xcodebuild"

mkdir -p "$TEST_DIR/Developer"
cat > "$TEST_DIR/xcode-select" <<'EOF'
#!/bin/bash
[[ "$*" == -p ]] || exit 90
printf '%s\n' "$FIXTURE_DEVELOPER_DIR"
EOF
cat > "$TEST_DIR/xcrun" <<'EOF'
#!/bin/bash
case "$*" in
  '--sdk macosx --show-sdk-version') printf '99.0\n' ;;
  'swiftc --version') printf 'Apple Swift Fixture\nTarget: fixture\n' ;;
  *) exit 90 ;;
esac
EOF
chmod 755 "$TEST_DIR/xcode-select" "$TEST_DIR/xcrun"
export FIXTURE_DEVELOPER_DIR="$(realpath "$TEST_DIR/Developer")"
export DEVELOPER_DIR="$FIXTURE_DEVELOPER_DIR"
export PLAYGROUND_XCRUN_BIN="$TEST_DIR/xcrun"
export PLAYGROUND_XCODE_SELECT_BIN="$TEST_DIR/xcode-select"

export FIXTURE_ROOT ARG_LOG
export APP_STORE_CONNECT_API_KEY_P8=secret
export MAC_RELEASE_SPARKLE_OP_REF=secret
export OP_SERVICE_ACCOUNT_TOKEN=secret
if PLAYGROUND_XCODEBUILD_BIN="$TEST_DIR/xcodebuild" \
  PEEKABOO_TERMINAL_TEST_MODE=1 \
  "$FIXTURE_ROOT/scripts/build-playground-artifact.sh" \
  --output-app "$OUTPUT_APP" >/dev/null 2>&1; then
  fail 'direct credentialed build unexpectedly succeeded'
fi
terminal_artifact_run_build env \
  PLAYGROUND_XCODEBUILD_BIN="$TEST_DIR/xcodebuild" \
  PEEKABOO_TERMINAL_TEST_MODE=1 \
  "$FIXTURE_ROOT/scripts/build-playground-artifact.sh" \
  --output-app "$OUTPUT_APP" >/dev/null
for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do unset "$secret_name"; done

manifest="$OUTPUT_APP/Contents/Resources/PeekabooPlaygroundSource.json"
lock_sha="$(shasum -a 256 \
  "$FIXTURE_ROOT/Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved" | awk '{print $1}')"
jq -e --arg lockSHA "$lock_sha" '
  type == "object" and keys == [
    "bundle_identifier", "configuration", "dependency_lock_path", "dependency_lock_sha256",
    "developer_dir", "marketing_version", "scheme", "sdk_version", "source_commit",
    "source_tree", "swiftc_version", "version", "workspace", "xcodebuild_version"
  ] and
  .version == 2 and
  .dependency_lock_path == "Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved" and
  .dependency_lock_sha256 == $lockSHA and
  .workspace == "Apps/Peekaboo.xcworkspace" and
  .scheme == "Playground" and
  .configuration == "Debug" and
  .bundle_identifier == "boo.peekaboo.playground.debug" and
  (.source_commit | test("^[0-9a-f]{40}$")) and
  (.source_tree | test("^[0-9a-f]{40}$"))
' "$manifest" >/dev/null || fail 'embedded provenance manifest violates schema v2'

for required_arg in \
  -workspace \
  "$FIXTURE_ROOT/Apps/Peekaboo.xcworkspace" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  CODE_SIGNING_ALLOWED=NO; do
  grep -Fxq -- "$required_arg" "$ARG_LOG" || fail "xcodebuild omitted $required_arg"
done

# Exercise the canonical wrapper without running the terminal orchestrator.
source "$ROOT_DIR/scripts/source-provenance.sh"
eval "$(sed -n '/^verify_playground_manifest() {/,/^}/p' "$ROOT_DIR/scripts/build-terminal-artifacts.sh")"
SOURCE_COMMIT="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
CANONICAL_LOCK_RELATIVE=Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved
DEPENDENCY_LOCK_SHA256="$lock_sha"
VERSION="$(/usr/bin/plutil -extract version raw -o - "$FIXTURE_ROOT/package.json")"
EFFECTIVE_DEVELOPER_DIR="$FIXTURE_DEVELOPER_DIR"
XCODEBUILD_VERSION="$($TEST_DIR/xcodebuild -version)"
SDK_VERSION="$($TEST_DIR/xcrun --sdk macosx --show-sdk-version)"
SWIFTC_VERSION="$($TEST_DIR/xcrun swiftc --version)"
(ROOT_DIR="$FIXTURE_ROOT"; verify_playground_manifest "$OUTPUT_APP") || fail 'canonical terminal rejected producer v2'
printf 'canonical terminal wrapper accepted unchanged producer v2\n'

caller_derived="$TEST_DIR/caller-derived"
PLAYGROUND_XCODEBUILD_BIN="$TEST_DIR/xcodebuild" PEEKABOO_TERMINAL_TEST_MODE=1 \
  "$FIXTURE_ROOT/scripts/build-playground-artifact.sh" \
  --derived-data "$caller_derived" --output-app "$TEST_DIR/output-two/Playground.app" >/dev/null
[[ ! -e "$caller_derived" ]] || fail 'caller-provided DerivedData was retained without --keep-derived-data'

# Shared validator, actual terminal wrapper, and the native validation-only CLI.
source "$ROOT_DIR/scripts/support/test-playground-fixture-compatibility.sh"

mkdir -p "$FIXTURE_ROOT/Apps/Playground/Playground.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
printf '{}\n' > \
  "$FIXTURE_ROOT/Apps/Playground/Playground.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
if "$FIXTURE_ROOT/scripts/build-playground-artifact.sh" --print-contract >/dev/null 2>&1; then
  fail 'noncanonical Playground dependency lock was accepted'
fi

printf 'test-build-playground-artifact: ok\n'
