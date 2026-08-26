#!/bin/bash -p

# Source-addressed terminal artifact pipeline. Compilation, code signing,
# notarization, DMG construction, and final publication are separate retryable
# phases with the narrowest environment each phase needs.

builtin set +vx
# Keep inherited secrets available only to this privileged shell until they
# are either moved into owner-private custody or rejected below. In particular,
# do not expose them to the entrypoint's environment/function scrub subprocesses.
for early_secret_name in \
  APP_STORE_CONNECT_API_KEY_P8 APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_KEY_ID \
  ASC_ISSUER_ID ASC_KEY_ID ASC_PRIVATE_KEY_P8 BASH_ENV CDPATH DYLD_INSERT_LIBRARIES \
  DYLD_LIBRARY_PATH ENV GH_TOKEN GITHUB_TOKEN GLOBIGNORE MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD \
  MAC_RELEASE_SPARKLE_KEY_FILE MAC_RELEASE_SPARKLE_OP_REF MAC_RELEASE_SIGNING_KEY_FILE \
  MAC_RELEASE_TOOL MOLTY_OP_SERVICE_ACCOUNT_TOKEN NODE_AUTH_TOKEN NODE_OPTIONS NODE_PATH \
  NOTARYTOOL_ISSUER NOTARYTOOL_KEY NOTARYTOOL_KEYCHAIN_PROFILE NOTARYTOOL_KEY_ID \
  NOTARYTOOL_PROFILE NPM_CONFIG_USERCONFIG NPM_TOKEN OP_SERVICE_ACCOUNT_TOKEN PERL5LIB PERL5OPT \
  PYTHONHOME PYTHONPATH RUBYLIB RUBYOPT SPARKLE_PRIVATE_KEY SPARKLE_PRIVATE_KEY_FILE ZDOTDIR; do
  if [[ -n "${!early_secret_name+x}" ]]; then
    builtin export -n "$early_secret_name" || builtin exit 1
  fi
done
builtin unset early_secret_name
entry_requires_service_custody=false
for required_entry_value in OP_SERVICE_ACCOUNT_TOKEN MOLTY_OP_SERVICE_ACCOUNT_TOKEN; do
  [[ -z "${!required_entry_value+x}" ]] || entry_requires_service_custody=true
done
builtin unset required_entry_value
PATH=/usr/bin:/bin
builtin export PATH
raw_function_names_file=$(/usr/bin/mktemp /tmp/peekaboo-functions.XXXXXX) || builtin exit 1
/usr/bin/env -0 | /usr/bin/env -i /usr/bin/perl -0ne '
  if (index($_, "BASH_FUNC_") == 0) { my ($name) = split(/=/, $_, 2); print $name, chr(0); }
' > "$raw_function_names_file"
raw_function_scan_status=("${PIPESTATUS[@]}")
if [[ ${raw_function_scan_status[0]} -ne 0 || ${raw_function_scan_status[1]} -ne 0 ]]; then
  /bin/rm -f "$raw_function_names_file"
  /bin/echo 'Could not inspect exported-function environment safely.' >&2
  builtin exit 1
fi
raw_function_scrub_args=()
while IFS= read -r -d '' raw_function_name; do
  [[ -n "$raw_function_name" ]] || { /bin/rm -f "$raw_function_names_file"; builtin exit 1; }
  raw_function_scrub_args+=(-u "$raw_function_name")
done < "$raw_function_names_file"
/bin/rm -f "$raw_function_names_file"
if (("${#raw_function_scrub_args[@]}" > 0)); then
  if [[ "$entry_requires_service_custody" == true ]]; then
    /bin/echo 'Service-token invocation refuses an exported-function environment.' >&2
    builtin exit 1
  fi
  builtin exec /usr/bin/env "${raw_function_scrub_args[@]}" \
    -u BASH_ENV -u ENV -u CDPATH -u GLOBIGNORE \
    PATH=/usr/bin:/bin \
    /bin/bash -p "${BASH_SOURCE[0]}" "$@"
fi
for imported_function in $(builtin compgen -A function); do
  builtin unset -f -- "$imported_function"
done
builtin unset BASH_ENV ENV CDPATH GLOBIGNORE 2>/dev/null || true
builtin set +p

builtin set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERMINAL_ARTIFACT_ROOT="$ROOT_DIR"
export TERMINAL_ARTIFACT_ROOT
# shellcheck source=scripts/source-provenance.sh
source "$ROOT_DIR/scripts/source-provenance.sh"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"
# shellcheck source=scripts/terminal-artifact-policy.sh
source "$ROOT_DIR/scripts/terminal-artifact-policy.sh"
# shellcheck source=scripts/native-only-policy.sh
source "$ROOT_DIR/scripts/native-only-policy.sh"
# shellcheck source=scripts/release-version.sh
source "$ROOT_DIR/scripts/release-version.sh"

EXPECTED_IDENTITY='Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)'
EXPECTED_TEAM_ID=FWJYW4S8P8
EXPECTED_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
TIMESTAMP_URL=http://timestamp.apple.com/ts01
EXPECTED_RELEASE_HELPER_COMMIT=20ab9a5e6bb1107788366726868f1a9b4c16d953
EXPECTED_RELEASE_HELPER_SHA=e65e06ef89ec90ebfc537d28748a3c4de8ce89bd09b51e4d67ba4bdd95427255
EXPECTED_RELEASE_HELPER_LIB_SHA=c29d3c46506c2d0bd2db7ab688bd3108d54e8824074a4fe800de6e3fe17284c9
CANONICAL_LOCK_RELATIVE=Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved
CANONICAL_LOCK="$ROOT_DIR/$CANONICAL_LOCK_RELATIVE"

COMMAND="${1:-}"
[[ -z "$COMMAND" ]] || shift
STAGE_DIR=""
OUTPUT_DIR=""

builtin unset owned_op_service_token_file owned_molty_op_service_token_file 2>/dev/null || builtin exit 1
owned_op_service_token_file=""
owned_molty_op_service_token_file=""
cleanup_service_token_files() {
  if [[ -n "$owned_op_service_token_file" ]]; then
    /bin/rm -f "$owned_op_service_token_file"
  fi
  if [[ -n "$owned_molty_op_service_token_file" ]]; then
    /bin/rm -f "$owned_molty_op_service_token_file"
  fi
}
trap cleanup_service_token_files EXIT

if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  [[ -z "${PEEKABOO_OP_SERVICE_TOKEN_FILE:-}" ]] || {
    /bin/echo 'Conflicting service-token custody.' >&2
    builtin exit 1
  }
  owned_op_service_token_file="$(/usr/bin/mktemp /tmp/peekaboo-op-token.XXXXXX)" || builtin exit 1
  PEEKABOO_OP_SERVICE_TOKEN_FILE="$owned_op_service_token_file"
  printf '%s' "$OP_SERVICE_ACCOUNT_TOKEN" > "$PEEKABOO_OP_SERVICE_TOKEN_FILE"
  /bin/chmod 600 "$PEEKABOO_OP_SERVICE_TOKEN_FILE"
  builtin export PEEKABOO_OP_SERVICE_TOKEN_FILE
  builtin unset OP_SERVICE_ACCOUNT_TOKEN
fi
if [[ -n "${MOLTY_OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  [[ -z "${PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE:-}" ]] || {
    /bin/echo 'Conflicting legacy service-token custody.' >&2
    builtin exit 1
  }
  owned_molty_op_service_token_file="$(/usr/bin/mktemp /tmp/peekaboo-molty-op-token.XXXXXX)" || builtin exit 1
  PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE="$owned_molty_op_service_token_file"
  printf '%s' "$MOLTY_OP_SERVICE_ACCOUNT_TOKEN" > "$PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE"
  /bin/chmod 600 "$PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE"
  builtin export PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE
  builtin unset MOLTY_OP_SERVICE_ACCOUNT_TOKEN
fi
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
builtin export PATH

fail() {
  printf 'build-terminal-artifacts: %s\n' "$*" >&2
  exit 1
}

expose_service_tokens() {
  if [[ -n "${PEEKABOO_OP_SERVICE_TOKEN_FILE:-}" ]]; then
    OP_SERVICE_ACCOUNT_TOKEN="$(<"$PEEKABOO_OP_SERVICE_TOKEN_FILE")"
    builtin export OP_SERVICE_ACCOUNT_TOKEN
  fi
  if [[ -n "${PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE:-}" ]]; then
    MOLTY_OP_SERVICE_ACCOUNT_TOKEN="$(<"$PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE")"
    builtin export MOLTY_OP_SERVICE_ACCOUNT_TOKEN
  fi
}

hide_service_tokens() {
  builtin unset OP_SERVICE_ACCOUNT_TOKEN MOLTY_OP_SERVICE_ACCOUNT_TOKEN
}

usage() {
  cat <<'EOF'
Usage: scripts/build-terminal-artifacts.sh COMMAND [options]

Commands:
  build       Credential-free compilation and unsigned input sealing.
  sign-code   Codesign-only private snapshot of CLI and both apps.
  build-dmg   Credential-free DMG construction from notarized Peekaboo.app.
  sign-dmg    Codesign-only private snapshot of the unsigned DMG.
  publish     Credential-free verification and atomic artifact publication.
  check-helper Verify the exact credential runner without resolving credentials.
  all         Orchestrate every phase, including narrow notary-only children.

Options:
  --stage PATH   New or existing source-addressed stage.
  --output PATH  New final artifact directory for publish/all.

Notary submission is deliberately owned only by notarize-terminal-artifact.sh.
This workflow never tags, uploads, edits appcast.xml, or publishes npm.
EOF
}

if [[ "$COMMAND" == -h || "$COMMAND" == --help ]]; then
  usage
  exit 0
fi
while (($# > 0)); do
  case "$1" in
    --stage) STAGE_DIR="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done
case "$COMMAND" in
  build|sign-code|build-dmg|sign-dmg|publish|check-helper|all) ;;
  *) usage >&2; fail 'invalid command' ;;
esac
if [[ "$COMMAND" != all ]]; then
  cleanup_service_token_files
  PEEKABOO_OP_SERVICE_TOKEN_FILE=""
  PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE=""
  builtin unset PEEKABOO_OP_SERVICE_TOKEN_FILE PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE
  trap - EXIT
fi

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

assert_clean_phase_environment() {
  terminal_artifact_assert_build_env_is_clean || fail 'credential reached a non-notary phase'
}

require_clean_source() {
  SOURCE_COMMIT="$(peekaboo_require_source_commit "$ROOT_DIR")" || fail 'clean exact source required'
  VERSION="$(/usr/bin/plutil -extract version raw -o - "$ROOT_DIR/package.json")" || fail 'package version missing'
  DEPENDENCY_LOCK_SHA256="$(/usr/bin/shasum -a 256 "$CANONICAL_LOCK" | /usr/bin/awk '{print $1}')"
}

validate_version_surfaces() {
  [[ "$("$ROOT_DIR/scripts/validate-release-version-surfaces.sh")" == "$VERSION" ]] || \
    fail 'release version surfaces disagree'
}

record_release_helper() {
  local candidate helper_repo helper_commit helper_sha helper_lib_sha
  [[ -z "${MAC_RELEASE_TOOL+x}" ]] || fail 'terminal artifacts reject MAC_RELEASE_TOOL overrides'
  for candidate in \
    "$ROOT_DIR/../agent-scripts/skills/release-mac-app/scripts/mac-release" \
    "$HOME/Projects/agent-scripts/skills/release-mac-app/scripts/mac-release"; do
    [[ -x "$candidate" ]] && break
    candidate=""
  done
  [[ -n "$candidate" ]] || fail 'trusted mac-release helper is missing'
  helper_repo="$(/usr/bin/git -C "$(dirname "$candidate")" rev-parse --show-toplevel)" || \
    fail 'mac-release helper is not in a Git checkout'
  helper_commit="$(/usr/bin/git -C "$helper_repo" rev-parse HEAD)"
  [[ "$helper_commit" == "$EXPECTED_RELEASE_HELPER_COMMIT" ]] || \
    fail "mac-release helper commit mismatch: $helper_commit"
  [[ -z "$(/usr/bin/git -C "$helper_repo" status --porcelain --untracked-files=no)" ]] || \
    fail 'mac-release helper checkout has tracked changes'
  helper_sha="$(/usr/bin/shasum -a 256 "$candidate" | /usr/bin/awk '{print $1}')"
  helper_lib_sha="$(/usr/bin/shasum -a 256 "$(dirname "$candidate")/lib/mac_release.sh" | /usr/bin/awk '{print $1}')"
  [[ "$helper_sha" == "$EXPECTED_RELEASE_HELPER_SHA" && "$helper_lib_sha" == "$EXPECTED_RELEASE_HELPER_LIB_SHA" ]] || \
    fail 'mac-release package-run contract hash mismatch'
  RELEASE_HELPER_COMMIT="$helper_commit"
  RELEASE_HELPER_EXECUTABLE_SHA256="$helper_sha"
  RELEASE_HELPER_LIBRARY_SHA256="$helper_lib_sha"
}

record_toolchain() {
  local selected
  selected="${DEVELOPER_DIR:-$(terminal_artifact_run_build /usr/bin/xcode-select -p)}"
  EFFECTIVE_DEVELOPER_DIR="$(realpath "$selected")"
  XCODEBUILD_VERSION="$(terminal_artifact_run_build /usr/bin/env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    /usr/bin/xcodebuild -version)"
  SDK_VERSION="$(terminal_artifact_run_build /usr/bin/env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    /usr/bin/xcrun --sdk macosx --show-sdk-version)"
  SWIFTC_VERSION="$(terminal_artifact_run_build /usr/bin/env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    /usr/bin/xcrun swiftc --version 2>&1)"
  record_release_helper
}

set_stage_paths() {
  [[ -n "$STAGE_DIR" ]] || STAGE_DIR="/tmp/peekaboo-terminal-build-${SOURCE_COMMIT:?}"
  [[ "$STAGE_DIR" == /* && ! -L "$STAGE_DIR" ]] || fail 'stage path must be absolute and unsymlinked'
  BUILD_MANIFEST="$STAGE_DIR/terminal-build-manifest.json"
  UNSIGNED_CLI="$STAGE_DIR/cli"
  UNSIGNED_APP="$STAGE_DIR/peekaboo-derived/Build/Products/Release/Peekaboo.app"
  UNSIGNED_PLAYGROUND="$STAGE_DIR/playground/Playground.app"
  UNSIGNED_NODE="$STAGE_DIR/node/PeekabooQualificationNode.app"
  UNSIGNED_QUALIFICATION_ROOT="$STAGE_DIR/qualification"
  UNSIGNED_CONTROLLER="$UNSIGNED_QUALIFICATION_ROOT/peekaboo-certification-controller"
  UNSIGNED_MONITOR="$UNSIGNED_QUALIFICATION_ROOT/background-computer-use-probe"
  SOURCE_SNAPSHOT_ROOT="$STAGE_DIR/qualification-source"
  SOURCE_RECEIPT="$STAGE_DIR/controller-source-manifest.json"
  SOURCE_TREE_MANIFEST="$STAGE_DIR/qualification-source-tree.json"
  SIGNED_ROOT="$STAGE_DIR/signed"
  SIGNED_CLI="$SIGNED_ROOT/cli"
  SIGNED_APP="$SIGNED_ROOT/Peekaboo.app"
  SIGNED_PLAYGROUND="$SIGNED_ROOT/Playground.app"
  SIGNED_NODE="$SIGNED_ROOT/PeekabooQualificationNode.app"
  SIGNED_CONTROLLER_ROOT="$SIGNED_ROOT/qualification"
  NOTARY_ROOT="$STAGE_DIR/notary"
  CLI_NOTARY_TRANSACTION="$NOTARY_ROOT/cli"
  APP_NOTARY_TRANSACTION="$NOTARY_ROOT/peekaboo-app"
  PLAYGROUND_NOTARY_TRANSACTION="$NOTARY_ROOT/playground-app"
  NODE_NOTARY_TRANSACTION="$NOTARY_ROOT/qualification-node-app"
  CONTROLLER_NOTARY_TRANSACTION="$NOTARY_ROOT/certification-controller"
  DMG_NOTARY_TRANSACTION="$NOTARY_ROOT/peekaboo-dmg"
  NOTARIZED_APP="$APP_NOTARY_TRANSACTION/Peekaboo.app"
  NOTARIZED_PLAYGROUND="$PLAYGROUND_NOTARY_TRANSACTION/Playground.app"
  NOTARIZED_NODE="$NODE_NOTARY_TRANSACTION/PeekabooQualificationNode.app"
  DMG_ROOT="$STAGE_DIR/dmg"
  UNSIGNED_DMG="$DMG_ROOT/Peekaboo-$VERSION.unsigned.dmg"
  SIGNED_DMG="$DMG_ROOT/Peekaboo-$VERSION.signed.dmg"
  DMG_PAYLOAD_RECEIPT="$DMG_ROOT/payload.json"
  NOTARIZED_DMG="$DMG_NOTARY_TRANSACTION/$(basename "$SIGNED_DMG")"
}

tree_digest() {
  local target="$1"
  local output
  output="$(mktemp /tmp/peekaboo-tree-digest.XXXXXX)"
  terminal_artifact_tree_manifest "$target" "$output"
  /usr/bin/shasum -a 256 "$output" | /usr/bin/awk '{print $1}'
  rm -f "$output"
}

verify_playground_manifest() {
  local app="$1"
  local manifest="$app/Contents/Resources/PeekabooPlaygroundSource.json"
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  jq -e \
    --arg sourceCommit "$SOURCE_COMMIT" \
    --arg sourceTree "$(git -C "$ROOT_DIR" rev-parse HEAD:Apps/Playground)" \
    --arg lockPath "$CANONICAL_LOCK_RELATIVE" \
    --arg lockSHA "$DEPENDENCY_LOCK_SHA256" \
    --arg marketingVersion "$VERSION" \
    --arg developerDir "$EFFECTIVE_DEVELOPER_DIR" \
    --arg xcodebuildVersion "$XCODEBUILD_VERSION" \
    --arg sdkVersion "$SDK_VERSION" \
    --arg swiftcVersion "$SWIFTC_VERSION" '
      type == "object" and keys == [
        "bundle_identifier", "configuration", "dependency_lock_path", "dependency_lock_sha256",
        "developer_dir", "marketing_version", "scheme", "sdk_version", "source_commit",
        "source_tree", "swiftc_version", "version", "workspace", "xcodebuild_version"
      ] and .version == 2 and .source_commit == $sourceCommit and .source_tree == $sourceTree and
      .dependency_lock_path == $lockPath and .dependency_lock_sha256 == $lockSHA and
      .workspace == "Apps/Peekaboo.xcworkspace" and .scheme == "Playground" and
      .configuration == "Debug" and .bundle_identifier == "boo.peekaboo.playground.debug" and
      .marketing_version == $marketingVersion and .developer_dir == $developerDir and
      .xcodebuild_version == $xcodebuildVersion and .sdk_version == $sdkVersion and
      .swiftc_version == $swiftcVersion
    ' "$manifest" >/dev/null
}

verify_node_source_manifest() {
  local app="$1"
  local mode="${2:-unsigned}"
  local pin_mode="${3:-${BUILD_MODE:-production}}"
  local manifest="$app/Contents/Resources/PeekabooQualificationNodeSource.json"
  local node_binary="$app/Contents/MacOS/node"
  local license="$app/Contents/Resources/LICENSE"
  local entitlements="$app/Contents/Resources/qualification-node.entitlements"
  [[ -f "$manifest" && -x "$node_binary" && -f "$license" && -f "$entitlements" ]] || return 1
  jq -e \
    --arg pinMode "$pin_mode" \
    --arg licenseSHA "$(/usr/bin/shasum -a 256 "$license" | /usr/bin/awk '{print $1}')" \
    --arg entitlementsSHA "$(/usr/bin/shasum -a 256 "$entitlements" | /usr/bin/awk '{print $1}')" \
    --arg expectedEntitlementsSHA "$(/usr/bin/shasum -a 256 "$ROOT_DIR/scripts/qualification-node.entitlements" | /usr/bin/awk '{print $1}')" \
    --arg binarySHA "$(/usr/bin/shasum -a 256 "$node_binary" | /usr/bin/awk '{print $1}')" \
    --argjson binarySize "$(/usr/bin/stat -f%z "$node_binary")" '
      type == "object" and keys == ["architectures", "entitlements", "executable_path", "identifier", "inputs", "license",
        "runtime_version", "universal_binary_sha256", "universal_binary_size", "version"] and
      .version == 1 and .runtime_version == "24.15.0" and
      .identifier == "boo.peekaboo.qualification-node" and .executable_path == "Contents/MacOS/node" and
      .architectures == ["arm64", "x86_64"] and .license == {
        path: "Contents/Resources/LICENSE",
        sha256: $licenseSHA
      } and .entitlements == {
        path: "Contents/Resources/qualification-node.entitlements", sha256: $entitlementsSHA
      } and ($pinMode == "test_fixture" or $entitlementsSHA == $expectedEntitlementsSHA) and
      (.inputs | keys == ["arm64", "x86_64"]) and
      (.inputs.arm64 | keys == ["archive_sha256", "binary_sha256", "url"]) and
      (.inputs.x86_64 | keys == ["archive_sha256", "binary_sha256", "url"]) and
      .inputs.arm64.url == "https://nodejs.org/dist/v24.15.0/node-v24.15.0-darwin-arm64.tar.gz" and
      .inputs.x86_64.url == "https://nodejs.org/dist/v24.15.0/node-v24.15.0-darwin-x64.tar.gz" and
      (($pinMode == "production" and
        .universal_binary_sha256 == "f638dd249d1df9ff89764a312a510c55250f23ce40e977ac8b68a295161d6f3a" and
        .universal_binary_size == 242234784 and
        .license.sha256 == "4573185d56580da2b890ba34a85a409257640f1c5632eade4300137266194d18" and
        .inputs.arm64.archive_sha256 == "372331b969779ab5d15b949884fc6eaf88d5afe87bde8ba881d6400b9100ffc4" and
        .inputs.arm64.binary_sha256 == "3200fbd9f7fd4410426dd541e10d1ab829d3472f270d743c7fabd1696c03fe32" and
        .inputs.x86_64.archive_sha256 == "ffd5ee293467927f3ee731a553eb88fd1f48cf74eebc2d74a6babe4af228673b" and
        .inputs.x86_64.binary_sha256 == "2a249a6a7015b0555c3448a77d226c1f3c8f62bd133d89044a2e1518cd16c4b3") or
       ($pinMode == "test_fixture" and .universal_binary_sha256 == $binarySHA and
        .universal_binary_size == $binarySize and
        (.inputs.arm64.archive_sha256 | test("^[0-9a-f]{64}$")) and
        (.inputs.arm64.binary_sha256 | test("^[0-9a-f]{64}$")) and
        (.inputs.x86_64.archive_sha256 | test("^[0-9a-f]{64}$")) and
        (.inputs.x86_64.binary_sha256 | test("^[0-9a-f]{64}$"))))
    ' "$manifest" >/dev/null || return 1
  if [[ "$pin_mode" == production && "$mode" == unsigned && \
    "$(/usr/bin/shasum -a 256 "$node_binary" | /usr/bin/awk '{print $1}')" != \
    "f638dd249d1df9ff89764a312a510c55250f23ce40e977ac8b68a295161d6f3a" ]]; then
    return 1
  fi
  archs=" $(/usr/bin/lipo -archs "$node_binary") "
  [[ "$archs" == *' arm64 '* && "$archs" == *' x86_64 '* && \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" == \
      boo.peekaboo.qualification-node && \
    "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == 24.15.0 ]]
}

verify_unsigned_stage() {
  local verify_dir
  [[ -f "$BUILD_MANIFEST" && ! -L "$BUILD_MANIFEST" ]] || fail 'build manifest missing'
  BUILD_MODE="$(jq -er .build_mode "$BUILD_MANIFEST")" || fail 'build mode missing'
  validate_version_surfaces
  jq -e \
    --arg sourceCommit "$SOURCE_COMMIT" --arg version "$VERSION" \
    --arg lockPath "$CANONICAL_LOCK_RELATIVE" --arg lockSHA "$DEPENDENCY_LOCK_SHA256" \
    --arg developerDir "$EFFECTIVE_DEVELOPER_DIR" --arg xcodebuildVersion "$XCODEBUILD_VERSION" \
    --arg sdkVersion "$SDK_VERSION" --arg swiftcVersion "$SWIFTC_VERSION" \
    --argjson manifestKeys "$TERMINAL_ARTIFACT_BUILD_MANIFEST_KEYS_JSON" '
      type == "object" and keys == $manifestKeys and
      .version == 1 and (.build_mode == "production" or .build_mode == "test_fixture") and
      .source_commit == $sourceCommit and .marketing_version == $version and
      .dependency_lock_path == $lockPath and .dependency_lock_sha256 == $lockSHA and
      .toolchain == {developer_dir: $developerDir, xcodebuild_version: $xcodebuildVersion,
        sdk_version: $sdkVersion, swiftc_version: $swiftcVersion} and
      .release_helper == {commit: "20ab9a5e6bb1107788366726868f1a9b4c16d953",
        executable_sha256: "e65e06ef89ec90ebfc537d28748a3c4de8ce89bd09b51e4d67ba4bdd95427255",
        library_sha256: "c29d3c46506c2d0bd2db7ab688bd3108d54e8824074a4fe800de6e3fe17284c9"} and
      (.unsigned_inputs | keys == ["cli_inventory_sha256", "peekaboo_inventory_sha256",
        "playground_inventory_sha256", "qualification_inventory_sha256",
        "qualification_node_inventory_sha256", "qualification_source_inventory_sha256"] and
        all(.[]; test("^[0-9a-f]{64}$")))
    ' "$BUILD_MANIFEST" >/dev/null || fail 'build manifest does not match source/toolchain'

  verify_dir="$(mktemp -d /tmp/peekaboo-stage-verify.XXXXXX)"
  terminal_artifact_tree_manifest "$UNSIGNED_CLI" "$verify_dir/cli.json"
  terminal_artifact_tree_manifest "$UNSIGNED_APP" "$verify_dir/app.json"
  terminal_artifact_tree_manifest "$UNSIGNED_PLAYGROUND" "$verify_dir/playground.json"
  terminal_artifact_tree_manifest "$UNSIGNED_NODE" "$verify_dir/node.json"
  terminal_artifact_tree_manifest "$UNSIGNED_QUALIFICATION_ROOT" "$verify_dir/qualification.json"
  terminal_artifact_tree_manifest "$SOURCE_SNAPSHOT_ROOT" "$verify_dir/qualification-source.json"
  [[ "$(/usr/bin/shasum -a 256 "$verify_dir/cli.json" | /usr/bin/awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.cli_inventory_sha256 "$BUILD_MANIFEST")" ]] || fail 'CLI stage changed'
  [[ "$(/usr/bin/shasum -a 256 "$verify_dir/app.json" | /usr/bin/awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.peekaboo_inventory_sha256 "$BUILD_MANIFEST")" ]] || fail 'app stage changed'
  [[ "$(/usr/bin/shasum -a 256 "$verify_dir/playground.json" | /usr/bin/awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.playground_inventory_sha256 "$BUILD_MANIFEST")" ]] || \
    fail 'Playground stage changed'
  [[ "$(/usr/bin/shasum -a 256 "$verify_dir/node.json" | /usr/bin/awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.qualification_node_inventory_sha256 "$BUILD_MANIFEST")" ]] || \
    fail 'qualification Node stage changed'
  [[ "$(/usr/bin/shasum -a 256 "$verify_dir/qualification.json" | /usr/bin/awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.qualification_inventory_sha256 "$BUILD_MANIFEST")" ]] || \
    fail 'qualification tool stage changed'
  [[ "$(/usr/bin/shasum -a 256 "$verify_dir/qualification-source.json" | /usr/bin/awk '{print $1}')" == \
    "$(jq -r .unsigned_inputs.qualification_source_inventory_sha256 "$BUILD_MANIFEST")" ]] || \
    fail 'qualification source snapshot changed'
  /usr/bin/cmp -s "$SOURCE_TREE_MANIFEST" "$verify_dir/qualification-source.json" || \
    fail 'qualification source tree receipt changed'
  rm -rf -- "$verify_dir"

  cli_source="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$UNSIGNED_CLI/peekaboo" \
    --key PeekabooSourceCommit)"
  cli_version="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$UNSIGNED_CLI/peekaboo" \
    --key CFBundleShortVersionString)"
  app_source="$(/usr/libexec/PlistBuddy -c 'Print :PeekabooSourceCommit' "$UNSIGNED_APP/Contents/Info.plist")"
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$UNSIGNED_APP/Contents/Info.plist")"
  controller_source="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$UNSIGNED_CONTROLLER" \
    --key PeekabooSourceCommit)"
  controller_version="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$UNSIGNED_CONTROLLER" \
    --key CFBundleShortVersionString)"
  monitor_source="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$UNSIGNED_MONITOR" \
    --key PeekabooSourceCommit)"
  monitor_version="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$UNSIGNED_MONITOR" \
    --key CFBundleShortVersionString)"
  [[ "$cli_source" == "$SOURCE_COMMIT" && "$app_source" == "$SOURCE_COMMIT" && \
    "$controller_source" == "$SOURCE_COMMIT" && "$monitor_source" == "$SOURCE_COMMIT" && \
    "$cli_version" == "$VERSION" && "$app_version" == "$VERSION" && \
    "$controller_version" == "$VERSION" && "$monitor_version" == "$VERSION" ]] || \
    fail 'embedded source/version mismatch'
  certification_source_sha="$(jq -er .aggregate_sha256 "$SOURCE_RECEIPT")"
  certification_catalog_sha="$(jq -er .catalog_sha256 "$SOURCE_RECEIPT")"
  for provenance_binary in "$UNSIGNED_CLI/peekaboo" "$UNSIGNED_CONTROLLER" "$UNSIGNED_MONITOR"; do
    [[ "$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$provenance_binary" \
      --key PeekabooCertificationSourceManifestSHA256)" == "$certification_source_sha" && \
      "$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$provenance_binary" \
      --key PeekabooCertificationCatalogSHA256)" == "$certification_catalog_sha" ]] || \
      fail 'signed producer source anchor mismatch'
  done
  [[ "$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$UNSIGNED_MONITOR" \
    --key PeekabooQualificationMonitorSourceSHA256)" == \
    "$(/usr/bin/shasum -a 256 "$SOURCE_SNAPSHOT_ROOT/scripts/support/background-computer-use-probe.swift" | \
      /usr/bin/awk '{print $1}')" ]] || fail 'monitor source anchor mismatch'
  verify_playground_manifest "$UNSIGNED_PLAYGROUND" || fail 'Playground manifest mismatch'
  verify_node_source_manifest "$UNSIGNED_NODE" || fail 'qualification Node source contract mismatch'
  if ! controller_native_error="$(native_only_verify_macho "$UNSIGNED_CONTROLLER" \
    'certification controller' /usr/bin/nm /usr/bin/strings)"; then
    fail "$controller_native_error"
  fi
  if ! monitor_native_error="$(native_only_verify_macho "$UNSIGNED_MONITOR" \
    'qualification monitor' /usr/bin/nm /usr/bin/strings)"; then
    fail "$monitor_native_error"
  fi
}

build_phase() {
  local stage_destination build_root cli_lock build_result
  assert_clean_phase_environment
  require_clean_source
  record_toolchain
  set_stage_paths
  case "${PEEKABOO_TERMINAL_TEST_MODE:-0}" in
    1|true|yes|on) BUILD_MODE=test_fixture ;;
    0|false|no|off|'') BUILD_MODE=production ;;
    *) fail 'PEEKABOO_TERMINAL_TEST_MODE must be boolean' ;;
  esac
  stage_destination="$STAGE_DIR"
  [[ ! -e "$stage_destination" && ! -L "$stage_destination" ]] || \
    fail "stage already exists: $stage_destination"
  mkdir -p "$(dirname "$stage_destination")"
  build_root="$(mktemp -d "$(dirname "$stage_destination")/.peekaboo-terminal-build.XXXXXX")"
  STAGE_DIR="$build_root"
  set_stage_paths
  cleanup_build_phase() {
    [[ -z "${cli_lock:-}" ]] || rm -f -- "$cli_lock"
    [[ -z "${build_root:-}" ]] || rm -rf -- "$build_root"
  }
  trap cleanup_build_phase EXIT
  trap 'cleanup_build_phase; exit 130' INT
  trap 'cleanup_build_phase; exit 143' TERM HUP
  [[ -f "$CANONICAL_LOCK" && ! -L "$CANONICAL_LOCK" ]] || fail 'canonical dependency lock missing'
  mkdir -p "$UNSIGNED_CLI" "$STAGE_DIR/inventories" "$STAGE_DIR/node" "$UNSIGNED_QUALIFICATION_ROOT" \
    "$STAGE_DIR/peekaboo-derived" "$STAGE_DIR/playground"
  build_source_snapshot
  certification_source_sha="$(jq -er .aggregate_sha256 "$SOURCE_RECEIPT")"
  certification_catalog_sha="$(jq -er .catalog_sha256 "$SOURCE_RECEIPT")"
  terminal_artifact_run_build "$ROOT_DIR/scripts/build-node-runtime-macos.sh" --output-app "$UNSIGNED_NODE"
  validate_version_surfaces

  cli_lock="$ROOT_DIR/Apps/CLI/Package.resolved"
  [[ ! -e "$cli_lock" && ! -L "$cli_lock" ]] || fail 'remove noncanonical CLI lock'
  cp "$CANONICAL_LOCK" "$cli_lock"
  set +e
  terminal_artifact_run_build /usr/bin/env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    MAC_RELEASE_CODESIGN_IDENTITY=- CODESIGN_TIMESTAMP=off PEEKABOO_USE_RESOLVED_VERSIONS=1 \
    PEEKABOO_CERTIFICATION_SOURCE_MANIFEST_SHA256="$certification_source_sha" \
    PEEKABOO_CERTIFICATION_CATALOG_SHA256="$certification_catalog_sha" \
    pnpm run build:swift:all
  build_result=$?
  set -e
  rm -f "$cli_lock"
  cli_lock=""
  ((build_result == 0)) || fail 'universal CLI build failed'
  cp "$ROOT_DIR/peekaboo" "$UNSIGNED_CLI/peekaboo"
  for runtime_library in "$ROOT_DIR"/libswiftCompatibility*.dylib; do
    [[ -e "$runtime_library" ]] && cp "$runtime_library" "$UNSIGNED_CLI/"
  done
  controller_arm="$(bash "$ROOT_DIR/scripts/resolve-swift-binary-path.sh" \
    "$ROOT_DIR/Apps/CLI" arm64 release peekaboo-certification-controller)"
  controller_x64="$(bash "$ROOT_DIR/scripts/resolve-swift-binary-path.sh" \
    "$ROOT_DIR/Apps/CLI" x86_64 release peekaboo-certification-controller)"
  /usr/bin/lipo -create -output "$UNSIGNED_CONTROLLER" "$controller_arm" "$controller_x64"
  /usr/bin/strip -Sxu "$UNSIGNED_CONTROLLER"
  [[ " $(/usr/bin/lipo -archs "$UNSIGNED_CONTROLLER") " == *' arm64 '* && \
    " $(/usr/bin/lipo -archs "$UNSIGNED_CONTROLLER") " == *' x86_64 '* ]] || fail 'controller is not universal'

  monitor_build="$STAGE_DIR/monitor-build"
  mkdir -p "$monitor_build"
  monitor_source="$SOURCE_SNAPSHOT_ROOT/scripts/support/background-computer-use-probe.swift"
  monitor_source_sha="$(/usr/bin/shasum -a 256 "$monitor_source" | /usr/bin/awk '{print $1}')"
  cat > "$monitor_build/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>boo.peekaboo.background-computer-use-probe</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$VERSION</string>
<key>PeekabooSourceCommit</key><string>$SOURCE_COMMIT</string>
<key>PeekabooCertificationSourceManifestSHA256</key><string>$certification_source_sha</string>
<key>PeekabooCertificationCatalogSHA256</key><string>$certification_catalog_sha</string>
<key>PeekabooQualificationMonitorSourceSHA256</key><string>$monitor_source_sha</string>
</dict></plist>
EOF
  for architecture in arm64 x86_64; do
    terminal_artifact_run_build /usr/bin/env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" /usr/bin/xcrun swiftc \
      -target "$architecture-apple-macos15.0" -O "$monitor_source" \
      -o "$monitor_build/monitor-$architecture" \
      -framework AppKit -framework ApplicationServices -framework CoreGraphics \
      -framework CryptoKit -framework Security \
      -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$monitor_build/Info.plist"
  done
  /usr/bin/lipo -create -output "$UNSIGNED_MONITOR" "$monitor_build/monitor-arm64" "$monitor_build/monitor-x86_64"
  /usr/bin/strip -Sxu "$UNSIGNED_MONITOR"
  [[ " $(/usr/bin/lipo -archs "$UNSIGNED_MONITOR") " == *' arm64 '* && \
    " $(/usr/bin/lipo -archs "$UNSIGNED_MONITOR") " == *' x86_64 '* ]] || fail 'monitor is not universal'
  /usr/bin/xcrun swift-stdlib-tool --copy \
    --scan-executable "$UNSIGNED_CONTROLLER" --scan-executable "$UNSIGNED_MONITOR" \
    --platform macosx --destination "$UNSIGNED_QUALIFICATION_ROOT"
  for runtime_library in "$UNSIGNED_QUALIFICATION_ROOT"/libswiftCompatibility*.dylib; do
    [[ -e "$runtime_library" ]] || continue
    /usr/bin/codesign --force --sign - --options runtime --timestamp=none "$runtime_library"
  done
  "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" "$UNSIGNED_CONTROLLER" "$UNSIGNED_QUALIFICATION_ROOT"
  "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" "$UNSIGNED_MONITOR" "$UNSIGNED_QUALIFICATION_ROOT"

  build_number="$(peekaboo_release_build_number "$VERSION")"
  terminal_artifact_run_build /usr/bin/env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" /usr/bin/xcodebuild \
    -workspace "$ROOT_DIR/Apps/Peekaboo.xcworkspace" -scheme Peekaboo -configuration Release \
    -destination platform=macOS,arch=arm64 -derivedDataPath "$STAGE_DIR/peekaboo-derived" \
    -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -quiet \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$build_number" PEEKABOO_SOURCE_COMMIT="$SOURCE_COMMIT" \
    CODE_SIGN_IDENTITY= CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
  terminal_artifact_run_build /usr/bin/env DEVELOPER_DIR="$EFFECTIVE_DEVELOPER_DIR" \
    "$ROOT_DIR/scripts/build-playground-artifact.sh" --configuration Debug --output-app "$UNSIGNED_PLAYGROUND"
  peekaboo_verify_source_commit "$ROOT_DIR" "$SOURCE_COMMIT" || fail 'source changed during build'

  terminal_artifact_tree_manifest "$UNSIGNED_CLI" "$STAGE_DIR/inventories/cli.json"
  terminal_artifact_tree_manifest "$UNSIGNED_APP" "$STAGE_DIR/inventories/peekaboo-app.json"
  terminal_artifact_tree_manifest "$UNSIGNED_PLAYGROUND" "$STAGE_DIR/inventories/playground-app.json"
  terminal_artifact_tree_manifest "$UNSIGNED_NODE" "$STAGE_DIR/inventories/qualification-node-app.json"
  terminal_artifact_tree_manifest "$UNSIGNED_QUALIFICATION_ROOT" "$STAGE_DIR/inventories/qualification.json"
  chmod 444 "$STAGE_DIR"/inventories/*.json
  jq -n \
    --arg sourceCommit "$SOURCE_COMMIT" --arg version "$VERSION" --arg buildMode "$BUILD_MODE" \
    --arg lockPath "$CANONICAL_LOCK_RELATIVE" --arg lockSHA "$DEPENDENCY_LOCK_SHA256" \
    --arg developerDir "$EFFECTIVE_DEVELOPER_DIR" --arg xcodebuildVersion "$XCODEBUILD_VERSION" \
    --arg sdkVersion "$SDK_VERSION" --arg swiftcVersion "$SWIFTC_VERSION" \
    --arg cliInventory "$(/usr/bin/shasum -a 256 "$STAGE_DIR/inventories/cli.json" | /usr/bin/awk '{print $1}')" \
    --arg appInventory "$(/usr/bin/shasum -a 256 "$STAGE_DIR/inventories/peekaboo-app.json" | /usr/bin/awk '{print $1}')" \
    --arg playgroundInventory "$(/usr/bin/shasum -a 256 "$STAGE_DIR/inventories/playground-app.json" | /usr/bin/awk '{print $1}')" \
    --arg nodeInventory "$(/usr/bin/shasum -a 256 "$STAGE_DIR/inventories/qualification-node-app.json" | /usr/bin/awk '{print $1}')" \
    --arg qualificationInventory "$(/usr/bin/shasum -a 256 "$STAGE_DIR/inventories/qualification.json" | /usr/bin/awk '{print $1}')" \
    --arg qualificationSourceInventory "$(/usr/bin/shasum -a 256 "$SOURCE_TREE_MANIFEST" | /usr/bin/awk '{print $1}')" '
      {version: 1, build_mode: $buildMode, source_commit: $sourceCommit, marketing_version: $version,
       dependency_lock_path: $lockPath, dependency_lock_sha256: $lockSHA,
       release_helper: {commit: "20ab9a5e6bb1107788366726868f1a9b4c16d953",
         executable_sha256: "e65e06ef89ec90ebfc537d28748a3c4de8ce89bd09b51e4d67ba4bdd95427255",
         library_sha256: "c29d3c46506c2d0bd2db7ab688bd3108d54e8824074a4fe800de6e3fe17284c9"},
       toolchain: {developer_dir: $developerDir, xcodebuild_version: $xcodebuildVersion,
         sdk_version: $sdkVersion, swiftc_version: $swiftcVersion},
       unsigned_inputs: {cli_inventory_sha256: $cliInventory,
         peekaboo_inventory_sha256: $appInventory,
         playground_inventory_sha256: $playgroundInventory,
         qualification_node_inventory_sha256: $nodeInventory,
         qualification_inventory_sha256: $qualificationInventory,
         qualification_source_inventory_sha256: $qualificationSourceInventory}}
    ' > "$BUILD_MANIFEST"
  chmod 444 "$BUILD_MANIFEST"
  verify_unsigned_stage
  "$ROOT_DIR/scripts/atomic-rename-exclusive.rb" "$build_root" "$stage_destination"
  build_root=""
  trap - EXIT INT TERM HUP
  STAGE_DIR="$stage_destination"
  set_stage_paths
  printf 'Build stage: %s\n' "$STAGE_DIR"
}

verify_foundation_signature() {
  local target="$1"
  local details authority team_id
  /usr/bin/codesign --verify --strict -R="$EXPECTED_REQUIREMENT" "$target"
  details="$(terminal_artifact_signature_details "$target")"
  authority="$(terminal_artifact_signature_field_from_details "$details" Authority)"
  team_id="$(terminal_artifact_signature_field_from_details "$details" TeamIdentifier)"
  [[ "$authority" == "$EXPECTED_IDENTITY" && "$team_id" == "$EXPECTED_TEAM_ID" ]]
}

architecture_cdhashes_json() {
  local binary="$1"
  local expected_identifier="$2"
  local arm_details x64_details arm_id x64_id arm_hash x64_hash
  arm_details="$(/usr/bin/codesign -dvvv --arch arm64 "$binary" 2>&1)" || return 1
  x64_details="$(/usr/bin/codesign -dvvv --arch x86_64 "$binary" 2>&1)" || return 1
  arm_id="$(terminal_artifact_signature_field_from_details "$arm_details" Identifier)"
  x64_id="$(terminal_artifact_signature_field_from_details "$x64_details" Identifier)"
  [[ "$arm_id" == "$expected_identifier" && "$x64_id" == "$expected_identifier" ]] || return 1
  for details in "$arm_details" "$x64_details"; do
    [[ "$(terminal_artifact_signature_field_from_details "$details" Authority)" == "$EXPECTED_IDENTITY" && \
      "$(terminal_artifact_signature_field_from_details "$details" TeamIdentifier)" == "$EXPECTED_TEAM_ID" ]] || return 1
  done
  arm_hash="$(terminal_artifact_signature_field_from_details "$arm_details" CDHash)"
  x64_hash="$(terminal_artifact_signature_field_from_details "$x64_details" CDHash)"
  [[ "$arm_hash" =~ ^[0-9a-fA-F]{40,64}$ && "$x64_hash" =~ ^[0-9a-fA-F]{40,64}$ ]] || return 1
  arm_hash="$(printf '%s' "$arm_hash" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  x64_hash="$(printf '%s' "$x64_hash" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  jq -cn --arg arm64 "$arm_hash" --arg x86_64 "$x64_hash" '{arm64: $arm64, x86_64: $x86_64}'
}

node_arch_cdhashes_json() {
  architecture_cdhashes_json "$1" boo.peekaboo.qualification-node
}

verify_node_entitlements() {
  local binary="$1"
  local work_dir expected_json actual_plist actual_json architecture
  work_dir="$(mktemp -d /tmp/peekaboo-node-entitlements.XXXXXX)" || return 1
  expected_json="$(/usr/bin/plutil -convert json -o - "$ROOT_DIR/scripts/qualification-node.entitlements")" || {
    rm -rf -- "$work_dir"; return 1;
  }
  for architecture in arm64 x86_64; do
    actual_plist="$work_dir/$architecture.plist"
    /usr/bin/codesign -d --entitlements :- --arch "$architecture" "$binary" \
      > "$actual_plist" 2>/dev/null || { rm -rf -- "$work_dir"; return 1; }
    actual_json="$(/usr/bin/plutil -convert json -o - "$actual_plist")" || {
      rm -rf -- "$work_dir"; return 1;
    }
    [[ "$actual_json" == "$expected_json" ]] || { rm -rf -- "$work_dir"; return 1; }
  done
  rm -rf -- "$work_dir"
}

materialize_committed_file() {
  local relative_path="$1"
  local destination="$2"
  local tree_entry tree_mode
  [[ "$relative_path" =~ ^[A-Za-z0-9_./+-]+$ && "$relative_path" != /* &&
    "$relative_path" != */../* && "$relative_path" != ../* && "$relative_path" != */.. &&
    "$relative_path" != ./* && "$relative_path" != */./* && "$relative_path" != */. ]] ||
    fail "unsafe committed source path: $relative_path"
  tree_entry="$(/usr/bin/git -C "$ROOT_DIR" ls-tree "$SOURCE_COMMIT" -- "$relative_path")"
  tree_mode="${tree_entry%% *}"
  [[ "$tree_mode" == 100644 || "$tree_mode" == 100755 ]] || \
    fail "committed source is not a regular file: $relative_path"
  mkdir -p "$(dirname "$destination")"
  /usr/bin/git -C "$ROOT_DIR" show "$SOURCE_COMMIT:$relative_path" > "$destination"
  if [[ "$tree_mode" == 100755 ]]; then
    chmod 755 "$destination"
  else
    chmod 644 "$destination"
  fi
}

build_source_snapshot() {
  local source_path
  [[ ! -e "$SOURCE_SNAPSHOT_ROOT" && ! -e "$SOURCE_RECEIPT" && ! -e "$SOURCE_TREE_MANIFEST" ]] || \
    fail 'qualification source snapshot already exists'
  terminal_artifact_run_build node "$ROOT_DIR/scripts/controller-source-manifest.mjs" \
    --source-commit "$SOURCE_COMMIT" > "$SOURCE_RECEIPT"
  while IFS= read -r source_path; do
    materialize_committed_file "$source_path" "$SOURCE_SNAPSHOT_ROOT/$source_path"
  done < <(jq -r '.files[].path, .catalog_path' "$SOURCE_RECEIPT")
  for source_path in \
    scripts/support/background-computer-use-probe.swift \
    "$CANONICAL_LOCK_RELATIVE"; do
    materialize_committed_file "$source_path" "$SOURCE_SNAPSHOT_ROOT/$source_path"
  done
  find "$SOURCE_SNAPSHOT_ROOT" -type d -exec chmod 555 {} +
  find "$SOURCE_SNAPSHOT_ROOT" -type f -exec chmod 444 {} +
  chmod 444 "$SOURCE_RECEIPT"
  terminal_artifact_tree_manifest "$SOURCE_SNAPSHOT_ROOT" "$SOURCE_TREE_MANIFEST"
  chmod 444 "$SOURCE_TREE_MANIFEST"
}

sign_leaf() {
  "$ROOT_DIR/scripts/codesign-with-retry.sh" --force --options runtime --timestamp="$TIMESTAMP_URL" \
    --sign "$EXPECTED_IDENTITY" "$1"
}

sign_code_phase() {
  assert_clean_phase_environment
  require_clean_source
  record_toolchain
  set_stage_paths
  [[ "$(jq -r .build_mode "$BUILD_MANIFEST")" == production ]] || fail 'signing refuses fixture-built stage'
  verify_unsigned_stage
  [[ "${MAC_RELEASE_CODESIGN_IDENTITY:-}" == "$EXPECTED_IDENTITY" ]] || fail 'Foundation codesign lane required'
  [[ ! -e "$SIGNED_ROOT" && ! -L "$SIGNED_ROOT" ]] || fail 'signed output already exists'
  signing_root="$(mktemp -d "$STAGE_DIR/.signing.XXXXXX")"
  trap 'rm -rf -- "${signing_root:-}"' EXIT INT TERM HUP
  /usr/bin/ditto "$UNSIGNED_CLI" "$signing_root/cli"
  /usr/bin/ditto "$UNSIGNED_APP" "$signing_root/Peekaboo.app"
  /usr/bin/ditto "$UNSIGNED_PLAYGROUND" "$signing_root/Playground.app"
  /usr/bin/ditto "$UNSIGNED_NODE" "$signing_root/PeekabooQualificationNode.app"
  /usr/bin/ditto "$(dirname "$UNSIGNED_CONTROLLER")" "$signing_root/qualification"
  [[ "$(tree_digest "$signing_root/cli")" == "$(jq -r .unsigned_inputs.cli_inventory_sha256 "$BUILD_MANIFEST")" ]]
  [[ "$(tree_digest "$signing_root/Peekaboo.app")" == \
    "$(jq -r .unsigned_inputs.peekaboo_inventory_sha256 "$BUILD_MANIFEST")" ]]
  [[ "$(tree_digest "$signing_root/Playground.app")" == \
    "$(jq -r .unsigned_inputs.playground_inventory_sha256 "$BUILD_MANIFEST")" ]]
  [[ "$(tree_digest "$signing_root/PeekabooQualificationNode.app")" == \
    "$(jq -r .unsigned_inputs.qualification_node_inventory_sha256 "$BUILD_MANIFEST")" ]]
  [[ "$(tree_digest "$signing_root/qualification")" == \
    "$(jq -r .unsigned_inputs.qualification_inventory_sha256 "$BUILD_MANIFEST")" ]]
  verify_playground_manifest "$signing_root/Playground.app" || fail 'private Playground snapshot changed'
  [[ "$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$signing_root/cli/peekaboo" \
    --key PeekabooSourceCommit)" == "$SOURCE_COMMIT" ]] || fail 'private CLI snapshot changed'
  verify_node_source_manifest "$signing_root/PeekabooQualificationNode.app" || fail 'private Node snapshot changed'

  for runtime_library in "$signing_root"/cli/libswiftCompatibility*.dylib; do
    [[ -e "$runtime_library" ]] && sign_leaf "$runtime_library"
  done
  "$ROOT_DIR/scripts/codesign-with-retry.sh" --force --options runtime --timestamp="$TIMESTAMP_URL" \
    --identifier boo.peekaboo.peekaboo --sign "$EXPECTED_IDENTITY" "$signing_root/cli/peekaboo"
  "$ROOT_DIR/scripts/sign-release-app.sh" --app "$signing_root/Peekaboo.app" \
    --entitlements "$ROOT_DIR/Apps/Mac/Peekaboo/Peekaboo.entitlements" \
    --sign-identity "$EXPECTED_IDENTITY" --timestamp-url "$TIMESTAMP_URL"

  playground_main="$signing_root/Playground.app/Contents/MacOS/Playground"
  nested_bundle="$(find "$signing_root/Playground.app/Contents" -mindepth 1 -type d \
    \( -name '*.app' -o -name '*.framework' -o -name '*.xpc' \) -print -quit)"
  [[ -z "$nested_bundle" ]] || fail "unsupported Playground nested bundle: $nested_bundle"
  while IFS= read -r -d '' candidate; do
    [[ "$candidate" == "$playground_main" ]] && continue
    /usr/bin/file -b "$candidate" | /usr/bin/grep -q Mach-O && sign_leaf "$candidate"
  done < <(find "$signing_root/Playground.app/Contents" -type f -perm -111 -print0)
  sign_leaf "$signing_root/Playground.app"
  "$ROOT_DIR/scripts/codesign-with-retry.sh" --force --options runtime --timestamp="$TIMESTAMP_URL" \
    --entitlements "$ROOT_DIR/scripts/qualification-node.entitlements" \
    --identifier boo.peekaboo.qualification-node --sign "$EXPECTED_IDENTITY" \
    "$signing_root/PeekabooQualificationNode.app/Contents/MacOS/node"
  "$ROOT_DIR/scripts/codesign-with-retry.sh" --force --options runtime --timestamp="$TIMESTAMP_URL" \
    --entitlements "$ROOT_DIR/scripts/qualification-node.entitlements" \
    --sign "$EXPECTED_IDENTITY" "$signing_root/PeekabooQualificationNode.app"
  for runtime_library in "$signing_root"/qualification/libswiftCompatibility*.dylib; do
    [[ -e "$runtime_library" ]] && sign_leaf "$runtime_library"
  done
  "$ROOT_DIR/scripts/codesign-with-retry.sh" --force --options runtime --timestamp="$TIMESTAMP_URL" \
    --identifier boo.peekaboo.peekaboo-certification-controller --sign "$EXPECTED_IDENTITY" \
    "$signing_root/qualification/peekaboo-certification-controller"
  "$ROOT_DIR/scripts/codesign-with-retry.sh" --force --options runtime --timestamp="$TIMESTAMP_URL" \
    --identifier boo.peekaboo.background-computer-use-probe --sign "$EXPECTED_IDENTITY" \
    "$signing_root/qualification/background-computer-use-probe"

  verify_foundation_signature "$signing_root/cli/peekaboo" || fail 'CLI signer mismatch'
  architecture_cdhashes_json "$signing_root/cli/peekaboo" boo.peekaboo.peekaboo >/dev/null || \
    fail 'CLI per-architecture signature mismatch'
  /usr/bin/codesign --verify --deep --strict "$signing_root/Peekaboo.app"
  verify_foundation_signature "$signing_root/Peekaboo.app" || fail 'app signer mismatch'
  /usr/bin/codesign --verify --deep --strict "$signing_root/Playground.app"
  verify_foundation_signature "$signing_root/Playground.app" || fail 'Playground signer mismatch'
  /usr/bin/codesign --verify --deep --strict "$signing_root/PeekabooQualificationNode.app"
  verify_foundation_signature "$signing_root/PeekabooQualificationNode.app" || fail 'Node signer mismatch'
  node_arch_cdhashes_json "$signing_root/PeekabooQualificationNode.app/Contents/MacOS/node" >/dev/null || \
    fail 'Node per-architecture signature mismatch'
  verify_node_entitlements "$signing_root/PeekabooQualificationNode.app/Contents/MacOS/node" || \
    fail 'Node JIT entitlements mismatch'
  verify_foundation_signature "$signing_root/qualification/peekaboo-certification-controller" || \
    fail 'controller signer mismatch'
  controller_details="$(terminal_artifact_signature_details \
    "$signing_root/qualification/peekaboo-certification-controller")"
  [[ "$(terminal_artifact_signature_field_from_details "$controller_details" Identifier)" == \
    boo.peekaboo.peekaboo-certification-controller ]] || fail 'controller identifier mismatch'
  architecture_cdhashes_json "$signing_root/qualification/peekaboo-certification-controller" \
    boo.peekaboo.peekaboo-certification-controller >/dev/null || fail 'controller architecture identity mismatch'
  MAC_RELEASE_CODESIGN_IDENTITY="$EXPECTED_IDENTITY" MAC_RELEASE_CODESIGN_TEAM_ID="$EXPECTED_TEAM_ID" \
    "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" \
    "$signing_root/qualification/peekaboo-certification-controller" "$signing_root/qualification"
  verify_foundation_signature "$signing_root/qualification/background-computer-use-probe" || \
    fail 'monitor signer mismatch'
  monitor_details="$(terminal_artifact_signature_details "$signing_root/qualification/background-computer-use-probe")"
  [[ "$(terminal_artifact_signature_field_from_details "$monitor_details" Identifier)" == \
    boo.peekaboo.background-computer-use-probe ]] || fail 'monitor identifier mismatch'
  architecture_cdhashes_json "$signing_root/qualification/background-computer-use-probe" \
    boo.peekaboo.background-computer-use-probe >/dev/null || fail 'monitor architecture identity mismatch'
  MAC_RELEASE_CODESIGN_IDENTITY="$EXPECTED_IDENTITY" MAC_RELEASE_CODESIGN_TEAM_ID="$EXPECTED_TEAM_ID" \
    "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" \
    "$signing_root/qualification/background-computer-use-probe" "$signing_root/qualification"
  native_only_verify_macho "$signing_root/qualification/peekaboo-certification-controller" \
    'signed certification controller' /usr/bin/nm /usr/bin/strings >/dev/null || \
    fail 'signed controller violates native-only policy'
  native_only_verify_macho "$signing_root/qualification/background-computer-use-probe" \
    'signed qualification monitor' /usr/bin/nm /usr/bin/strings >/dev/null || \
    fail 'signed monitor violates native-only policy'
  "$ROOT_DIR/scripts/verify-native-only-app.sh" --app "$signing_root/Peekaboo.app"
  "$ROOT_DIR/scripts/verify-native-only-app.sh" --app "$signing_root/Playground.app"
  "$ROOT_DIR/scripts/verify-native-only-app.sh" --app "$signing_root/PeekabooQualificationNode.app"
  terminal_artifact_assert_no_xattrs "$signing_root" || fail 'signing introduced unbound xattrs'
  "$ROOT_DIR/scripts/atomic-rename-exclusive.rb" "$signing_root" "$SIGNED_ROOT"
  signing_root=""
  trap - EXIT INT TERM HUP
  printf 'Signed snapshot: %s\n' "$SIGNED_ROOT"
}

validate_notary_receipt() {
  local receipt="$1"
  local expected_kind="$2"
  local artifact="$3"
  local final_sha code_target signature_details code_cdhash code_identifier submission_sha submission_size
  [[ -f "$receipt" && ! -L "$receipt" ]] || return 1
  code_target="$artifact"
  [[ "$expected_kind" != controller_tree ]] || code_target="$artifact/peekaboo-certification-controller"
  [[ "$expected_kind" != cli_tree ]] || code_target="$artifact/peekaboo"
  signature_details="$(terminal_artifact_signature_details "$code_target")" || return 1
  code_cdhash="$(terminal_artifact_signature_field_from_details "$signature_details" CDHash)"
  code_cdhash="$(printf '%s' "$code_cdhash" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  code_identifier="$(terminal_artifact_signature_field_from_details "$signature_details" Identifier)"
  [[ "$(terminal_artifact_signature_field_from_details "$signature_details" Authority)" == "$EXPECTED_IDENTITY" &&
    "$(terminal_artifact_signature_field_from_details "$signature_details" TeamIdentifier)" == "$EXPECTED_TEAM_ID" &&
    "$code_cdhash" =~ ^[0-9a-fA-F]{40,64}$ && -n "$code_identifier" ]] || return 1
  submission_sha="$(jq -er .submission.sha256 "$receipt")" || return 1
  submission_size="$(jq -er .submission.size "$receipt")" || return 1
  [[ "$(jq -er .submission.path "$receipt")" == "notary/submissions/$submission_sha" &&
    -f "$(dirname "$receipt")/submission.bin" && \
    "$(/usr/bin/shasum -a 256 "$(dirname "$receipt")/submission.bin" | /usr/bin/awk '{print $1}')" == \
      "$submission_sha" && "$(/usr/bin/stat -f%z "$(dirname "$receipt")/submission.bin")" == "$submission_size" ]] || \
    return 1
  if [[ "$expected_kind" == app || "$expected_kind" == controller_tree || "$expected_kind" == cli_tree ]]; then
    retained_tree="$(dirname "$receipt")/tree.json"
    [[ -f "$retained_tree" ]] || return 1
    final_sha="$(/usr/bin/shasum -a 256 "$retained_tree" | /usr/bin/awk '{print $1}')"
    [[ "$(tree_digest "$artifact")" == "$final_sha" ]] || return 1
    jq -e --arg kind "$expected_kind" --arg sha "$final_sha" --arg team "$EXPECTED_TEAM_ID" \
      --arg authority "$EXPECTED_IDENTITY" --arg identifier "$code_identifier" --arg cdhash "$code_cdhash" \
      --argjson size "$(/usr/bin/stat -f%z "$retained_tree")" '
      .version == 2 and .kind == $kind and .status == "Accepted" and
      (.id | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")) and
      (.submission.sha256 | test("^[0-9a-f]{64}$")) and (.submission.size | integers) > 0 and
      .code_identity.authority == $authority and .code_identity.identifier == $identifier and
      .code_identity.team_id == $team and .code_identity.cdhash == $cdhash and
      (.code_identity.architectures | arrays | length > 0) and
      (.code_identity.cdhashes | objects | length > 0) and
      .final_artifact == {tree_manifest_sha256: $sha, tree_manifest_size: $size}
    ' "$receipt" >/dev/null
  else
    final_sha="$(/usr/bin/shasum -a 256 "$artifact" | /usr/bin/awk '{print $1}')"
    jq -e --arg kind "$expected_kind" --arg sha "$final_sha" --arg team "$EXPECTED_TEAM_ID" \
      --arg authority "$EXPECTED_IDENTITY" --arg identifier "$code_identifier" --arg cdhash "$code_cdhash" \
      --argjson size "$(/usr/bin/stat -f%z "$artifact")" '
      .version == 2 and .kind == $kind and .status == "Accepted" and
      (.id | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89aAbB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$")) and
      (.submission.sha256 | test("^[0-9a-f]{64}$")) and (.submission.size | integers) > 0 and
      .code_identity.authority == $authority and .code_identity.identifier == $identifier and
      .code_identity.team_id == $team and .code_identity.cdhash == $cdhash and
      (.code_identity.architectures | arrays | length > 0) and
      (.code_identity.cdhashes | objects | length > 0) and
      .final_artifact == {sha256: $sha, size: $size}
    ' "$receipt" >/dev/null
  fi
}

build_dmg_phase() {
  assert_clean_phase_environment
  require_clean_source
  record_toolchain
  set_stage_paths
  validate_notary_receipt "$APP_NOTARY_TRANSACTION/receipt.json" app "$NOTARIZED_APP" || \
    fail 'Peekaboo.app notary receipt mismatch'
  [[ ! -e "$DMG_ROOT" ]] || fail 'DMG stage already exists'
  dmg_build_root="$(mktemp -d "$STAGE_DIR/.dmg.XXXXXX")"
  trap 'rm -rf -- "${dmg_build_root:-}"' EXIT INT TERM HUP
  "$ROOT_DIR/scripts/build-terminal-dmg.sh" --app "$NOTARIZED_APP" \
    --output "$dmg_build_root/$(basename "$UNSIGNED_DMG")" --version "$VERSION"
  terminal_artifact_run_build node "$ROOT_DIR/scripts/terminal-dmg-payload.mjs" \
    --dmg "$dmg_build_root/$(basename "$UNSIGNED_DMG")" \
    --expected-app-tree "$APP_NOTARY_TRANSACTION/tree.json" \
    --tree-generator "$ROOT_DIR/scripts/artifact-tree-manifest.rb" > "$dmg_build_root/payload.json"
  chmod 444 "$dmg_build_root/payload.json"
  "$ROOT_DIR/scripts/atomic-rename-exclusive.rb" "$dmg_build_root" "$DMG_ROOT"
  dmg_build_root=""
  trap - EXIT INT TERM HUP
}

sign_dmg_phase() {
  assert_clean_phase_environment
  require_clean_source
  record_toolchain
  set_stage_paths
  [[ "${MAC_RELEASE_CODESIGN_IDENTITY:-}" == "$EXPECTED_IDENTITY" ]] || fail 'Foundation codesign lane required'
  [[ -f "$UNSIGNED_DMG" && ! -e "$SIGNED_DMG" ]] || fail 'unsigned DMG missing or signed output exists'
  signing_dmg=""
  dmg_payload_check=""
  trap 'rm -f -- "${signing_dmg:-}" "${dmg_payload_check:-}"' EXIT INT TERM HUP
  signing_dmg="$(mktemp "$DMG_ROOT/.signing.XXXXXX")"
  cp "$UNSIGNED_DMG" "$signing_dmg"
  dmg_payload_check="$(mktemp "$DMG_ROOT/.payload-check.XXXXXX")"
  terminal_artifact_run_build node "$ROOT_DIR/scripts/terminal-dmg-payload.mjs" \
    --dmg "$signing_dmg" --expected-app-tree "$APP_NOTARY_TRANSACTION/tree.json" \
    --tree-generator "$ROOT_DIR/scripts/artifact-tree-manifest.rb" > "$dmg_payload_check"
  /usr/bin/cmp -s "$DMG_PAYLOAD_RECEIPT" "$dmg_payload_check" || fail 'unsigned DMG payload changed before signing'
  rm -f "$dmg_payload_check"
  dmg_payload_check=""
  "$ROOT_DIR/scripts/codesign-with-retry.sh" --force --timestamp="$TIMESTAMP_URL" \
    --sign "$EXPECTED_IDENTITY" "$signing_dmg"
  verify_foundation_signature "$signing_dmg" || fail 'DMG signer mismatch'
  terminal_artifact_assert_no_xattrs "$signing_dmg" || fail 'DMG signing introduced xattrs'
  "$ROOT_DIR/scripts/atomic-rename-exclusive.rb" "$signing_dmg" "$SIGNED_DMG"
  signing_dmg=""
  trap - EXIT INT TERM HUP
}

verify_notarized_inputs() {
  validate_notary_receipt "$CLI_NOTARY_TRANSACTION/receipt.json" cli_tree "$SIGNED_CLI" || return 1
  validate_notary_receipt "$APP_NOTARY_TRANSACTION/receipt.json" app "$NOTARIZED_APP" || return 1
  validate_notary_receipt "$PLAYGROUND_NOTARY_TRANSACTION/receipt.json" app "$NOTARIZED_PLAYGROUND" || return 1
  validate_notary_receipt "$NODE_NOTARY_TRANSACTION/receipt.json" app "$NOTARIZED_NODE" || return 1
  validate_notary_receipt "$DMG_NOTARY_TRANSACTION/receipt.json" dmg "$NOTARIZED_DMG" || return 1
  validate_notary_receipt "$CONTROLLER_NOTARY_TRANSACTION/receipt.json" controller_tree \
    "$SIGNED_CONTROLLER_ROOT" || return 1
  /usr/bin/codesign --verify --strict --check-notarization -R=notarized "$SIGNED_CLI/peekaboo" || return 1
  /usr/bin/codesign --verify --deep --strict --check-notarization -R=notarized "$NOTARIZED_APP" || return 1
  /usr/bin/xcrun stapler validate "$NOTARIZED_APP" || return 1
  /usr/bin/codesign --verify --deep --strict --check-notarization -R=notarized "$NOTARIZED_PLAYGROUND" || return 1
  /usr/bin/xcrun stapler validate "$NOTARIZED_PLAYGROUND" || return 1
  /usr/bin/codesign --verify --deep --strict --check-notarization -R=notarized "$NOTARIZED_NODE" || return 1
  /usr/bin/xcrun stapler validate "$NOTARIZED_NODE" || return 1
  /usr/bin/codesign --verify --strict --check-notarization -R=notarized "$NOTARIZED_DMG" || return 1
  /usr/bin/xcrun stapler validate "$NOTARIZED_DMG" || return 1
  while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q Mach-O; then
      /usr/bin/codesign --verify --strict --check-notarization -R=notarized "$candidate" || return 1
    fi
  done < <(find "$SIGNED_CONTROLLER_ROOT" -type f -print0)
  while IFS= read -r -d '' candidate; do
    if /usr/bin/file -b "$candidate" | /usr/bin/grep -q Mach-O; then
      /usr/bin/codesign --verify --strict --check-notarization -R=notarized "$candidate" || return 1
    fi
  done < <(find "$SIGNED_CLI" -type f -print0)
}

retain_notary_transaction() {
  local transaction="$1"
  local receipt_name="$2"
  local submission_sha submission_size submission_path destination
  [[ -f "$transaction/receipt.json" && -f "$transaction/submission.bin" ]] || \
    fail "notary transaction is incomplete: $transaction"
  submission_sha="$(jq -er .submission.sha256 "$transaction/receipt.json")"
  submission_size="$(jq -er .submission.size "$transaction/receipt.json")"
  submission_path="$(jq -er .submission.path "$transaction/receipt.json")"
  [[ "$submission_path" == "notary/submissions/$submission_sha" && \
    "$(/usr/bin/shasum -a 256 "$transaction/submission.bin" | /usr/bin/awk '{print $1}')" == "$submission_sha" && \
    "$(/usr/bin/stat -f%z "$transaction/submission.bin")" == "$submission_size" ]] || \
    fail "notary submission retention mismatch: $transaction"
  destination="$publish_root/$submission_path"
  mkdir -p "$(dirname "$destination")"
  if [[ -e "$destination" ]]; then
    /usr/bin/cmp -s "$transaction/submission.bin" "$destination" || fail 'notary submission hash collision'
  else
    cp "$transaction/submission.bin" "$destination"
  fi
  cp "$transaction/receipt.json" "$publish_root/notary/$receipt_name"
}

publish_phase() {
  publish_root=""
  dmg_payload_check=""
  cleanup_publish_phase() {
    [[ -z "${dmg_payload_check:-}" ]] || rm -f -- "$dmg_payload_check"
    [[ -z "${publish_root:-}" ]] || rm -rf -- "$publish_root"
  }
  trap cleanup_publish_phase EXIT
  trap 'cleanup_publish_phase; exit 130' INT
  trap 'cleanup_publish_phase; exit 143' TERM HUP
  assert_clean_phase_environment
  require_clean_source
  record_toolchain
  set_stage_paths
  [[ -n "$OUTPUT_DIR" && "$OUTPUT_DIR" == /* && ! -e "$OUTPUT_DIR" && ! -L "$OUTPUT_DIR" ]] || \
    fail 'publish output path must be new and absolute'
  verify_unsigned_stage
  verify_notarized_inputs || fail 'notarized inputs or receipts are incomplete'
  dmg_payload_check="$(mktemp /tmp/peekaboo-dmg-payload-check.XXXXXX)"
  terminal_artifact_run_build node "$ROOT_DIR/scripts/terminal-dmg-payload.mjs" \
    --dmg "$NOTARIZED_DMG" --expected-app-tree "$APP_NOTARY_TRANSACTION/tree.json" \
    --tree-generator "$ROOT_DIR/scripts/artifact-tree-manifest.rb" > "$dmg_payload_check"
  /usr/bin/cmp -s "$DMG_PAYLOAD_RECEIPT" "$dmg_payload_check" || fail 'notarized DMG payload changed'
  rm -f "$dmg_payload_check"
  dmg_payload_check=""
  node_binary="$NOTARIZED_NODE/Contents/MacOS/node"
  verify_node_entitlements "$node_binary" || fail 'post-notary Node JIT entitlements mismatch'
  [[ "$(/usr/bin/env -i PATH=/usr/bin:/bin "$node_binary" --version)" == v24.15.0 ]] || \
    fail 'post-notary qualification Node version probe failed'
  /usr/bin/env -i PATH=/usr/bin:/bin "$node_binary" -e \
    'const value = new Function("return 6 * 7")(); if (value !== 42) process.exit(1);' || \
    fail 'post-notary qualification Node JavaScript/JIT probe failed'
  verify_playground_manifest "$NOTARIZED_PLAYGROUND" || fail 'notarized Playground provenance changed'
  verify_node_source_manifest "$NOTARIZED_NODE" signed || fail 'notarized Node provenance changed'
  cli_source="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$SIGNED_CLI/peekaboo" \
    --key PeekabooSourceCommit)"
  cli_version="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$SIGNED_CLI/peekaboo" \
    --key CFBundleShortVersionString)"
  app_source="$(/usr/libexec/PlistBuddy -c 'Print :PeekabooSourceCommit' "$NOTARIZED_APP/Contents/Info.plist")"
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NOTARIZED_APP/Contents/Info.plist")"
  [[ "$cli_source" == "$SOURCE_COMMIT" && "$app_source" == "$SOURCE_COMMIT" && \
    "$cli_version" == "$VERSION" && "$app_version" == "$VERSION" ]] || fail 'final source/version mismatch'

  output_parent="$(dirname "$OUTPUT_DIR")"
  mkdir -p "$output_parent"
  publish_root="$(mktemp -d "$output_parent/.peekaboo-terminal-publish.XXXXXX")"
  mkdir -p "$publish_root/notary" "$publish_root/peekaboo-macos-universal"
  cp "$SIGNED_CLI/peekaboo" "$publish_root/peekaboo-macos-universal/"
  for runtime_library in "$SIGNED_CLI"/libswiftCompatibility*.dylib; do
    [[ -e "$runtime_library" ]] && cp "$runtime_library" "$publish_root/peekaboo-macos-universal/"
  done
  materialize_committed_file LICENSE "$publish_root/peekaboo-macos-universal/LICENSE"
  printf '%s\n' "$VERSION" > "$publish_root/peekaboo-macos-universal/VERSION"
  terminal_artifact_assert_no_xattrs "$publish_root/peekaboo-macos-universal" || \
    fail 'CLI package contains unbound xattrs'
  terminal_artifact_tree_manifest "$publish_root/peekaboo-macos-universal" "$publish_root/cli-tree.json"
  /usr/bin/tar -czf "$publish_root/peekaboo-macos-universal.tar.gz" -C "$publish_root" \
    peekaboo-macos-universal
  find "$publish_root/peekaboo-macos-universal" -depth -delete
  cp "$CLI_NOTARY_TRANSACTION/tree.json" "$publish_root/cli-notary-tree.json"

  terminal_artifact_zip_app_exact "$NOTARIZED_APP" "$publish_root/Peekaboo-$VERSION.app.zip" \
    "$publish_root/peekaboo-app-tree.json"
  terminal_artifact_zip_app_exact "$NOTARIZED_PLAYGROUND" "$publish_root/Playground-$VERSION.app.zip" \
    "$publish_root/playground-app-tree.json"
  terminal_artifact_zip_app_exact "$NOTARIZED_NODE" \
    "$publish_root/PeekabooQualificationNode-24.15.0.app.zip" \
    "$publish_root/qualification-node-app-tree.json"
  /usr/bin/cmp -s "$APP_NOTARY_TRANSACTION/tree.json" "$publish_root/peekaboo-app-tree.json" || \
    fail 'Peekaboo.app notary tree differs from package tree'
  /usr/bin/cmp -s "$PLAYGROUND_NOTARY_TRANSACTION/tree.json" "$publish_root/playground-app-tree.json" || \
    fail 'Playground notary tree differs from package tree'
  /usr/bin/cmp -s "$NODE_NOTARY_TRANSACTION/tree.json" "$publish_root/qualification-node-app-tree.json" || \
    fail 'Node notary tree differs from package tree'
  cp "$NOTARIZED_DMG" "$publish_root/Peekaboo-$VERSION.dmg"
  cp "$DMG_PAYLOAD_RECEIPT" "$publish_root/peekaboo-dmg-payload.json"
  /usr/bin/ditto "$SIGNED_CONTROLLER_ROOT" "$publish_root/qualification"
  terminal_artifact_tree_manifest "$publish_root/qualification" "$publish_root/qualification-tree.json"
  /usr/bin/cmp -s "$CONTROLLER_NOTARY_TRANSACTION/tree.json" "$publish_root/qualification-tree.json" || \
    fail 'controller notary tree differs from retained qualification tree'
  retain_notary_transaction "$CLI_NOTARY_TRANSACTION" cli.json
  retain_notary_transaction "$APP_NOTARY_TRANSACTION" peekaboo-app.json
  retain_notary_transaction "$PLAYGROUND_NOTARY_TRANSACTION" playground-app.json
  retain_notary_transaction "$DMG_NOTARY_TRANSACTION" peekaboo-dmg.json
  retain_notary_transaction "$NODE_NOTARY_TRANSACTION" qualification-node-app.json
  retain_notary_transaction "$CONTROLLER_NOTARY_TRANSACTION" certification-controller.json

  cli_cdhash="$(terminal_artifact_cdhash "$SIGNED_CLI/peekaboo" arm64)"
  cli_cdhashes="$(architecture_cdhashes_json "$SIGNED_CLI/peekaboo" boo.peekaboo.peekaboo)"
  app_cdhash="$(terminal_artifact_cdhash "$NOTARIZED_APP" arm64)"
  playground_cdhash="$(terminal_artifact_cdhash "$NOTARIZED_PLAYGROUND" arm64)"
  dmg_cdhash="$(terminal_artifact_cdhash "$NOTARIZED_DMG")"
  node_app_cdhash="$(terminal_artifact_cdhash "$NOTARIZED_NODE" arm64)"
  node_binary_cdhashes="$(node_arch_cdhashes_json "$node_binary")" || fail 'signed Node architecture identity drifted'
  node_source_manifest="$NOTARIZED_NODE/Contents/Resources/PeekabooQualificationNodeSource.json"
  node_source_manifest_sha="$(/usr/bin/shasum -a 256 "$node_source_manifest" | /usr/bin/awk '{print $1}')"
  retained_controller="$publish_root/qualification/peekaboo-certification-controller"
  retained_monitor="$publish_root/qualification/background-computer-use-probe"
  controller_cdhash="$(terminal_artifact_cdhash "$retained_controller" arm64)"
  controller_cdhashes="$(architecture_cdhashes_json "$retained_controller" \
    boo.peekaboo.peekaboo-certification-controller)"
  controller_source="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$retained_controller" \
    --key PeekabooSourceCommit)"
  controller_version="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$retained_controller" \
    --key CFBundleShortVersionString)"
  [[ "$controller_source" == "$SOURCE_COMMIT" && "$controller_version" == "$VERSION" ]] || \
    fail 'retained controller source/version mismatch'
  monitor_cdhash="$(terminal_artifact_cdhash "$retained_monitor" arm64)"
  monitor_cdhashes="$(architecture_cdhashes_json "$retained_monitor" \
    boo.peekaboo.background-computer-use-probe)"
  monitor_source_commit="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$retained_monitor" \
    --key PeekabooSourceCommit)"
  monitor_version="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$retained_monitor" \
    --key CFBundleShortVersionString)"
  [[ "$monitor_source_commit" == "$SOURCE_COMMIT" && "$monitor_version" == "$VERSION" ]] || \
    fail 'retained monitor source/version mismatch'
  cp "$SOURCE_RECEIPT" "$publish_root/controller-source-manifest.json"
  controller_source_aggregate="$(jq -er .aggregate_sha256 "$publish_root/controller-source-manifest.json")"
  mkdir -p "$publish_root/tools"
  materialize_committed_file scripts/validate-terminal-artifact-manifest.mjs \
    "$publish_root/tools/validate-terminal-artifact-manifest.mjs"
  materialize_committed_file scripts/artifact-tree-manifest.rb \
    "$publish_root/tools/artifact-tree-manifest.rb"
  materialize_committed_file scripts/terminal-archive-policy.mjs \
    "$publish_root/tools/terminal-archive-policy.mjs"
  materialize_committed_file scripts/terminal-dmg-payload.mjs \
    "$publish_root/tools/terminal-dmg-payload.mjs"
  /usr/bin/ditto "$SOURCE_SNAPSHOT_ROOT" "$publish_root/qualification-source"
  terminal_artifact_tree_manifest "$publish_root/qualification-source" \
    "$publish_root/qualification-source-tree.json"
  /usr/bin/cmp -s "$SOURCE_TREE_MANIFEST" "$publish_root/qualification-source-tree.json" || \
    fail 'sealed qualification source snapshot changed during publication'
  playground_manifest_sha="$(/usr/bin/shasum -a 256 \
    "$NOTARIZED_PLAYGROUND/Contents/Resources/PeekabooPlaygroundSource.json" | /usr/bin/awk '{print $1}')"

  jq -n \
    --arg sourceCommit "$SOURCE_COMMIT" --arg version "$VERSION" \
    --arg lockPath "$CANONICAL_LOCK_RELATIVE" --arg lockSHA "$DEPENDENCY_LOCK_SHA256" \
    --arg developerDir "$EFFECTIVE_DEVELOPER_DIR" --arg xcodebuildVersion "$XCODEBUILD_VERSION" \
    --arg sdkVersion "$SDK_VERSION" --arg swiftcVersion "$SWIFTC_VERSION" \
    --arg cliSHA "$(/usr/bin/shasum -a 256 "$publish_root/peekaboo-macos-universal.tar.gz" | /usr/bin/awk '{print $1}')" \
    --argjson cliSize "$(/usr/bin/stat -f%z "$publish_root/peekaboo-macos-universal.tar.gz")" \
    --arg cliCDHash "$cli_cdhash" --argjson cliCDHashes "$cli_cdhashes" \
    --arg cliTreeSHA "$(/usr/bin/shasum -a 256 "$publish_root/cli-tree.json" | /usr/bin/awk '{print $1}')" \
    --arg cliNotaryTreeSHA "$(/usr/bin/shasum -a 256 "$publish_root/cli-notary-tree.json" | /usr/bin/awk '{print $1}')" \
    --arg appSHA "$(/usr/bin/shasum -a 256 "$publish_root/Peekaboo-$VERSION.app.zip" | /usr/bin/awk '{print $1}')" \
    --argjson appSize "$(/usr/bin/stat -f%z "$publish_root/Peekaboo-$VERSION.app.zip")" \
    --arg appCDHash "$app_cdhash" --arg appTreeSHA "$(/usr/bin/shasum -a 256 "$publish_root/peekaboo-app-tree.json" | /usr/bin/awk '{print $1}')" \
    --arg dmgSHA "$(/usr/bin/shasum -a 256 "$publish_root/Peekaboo-$VERSION.dmg" | /usr/bin/awk '{print $1}')" \
    --argjson dmgSize "$(/usr/bin/stat -f%z "$publish_root/Peekaboo-$VERSION.dmg")" --arg dmgCDHash "$dmg_cdhash" \
    --arg dmgPayloadSHA "$(/usr/bin/shasum -a 256 "$publish_root/peekaboo-dmg-payload.json" | /usr/bin/awk '{print $1}')" \
    --arg playgroundSHA "$(/usr/bin/shasum -a 256 "$publish_root/Playground-$VERSION.app.zip" | /usr/bin/awk '{print $1}')" \
    --argjson playgroundSize "$(/usr/bin/stat -f%z "$publish_root/Playground-$VERSION.app.zip")" \
    --arg playgroundCDHash "$playground_cdhash" --arg playgroundTreeSHA "$(/usr/bin/shasum -a 256 "$publish_root/playground-app-tree.json" | /usr/bin/awk '{print $1}')" \
    --arg playgroundManifestSHA "$playground_manifest_sha" \
    --arg nodeZipSHA "$(/usr/bin/shasum -a 256 "$publish_root/PeekabooQualificationNode-24.15.0.app.zip" | /usr/bin/awk '{print $1}')" \
    --argjson nodeZipSize "$(/usr/bin/stat -f%z "$publish_root/PeekabooQualificationNode-24.15.0.app.zip")" \
    --arg nodeAppCDHash "$node_app_cdhash" \
    --arg nodeTreeSHA "$(/usr/bin/shasum -a 256 "$publish_root/qualification-node-app-tree.json" | /usr/bin/awk '{print $1}')" \
    --arg nodeSourceManifestSHA "$node_source_manifest_sha" \
    --arg nodeBinarySHA "$(/usr/bin/shasum -a 256 "$node_binary" | /usr/bin/awk '{print $1}')" \
    --argjson nodeBinaryCDHashes "$node_binary_cdhashes" \
    --argjson nodeBinarySize "$(/usr/bin/stat -f%z "$node_binary")" \
    --slurpfile nodeSource "$node_source_manifest" \
    --arg controllerSHA "$(/usr/bin/shasum -a 256 "$retained_controller" | /usr/bin/awk '{print $1}')" \
    --argjson controllerSize "$(/usr/bin/stat -f%z "$retained_controller")" \
    --arg controllerCDHash "$controller_cdhash" \
    --argjson controllerCDHashes "$controller_cdhashes" \
    --arg controllerTreeSHA "$(/usr/bin/shasum -a 256 "$publish_root/qualification-tree.json" | /usr/bin/awk '{print $1}')" \
    --arg controllerSourceAggregate "$controller_source_aggregate" \
    --arg controllerSourceReceiptSHA "$(/usr/bin/shasum -a 256 "$publish_root/controller-source-manifest.json" | /usr/bin/awk '{print $1}')" \
    --arg cliExecutableSHA "$(/usr/bin/shasum -a 256 "$SIGNED_CLI/peekaboo" | /usr/bin/awk '{print $1}')" \
    --arg monitorSourceSHA "$(/usr/bin/shasum -a 256 "$publish_root/qualification-source/scripts/support/background-computer-use-probe.swift" | /usr/bin/awk '{print $1}')" \
    --arg monitorExecutableSHA "$(/usr/bin/shasum -a 256 "$retained_monitor" | /usr/bin/awk '{print $1}')" \
    --argjson monitorSize "$(/usr/bin/stat -f%z "$retained_monitor")" \
    --arg monitorCDHash "$monitor_cdhash" \
    --argjson monitorCDHashes "$monitor_cdhashes" \
    --arg validatorSHA "$(/usr/bin/shasum -a 256 "$publish_root/tools/validate-terminal-artifact-manifest.mjs" | /usr/bin/awk '{print $1}')" \
    --arg treeGeneratorSHA "$(/usr/bin/shasum -a 256 "$publish_root/tools/artifact-tree-manifest.rb" | /usr/bin/awk '{print $1}')" \
    --arg archivePolicySHA "$(/usr/bin/shasum -a 256 "$publish_root/tools/terminal-archive-policy.mjs" | /usr/bin/awk '{print $1}')" \
    --arg dmgPolicySHA "$(/usr/bin/shasum -a 256 "$publish_root/tools/terminal-dmg-payload.mjs" | /usr/bin/awk '{print $1}')" \
    --arg sourceTreeSHA "$(/usr/bin/shasum -a 256 "$publish_root/qualification-source-tree.json" | /usr/bin/awk '{print $1}')" \
    --slurpfile cliNotary "$publish_root/notary/cli.json" --slurpfile appNotary "$publish_root/notary/peekaboo-app.json" \
    --slurpfile playgroundNotary "$publish_root/notary/playground-app.json" \
    --slurpfile dmgNotary "$publish_root/notary/peekaboo-dmg.json" \
    --slurpfile nodeNotary "$publish_root/notary/qualification-node-app.json" \
    --slurpfile controllerNotary "$publish_root/notary/certification-controller.json" '
      {schema: 7, phase: "candidate_verified_not_installed", root: ".",
       source_commit: $sourceCommit, version: $version,
       portable: {validator: {path: "tools/validate-terminal-artifact-manifest.mjs", sha256: $validatorSHA},
         tree_generator: {path: "tools/artifact-tree-manifest.rb", sha256: $treeGeneratorSHA},
         archive_policy: {path: "tools/terminal-archive-policy.mjs", sha256: $archivePolicySHA},
         dmg_policy: {path: "tools/terminal-dmg-payload.mjs", sha256: $dmgPolicySHA},
         source_tree: {path: "qualification-source", tree_manifest: {
           path: "qualification-source-tree.json", sha256: $sourceTreeSHA}}},
       dependency_lock_path: $lockPath, dependency_lock_sha256: $lockSHA,
       toolchain: {developer_dir: $developerDir, xcodebuild_version: $xcodebuildVersion,
         sdk_version: $sdkVersion, swiftc_version: $swiftcVersion},
       signing: {authority: "Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)", team_id: "FWJYW4S8P8",
         release_helper: {commit: "20ab9a5e6bb1107788366726868f1a9b4c16d953",
           executable_sha256: "e65e06ef89ec90ebfc537d28748a3c4de8ce89bd09b51e4d67ba4bdd95427255",
           library_sha256: "c29d3c46506c2d0bd2db7ab688bd3108d54e8824074a4fe800de6e3fe17284c9"}},
       notarization: {cli: $cliNotary[0], peekaboo_app: $appNotary[0],
         playground_app: $playgroundNotary[0], peekaboo_dmg: $dmgNotary[0],
         qualification_node_app: $nodeNotary[0], certification_controller: $controllerNotary[0]},
       cli: {sha256: $cliExecutableSHA, cdhash: $cliCDHash},
       app: {source_commit: $sourceCommit, zip_sha256: $appSHA, cdhash: $appCDHash},
       playground: {source_commit: $sourceCommit, zip_sha256: $playgroundSHA, cdhash: $playgroundCDHash},
       monitor: {source_commit: $sourceCommit,
         source_path: "scripts/support/background-computer-use-probe.swift",
         source_sha256: $monitorSourceSHA, relative_path: "qualification/background-computer-use-probe",
         executable_sha256: $monitorExecutableSHA, cdhash: $monitorCDHash},
       controller: {source_commit: $sourceCommit, source_manifest_sha256: $controllerSourceAggregate,
         relative_path: "qualification/peekaboo-certification-controller",
         executable_sha256: $controllerSHA, cdhash: $controllerCDHash, team_id: "FWJYW4S8P8",
         authority: "Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)",
         signing_identifier: "boo.peekaboo.peekaboo-certification-controller",
         architectures: ["arm64", "x86_64"]},
       verification: {cli_source: true, cli_native_only: true, monitor_source: true,
         monitor_native_only: true, controller_source: true, controller_native_only: true,
         app_source: true, app_native_only: true, playground_native_only: true},
       artifacts: {
         cli: {path: "peekaboo-macos-universal.tar.gz", sha256: $cliSHA, size: $cliSize,
           cdhash: $cliCDHash, cdhashes: $cliCDHashes, source_commit: $sourceCommit,
           tree_manifest: {path: "cli-tree.json", sha256: $cliTreeSHA},
           notarized_tree_manifest: {path: "cli-notary-tree.json", sha256: $cliNotaryTreeSHA}},
         peekaboo_app_zip: {path: ("Peekaboo-" + $version + ".app.zip"), sha256: $appSHA,
           size: $appSize, cdhash: $appCDHash, source_commit: $sourceCommit,
           tree_manifest: {path: "peekaboo-app-tree.json", sha256: $appTreeSHA}},
         peekaboo_dmg: {path: ("Peekaboo-" + $version + ".dmg"), sha256: $dmgSHA,
           size: $dmgSize, cdhash: $dmgCDHash, source_commit: $sourceCommit,
           payload_receipt: {path: "peekaboo-dmg-payload.json", sha256: $dmgPayloadSHA}},
         playground_app_zip: {path: ("Playground-" + $version + ".app.zip"),
           sha256: $playgroundSHA, size: $playgroundSize, cdhash: $playgroundCDHash,
           source_commit: $sourceCommit, embedded_manifest_sha256: $playgroundManifestSHA,
           tree_manifest: {path: "playground-app-tree.json", sha256: $playgroundTreeSHA}},
         qualification_node_app_zip: {path: "PeekabooQualificationNode-24.15.0.app.zip",
           sha256: $nodeZipSHA, size: $nodeZipSize, cdhash: $nodeAppCDHash,
           source_commit: $sourceCommit, embedded_runtime_manifest_sha256: $nodeSourceManifestSHA,
           tree_manifest: {path: "qualification-node-app-tree.json", sha256: $nodeTreeSHA},
           runtime: {version: $nodeSource[0].runtime_version, identifier: $nodeSource[0].identifier,
             executable_path: $nodeSource[0].executable_path, architectures: $nodeSource[0].architectures,
             unsigned_binary_sha256: $nodeSource[0].universal_binary_sha256,
             unsigned_binary_size: $nodeSource[0].universal_binary_size,
             binary_sha256: $nodeBinarySHA, binary_cdhashes: $nodeBinaryCDHashes,
             binary_size: $nodeBinarySize, license: $nodeSource[0].license,
             entitlements: $nodeSource[0].entitlements,
             inputs: $nodeSource[0].inputs}},
         qualification_monitor: {path: "qualification/background-computer-use-probe",
           sha256: $monitorExecutableSHA, size: $monitorSize, cdhash: $monitorCDHash,
           cdhashes: $monitorCDHashes,
           source_commit: $sourceCommit, identifier: "boo.peekaboo.background-computer-use-probe",
           architectures: ["arm64", "x86_64"],
           source: {path: "scripts/support/background-computer-use-probe.swift", sha256: $monitorSourceSHA},
           tree_manifest: {path: "qualification-tree.json", sha256: $controllerTreeSHA}},
         certification_controller: {path: "qualification/peekaboo-certification-controller",
           sha256: $controllerSHA, size: $controllerSize, cdhash: $controllerCDHash,
           cdhashes: $controllerCDHashes,
           source_commit: $sourceCommit, identifier: "boo.peekaboo.peekaboo-certification-controller",
           architectures: ["arm64", "x86_64"],
           source_manifest: {path: "controller-source-manifest.json",
             sha256: $controllerSourceReceiptSHA, aggregate_sha256: $controllerSourceAggregate},
           tree_manifest: {path: "qualification-tree.json", sha256: $controllerTreeSHA}}}}
    ' > "$publish_root/terminal-artifacts.json"
  chmod 444 "$publish_root/terminal-artifacts.json" "$publish_root/controller-source-manifest.json" \
    "$publish_root"/*-tree.json "$publish_root/notary"/*.json "$publish_root/tools"/*
  (cd "$publish_root" && /usr/bin/shasum -a 256 \
    peekaboo-macos-universal.tar.gz "Peekaboo-$VERSION.app.zip" "Peekaboo-$VERSION.dmg" \
    "Playground-$VERSION.app.zip" PeekabooQualificationNode-24.15.0.app.zip \
    cli-tree.json cli-notary-tree.json peekaboo-app-tree.json peekaboo-dmg-payload.json \
    playground-app-tree.json qualification-node-app-tree.json \
    qualification/peekaboo-certification-controller qualification/background-computer-use-probe \
    qualification-tree.json controller-source-manifest.json qualification-source-tree.json \
    tools/validate-terminal-artifact-manifest.mjs tools/artifact-tree-manifest.rb \
    tools/terminal-archive-policy.mjs tools/terminal-dmg-payload.mjs \
    notary/*.json notary/submissions/* > checksums.txt)
  terminal_artifact_assert_no_xattrs "$publish_root" || fail 'published artifact contains unbound xattrs'
  /usr/bin/env -i PATH=/usr/bin:/bin "$node_binary" "$ROOT_DIR/scripts/validate-terminal-artifact-manifest.mjs" \
    "$publish_root/terminal-artifacts.json"
  "$ROOT_DIR/scripts/atomic-rename-exclusive.rb" "$publish_root" "$OUTPUT_DIR"
  publish_root=""
  trap - EXIT INT TERM HUP
  printf 'Terminal artifacts: %s\n' "$OUTPUT_DIR"
}

run_codesign_phase() {
  local phase="$1"
  local command_result
  record_release_helper
  expose_service_tokens
  set +e
  /usr/bin/env -u GH_TOKEN -u GITHUB_TOKEN -u NODE_AUTH_TOKEN -u NPM_CONFIG_USERCONFIG -u NPM_TOKEN \
    -u PEEKABOO_TERMINAL_TEST_MODE \
    MAC_RELEASE_MANIFEST="$ROOT_DIR/.mac-release-terminal.env" \
    "$ROOT_DIR/scripts/mac-release" codesign-run -- \
    /usr/bin/env -u OP_SERVICE_ACCOUNT_TOKEN -u MOLTY_OP_SERVICE_ACCOUNT_TOKEN \
    -u PEEKABOO_OP_SERVICE_TOKEN_FILE -u PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE \
    -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH -u GLOBIGNORE \
    PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin \
    /bin/bash --noprofile --norc -p -c 'exec "$@"' peekaboo-codesign-phase \
    "$ROOT_DIR/scripts/build-terminal-artifacts.sh" "$phase" --stage "$STAGE_DIR"
  command_result=$?
  set -e
  hide_service_tokens
  return "$command_result"
}

run_notary_only() {
  local command_result
  record_release_helper
  expose_service_tokens
  set +e
  /usr/bin/env -u GH_TOKEN -u GITHUB_TOKEN -u NODE_AUTH_TOKEN -u NPM_CONFIG_USERCONFIG -u NPM_TOKEN \
    -u PEEKABOO_TERMINAL_TEST_MODE \
    MAC_RELEASE_MANIFEST="$ROOT_DIR/.mac-release-terminal.env" \
    "$ROOT_DIR/scripts/mac-release" package-run -- \
    /usr/bin/env -u OP_SERVICE_ACCOUNT_TOKEN -u MOLTY_OP_SERVICE_ACCOUNT_TOKEN \
    -u PEEKABOO_OP_SERVICE_TOKEN_FILE -u PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE \
    -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH -u GLOBIGNORE \
    -u MAC_RELEASE_CODESIGN_KEYCHAIN -u MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD -u CODESIGN_KEYCHAIN \
    PATH=/usr/bin:/bin /bin/bash --noprofile --norc -p -c 'exec "$@"' peekaboo-notary-phase \
    "$ROOT_DIR/scripts/notarize-terminal-artifact.sh" "$@"
  command_result=$?
  set -e
  hide_service_tokens
  return "$command_result"
}

case "$COMMAND" in
  build)
    if ! terminal_artifact_assert_build_env_is_clean >/dev/null 2>&1; then
      args=(build)
      [[ -z "$STAGE_DIR" ]] || args+=(--stage "$STAGE_DIR")
      terminal_artifact_run_build /bin/bash --noprofile --norc -p \
        "$ROOT_DIR/scripts/build-terminal-artifacts.sh" "${args[@]}"
    else
      build_phase
    fi
    ;;
  sign-code) sign_code_phase ;;
  build-dmg) build_dmg_phase ;;
  sign-dmg) sign_dmg_phase ;;
  publish) publish_phase ;;
  check-helper)
    record_release_helper
    printf 'mac-release helper: %s\n' "$RELEASE_HELPER_COMMIT"
    printf 'mac-release helper executable sha256: %s\n' "$RELEASE_HELPER_EXECUTABLE_SHA256"
    printf 'mac-release helper library sha256: %s\n' "$RELEASE_HELPER_LIBRARY_SHA256"
    ;;
  all)
    case "${PEEKABOO_TERMINAL_TEST_MODE:-0}" in 0|false|no|off|'') ;; *) fail 'all refuses fixture mode' ;; esac
    if [[ "${PEEKABOO_TERMINAL_ORCHESTRATOR_CLEAN:-0}" != 1 ]]; then
      args=(all)
      [[ -z "$STAGE_DIR" ]] || args+=(--stage "$STAGE_DIR")
      [[ -z "$OUTPUT_DIR" ]] || args+=(--output "$OUTPUT_DIR")
      PEEKABOO_TERMINAL_ORCHESTRATOR_CLEAN=1 \
        terminal_artifact_run_orchestrator /bin/bash --noprofile --norc -p \
          "$ROOT_DIR/scripts/build-terminal-artifacts.sh" "${args[@]}"
      exit $?
    fi
    require_clean_source
    record_toolchain
    set_stage_paths
    [[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="/tmp/peekaboo-terminal-artifacts-$SOURCE_COMMIT"
    terminal_artifact_run_build /bin/bash --noprofile --norc -p \
      "$ROOT_DIR/scripts/build-terminal-artifacts.sh" build --stage "$STAGE_DIR"
    run_codesign_phase sign-code
    run_notary_only --kind cli-tree --artifact "$SIGNED_CLI" --transaction "$CLI_NOTARY_TRANSACTION"
    run_notary_only --kind app --artifact "$SIGNED_APP" --transaction "$APP_NOTARY_TRANSACTION"
    run_notary_only --kind app --artifact "$SIGNED_PLAYGROUND" --transaction "$PLAYGROUND_NOTARY_TRANSACTION"
    run_notary_only --kind app --artifact "$SIGNED_NODE" --transaction "$NODE_NOTARY_TRANSACTION"
    run_notary_only --kind controller-tree --artifact "$SIGNED_CONTROLLER_ROOT" \
      --transaction "$CONTROLLER_NOTARY_TRANSACTION"
    terminal_artifact_run_build /bin/bash --noprofile --norc -p \
      "$ROOT_DIR/scripts/build-terminal-artifacts.sh" build-dmg --stage "$STAGE_DIR"
    run_codesign_phase sign-dmg
    run_notary_only --kind dmg --artifact "$SIGNED_DMG" --transaction "$DMG_NOTARY_TRANSACTION"
    terminal_artifact_run_build /bin/bash --noprofile --norc -p \
      "$ROOT_DIR/scripts/build-terminal-artifacts.sh" publish \
      --stage "$STAGE_DIR" --output "$OUTPUT_DIR"
    ;;
esac
