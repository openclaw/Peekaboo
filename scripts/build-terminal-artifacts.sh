#!/usr/bin/env bash

# Produce source-addressed terminal-only artifacts without publishing. Compilation
# runs with every release credential removed from the environment. The finalize
# phase is intentionally narrow: it only signs, notarizes, staples, and packages
# already-built payloads.

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/source-provenance.sh
source "$ROOT_DIR/scripts/source-provenance.sh"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"
# shellcheck source=scripts/native-only-policy.sh
source "$ROOT_DIR/scripts/native-only-policy.sh"

EXPECTED_IDENTITY='Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)'
EXPECTED_TEAM_ID=FWJYW4S8P8
EXPECTED_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
TIMESTAMP_URL=http://timestamp.apple.com/ts01
CANONICAL_LOCK_RELATIVE=Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved
CANONICAL_LOCK="$ROOT_DIR/$CANONICAL_LOCK_RELATIVE"

COMMAND="${1:-}"
[[ -z "$COMMAND" ]] || shift
STAGE_DIR=""
OUTPUT_DIR=""

fail() {
  printf 'build-terminal-artifacts: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/build-terminal-artifacts.sh build|finalize|all [options]

Commands:
  build       Resolve and compile with all release credentials removed.
  finalize    Sign/notarize/package one previously sealed build stage.
  all         Run build, then enter the managed narrow credential finalizer.

Options:
  --stage PATH   New build-stage directory (default: /tmp, source-addressed).
  --output PATH  New final artifact directory (required by finalize; /tmp default for all).
  --help         Show this help.

This workflow never tags, uploads, edits appcast.xml, creates a GitHub release,
or publishes npm. Public releases still use release-binaries.sh.
EOF
}

if [[ "$COMMAND" == -h || "$COMMAND" == --help ]]; then
  usage
  exit 0
fi

while (($# > 0)); do
  case "$1" in
    --stage)
      [[ "$#" -ge 2 ]] || fail '--stage requires a path'
      STAGE_DIR="$2"
      shift 2
      ;;
    --output)
      [[ "$#" -ge 2 ]] || fail '--output requires a path'
      OUTPUT_DIR="$2"
      shift 2
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

[[ "$COMMAND" == build || "$COMMAND" == finalize || "$COMMAND" == all ]] || {
  usage >&2
  fail 'command must be build, finalize, or all'
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

require_clean_source() {
  SOURCE_COMMIT="$(peekaboo_require_source_commit "$ROOT_DIR")" || \
    fail 'a clean checkout with an exact source commit is required'
  VERSION="$(node -p "require('$ROOT_DIR/package.json').version")"
  DEPENDENCY_LOCK_SHA256="$(shasum -a 256 "$CANONICAL_LOCK" | awk '{print $1}')"
}

record_toolchain() {
  SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-$(terminal_artifact_run_build /usr/bin/xcode-select -p)}"
  EFFECTIVE_DEVELOPER_DIR="$(realpath "$SELECTED_DEVELOPER_DIR")"
  XCODEBUILD_VERSION="$(terminal_artifact_run_build env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    /usr/bin/xcodebuild -version)"
  SDK_VERSION="$(terminal_artifact_run_build env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    /usr/bin/xcrun --sdk macosx --show-sdk-version)"
  SWIFTC_VERSION="$(terminal_artifact_run_build env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    /usr/bin/xcrun swiftc --version)"
}

version_to_build_number() {
  local version="$1"
  local core major minor patch
  core="${version%%-*}"
  IFS=. read -r major minor patch <<<"$core"
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ && "$patch" =~ ^[0-9]+$ ]] || \
    fail "version is not numeric semver: $version"
  ((10#$minor <= 99 && 10#$patch <= 99)) || fail "version exceeds build-number bounds: $version"
  printf '%d\n' $((((10#$major * 100 + 10#$minor) * 100 + 10#$patch) * 100 + 99))
}

assert_new_absolute_directory() {
  local path="$1"
  local label="$2"
  [[ "$path" == /* ]] || fail "$label must be absolute: $path"
  [[ ! -e "$path" && ! -L "$path" ]] || fail "$label already exists: $path"
}

stage_manifest_path() {
  printf '%s\n' "$STAGE_DIR/terminal-build-manifest.json"
}

build_phase() {
  require_command git
  require_command jq
  require_command node
  require_command pnpm
  require_command shasum
  require_clean_source
  record_toolchain
  [[ -f "$CANONICAL_LOCK" && ! -L "$CANONICAL_LOCK" ]] || fail 'canonical workspace lock is missing'

  if [[ -z "$STAGE_DIR" ]]; then
    STAGE_DIR="/tmp/peekaboo-terminal-build-$SOURCE_COMMIT"
  fi
  assert_new_absolute_directory "$STAGE_DIR" 'stage directory'
  mkdir -p "$STAGE_DIR/cli" "$STAGE_DIR/inventories" "$STAGE_DIR/peekaboo-derived" "$STAGE_DIR/playground"

  printf '==> Build universal CLI without release credentials\n'
  CLI_LOCK="$ROOT_DIR/Apps/CLI/Package.resolved"
  [[ ! -e "$CLI_LOCK" && ! -L "$CLI_LOCK" ]] || \
    fail "remove noncanonical CLI dependency lock before terminal build: $CLI_LOCK"
  cp "$CANONICAL_LOCK" "$CLI_LOCK"
  trap 'rm -f -- "${CLI_LOCK:-}"' EXIT INT TERM HUP
  set +e
  terminal_artifact_run_build env \
    DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    MAC_RELEASE_CODESIGN_IDENTITY=- \
    CODESIGN_TIMESTAMP=off \
    PEEKABOO_USE_RESOLVED_VERSIONS=1 \
    pnpm run build:swift:all
  CLI_BUILD_RESULT=$?
  set -e
  rm -f -- "$CLI_LOCK"
  trap - EXIT INT TERM HUP
  ((CLI_BUILD_RESULT == 0)) || fail "universal CLI build failed with status $CLI_BUILD_RESULT"
  cp "$ROOT_DIR/peekaboo" "$STAGE_DIR/cli/peekaboo"
  for runtime_library in "$ROOT_DIR"/libswiftCompatibility*.dylib; do
    [[ -e "$runtime_library" ]] || continue
    cp "$runtime_library" "$STAGE_DIR/cli/"
  done

  printf '==> Build Peekaboo.app unsigned without release credentials\n'
  BUILD_NUMBER="$(version_to_build_number "$VERSION")"
  terminal_artifact_run_build env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" /usr/bin/xcodebuild \
    -workspace "$ROOT_DIR/Apps/Peekaboo.xcworkspace" \
    -scheme Peekaboo \
    -configuration Release \
    -destination platform=macOS,arch=arm64 \
    -derivedDataPath "$STAGE_DIR/peekaboo-derived" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    -skipPackageUpdates \
    -quiet \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    PEEKABOO_SOURCE_COMMIT="$SOURCE_COMMIT" \
    CODE_SIGN_IDENTITY= \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

  PEEKABOO_APP="$STAGE_DIR/peekaboo-derived/Build/Products/Release/Peekaboo.app"
  [[ -d "$PEEKABOO_APP" ]] || fail "Peekaboo.app build output missing: $PEEKABOO_APP"
  APP_SOURCE_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :PeekabooSourceCommit' \
    "$PEEKABOO_APP/Contents/Info.plist")"
  [[ "$APP_SOURCE_COMMIT" == "$SOURCE_COMMIT" ]] || fail 'Peekaboo.app source stamp mismatch'

  printf '==> Build Playground unsigned from the canonical dependency graph\n'
  terminal_artifact_run_build env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    "$ROOT_DIR/scripts/build-playground-artifact.sh" \
    --configuration Debug \
    --output-app "$STAGE_DIR/playground/Playground.app"

  peekaboo_verify_source_commit "$ROOT_DIR" "$SOURCE_COMMIT" || fail 'source changed during build phase'
  CURRENT_LOCK_SHA256="$(shasum -a 256 "$CANONICAL_LOCK" | awk '{print $1}')"
  [[ "$CURRENT_LOCK_SHA256" == "$DEPENDENCY_LOCK_SHA256" ]] || fail 'dependency lock changed during build phase'

  CLI_SHA256="$(shasum -a 256 "$STAGE_DIR/cli/peekaboo" | awk '{print $1}')"
  APP_EXECUTABLE_SHA256="$(shasum -a 256 "$PEEKABOO_APP/Contents/MacOS/Peekaboo" | awk '{print $1}')"
  PLAYGROUND_EXECUTABLE_SHA256="$(shasum -a 256 \
    "$STAGE_DIR/playground/Playground.app/Contents/MacOS/Playground" | awk '{print $1}')"
  node "$ROOT_DIR/scripts/artifact-tree-manifest.mjs" "$STAGE_DIR/cli" \
    > "$STAGE_DIR/inventories/cli.json"
  node "$ROOT_DIR/scripts/artifact-tree-manifest.mjs" "$PEEKABOO_APP" \
    > "$STAGE_DIR/inventories/peekaboo-app.json"
  node "$ROOT_DIR/scripts/artifact-tree-manifest.mjs" "$STAGE_DIR/playground/Playground.app" \
    > "$STAGE_DIR/inventories/playground-app.json"
  chmod 444 "$STAGE_DIR"/inventories/*.json
  CLI_INVENTORY_SHA256="$(shasum -a 256 "$STAGE_DIR/inventories/cli.json" | awk '{print $1}')"
  APP_INVENTORY_SHA256="$(shasum -a 256 "$STAGE_DIR/inventories/peekaboo-app.json" | awk '{print $1}')"
  PLAYGROUND_INVENTORY_SHA256="$(shasum -a 256 "$STAGE_DIR/inventories/playground-app.json" | awk '{print $1}')"
  jq -n \
    --arg sourceCommit "$SOURCE_COMMIT" \
    --arg version "$VERSION" \
    --arg dependencyLockPath "$CANONICAL_LOCK_RELATIVE" \
    --arg dependencyLockSHA256 "$DEPENDENCY_LOCK_SHA256" \
    --arg cliSHA256 "$CLI_SHA256" \
    --arg cliInventorySHA256 "$CLI_INVENTORY_SHA256" \
    --arg appExecutableSHA256 "$APP_EXECUTABLE_SHA256" \
    --arg appInventorySHA256 "$APP_INVENTORY_SHA256" \
    --arg playgroundExecutableSHA256 "$PLAYGROUND_EXECUTABLE_SHA256" \
    --arg playgroundInventorySHA256 "$PLAYGROUND_INVENTORY_SHA256" \
    --arg developerDir "$EFFECTIVE_DEVELOPER_DIR" \
    --arg xcodebuildVersion "$XCODEBUILD_VERSION" \
    --arg sdkVersion "$SDK_VERSION" \
    --arg swiftcVersion "$SWIFTC_VERSION" '
      {
        version: 1,
        source_commit: $sourceCommit,
        marketing_version: $version,
        dependency_lock_path: $dependencyLockPath,
        dependency_lock_sha256: $dependencyLockSHA256,
        toolchain: {
          developer_dir: $developerDir,
          xcodebuild_version: $xcodebuildVersion,
          sdk_version: $sdkVersion,
          swiftc_version: $swiftcVersion
        },
        unsigned_inputs: {
          cli_sha256: $cliSHA256,
          cli_inventory_sha256: $cliInventorySHA256,
          peekaboo_executable_sha256: $appExecutableSHA256,
          peekaboo_inventory_sha256: $appInventorySHA256,
          playground_inventory_sha256: $playgroundInventorySHA256,
          playground_executable_sha256: $playgroundExecutableSHA256
        }
      }
    ' > "$(stage_manifest_path)"
  chmod 444 "$(stage_manifest_path)"
  printf 'Build stage: %s\n' "$STAGE_DIR"
}

verify_stage() {
  local manifest verify_inventory_dir
  manifest="$(stage_manifest_path)"
  [[ -f "$manifest" && ! -L "$manifest" ]] || fail "sealed build manifest missing: $manifest"
  require_clean_source
  record_toolchain
  jq -e \
    --arg sourceCommit "$SOURCE_COMMIT" \
    --arg version "$VERSION" \
    --arg dependencyLockPath "$CANONICAL_LOCK_RELATIVE" \
    --arg dependencyLockSHA256 "$DEPENDENCY_LOCK_SHA256" \
    --arg developerDir "$EFFECTIVE_DEVELOPER_DIR" \
    --arg xcodebuildVersion "$XCODEBUILD_VERSION" \
    --arg sdkVersion "$SDK_VERSION" \
    --arg swiftcVersion "$SWIFTC_VERSION" '
      type == "object" and keys == [
        "dependency_lock_path", "dependency_lock_sha256", "marketing_version",
        "source_commit", "toolchain", "unsigned_inputs", "version"
      ] and
      .version == 1 and
      .source_commit == $sourceCommit and
      .marketing_version == $version and
      .dependency_lock_path == $dependencyLockPath and
      .dependency_lock_sha256 == $dependencyLockSHA256 and
      .toolchain == {
        developer_dir: $developerDir,
        xcodebuild_version: $xcodebuildVersion,
        sdk_version: $sdkVersion,
        swiftc_version: $swiftcVersion
      } and
      (.unsigned_inputs | type == "object" and keys == [
        "cli_inventory_sha256", "cli_sha256", "peekaboo_executable_sha256",
        "peekaboo_inventory_sha256", "playground_executable_sha256",
        "playground_inventory_sha256"
      ]) and
      ([.unsigned_inputs[] | test("^[0-9a-f]{64}$")] | all)
    ' "$manifest" >/dev/null || fail 'sealed build manifest does not match current source or toolchain'

  [[ "$(shasum -a 256 "$STAGE_DIR/cli/peekaboo" | awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.cli_sha256 "$manifest")" ]] || fail 'staged CLI changed after build'
  [[ "$(shasum -a 256 "$STAGE_DIR/peekaboo-derived/Build/Products/Release/Peekaboo.app/Contents/MacOS/Peekaboo" | awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.peekaboo_executable_sha256 "$manifest")" ]] || \
    fail 'staged Peekaboo.app executable changed after build'
  [[ "$(shasum -a 256 "$STAGE_DIR/playground/Playground.app/Contents/MacOS/Playground" | awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.playground_executable_sha256 "$manifest")" ]] || \
    fail 'staged Playground executable changed after build'

  verify_inventory_dir="$(mktemp -d /tmp/peekaboo-terminal-inventory-verify.XXXXXX)"
  node "$ROOT_DIR/scripts/artifact-tree-manifest.mjs" "$STAGE_DIR/cli" > "$verify_inventory_dir/cli.json"
  node "$ROOT_DIR/scripts/artifact-tree-manifest.mjs" \
    "$STAGE_DIR/peekaboo-derived/Build/Products/Release/Peekaboo.app" \
    > "$verify_inventory_dir/peekaboo-app.json"
  node "$ROOT_DIR/scripts/artifact-tree-manifest.mjs" "$STAGE_DIR/playground/Playground.app" \
    > "$verify_inventory_dir/playground-app.json"
  [[ "$(shasum -a 256 "$verify_inventory_dir/cli.json" | awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.cli_inventory_sha256 "$manifest")" ]] || \
    fail 'complete staged CLI payload changed after build'
  [[ "$(shasum -a 256 "$verify_inventory_dir/peekaboo-app.json" | awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.peekaboo_inventory_sha256 "$manifest")" ]] || \
    fail 'complete staged Peekaboo.app payload changed after build'
  [[ "$(shasum -a 256 "$verify_inventory_dir/playground-app.json" | awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.playground_inventory_sha256 "$manifest")" ]] || \
    fail 'complete staged Playground.app payload changed after build'
  rm -rf -- "$verify_inventory_dir"
}

sign_leaf() {
  "$ROOT_DIR/scripts/codesign-with-retry.sh" \
    --force \
    --options runtime \
    --timestamp="$TIMESTAMP_URL" \
    --sign "$EXPECTED_IDENTITY" \
    "$1"
}

verify_foundation_signature() {
  local artifact="$1"
  local authority team_id
  codesign --verify --strict --verbose=2 "$artifact"
  codesign --verify --strict -R="$EXPECTED_REQUIREMENT" "$artifact"
  authority="$(codesign -dv --verbose=4 "$artifact" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  team_id="$(codesign -dv --verbose=4 "$artifact" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  [[ "$authority" == "$EXPECTED_IDENTITY" && "$team_id" == "$EXPECTED_TEAM_ID" ]] || \
    fail "unexpected signing identity: $artifact"
}

finalize_cli() {
  local runtime_library
  for runtime_library in "$STAGE_DIR"/cli/libswiftCompatibility*.dylib; do
    [[ -e "$runtime_library" ]] || continue
    sign_leaf "$runtime_library"
  done
  "$ROOT_DIR/scripts/codesign-with-retry.sh" \
    --force \
    --options runtime \
    --timestamp="$TIMESTAMP_URL" \
    --identifier boo.peekaboo.peekaboo \
    --sign "$EXPECTED_IDENTITY" \
    "$STAGE_DIR/cli/peekaboo"
  verify_foundation_signature "$STAGE_DIR/cli/peekaboo"
  MAC_RELEASE_CODESIGN_IDENTITY="$EXPECTED_IDENTITY" \
    MAC_RELEASE_CODESIGN_TEAM_ID="$EXPECTED_TEAM_ID" \
    "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" \
    "$STAGE_DIR/cli/peekaboo" "$STAGE_DIR/cli"
  if ! native_only_error="$(native_only_verify_macho \
    "$STAGE_DIR/cli/peekaboo" 'terminal CLI' /usr/bin/nm /usr/bin/strings)"; then
    fail "$native_only_error"
  fi
  "$ROOT_DIR/scripts/notarize-terminal-artifact.sh" \
    --kind cli \
    --artifact "$STAGE_DIR/cli/peekaboo" \
    --result "$OUTPUT_DIR/notary/cli.json"

  CLI_PACKAGE_DIR="$OUTPUT_DIR/peekaboo-macos-universal"
  mkdir -p "$CLI_PACKAGE_DIR"
  cp "$STAGE_DIR/cli/peekaboo" "$CLI_PACKAGE_DIR/"
  for runtime_library in "$STAGE_DIR"/cli/libswiftCompatibility*.dylib; do
    [[ -e "$runtime_library" ]] || continue
    cp "$runtime_library" "$CLI_PACKAGE_DIR/"
  done
  cp "$ROOT_DIR/LICENSE" "$CLI_PACKAGE_DIR/"
  printf '%s\n' "$VERSION" > "$CLI_PACKAGE_DIR/VERSION"
  tar -czf "$OUTPUT_DIR/peekaboo-macos-universal.tar.gz" \
    -C "$OUTPUT_DIR" peekaboo-macos-universal
}

finalize_peekaboo_app() {
  DERIVED_DATA_PATH="$STAGE_DIR/peekaboo-derived" \
    RELEASE_DIR="$OUTPUT_DIR" \
    MAC_APP_NOTARY_RESULT_PATH="$OUTPUT_DIR/notary/peekaboo-app.json" \
    MAC_DMG_NOTARY_RESULT_PATH="$OUTPUT_DIR/notary/peekaboo-dmg.json" \
    "$ROOT_DIR/scripts/release-macos-app.sh" \
    --skip-build \
    --no-appcast \
    --keep-derived-data
}

finalize_playground() {
  local app main_executable nested_code
  app="$STAGE_DIR/playground/Playground.app"
  main_executable="$app/Contents/MacOS/Playground"
  [[ -f "$main_executable" && -x "$main_executable" ]] || fail 'Playground executable missing'

  nested_code="$(find "$app/Contents" -mindepth 1 -type d \
    \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' \) -print -quit)"
  [[ -z "$nested_code" ]] || fail "unsupported nested Playground code bundle: $nested_code"
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$main_executable" ]] && continue
    if file -b "$candidate" | grep -q Mach-O; then
      sign_leaf "$candidate"
    fi
  done < <(find "$app/Contents" -type f -perm -111 -print0)
  sign_leaf "$app"
  codesign --verify --deep --strict --verbose=2 "$app"
  verify_foundation_signature "$app"
  "$ROOT_DIR/scripts/verify-native-only-app.sh" --app "$app"
  "$ROOT_DIR/scripts/notarize-terminal-artifact.sh" \
    --kind app \
    --artifact "$app" \
    --result "$OUTPUT_DIR/notary/playground-app.json"
  ditto -c -k --sequesterRsrc --keepParent "$app" \
    "$OUTPUT_DIR/Playground-$VERSION.app.zip"
}

write_final_manifest() {
  local manifest_path="$OUTPUT_DIR/terminal-artifacts.json"
  local cli_tar="$OUTPUT_DIR/peekaboo-macos-universal.tar.gz"
  local app_zip="$OUTPUT_DIR/Peekaboo-$VERSION.app.zip"
  local app_dmg="$OUTPUT_DIR/Peekaboo-$VERSION.dmg"
  local playground_zip="$OUTPUT_DIR/Playground-$VERSION.app.zip"
  local cli_source app_source playground_source playground_manifest playground_manifest_sha256
  local cli_cdhash app_cdhash dmg_cdhash playground_cdhash

  cli_source="$("$STAGE_DIR/cli/peekaboo" --version --json | jq -er .data.sourceCommit)"
  app_source="$(/usr/libexec/PlistBuddy -c 'Print :PeekabooSourceCommit' \
    "$STAGE_DIR/peekaboo-derived/Build/Products/Release/Peekaboo.app/Contents/Info.plist")"
  playground_manifest="$STAGE_DIR/playground/Playground.app/Contents/Resources/PeekabooPlaygroundSource.json"
  playground_source="$(jq -er .source_commit "$playground_manifest")"
  playground_manifest_sha256="$(shasum -a 256 "$playground_manifest" | awk '{print $1}')"
  cli_cdhash="$(codesign -dvvv "$STAGE_DIR/cli/peekaboo" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
  app_cdhash="$(codesign -dvvv \
    "$STAGE_DIR/peekaboo-derived/Build/Products/Release/Peekaboo.app" 2>&1 | \
    awk -F= '/^CDHash=/{print $2; exit}')"
  dmg_cdhash="$(codesign -dvvv "$app_dmg" 2>&1 | awk -F= '/^CDHash=/{print $2; exit}')"
  playground_cdhash="$(codesign -dvvv "$STAGE_DIR/playground/Playground.app" 2>&1 | \
    awk -F= '/^CDHash=/{print $2; exit}')"
  [[ "$cli_source" == "$SOURCE_COMMIT" && "$app_source" == "$SOURCE_COMMIT" && \
    "$playground_source" == "$SOURCE_COMMIT" ]] || fail 'final artifact source stamps disagree'

  jq -n \
    --arg sourceCommit "$SOURCE_COMMIT" \
    --arg version "$VERSION" \
    --arg dependencyLockPath "$CANONICAL_LOCK_RELATIVE" \
    --arg dependencyLockSHA256 "$DEPENDENCY_LOCK_SHA256" \
    --arg developerDir "$EFFECTIVE_DEVELOPER_DIR" \
    --arg xcodebuildVersion "$XCODEBUILD_VERSION" \
    --arg sdkVersion "$SDK_VERSION" \
    --arg swiftcVersion "$SWIFTC_VERSION" \
    --arg cliPath "$(basename "$cli_tar")" \
    --arg cliSHA256 "$(shasum -a 256 "$cli_tar" | awk '{print $1}')" \
    --argjson cliSize "$(stat -f%z "$cli_tar")" \
    --arg cliCDHash "$cli_cdhash" \
    --arg appZipPath "$(basename "$app_zip")" \
    --arg appZipSHA256 "$(shasum -a 256 "$app_zip" | awk '{print $1}')" \
    --argjson appZipSize "$(stat -f%z "$app_zip")" \
    --arg appCDHash "$app_cdhash" \
    --arg appDMGPath "$(basename "$app_dmg")" \
    --arg appDMGSHA256 "$(shasum -a 256 "$app_dmg" | awk '{print $1}')" \
    --argjson appDMGSize "$(stat -f%z "$app_dmg")" \
    --arg dmgCDHash "$dmg_cdhash" \
    --arg playgroundPath "$(basename "$playground_zip")" \
    --arg playgroundSHA256 "$(shasum -a 256 "$playground_zip" | awk '{print $1}')" \
    --argjson playgroundSize "$(stat -f%z "$playground_zip")" \
    --arg playgroundCDHash "$playground_cdhash" \
    --arg playgroundManifestSHA256 "$playground_manifest_sha256" \
    --slurpfile cliNotary "$OUTPUT_DIR/notary/cli.json" \
    --slurpfile appNotary "$OUTPUT_DIR/notary/peekaboo-app.json" \
    --slurpfile dmgNotary "$OUTPUT_DIR/notary/peekaboo-dmg.json" \
    --slurpfile playgroundNotary "$OUTPUT_DIR/notary/playground-app.json" '
      {
        version: 1,
        source_commit: $sourceCommit,
        marketing_version: $version,
        dependency_lock_path: $dependencyLockPath,
        dependency_lock_sha256: $dependencyLockSHA256,
        toolchain: {
          developer_dir: $developerDir,
          xcodebuild_version: $xcodebuildVersion,
          sdk_version: $sdkVersion,
          swiftc_version: $swiftcVersion
        },
        signing: {
          authority: "Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)",
          team_id: "FWJYW4S8P8"
        },
        notarization: {
          cli: $cliNotary[0],
          peekaboo_app: $appNotary[0],
          peekaboo_dmg: $dmgNotary[0],
          playground_app: $playgroundNotary[0]
        },
        artifacts: {
          cli: {path: $cliPath, sha256: $cliSHA256, size: $cliSize, cdhash: $cliCDHash, source_commit: $sourceCommit},
          peekaboo_app_zip: {path: $appZipPath, sha256: $appZipSHA256, size: $appZipSize, cdhash: $appCDHash, source_commit: $sourceCommit},
          peekaboo_dmg: {path: $appDMGPath, sha256: $appDMGSHA256, size: $appDMGSize, cdhash: $dmgCDHash, source_commit: $sourceCommit},
          playground_app_zip: {
            path: $playgroundPath,
            sha256: $playgroundSHA256,
            size: $playgroundSize,
            cdhash: $playgroundCDHash,
            source_commit: $sourceCommit,
            embedded_manifest_sha256: $playgroundManifestSHA256
          }
        }
      }
    ' > "$manifest_path"
  chmod 444 "$manifest_path"
  (cd "$OUTPUT_DIR" && shasum -a 256 \
    peekaboo-macos-universal.tar.gz \
    "Peekaboo-$VERSION.app.zip" \
    "Peekaboo-$VERSION.dmg" \
    "Playground-$VERSION.app.zip" > checksums.txt)
}

finalize_phase() {
  require_command codesign
  require_command ditto
  require_command file
  require_command jq
  require_command node
  require_command shasum
  require_command tar
  [[ -n "$STAGE_DIR" ]] || fail 'finalize requires --stage'
  [[ "$STAGE_DIR" == /* && -d "$STAGE_DIR" && ! -L "$STAGE_DIR" ]] || \
    fail "invalid stage directory: $STAGE_DIR"
  verify_stage

  if [[ -z "$OUTPUT_DIR" ]]; then
    fail 'finalize requires --output'
  fi
  assert_new_absolute_directory "$OUTPUT_DIR" 'output directory'
  mkdir -p "$OUTPUT_DIR/notary"
  [[ "${MAC_RELEASE_CODESIGN_IDENTITY:-$EXPECTED_IDENTITY}" == "$EXPECTED_IDENTITY" ]] || \
    fail "finalization requires $EXPECTED_IDENTITY"

  printf '==> Sign and notarize CLI\n'
  finalize_cli
  printf '==> Sign, notarize, staple, and package Peekaboo.app\n'
  finalize_peekaboo_app
  printf '==> Sign, notarize, staple, and package Playground.app\n'
  finalize_playground
  write_final_manifest
  printf 'Terminal artifacts: %s\n' "$OUTPUT_DIR"
}

case "$COMMAND" in
  build)
    if ! terminal_artifact_assert_build_env_is_clean >/dev/null 2>&1; then
      reexec_args=(build)
      [[ -z "$STAGE_DIR" ]] || reexec_args+=(--stage "$STAGE_DIR")
      terminal_artifact_run_build "$ROOT_DIR/scripts/build-terminal-artifacts.sh" "${reexec_args[@]}"
      exit $?
    fi
    build_phase
    ;;
  finalize)
    finalize_phase
    ;;
  all)
    require_clean_source
    if [[ -z "$STAGE_DIR" ]]; then
      STAGE_DIR="/tmp/peekaboo-terminal-build-$SOURCE_COMMIT"
    fi
    if [[ -z "$OUTPUT_DIR" ]]; then
      OUTPUT_DIR="/tmp/peekaboo-terminal-artifacts-$SOURCE_COMMIT"
    fi
    terminal_artifact_run_build "$ROOT_DIR/scripts/build-terminal-artifacts.sh" build \
      --stage "$STAGE_DIR"
    env \
      -u GH_TOKEN \
      -u GITHUB_TOKEN \
      -u NODE_AUTH_TOKEN \
      -u NPM_CONFIG_USERCONFIG \
      -u NPM_TOKEN \
      MAC_RELEASE_MANIFEST="$ROOT_DIR/.mac-release-terminal.env" \
      "$ROOT_DIR/scripts/mac-release" codesign-run --with-package-secrets -- \
      "$ROOT_DIR/scripts/build-terminal-artifacts.sh" finalize \
      --stage "$STAGE_DIR" \
      --output "$OUTPUT_DIR"
    ;;
esac
