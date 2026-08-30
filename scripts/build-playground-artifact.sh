#!/usr/bin/env bash

# Build an unsigned, source-addressed Playground fixture from the repository's
# canonical Xcode workspace dependency lock. Signing and notarization belong to
# the terminal artifact finalization phase, after compilation has completed.

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/source-provenance.sh
source "$ROOT_DIR/scripts/source-provenance.sh"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"
terminal_artifact_assert_build_env_is_clean || {
  printf 'build-playground-artifact: credentialed build environment\n' >&2
  exit 1
}

WORKSPACE="$ROOT_DIR/Apps/Peekaboo.xcworkspace"
WORKSPACE_RELATIVE="Apps/Peekaboo.xcworkspace"
CANONICAL_LOCK_RELATIVE="Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved"
CANONICAL_LOCK="$ROOT_DIR/$CANONICAL_LOCK_RELATIVE"
SCHEME=Playground
CONFIGURATION=Debug
DESTINATION="platform=macOS,arch=arm64"
EXPECTED_BUNDLE_ID=boo.peekaboo.playground.debug
MARKETING_VERSION="$(/usr/bin/plutil -extract version raw -o - "$ROOT_DIR/package.json")"
DERIVED_DATA_PATH=""
OUTPUT_APP=""
KEEP_DERIVED_DATA=false
PRINT_CONTRACT=false

fail() {
  printf 'build-playground-artifact: %s\n' "$*" >&2
  exit 1
}

case "${PEEKABOO_TERMINAL_TEST_MODE:-0}" in
  1|true|yes|on)
    XCODEBUILD_BIN="${PLAYGROUND_XCODEBUILD_BIN:?test xcodebuild required}"
    DITTO_BIN="${PLAYGROUND_DITTO_BIN:-/usr/bin/ditto}"
    PLISTBUDDY_BIN="${PLAYGROUND_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
    XCRUN_BIN="${PLAYGROUND_XCRUN_BIN:-/usr/bin/xcrun}"
    XCODE_SELECT_BIN="${PLAYGROUND_XCODE_SELECT_BIN:-/usr/bin/xcode-select}"
    ;;
  0|false|no|off|'')
    for override_name in PLAYGROUND_XCODEBUILD_BIN PLAYGROUND_DITTO_BIN PLAYGROUND_PLISTBUDDY_BIN \
      PLAYGROUND_XCRUN_BIN PLAYGROUND_XCODE_SELECT_BIN; do
      [[ -z "${!override_name+x}" ]] || fail "$override_name is test-only"
    done
    XCODEBUILD_BIN=/usr/bin/xcodebuild
    DITTO_BIN=/usr/bin/ditto
    PLISTBUDDY_BIN=/usr/libexec/PlistBuddy
    XCRUN_BIN=/usr/bin/xcrun
    XCODE_SELECT_BIN=/usr/bin/xcode-select
    ;;
  *) fail 'PEEKABOO_TERMINAL_TEST_MODE must be boolean' ;;
esac

usage() {
  cat <<'EOF'
Usage: scripts/build-playground-artifact.sh [options]

Options:
  --output-app PATH       Destination Playground.app (must not exist).
  --derived-data PATH     New DerivedData directory (default: private /tmp directory).
  --configuration NAME    Xcode configuration (default: Debug).
  --keep-derived-data     Keep the generated DerivedData directory.
  --print-contract        Print the immutable build contract without compiling.
  --help                  Show this help.

The build is always unsigned and never receives signing, notarization, Sparkle,
npm, or 1Password credentials. Use build-terminal-artifacts.sh to finalize it.
EOF
}

while (($# > 0)); do
  case "$1" in
    --output-app)
      [[ "$#" -ge 2 ]] || fail '--output-app requires a path'
      OUTPUT_APP="$2"
      shift 2
      ;;
    --derived-data)
      [[ "$#" -ge 2 ]] || fail '--derived-data requires a path'
      DERIVED_DATA_PATH="$2"
      shift 2
      ;;
    --configuration)
      [[ "$#" -ge 2 ]] || fail '--configuration requires a value'
      CONFIGURATION="$2"
      shift 2
      ;;
    --keep-derived-data)
      KEEP_DERIVED_DATA=true
      shift
      ;;
    --print-contract)
      PRINT_CONTRACT=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

case "$CONFIGURATION" in
  Debug) EXPECTED_BUNDLE_ID=boo.peekaboo.playground.debug ;;
  Release) EXPECTED_BUNDLE_ID=boo.peekaboo.playground ;;
  *) fail "unsupported configuration: $CONFIGURATION" ;;
esac

[[ -d "$WORKSPACE" ]] || fail "workspace missing: $WORKSPACE"
[[ -f "$CANONICAL_LOCK" && ! -L "$CANONICAL_LOCK" ]] || \
  fail "canonical dependency lock missing or symlinked: $CANONICAL_LOCK"
git -C "$ROOT_DIR" ls-files --error-unmatch "$CANONICAL_LOCK_RELATIVE" >/dev/null || \
  fail "canonical dependency lock is not tracked: $CANONICAL_LOCK_RELATIVE"

competing_locks=(
  "$ROOT_DIR/Apps/Playground/Package.resolved"
  "$ROOT_DIR/Apps/Playground/Playground.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
for competing_lock in "${competing_locks[@]}"; do
  [[ ! -e "$competing_lock" && ! -L "$competing_lock" ]] || \
    fail "remove noncanonical Playground dependency lock: $competing_lock"
done

SOURCE_COMMIT="$(peekaboo_require_source_commit "$ROOT_DIR")" || \
  fail 'a clean checkout with an exact source commit is required'
SOURCE_TREE="$(git -C "$ROOT_DIR" rev-parse HEAD:Apps/Playground)"
DEPENDENCY_LOCK_SHA256="$(shasum -a 256 "$CANONICAL_LOCK" | awk '{print $1}')"
SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-$(terminal_artifact_run_build "$XCODE_SELECT_BIN" -p)}"
EFFECTIVE_DEVELOPER_DIR="$(realpath "$SELECTED_DEVELOPER_DIR")"
XCODEBUILD_VERSION="$(terminal_artifact_run_build env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
  "$XCODEBUILD_BIN" -version)"
SDK_VERSION="$(terminal_artifact_run_build env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
  "$XCRUN_BIN" --sdk macosx --show-sdk-version)"
SWIFTC_VERSION="$(terminal_artifact_run_build env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
  "$XCRUN_BIN" swiftc --version 2>&1)"

contract_json() {
  jq -n \
    --arg sourceCommit "$SOURCE_COMMIT" \
    --arg sourceTree "$SOURCE_TREE" \
    --arg dependencyLockPath "$CANONICAL_LOCK_RELATIVE" \
    --arg dependencyLockSHA256 "$DEPENDENCY_LOCK_SHA256" \
    --arg workspace "$WORKSPACE_RELATIVE" \
    --arg scheme "$SCHEME" \
    --arg configuration "$CONFIGURATION" \
    --arg bundleIdentifier "$EXPECTED_BUNDLE_ID" \
    --arg marketingVersion "$MARKETING_VERSION" \
    --arg developerDir "$EFFECTIVE_DEVELOPER_DIR" \
    --arg xcodebuildVersion "$XCODEBUILD_VERSION" \
    --arg sdkVersion "$SDK_VERSION" \
    --arg swiftcVersion "$SWIFTC_VERSION" '
      {
        version: 2,
        source_commit: $sourceCommit,
        source_tree: $sourceTree,
        dependency_lock_path: $dependencyLockPath,
        dependency_lock_sha256: $dependencyLockSHA256,
        workspace: $workspace,
        scheme: $scheme,
        configuration: $configuration,
        bundle_identifier: $bundleIdentifier,
        marketing_version: $marketingVersion,
        developer_dir: $developerDir,
        xcodebuild_version: $xcodebuildVersion,
        sdk_version: $sdkVersion,
        swiftc_version: $swiftcVersion
      }
    '
}

if [[ "$PRINT_CONTRACT" == true ]]; then
  contract_json
  exit 0
fi

if [[ -z "$OUTPUT_APP" ]]; then
  OUTPUT_APP="$ROOT_DIR/build/playground-artifact/Playground.app"
fi
[[ "$OUTPUT_APP" == /* ]] || OUTPUT_APP="$ROOT_DIR/$OUTPUT_APP"
[[ ! -e "$OUTPUT_APP" && ! -L "$OUTPUT_APP" ]] || fail "output already exists: $OUTPUT_APP"

CREATED_DERIVED_DATA=false
if [[ -z "$DERIVED_DATA_PATH" ]]; then
  DERIVED_DATA_PATH="$(mktemp -d /tmp/peekaboo-playground-build.XXXXXX)"
  CREATED_DERIVED_DATA=true
else
  [[ "$DERIVED_DATA_PATH" == /* ]] || DERIVED_DATA_PATH="$ROOT_DIR/$DERIVED_DATA_PATH"
  [[ ! -e "$DERIVED_DATA_PATH" && ! -L "$DERIVED_DATA_PATH" ]] || \
    fail "DerivedData path already exists: $DERIVED_DATA_PATH"
  mkdir -p "$DERIVED_DATA_PATH"
  CREATED_DERIVED_DATA=true
fi

cleanup() {
  if [[ "$KEEP_DERIVED_DATA" != true && "$CREATED_DERIVED_DATA" == true ]]; then
    rm -rf -- "$DERIVED_DATA_PATH"
  fi
}
trap cleanup EXIT

terminal_artifact_run_build env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
  python3 "$ROOT_DIR/scripts/setup-swift-workspace.py" run --release -- "$XCODEBUILD_BIN" \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates \
  MARKETING_VERSION="$MARKETING_VERSION" \
  CODE_SIGN_IDENTITY= \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

BUILT_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Playground.app"
[[ -d "$BUILT_APP" && ! -L "$BUILT_APP" ]] || fail "build output missing: $BUILT_APP"
BUNDLE_ID="$($PLISTBUDDY_BIN -c 'Print :CFBundleIdentifier' "$BUILT_APP/Contents/Info.plist")"
[[ "$BUNDLE_ID" == "$EXPECTED_BUNDLE_ID" ]] || \
  fail "bundle identifier mismatch: expected $EXPECTED_BUNDLE_ID, got $BUNDLE_ID"

CURRENT_LOCK_SHA256="$(shasum -a 256 "$CANONICAL_LOCK" | awk '{print $1}')"
[[ "$CURRENT_LOCK_SHA256" == "$DEPENDENCY_LOCK_SHA256" ]] || \
  fail 'canonical dependency lock changed during the build'
peekaboo_verify_source_commit "$ROOT_DIR" "$SOURCE_COMMIT" || \
  fail 'source checkout changed during the build'

mkdir -p "$BUILT_APP/Contents/Resources" "$(dirname "$OUTPUT_APP")"
contract_json > "$BUILT_APP/Contents/Resources/PeekabooPlaygroundSource.json"
chmod 444 "$BUILT_APP/Contents/Resources/PeekabooPlaygroundSource.json"
"$DITTO_BIN" "$BUILT_APP" "$OUTPUT_APP"

printf 'Playground app: %s\n' "$OUTPUT_APP"
printf 'Source commit: %s\n' "$SOURCE_COMMIT"
printf 'Dependency lock SHA-256: %s\n' "$DEPENDENCY_LOCK_SHA256"
