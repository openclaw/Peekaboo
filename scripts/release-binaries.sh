#!/bin/bash
set -euo pipefail

# Release script for Peekaboo binaries
# Default: universal (arm64+x86_64). Use --arm64-only to skip Intel.

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Script directory and project root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=scripts/native-only-policy.sh
source "$SCRIPT_DIR/native-only-policy.sh"
# shellcheck source=scripts/source-provenance.sh
source "$SCRIPT_DIR/source-provenance.sh"
# shellcheck source=scripts/release-version.sh
source "$SCRIPT_DIR/release-version.sh"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$SCRIPT_DIR/terminal-artifact-env.sh"
BUILD_DIR="$PROJECT_ROOT/build"
RELEASE_DIR="${RELEASE_DIR:-$BUILD_DIR/release}"
MAC_RELEASE_MANIFEST="${MAC_RELEASE_MANIFEST:-$PROJECT_ROOT/.mac-release.env}"
RELEASE_CONTRACT="$PROJECT_ROOT/scripts/release-driver-contract.mjs"
GITHUB_HOST=github.com
GITHUB_REPOSITORY=github.com/openclaw/Peekaboo
GITHUB_API_REPOSITORY=openclaw/Peekaboo
NPM_REGISTRY=https://registry.npmjs.org
readonly GITHUB_HOST GITHUB_REPOSITORY GITHUB_API_REPOSITORY NPM_REGISTRY

echo -e "${BLUE}🚀 Peekaboo Release Build Script${NC}"

fail() {
    echo -e "${RED}❌ $*${NC}" >&2
    exit 1
}

canonical_path_allow_missing() {
    local candidate="$1" suffix="" component
    [[ "$candidate" == /* ]] || candidate="$PROJECT_ROOT/$candidate"
    [[ "/$candidate/" != */../* && "/$candidate/" != */./* ]] ||
        fail "Release directory must not contain parent or current-directory components"
    while [[ "$candidate" != / && "$candidate" == */ ]]; do
        candidate=${candidate%/}
    done
    [[ ! -L "$candidate" ]] || fail "Release directory must not be a symlink"
    while [[ ! -e "$candidate" ]]; do
        component=$(basename "$candidate")
        suffix="/$component$suffix"
        candidate=$(dirname "$candidate")
    done
    [[ -d "$candidate" ]] || fail "Release path ancestor is not a directory: $candidate"
    printf '%s%s\n' "$(cd "$candidate" && pwd -P)" "$suffix"
}

RELEASE_DIR=$(canonical_path_allow_missing "$RELEASE_DIR")
USER_HOME_DIR=$(cd "${HOME:?}" && pwd -P)
[[ "$RELEASE_DIR" != "/" && "$RELEASE_DIR" != "$PROJECT_ROOT" &&
   "$PROJECT_ROOT" != "$RELEASE_DIR"/* && "$RELEASE_DIR" != "$USER_HOME_DIR" &&
   "$USER_HOME_DIR" != "$RELEASE_DIR"/* ]] ||
    fail "Release directory must be a dedicated narrow output path"
RELEASE_OUTPUT_MARKER_CONTENT="peekaboo-release-output-v1:$PROJECT_ROOT:$RELEASE_DIR"

release_dir_is_build_output() {
    [[ "$RELEASE_DIR" == "$BUILD_DIR" || "$RELEASE_DIR" == "$BUILD_DIR"/* ]]
}

validate_release_output_directory() {
    local marker="$RELEASE_DIR/.peekaboo-release-output" relative
    local -a path_components
    [[ ! -L "$RELEASE_DIR" ]] || fail "Release directory must not be a symlink"
    if release_dir_is_build_output; then
        return 0
    fi
    [[ "$RELEASE_DIR" != "$PROJECT_ROOT"/* ]] ||
        fail "Custom release directory must be outside the source checkout"
    relative=${RELEASE_DIR#/}
    IFS=/ read -r -a path_components <<< "$relative"
    [[ ${#path_components[@]} -ge 3 ]] ||
        fail "Custom release directory is too broad for recursive cleanup"
    [[ ! -e "$RELEASE_DIR" || -d "$RELEASE_DIR" ]] ||
        fail "Custom release output exists and is not a directory"
    if [[ -d "$RELEASE_DIR" ]]; then
        [[ -f "$marker" && ! -L "$marker" && "$(<"$marker")" == "$RELEASE_OUTPUT_MARKER_CONTENT" ]] ||
            fail "Existing custom release directory lacks the exact Peekaboo output marker"
    fi
}

reset_release_output_directory() {
    validate_release_output_directory
    rm -rf "$RELEASE_DIR"
    mkdir -p "$RELEASE_DIR"
    if ! release_dir_is_build_output; then
        printf '%s\n' "$RELEASE_OUTPUT_MARKER_CONTENT" > "$RELEASE_DIR/.peekaboo-release-output"
        chmod 0444 "$RELEASE_DIR/.peekaboo-release-output"
    fi
}

validate_release_output_directory

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

sha256_file() {
    /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'
}

release_helper_pin() {
    local output commit executable_sha library_sha
    output=$("$PROJECT_ROOT/scripts/build-terminal-artifacts.sh" check-helper) ||
        fail "Trusted release helper verification failed"
    commit=$(printf '%s\n' "$output" | /usr/bin/sed -n 's/^mac-release helper: //p')
    executable_sha=$(printf '%s\n' "$output" |
        /usr/bin/sed -n 's/^mac-release helper executable sha256: //p')
    library_sha=$(printf '%s\n' "$output" |
        /usr/bin/sed -n 's/^mac-release helper library sha256: //p')
    [[ "$commit" =~ ^[0-9a-f]{40}$ && "$executable_sha" =~ ^[0-9a-f]{64}$ &&
       "$library_sha" =~ ^[0-9a-f]{64}$ ]] ||
        fail "Trusted release helper did not report one exact pin"
    printf '%s\t%s\t%s\n' "$commit" "$executable_sha" "$library_sha"
}

verify_release_source_state() {
    local observed_head status observed_appcast_sha
    observed_head=$(git -C "$PROJECT_ROOT" rev-parse HEAD) || return 1
    status=$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all) || return 1
    observed_appcast_sha=""
    [[ -z "${RELEASE_APPCAST_SHA256:-}" ]] || observed_appcast_sha=$(sha256_file "$PROJECT_ROOT/appcast.xml")
    EXPECTED_COMMIT="$RELEASE_SOURCE_COMMIT" OBSERVED_COMMIT="$observed_head" \
      PORCELAIN="$status" EXPECTED_APPCAST_SHA256="${RELEASE_APPCAST_SHA256:-}" \
      OBSERVED_APPCAST_SHA256="$observed_appcast_sha" node -e '
const input = {
  expectedCommit: process.env.EXPECTED_COMMIT,
  observedCommit: process.env.OBSERVED_COMMIT,
  porcelain: process.env.PORCELAIN,
  expectedAppcastSHA256: process.env.EXPECTED_APPCAST_SHA256 || null,
  observedAppcastSHA256: process.env.OBSERVED_APPCAST_SHA256 || null,
};
process.stdout.write(JSON.stringify(input));
' | node "$RELEASE_CONTRACT" source-state
}

assert_release_plan() {
    local observed_version observed_pin
    verify_release_source_state ||
        fail "Release checkout changed after the release plan was frozen"
    observed_version=$(node -p "require('$PROJECT_ROOT/package.json').version")
    [[ "$observed_version" == "$VERSION" ]] || fail "Release version changed after the release plan was frozen"
    observed_pin=$(release_helper_pin)
    [[ "$observed_pin" == "$RELEASE_HELPER_PIN" ]] ||
        fail "Release helper changed after the release plan was frozen"
    if [[ -n "${RELEASE_PLAN_SHA256:-}" ]]; then
        [[ -f "$RELEASE_DIR/release-plan.json" && ! -L "$RELEASE_DIR/release-plan.json" &&
           "$(sha256_file "$RELEASE_DIR/release-plan.json")" == "$RELEASE_PLAN_SHA256" ]] ||
            fail "Release plan artifact changed after it was frozen"
        if [[ -n "$RELEASE_PROOF_SHA256" ]]; then
            [[ -f "$RELEASE_DIR/release-proof.md" && ! -L "$RELEASE_DIR/release-proof.md" &&
               "$(sha256_file "$RELEASE_DIR/release-proof.md")" == "$RELEASE_PROOF_SHA256" ]] ||
                fail "Release proof artifact changed after it was frozen"
        fi
    fi
}

write_release_plan() {
    local proof_json=null
    [[ -z "$RELEASE_PROOF_SHA256" ]] || proof_json="\"$RELEASE_PROOF_SHA256\""
    printf '{"sourceCommit":"%s","version":"%s","helperCommit":"%s","helperExecutableSHA256":"%s","helperLibrarySHA256":"%s","proofSHA256":%s,"preflightCompleted":%s,"publicationEligible":%s}\n' \
        "$RELEASE_SOURCE_COMMIT" "$VERSION" "$RELEASE_HELPER_COMMIT" \
        "$RELEASE_HELPER_EXECUTABLE_SHA256" "$RELEASE_HELPER_LIBRARY_SHA256" "$proof_json" \
        "$RELEASE_PREFLIGHT_COMPLETED" "$RELEASE_PUBLICATION_ELIGIBLE" |
    node "$RELEASE_CONTRACT" release-plan > "$RELEASE_DIR/release-plan.json"
    chmod 0444 "$RELEASE_DIR/release-plan.json"
    RELEASE_PLAN_SHA256=$(sha256_file "$RELEASE_DIR/release-plan.json")
    if [[ -n "$RELEASE_PROOF_SHA256" ]]; then
        cp "$RELEASE_PROOF_FILE" "$RELEASE_DIR/release-proof.md"
        chmod 0444 "$RELEASE_DIR/release-proof.md"
        [[ "$(sha256_file "$RELEASE_DIR/release-proof.md")" == "$RELEASE_PROOF_SHA256" ]] ||
            fail "Release proof changed while being retained"
    fi
}

validate_tracked_release_notes() {
    node "$RELEASE_CONTRACT" tracked-notes <<EOF >/dev/null
{"changelog":$(node -e 'process.stdout.write(JSON.stringify(require("fs").readFileSync(process.argv[1], "utf8")))' "$PROJECT_ROOT/CHANGELOG.md"),"notes":$(node -e 'process.stdout.write(JSON.stringify(require("fs").readFileSync(process.argv[1], "utf8")))' "$PROJECT_ROOT/release/release-notes.md"),"version":"$VERSION"}
EOF
}

validate_publication_options() {
    node "$RELEASE_CONTRACT" publication-options <<EOF
{"skipChecks":$SKIP_CHECKS,"createGithubRelease":$CREATE_GITHUB_RELEASE,"publishNpm":$PUBLISH_NPM,"resumePublication":$RESUME_PUBLICATION,"retryNpmPublish":$RETRY_NPM_PUBLISH,"reuseBuiltCLI":$REUSE_BUILT_CLI,"universal":$UNIVERSAL,"includeMacApp":$INCLUDE_MAC_APP,"notarize":$MAC_APP_NOTARIZE,"appcast":$MAC_APP_APPCAST,"proofProvided":$RELEASE_PROOF_PROVIDED}
EOF
}

app_zip_tree_sha256() {
    local zip_path="$1" verify_root manifest app_path
    verify_root=$(mktemp -d /tmp/peekaboo-release-app-tree.XXXXXX)
    manifest="$verify_root/tree.json"
    /usr/bin/ditto -x -k "$zip_path" "$verify_root/extracted"
    app_path="$verify_root/extracted/Peekaboo.app"
    [[ -d "$app_path" && ! -L "$app_path" ]] || {
        rm -rf "$verify_root"
        fail "Release app zip has no exact Peekaboo.app root"
    }
    /usr/bin/ruby "$PROJECT_ROOT/scripts/artifact-tree-manifest.rb" "$app_path" > "$manifest"
    sha256_file "$manifest"
    rm -rf "$verify_root"
}

npm_package_integrity() {
    node -e '
const fs = require("fs");
const crypto = require("crypto");
const bytes = fs.readFileSync(process.argv[1]);
process.stdout.write(`sha512-${crypto.createHash("sha512").update(bytes).digest("base64")}`);
' "$1"
}

render_github_body() {
    local npm_metadata_path="${1:-}" output_path="$2"
    (
      cd "$PROJECT_ROOT"
      NOTES_PATH="$PROJECT_ROOT/release/release-notes.md" \
      PROOF_PATH="$RELEASE_DIR/release-proof.md" \
      PLAN_PATH="$RELEASE_DIR/release-plan.json" \
      CHECKSUMS_PATH="$RELEASE_DIR/checksums.txt" \
      NPM_METADATA_PATH="$npm_metadata_path" node --input-type=module <<'EOF'
import fs from 'node:fs';
import { createHash } from 'node:crypto';
import { composeGitHubBody } from './scripts/release-driver-contract.mjs';
const npm = process.env.NPM_METADATA_PATH ?
  JSON.parse(fs.readFileSync(process.env.NPM_METADATA_PATH, 'utf8')) : null;
process.stdout.write(composeGitHubBody({
  notes: fs.readFileSync(process.env.NOTES_PATH, 'utf8'),
  proof: fs.readFileSync(process.env.PROOF_PATH, 'utf8'),
  plan: JSON.parse(fs.readFileSync(process.env.PLAN_PATH, 'utf8')),
  checksumsSHA256: createHash('sha256').update(fs.readFileSync(process.env.CHECKSUMS_PATH)).digest('hex'),
  npm,
}));
EOF
    ) > "$output_path"
}

compose_github_body() {
    local npm_metadata_path="${1:-}" body_tmp
    [[ -n "$RELEASE_PROOF_SHA256" ]] || fail "Public release requires one frozen proof file"
    body_tmp=$(mktemp "$RELEASE_DIR/.github-release-body.XXXXXX")
    if ! render_github_body "$npm_metadata_path" "$body_tmp"; then
        rm -f "$body_tmp"
        return 1
    fi
    chmod 0444 "$body_tmp"
    mv -f "$body_tmp" "$RELEASE_DIR/github-release-body.md"
    GITHUB_BODY_SHA256=$(sha256_file "$RELEASE_DIR/github-release-body.md")
    GITHUB_BODY_NPM_METADATA_SHA256=""
    [[ -z "$npm_metadata_path" ]] || GITHUB_BODY_NPM_METADATA_SHA256=$(sha256_file "$npm_metadata_path")
}

assert_frozen_release_artifacts() {
    [[ -n "$RELEASE_CHECKSUMS_SHA256" &&
       "$(sha256_file "$RELEASE_DIR/checksums.txt")" == "$RELEASE_CHECKSUMS_SHA256" ]] ||
        fail "Release artifact manifest changed after verification"
    verify_checksums_file
}

assert_canonical_github_body() {
    local npm_metadata_path="${1:-}" expected_tmp
    assert_release_plan
    assert_frozen_release_artifacts
    validate_tracked_release_notes || fail "Tracked release notes changed before publication"
    [[ -f "$RELEASE_DIR/github-release-body.md" && ! -L "$RELEASE_DIR/github-release-body.md" &&
       "$(sha256_file "$RELEASE_DIR/github-release-body.md")" == "$GITHUB_BODY_SHA256" ]] ||
        fail "GitHub release body changed after composition"
    if [[ -n "$npm_metadata_path" ]]; then
        [[ "$(sha256_file "$npm_metadata_path")" == "$GITHUB_BODY_NPM_METADATA_SHA256" ]] ||
            fail "npm publication metadata changed after verification"
    else
        [[ -z "$GITHUB_BODY_NPM_METADATA_SHA256" ]] || fail "GitHub release body stage is inconsistent"
    fi
    expected_tmp=$(mktemp "$RELEASE_DIR/.github-release-body-expected.XXXXXX")
    if ! render_github_body "$npm_metadata_path" "$expected_tmp" ||
       ! cmp -s "$expected_tmp" "$RELEASE_DIR/github-release-body.md"; then
        rm -f "$expected_tmp"
        fail "GitHub release body is not the canonical plan-derived body"
    fi
    rm -f "$expected_tmp"
}

verify_release_binary_entitlements() {
    local binary_path="$1"
    local label="$2"
    local entitlements

    if ! entitlements=$(codesign -d --entitlements :- "$binary_path" 2>/dev/null); then
        fail "Could not read $label entitlements"
    fi
    if ! printf '%s' "$entitlements" | python3 -c '
import plistlib
import sys

raw = sys.stdin.buffer.read().strip()
entitlements = plistlib.loads(raw) if raw else {}
for forbidden in (
    "com.apple.security.get-task-allow",
    "com.apple.security.automation.apple-events",
):
    if entitlements.get(forbidden) is True:
        raise SystemExit(1)
'; then
        fail "$label requests forbidden debug or Apple Events entitlements"
    fi
}

verify_release_binary_apple_events_policy() {
    local binary_path="$1"
    local label="$2"
    local policy_error

    if ! policy_error="$(native_only_verify_macho \
        "$binary_path" "$label" "${PEEKABOO_NM_BIN:-/usr/bin/nm}" "${PEEKABOO_STRINGS_BIN:-/usr/bin/strings}")"; then
        fail "$policy_error"
    fi
}

verify_binary_artifact() {
    local binary_path="$1"
    local label="$2"
    local require_online_notarization="${3:-$MAC_APP_NOTARIZE}"
    local expected_source_commit="${4:-}"
    local version_output
    local provenance_json
    local source_commit
    local provenance_status=0
    local binary_size
    local lipo_output
    local authority
    local team_id

    [ -x "$binary_path" ] || fail "$label binary missing or not executable: $binary_path"
    require_command lipo
    binary_size=$(stat -f%z "$binary_path")
    (( binary_size > 1000000 )) || fail "$label binary is unexpectedly small: $binary_size bytes"
    file "$binary_path" | grep -q 'Mach-O' || fail "$label binary is not Mach-O: $binary_path"
    codesign --verify --strict --verbose=2 "$binary_path"
    codesign --verify --strict -R="$CLI_SIGN_REQUIREMENT" "$binary_path"
    verify_release_binary_entitlements "$binary_path" "$label"
    verify_release_binary_apple_events_policy "$binary_path" "$label"
    MAC_RELEASE_CODESIGN_IDENTITY="$CLI_SIGN_IDENTITY" \
        MAC_RELEASE_CODESIGN_TEAM_ID="$CLI_SIGN_TEAM_ID" \
        "$PROJECT_ROOT/scripts/verify-swift-runtime-libraries.sh" "$binary_path" "$(dirname "$binary_path")"
    authority=$(codesign -dv --verbose=4 "$binary_path" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    team_id=$(codesign -dv --verbose=4 "$binary_path" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)
    [ "$authority" = "$CLI_SIGN_IDENTITY" ] ||
        fail "$label signer mismatch: expected '$CLI_SIGN_IDENTITY', got '$authority'"
    [ "$team_id" = "$CLI_SIGN_TEAM_ID" ] ||
        fail "$label TeamIdentifier mismatch: expected '$CLI_SIGN_TEAM_ID', got '$team_id'"
    if [ "$require_online_notarization" = true ]; then
        codesign --verify --strict --check-notarization -R=notarized --verbose=2 "$binary_path"
    fi

    lipo_output=$(lipo -archs "$binary_path")
    if [ "$UNIVERSAL" = true ]; then
        case " $lipo_output " in *" x86_64 "*) ;; *) fail "$label binary is missing x86_64 slice" ;; esac
        case " $lipo_output " in *" arm64 "*) ;; *) fail "$label binary is missing arm64 slice" ;; esac
    else
        case " $lipo_output " in *" arm64 "*) ;; *) fail "$label binary is missing arm64 slice" ;; esac
    fi

    version_output=$("$binary_path" --version)
    printf '%s\n' "$version_output" | grep -Fq "Peekaboo $VERSION" ||
        fail "$label version output does not contain Peekaboo $VERSION: $version_output"
    if printf '%s\n' "$version_output" | grep -Fq -- '-dirty'; then
        fail "$label was built from a dirty tree: $version_output"
    fi
    if printf '%s\n' "$version_output" | grep -Fq 'unknown'; then
        fail "$label has incomplete version provenance: $version_output"
    fi
    provenance_json=$("$binary_path" --version --json)
    source_commit=$(PROVENANCE_JSON="$provenance_json" node -e '
        const parsed = JSON.parse(process.env.PROVENANCE_JSON);
        process.stdout.write(parsed?.data?.sourceCommit ?? "");
    ')
    peekaboo_is_exact_source_commit "$source_commit" ||
        fail "$label has no exact source commit in version JSON"
    if [ -n "$expected_source_commit" ]; then
        peekaboo_validate_artifact_source_commit \
            "$PROJECT_ROOT" "$source_commit" "$expected_source_commit" || provenance_status=$?
        case "$provenance_status" in
            0) ;;
            4) fail "$label release checkout changed or became dirty during verification" ;;
            5) fail "$label source mismatch: expected $expected_source_commit, got $source_commit" ;;
            *) fail "$label source provenance validation failed (status $provenance_status)" ;;
        esac
    fi
}

notarize_cli_binary() {
    local binary_path="$1"
    local notary_dir
    local key_file
    local submission_zip
    local result_json
    local result_status
    local submission_id

    require_command ditto
    require_command xcrun

    notary_dir=$(mktemp -d /tmp/peekaboo-cli-notary.XXXXXX)
    submission_zip="$notary_dir/peekaboo-cli.zip"
    ditto -c -k --sequesterRsrc "$binary_path" "$submission_zip"

    if [ -n "$NOTARYTOOL_PROFILE" ]; then
        result_json=$(xcrun notarytool submit "$submission_zip" \
            --keychain-profile "$NOTARYTOOL_PROFILE" \
            --no-s3-acceleration \
            --wait \
            --output-format json) || {
            rm -rf "$notary_dir"
            fail "CLI notarization submission failed"
        }
    else
        require_command node
        [ -n "${APP_STORE_CONNECT_KEY_ID:-}" ] || fail "APP_STORE_CONNECT_KEY_ID missing"
        [ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ] || fail "APP_STORE_CONNECT_ISSUER_ID missing"
        [ -n "${APP_STORE_CONNECT_API_KEY_P8:-}" ] || fail "APP_STORE_CONNECT_API_KEY_P8 missing"
        key_file="$notary_dir/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
        APP_STORE_CONNECT_API_KEY_P8="$APP_STORE_CONNECT_API_KEY_P8" node > "$key_file" <<'EOF'
const raw = process.env.APP_STORE_CONNECT_API_KEY_P8 ?? "";
let pem = raw.replace(/\\n/g, "\n").trim();
if (!pem.includes("\n")) {
  const match = pem.match(/^(-----BEGIN [^-]+-----)\s*(.+?)\s*(-----END [^-]+-----)$/);
  if (match) {
    const body = match[2].replace(/\s+/g, "");
    const wrapped = body.match(/.{1,64}/g)?.join("\n") ?? body;
    pem = `${match[1]}\n${wrapped}\n${match[3]}`;
  }
}
process.stdout.write(`${pem}\n`);
EOF
        chmod 600 "$key_file"
        if ! result_json=$(xcrun notarytool submit "$submission_zip" \
            --key "$key_file" \
            --key-id "$APP_STORE_CONNECT_KEY_ID" \
            --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
            --no-s3-acceleration \
            --wait \
            --output-format json); then
            /bin/rm -P "$key_file" 2>/dev/null || rm -f "$key_file"
            rm -rf "$notary_dir"
            fail "CLI notarization submission failed"
        fi
        /bin/rm -P "$key_file" 2>/dev/null || rm -f "$key_file"
    fi

    result_status=$(NOTARY_RESULT_JSON="$result_json" node -e \
        'const r=JSON.parse(process.env.NOTARY_RESULT_JSON); process.stdout.write(r.status ?? "")')
    submission_id=$(NOTARY_RESULT_JSON="$result_json" node -e \
        'const r=JSON.parse(process.env.NOTARY_RESULT_JSON); process.stdout.write(r.id ?? "")')
    rm -rf "$notary_dir"

    [ "$result_status" = "Accepted" ] || fail "CLI notarization was not accepted: ${result_status:-missing status}"
    [ -n "$submission_id" ] || fail "CLI notarization response did not include a submission ID"
    echo -e "${GREEN}✅ CLI notarization accepted (${submission_id})${NC}"
    codesign --verify --strict --check-notarization -R=notarized --verbose=2 "$binary_path"
}

verify_cli_tarball() {
    local tarball_path="$1"
    local verify_dir
    verify_dir=$(mktemp -d /tmp/peekaboo-cli-verify.XXXXXX)

    [ -f "$tarball_path" ] || fail "CLI tarball missing: $tarball_path"
    tar -tzf "$tarball_path" | grep -Fxq "$CLI_ARTIFACT_DIR/peekaboo" ||
        fail "CLI tarball does not contain $CLI_ARTIFACT_DIR/peekaboo"
    tar -xzf "$tarball_path" -C "$verify_dir"
    verify_binary_artifact "$verify_dir/$CLI_ARTIFACT_DIR/peekaboo" "CLI tarball"
    rm -rf "$verify_dir"
}

verify_npm_tarball() {
    local npm_path="$1"
    local verify_dir
    verify_dir=$(mktemp -d /tmp/peekaboo-npm-verify.XXXXXX)

    [ -f "$npm_path" ] || fail "npm package missing: $npm_path"
    tar -tzf "$npm_path" | grep -Eq '^(package/)?peekaboo$|^package/peekaboo$' ||
        fail "npm package does not contain peekaboo binary"
    tar -xzf "$npm_path" -C "$verify_dir"
    if [ -x "$verify_dir/package/peekaboo" ]; then
        verify_binary_artifact "$verify_dir/package/peekaboo" "npm package"
    elif [ -x "$verify_dir/peekaboo" ]; then
        verify_binary_artifact "$verify_dir/peekaboo" "npm package"
    else
        fail "npm package peekaboo binary missing after extraction"
    fi
    rm -rf "$verify_dir"
}

verify_appcast_entry() {
    [ "$INCLUDE_MAC_APP" = true ] || return 0
    [ "$MAC_APP_APPCAST" = true ] || return 0

    [[ -f "$RELEASE_DIR/appcast-entry.json" && ! -L "$RELEASE_DIR/appcast-entry.json" ]] ||
        fail "appcast-entry.json missing"
    [[ -f "$RELEASE_DIR/appcast.xml" && ! -L "$RELEASE_DIR/appcast.xml" &&
       "$(sha256_file "$RELEASE_DIR/appcast.xml")" == "$(sha256_file "$PROJECT_ROOT/appcast.xml")" ]] ||
        fail "Generated appcast differs from the retained release snapshot"
    (
      cd "$PROJECT_ROOT"
      APPCAST_PATH="$PROJECT_ROOT/appcast.xml" \
      APPCAST_RECEIPT="$RELEASE_DIR/appcast-entry.json" \
      APP_ZIP_LENGTH="$(stat -f%z "$MAC_APP_ZIP_PATH")" \
      APPCAST_BUILD_NUMBER="$(peekaboo_release_build_number "$VERSION")" \
      APPCAST_MINIMUM_SYSTEM_VERSION="15.0" \
      APPCAST_ASSET_URL="https://github.com/openclaw/Peekaboo/releases/download/v${VERSION}/$(basename "$MAC_APP_ZIP_PATH")" \
      APPCAST_RELEASE_URL="https://github.com/openclaw/Peekaboo/releases/tag/v${VERSION}" \
      VERSION="$VERSION" node --input-type=module <<'EOF'
import fs from 'node:fs';
import { validateAppcast } from './scripts/update-appcast-entry.mjs';
const xml = fs.readFileSync(process.env.APPCAST_PATH, 'utf8');
const expected = JSON.parse(fs.readFileSync(process.env.APPCAST_RECEIPT, 'utf8'));
if (expected.version !== process.env.VERSION || expected.zipLength !== process.env.APP_ZIP_LENGTH ||
    expected.buildNumber !== process.env.APPCAST_BUILD_NUMBER ||
    expected.minimumSystemVersion !== process.env.APPCAST_MINIMUM_SYSTEM_VERSION ||
    expected.assetUrl !== process.env.APPCAST_ASSET_URL ||
    expected.releaseUrl !== process.env.APPCAST_RELEASE_URL ||
    typeof expected.edSignature !== 'string' || expected.edSignature.length < 40) {
  throw new Error('Appcast receipt differs from the release app artifact');
}
validateAppcast(xml, expected);
EOF
    )

    if command -v xmllint >/dev/null 2>&1; then
        xmllint --noout "$PROJECT_ROOT/appcast.xml"
    fi
}

verify_checksums_file() {
    local checksum_path="$RELEASE_DIR/checksums.txt"
    [ -f "$checksum_path" ] || fail "checksums.txt missing"
    (cd "$RELEASE_DIR" && shasum -a 256 -c checksums.txt >/dev/null) ||
        fail "checksums.txt verification failed"
    grep -Fq "  $CLI_TARBALL_NAME" "$checksum_path" ||
        fail "checksums.txt missing $CLI_TARBALL_NAME"
    grep -Fq "  $(basename "$NPM_PACKAGE_PATH")" "$checksum_path" ||
        fail "checksums.txt missing $(basename "$NPM_PACKAGE_PATH")"
    grep -Fq "  release-plan.json" "$checksum_path" ||
        fail "checksums.txt missing release-plan.json"
    if [[ -n "$RELEASE_PROOF_SHA256" ]]; then
        grep -Fq "  release-proof.md" "$checksum_path" ||
            fail "checksums.txt missing release-proof.md"
    fi
    if [ "$INCLUDE_MAC_APP" = true ]; then
        grep -Fq "  $(basename "$MAC_APP_ZIP_PATH")" "$checksum_path" ||
            fail "checksums.txt missing $(basename "$MAC_APP_ZIP_PATH")"
        grep -Fq "  $(basename "$MAC_APP_DMG_PATH")" "$checksum_path" ||
            fail "checksums.txt missing $(basename "$MAC_APP_DMG_PATH")"
        if [ "$MAC_APP_APPCAST" = true ]; then
            grep -Fq "  appcast-entry.json" "$checksum_path" ||
                fail "checksums.txt missing appcast-entry.json"
            grep -Fq "  appcast.xml" "$checksum_path" ||
                fail "checksums.txt missing appcast.xml"
        fi
    fi
}

verify_release_artifacts() {
    local APP_ZIP_TREE_SHA256
    echo -e "\n${BLUE}Verifying release artifacts...${NC}"
    require_command tar
    require_command shasum
    require_command file
    require_command codesign
    assert_release_plan

    verify_cli_tarball "$RELEASE_DIR/$CLI_TARBALL_NAME"
    verify_npm_tarball "$NPM_PACKAGE_PATH"
    verify_checksums_file

    if [ "$INCLUDE_MAC_APP" = true ]; then
        MAC_VERIFY_ARGS=(--version "$VERSION" --verify-only "$MAC_APP_ZIP_PATH")
        if [ "$MAC_APP_NOTARIZE" = false ]; then
            MAC_VERIFY_ARGS+=(--no-notarize)
        fi
        PEEKABOO_RELEASE_SOURCE_COMMIT="$RELEASE_SOURCE_COMMIT" \
            PEEKABOO_RELEASE_VERSION="$VERSION" \
            PEEKABOO_RELEASE_APPCAST_SHA256="${RELEASE_APPCAST_SHA256:-}" \
            MAC_RELEASE_EXPECTED_HELPER_COMMIT="$RELEASE_HELPER_COMMIT" \
            MAC_RELEASE_EXPECTED_HELPER_EXECUTABLE_SHA256="$RELEASE_HELPER_EXECUTABLE_SHA256" \
            MAC_RELEASE_EXPECTED_HELPER_LIBRARY_SHA256="$RELEASE_HELPER_LIBRARY_SHA256" \
            "$PROJECT_ROOT/scripts/release-macos-app.sh" "${MAC_VERIFY_ARGS[@]}"
        APP_ZIP_TREE_SHA256=$(app_zip_tree_sha256 "$MAC_APP_ZIP_PATH")
        DMG_VERIFY_ARGS=(--version "$VERSION" --verify-only "$MAC_APP_DMG_PATH")
        DMG_VERIFY_ARGS+=(--expected-app-tree-sha256 "$APP_ZIP_TREE_SHA256")
        if [ "$MAC_APP_NOTARIZE" = false ]; then
            DMG_VERIFY_ARGS+=(--no-notarize)
        fi
        "$PROJECT_ROOT/scripts/create-release-dmg.sh" "${DMG_VERIFY_ARGS[@]}"
        verify_appcast_entry
    fi

    RELEASE_CHECKSUMS_SHA256=$(sha256_file "$RELEASE_DIR/checksums.txt")
    echo -e "${GREEN}✅ Release artifact verification passed${NC}"
}

expected_release_assets_json() {
    local expected_assets expected_assets_json
    expected_assets=(
        "$CLI_TARBALL_NAME=$(stat -f%z "$RELEASE_DIR/$CLI_TARBALL_NAME")=$(sha256_file "$RELEASE_DIR/$CLI_TARBALL_NAME")"
        "$(basename "$NPM_PACKAGE_PATH")=$(stat -f%z "$NPM_PACKAGE_PATH")=$(sha256_file "$NPM_PACKAGE_PATH")"
        "checksums.txt=$(stat -f%z "$RELEASE_DIR/checksums.txt")=$(sha256_file "$RELEASE_DIR/checksums.txt")"
        "release-plan.json=$(stat -f%z "$RELEASE_DIR/release-plan.json")=$(sha256_file "$RELEASE_DIR/release-plan.json")"
    )
    if [[ -n "$RELEASE_PROOF_SHA256" ]]; then
        expected_assets+=("release-proof.md=$(stat -f%z "$RELEASE_DIR/release-proof.md")=$(sha256_file "$RELEASE_DIR/release-proof.md")")
    fi
    if [ -n "$MAC_APP_ZIP_PATH" ]; then
        expected_assets+=("$(basename "$MAC_APP_ZIP_PATH")=$(stat -f%z "$MAC_APP_ZIP_PATH")=$(sha256_file "$MAC_APP_ZIP_PATH")")
        expected_assets+=("$(basename "$MAC_APP_DMG_PATH")=$(stat -f%z "$MAC_APP_DMG_PATH")=$(sha256_file "$MAC_APP_DMG_PATH")")
        expected_assets+=("appcast-entry.json=$(stat -f%z "$RELEASE_DIR/appcast-entry.json")=$(sha256_file "$RELEASE_DIR/appcast-entry.json")")
        expected_assets+=("appcast.xml=$(stat -f%z "$RELEASE_DIR/appcast.xml")=$(sha256_file "$RELEASE_DIR/appcast.xml")")
    fi
    expected_assets_json=$(node -e '
const assets = Object.fromEntries(process.argv.slice(1).map((entry) => {
  const parts = entry.split("=");
  const sha256 = parts.pop();
  const size = Number(parts.pop());
  return [parts.join("="), {size, sha256}];
}));
console.log(JSON.stringify(assets));
' "${expected_assets[@]}")
    printf '%s\n' "$expected_assets_json"
}

render_publication_receipt() {
    local output_path="$1" expected_assets_json
    expected_assets_json=$(expected_release_assets_json)
    printf '{"sourceCommit":"%s","version":"%s","checksumsSHA256":"%s","githubBodySHA256":"%s","assets":%s}\n' \
      "$RELEASE_SOURCE_COMMIT" "$VERSION" "$RELEASE_CHECKSUMS_SHA256" "$GITHUB_BODY_SHA256" \
      "$expected_assets_json" | node "$RELEASE_CONTRACT" publication-receipt > "$output_path"
}

freeze_publication_receipt() {
    local npm_metadata_path="${1:-}" receipt_tmp receipt_path
    assert_canonical_github_body "$npm_metadata_path"
    receipt_tmp=$(mktemp "$RELEASE_DIR/.publication-receipt.XXXXXX")
    render_publication_receipt "$receipt_tmp"
    chmod 0444 "$receipt_tmp"
    if [[ -n "$npm_metadata_path" ]]; then
        receipt_path="$RELEASE_DIR/publication-receipt.final.json"
    else
        receipt_path="$RELEASE_DIR/publication-receipt.pending.json"
    fi
    if /bin/ln "$receipt_tmp" "$receipt_path" 2>/dev/null; then
        rm -f "$receipt_tmp"
    else
        [[ -f "$receipt_path" && ! -L "$receipt_path" ]] || {
            rm -f "$receipt_tmp"
            fail "Existing publication receipt is not one regular file"
        }
        if ! cmp -s "$receipt_tmp" "$receipt_path"; then
            rm -f "$receipt_tmp"
            fail "Existing publication receipt differs from the canonical stage"
        fi
        rm -f "$receipt_tmp"
    fi
    PUBLICATION_RECEIPT_PATH="$receipt_path"
    PUBLICATION_RECEIPT_SHA256=$(sha256_file "$receipt_path")
}

assert_publication_receipt() {
    local npm_metadata_path="${1:-}" expected_tmp receipt_path
    assert_canonical_github_body "$npm_metadata_path"
    if [[ -n "$npm_metadata_path" ]]; then
        receipt_path="$RELEASE_DIR/publication-receipt.final.json"
    else
        receipt_path="$RELEASE_DIR/publication-receipt.pending.json"
    fi
    [[ "$PUBLICATION_RECEIPT_PATH" == "$receipt_path" && -f "$receipt_path" &&
       ! -L "$receipt_path" && "$(sha256_file "$receipt_path")" == "$PUBLICATION_RECEIPT_SHA256" ]] ||
        fail "Publication receipt changed after it was frozen"
    expected_tmp=$(mktemp "$RELEASE_DIR/.publication-receipt-expected.XXXXXX")
    render_publication_receipt "$expected_tmp"
    if ! cmp -s "$expected_tmp" "$receipt_path"; then
        rm -f "$expected_tmp"
        fail "Publication receipt differs from the frozen local artifacts"
    fi
    rm -f "$expected_tmp"
}

validate_retained_pending_receipt() {
    local pending_path="$RELEASE_DIR/publication-receipt.pending.json"
    local body_tmp receipt_tmp saved_body_sha saved_npm_sha
    [[ -f "$pending_path" && ! -L "$pending_path" ]] ||
        fail "Retained pending publication receipt is missing"
    body_tmp=$(mktemp "$RELEASE_DIR/.pending-body-expected.XXXXXX")
    receipt_tmp=$(mktemp "$RELEASE_DIR/.pending-receipt-expected.XXXXXX")
    render_github_body "" "$body_tmp"
    saved_body_sha="$GITHUB_BODY_SHA256"
    saved_npm_sha="$GITHUB_BODY_NPM_METADATA_SHA256"
    GITHUB_BODY_SHA256=$(sha256_file "$body_tmp")
    GITHUB_BODY_NPM_METADATA_SHA256=""
    render_publication_receipt "$receipt_tmp"
    GITHUB_BODY_SHA256="$saved_body_sha"
    GITHUB_BODY_NPM_METADATA_SHA256="$saved_npm_sha"
    if ! cmp -s "$receipt_tmp" "$pending_path"; then
        rm -f "$body_tmp" "$receipt_tmp"
        fail "Retained pending publication receipt differs from the original artifacts"
    fi
    RETAINED_PENDING_RECEIPT_SHA256=$(sha256_file "$pending_path")
    rm -f "$body_tmp" "$receipt_tmp"
}

activate_retained_pending_receipt() {
    PUBLICATION_RECEIPT_PATH="$RELEASE_DIR/publication-receipt.pending.json"
    PUBLICATION_RECEIPT_SHA256="$RETAINED_PENDING_RECEIPT_SHA256"
    assert_publication_receipt
}

github_tag_commit() {
    local allow_missing="${1:-false}" refs tuple object_type object_sha depth=0
    refs=$(gh api --hostname "$GITHUB_HOST" \
      "repos/${GITHUB_API_REPOSITORY}/git/matching-refs/tags/v${VERSION}") ||
        fail "Could not inspect the GitHub release tag"
    tuple=$(REFS_JSON="$refs" TAG_REF="refs/tags/v${VERSION}" node -e '
const refs = JSON.parse(process.env.REFS_JSON);
const matches = refs.filter((entry) => entry?.ref === process.env.TAG_REF);
if (matches.length > 1) throw new Error("duplicate exact tag refs");
if (matches.length === 1) process.stdout.write(`${matches[0].object.type}\t${matches[0].object.sha}`);
') || fail "GitHub returned an invalid release tag reference"
    if [[ -z "$tuple" ]]; then
        [[ "$allow_missing" == true ]] && return 2
        fail "GitHub release tag is missing"
    fi
    IFS=$'\t' read -r object_type object_sha <<< "$tuple"
    while [[ "$object_type" == tag ]]; do
        (( depth < 8 )) || fail "GitHub release tag nesting is invalid"
        tuple=$(gh api --hostname "$GITHUB_HOST" \
          "repos/${GITHUB_API_REPOSITORY}/git/tags/${object_sha}" --jq \
          '[.object.type, .object.sha] | @tsv') || fail "Could not peel the GitHub release tag"
        IFS=$'\t' read -r object_type object_sha <<< "$tuple"
        ((depth += 1))
    done
    [[ "$object_type" == commit && "$object_sha" =~ ^[0-9a-f]{40}$ ]] ||
        fail "GitHub release tag does not resolve to a commit"
    printf '%s\n' "$object_sha"
}

ensure_github_release_tag() {
    local tag_commit result
    if tag_commit=$(github_tag_commit true); then
        [[ "$tag_commit" == "$RELEASE_SOURCE_COMMIT" ]] ||
            fail "Existing GitHub release tag differs from the frozen source commit"
    else
        result=$?
        [[ $result -eq 2 ]] || fail "Could not validate the GitHub release tag"
        if ! gh api --hostname "$GITHUB_HOST" --method POST \
          "repos/${GITHUB_API_REPOSITORY}/git/refs" \
          -f "ref=refs/tags/v${VERSION}" -f "sha=${RELEASE_SOURCE_COMMIT}" >/dev/null; then
            tag_commit=$(github_tag_commit false) || fail "Could not create the frozen GitHub release tag"
            [[ "$tag_commit" == "$RELEASE_SOURCE_COMMIT" ]] ||
                fail "Concurrent GitHub release tag differs from the frozen source commit"
        fi
    fi
    tag_commit=$(github_tag_commit false)
    [[ "$tag_commit" == "$RELEASE_SOURCE_COMMIT" ]] ||
        fail "GitHub release tag differs from the frozen source commit"
}

verify_github_release_assets() {
    local npm_metadata_path="${1:-}" allow_body_mismatch="${2:-false}"
    local allow_asset_repair="${3:-false}"
    local expected_assets_json expected_body_json release_json tag_commit

    echo -e "\n${BLUE}Verifying GitHub release assets...${NC}"
    assert_publication_receipt "$npm_metadata_path"
    expected_assets_json=$(node -e '
const receipt = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
process.stdout.write(JSON.stringify(receipt.assets));
' "$PUBLICATION_RECEIPT_PATH")
    tag_commit=$(github_tag_commit false)
    if [[ "$allow_body_mismatch" == true ]]; then
        expected_body_json=null
    else
        expected_body_json=$(node -e \
          'process.stdout.write(JSON.stringify(require("fs").readFileSync(process.argv[1], "utf8")))' \
          "$RELEASE_DIR/github-release-body.md")
    fi

    release_json=$(gh api --hostname "$GITHUB_HOST" \
      "repos/${GITHUB_API_REPOSITORY}/releases/tags/v${VERSION}")
    printf '{"release":%s,"version":"%s","sourceCommit":"%s","tagCommit":"%s","expectedAssets":%s,"expectedBody":%s,"expectDraft":true,"allowAssetRepair":%s}\n' \
        "$release_json" "$VERSION" "$RELEASE_SOURCE_COMMIT" "$tag_commit" "$expected_assets_json" \
        "$expected_body_json" "$allow_asset_repair" |
        node "$RELEASE_CONTRACT" github-release
    echo -e "${GREEN}✅ GitHub release assets verified${NC}"
}

verify_npm_publication() {
    local metadata package_name publish_times metadata_tmp
    package_name=$(node -p "require('$PROJECT_ROOT/package.json').name")
    [[ "$(npm_package_integrity "$NPM_PACKAGE_PATH")" == "$NPM_PACKAGE_INTEGRITY" ]] ||
        fail "Local npm package changed after it was frozen"
    metadata=$(npm view "$package_name@$VERSION" --registry "$NPM_REGISTRY" --json)
    publish_times=$(npm view "$package_name" time --registry "$NPM_REGISTRY" --json)
    metadata=$(NPM_METADATA="$metadata" NPM_TIMES="$publish_times" node -e '
const metadata = JSON.parse(process.env.NPM_METADATA);
metadata.time = JSON.parse(process.env.NPM_TIMES);
process.stdout.write(JSON.stringify(metadata));
')
    metadata_tmp=$(mktemp "$RELEASE_DIR/.npm-publication.XXXXXX")
    printf '%s\n' "$metadata" > "$metadata_tmp"
    chmod 0444 "$metadata_tmp"
    mv -f "$metadata_tmp" "$RELEASE_DIR/npm-publication.json"
    printf '{"metadata":%s,"packageName":"%s","version":"%s","localIntegrity":"%s"}\n' \
        "$metadata" "$package_name" "$VERSION" "$NPM_PACKAGE_INTEGRITY" |
        node "$RELEASE_CONTRACT" npm-publication
    echo -e "${GREEN}✅ npm publication integrity verified${NC}"
}

configure_npm_publication() {
    set +x
    [[ -n "${NPM_TOKEN:-}" ]] ||
        fail "NPM_TOKEN is required for isolated registry-pinned publication"
    NPM_USERCONFIG=$(mktemp "${TMPDIR:-/tmp}/peekaboo-npmrc.XXXXXX")
    trap 'rm -f "${NPM_USERCONFIG:-}"' EXIT
    chmod 600 "$NPM_USERCONFIG"
    printf 'registry=%s/\n@steipete:registry=%s/\n//registry.npmjs.org/:_authToken=%s\n' \
      "$NPM_REGISTRY" "$NPM_REGISTRY" "$NPM_TOKEN" > "$NPM_USERCONFIG"
    export NPM_CONFIG_USERCONFIG="$NPM_USERCONFIG"
    unset NPM_TOKEN
    local publish_config_registry
    publish_config_registry=$(node -p "require('$PROJECT_ROOT/package.json').publishConfig?.registry ?? ''")
    [[ -z "$publish_config_registry" || "$publish_config_registry" == "$NPM_REGISTRY" ||
       "$publish_config_registry" == "$NPM_REGISTRY/" ]] ||
        fail "package publishConfig.registry conflicts with npmjs publication"
    if ! npm whoami --registry "$NPM_REGISTRY" >/dev/null 2>&1; then
        fail "npm authentication missing or invalid for $NPM_REGISTRY"
    fi
    NPM_TAG=""
    if [[ "$VERSION" == *"-"* ]]; then
        NPM_TAG=beta
    fi
}

confirm_npm_publication() {
    local reply
    if [ -n "$NPM_TAG" ]; then
        echo -e "${YELLOW}About to publish @steipete/peekaboo@${VERSION} to npm (tag: ${NPM_TAG})${NC}"
    else
        echo -e "${YELLOW}About to publish @steipete/peekaboo@${VERSION} to npm${NC}"
    fi
    if ! read -p "Continue? (y/N) " -n 1 -r reply; then
        fail "npm confirmation input closed; no new public action was taken"
    fi
    echo
    [[ $reply =~ ^[Yy]$ ]] || fail "npm publication declined; no new public action was taken"
}

validate_npm_publish_attempt() {
    local marker="$RELEASE_DIR/npm-publish-attempt.json"
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    printf '{"marker":%s,"sourceCommit":"%s","version":"%s","npmIntegrity":"%s"}\n' \
      "$(node -e 'process.stdout.write(JSON.stringify(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))))' \
        "$marker")" "$RELEASE_SOURCE_COMMIT" "$VERSION" "$NPM_PACKAGE_INTEGRITY" |
      node "$RELEASE_CONTRACT" npm-publish-attempt || fail "npm publish-attempt marker is invalid"
}

write_npm_publish_attempt() {
    local marker_tmp
    marker_tmp=$(mktemp "$RELEASE_DIR/.npm-publish-attempt.XXXXXX")
    printf '{"source_commit":"%s","version":"%s","npm_integrity":"%s"}\n' \
      "$RELEASE_SOURCE_COMMIT" "$VERSION" "$NPM_PACKAGE_INTEGRITY" > "$marker_tmp"
    chmod 0444 "$marker_tmp"
    mv -f "$marker_tmp" "$RELEASE_DIR/npm-publish-attempt.json"
}

publish_frozen_npm_package() {
    assert_publication_receipt
    [[ "$(npm_package_integrity "$NPM_PACKAGE_PATH")" == "$NPM_PACKAGE_INTEGRITY" ]] ||
        fail "Local npm package changed before publication"
    write_npm_publish_attempt
    if [ -n "$NPM_TAG" ]; then
        pnpm publish "$NPM_PACKAGE_PATH" --registry "$NPM_REGISTRY" --tag "$NPM_TAG" --no-git-checks
    else
        pnpm publish "$NPM_PACKAGE_PATH" --registry "$NPM_REGISTRY" --no-git-checks
    fi
}

npm_publication_exists() {
    local package_name observed error_path error_output result state
    package_name=$(node -p "require('$PROJECT_ROOT/package.json').name")
    error_path=$(mktemp "${TMPDIR:-/tmp}/peekaboo-npm-view.XXXXXX")
    if observed=$(npm view "$package_name@$VERSION" version --registry "$NPM_REGISTRY" \
      --json 2> "$error_path"); then
        result=0
    else
        result=$?
    fi
    error_output=$(<"$error_path")
    rm -f "$error_path"
    state=$(NPM_VIEW_STDOUT="$observed" NPM_VIEW_STDERR="$error_output" \
      NPM_VIEW_EXIT="$result" EXPECTED_VERSION="$VERSION" node -e '
process.stdout.write(JSON.stringify({
  exitCode: Number(process.env.NPM_VIEW_EXIT),
  stdout: process.env.NPM_VIEW_STDOUT,
  stderr: process.env.NPM_VIEW_STDERR,
  expectedVersion: process.env.EXPECTED_VERSION,
}));
' | node "$RELEASE_CONTRACT" npm-view-state) ||
        fail "Could not determine whether npm publication already exists"
    [[ "$state" == published ]] && return 0
    [[ "$state" == absent ]] && return 2
    fail "npm publication probe returned an unknown state"
}

prepare_release_assets() {
    RELEASE_ASSETS=(
        "$RELEASE_DIR/$CLI_TARBALL_NAME"
        "$NPM_PACKAGE_PATH"
        "$RELEASE_DIR/release-plan.json"
    )
    if [[ -n "$RELEASE_PROOF_SHA256" ]]; then
        RELEASE_ASSETS+=("$RELEASE_DIR/release-proof.md")
    fi
    if [[ -n "$MAC_APP_ZIP_PATH" ]]; then
        RELEASE_ASSETS+=("$MAC_APP_ZIP_PATH" "$MAC_APP_DMG_PATH" \
          "$RELEASE_DIR/appcast-entry.json" "$RELEASE_DIR/appcast.xml")
    fi
    RELEASE_ASSETS+=("$RELEASE_DIR/checksums.txt")
}

github_release_exists() {
    local error_path result
    error_path=$(mktemp "${TMPDIR:-/tmp}/peekaboo-gh-release-view.XXXXXX")
    if gh api --hostname "$GITHUB_HOST" \
      "repos/${GITHUB_API_REPOSITORY}/releases/tags/v${VERSION}" >/dev/null 2> "$error_path"; then
        rm -f "$error_path"
        return 0
    else
        result=$?
        if /usr/bin/grep -Eq 'HTTP 404|Not Found.*404' "$error_path"; then
            rm -f "$error_path"
            return 2
        fi
        rm -f "$error_path"
        fail "Could not determine whether the GitHub release draft exists (gh exit $result)"
    fi
}

create_github_release_draft() {
    prepare_release_assets
    assert_publication_receipt "${1:-}"
    ensure_github_release_tag
    gh release create "v${VERSION}" \
        --repo "$GITHUB_REPOSITORY" \
        --draft \
        --verify-tag \
        --title "v${VERSION}" \
        --notes-file "$RELEASE_DIR/github-release-body.md" \
        "${RELEASE_ASSETS[@]}"
}

load_retained_release_state() {
    local plan_json fields status helper_pin retained_version
    local -a npm_packages
    [[ -f "$RELEASE_DIR/release-plan.json" && ! -L "$RELEASE_DIR/release-plan.json" ]] ||
        fail "Retained release plan is missing"
    plan_json=$(node "$RELEASE_CONTRACT" release-plan-file < "$RELEASE_DIR/release-plan.json") ||
        fail "Retained release plan is invalid"
    fields=$(PLAN_JSON="$plan_json" node -e '
const plan = JSON.parse(process.env.PLAN_JSON);
process.stdout.write([
  plan.source_commit, plan.version, plan.helper.commit, plan.helper.executable_sha256,
  plan.helper.library_sha256, plan.proof_sha256 ?? "", plan.preflight_completed,
  plan.publication_eligible,
].join("\t"));
')
    IFS=$'\t' read -r RELEASE_SOURCE_COMMIT retained_version RELEASE_HELPER_COMMIT \
      RELEASE_HELPER_EXECUTABLE_SHA256 RELEASE_HELPER_LIBRARY_SHA256 RELEASE_PROOF_SHA256 \
      RELEASE_PREFLIGHT_COMPLETED RELEASE_PUBLICATION_ELIGIBLE <<< "$fields"
    [[ "$retained_version" == "$VERSION" && -n "$RELEASE_PROOF_SHA256" &&
       "$RELEASE_PREFLIGHT_COMPLETED" == true && "$RELEASE_PUBLICATION_ELIGIBLE" == true ]] ||
        fail "Retained release plan is not eligible for publication"
    [[ "$(git -C "$PROJECT_ROOT" rev-parse HEAD)" == "$RELEASE_SOURCE_COMMIT" ]] ||
        fail "Retained release plan differs from the current source commit"
    status=$(git -C "$PROJECT_ROOT" status --porcelain --untracked-files=all)
    [[ -z "$status" || "$status" == ' M appcast.xml' ]] ||
        fail "Resume requires a clean checkout or the retained generated appcast as the only source change"
    [[ -f "$RELEASE_DIR/appcast.xml" && ! -L "$RELEASE_DIR/appcast.xml" &&
       "$(sha256_file "$RELEASE_DIR/appcast.xml")" == "$(sha256_file "$PROJECT_ROOT/appcast.xml")" ]] ||
        fail "Current appcast differs from the retained release snapshot"
    RELEASE_APPCAST_SHA256=$(sha256_file "$PROJECT_ROOT/appcast.xml")
    RELEASE_PLAN_SHA256=$(sha256_file "$RELEASE_DIR/release-plan.json")
    RELEASE_PROOF_FILE="$RELEASE_DIR/release-proof.md"
    RELEASE_PROOF_PROVIDED=true
    [[ -f "$RELEASE_PROOF_FILE" && ! -L "$RELEASE_PROOF_FILE" &&
       "$(sha256_file "$RELEASE_PROOF_FILE")" == "$RELEASE_PROOF_SHA256" ]] ||
        fail "Retained release proof differs from the release plan"
    helper_pin=$(release_helper_pin)
    [[ "$helper_pin" == "$RELEASE_HELPER_COMMIT"$'\t'"$RELEASE_HELPER_EXECUTABLE_SHA256"$'\t'"$RELEASE_HELPER_LIBRARY_SHA256" ]] ||
        fail "Release helper differs from the retained release plan"
    RELEASE_HELPER_PIN="$helper_pin"

    CLI_ARTIFACT_DIR=peekaboo-macos-universal
    CLI_TARBALL_NAME=peekaboo-macos-universal.tar.gz
    MAC_APP_ZIP_PATH="$RELEASE_DIR/Peekaboo-${VERSION}.app.zip"
    MAC_APP_DMG_PATH="$RELEASE_DIR/Peekaboo-${VERSION}.dmg"
    shopt -s nullglob
    npm_packages=("$RELEASE_DIR"/*.tgz)
    shopt -u nullglob
    [[ ${#npm_packages[@]} -eq 1 ]] || fail "Resume requires exactly one retained npm package"
    NPM_PACKAGE_PATH=${npm_packages[0]}
    NPM_PACKAGE_INTEGRITY=$(npm_package_integrity "$NPM_PACKAGE_PATH")
    if [[ -e "$RELEASE_DIR/npm-publish-attempt.json" ]]; then
        validate_npm_publish_attempt || fail "Retained npm publish-attempt marker is invalid"
    fi
    assert_release_plan
    verify_appcast_entry
    verify_release_artifacts
    validate_retained_pending_receipt
}

resume_publication() {
    local npm_already_published=false
    echo -e "\n${BLUE}Resuming retained release publication...${NC}"
    require_command gh
    load_retained_release_state
    if npm_publication_exists; then
        npm_already_published=true
        verify_npm_publication
        compose_github_body "$RELEASE_DIR/npm-publication.json"
        freeze_publication_receipt "$RELEASE_DIR/npm-publication.json"
    else
        if validate_npm_publish_attempt && [[ "$RETRY_NPM_PUBLISH" != true ]]; then
            fail "npm publish was already attempted but the version is not visible; retry later or explicitly use --retry-npm-publish"
        fi
        compose_github_body
        activate_retained_pending_receipt
        configure_npm_publication
        confirm_npm_publication
    fi
    prepare_release_assets
    if github_release_exists; then
        if [[ "$npm_already_published" == true ]]; then
            verify_github_release_assets "$RELEASE_DIR/npm-publication.json" true true
        else
            verify_github_release_assets "" true true
        fi
        gh release upload "v${VERSION}" "${RELEASE_ASSETS[@]}" \
          --repo "$GITHUB_REPOSITORY" --clobber
    else
        if [[ "$npm_already_published" == true ]]; then
            create_github_release_draft "$RELEASE_DIR/npm-publication.json"
        else
            create_github_release_draft
        fi
    fi
    if [[ "$npm_already_published" == true ]]; then
        verify_github_release_assets "$RELEASE_DIR/npm-publication.json" true
    else
        verify_github_release_assets "" true
        publish_frozen_npm_package
        verify_npm_publication
        compose_github_body "$RELEASE_DIR/npm-publication.json"
        freeze_publication_receipt "$RELEASE_DIR/npm-publication.json"
    fi
    assert_publication_receipt "$RELEASE_DIR/npm-publication.json"
    gh release edit "v${VERSION}" --repo "$GITHUB_REPOSITORY" \
      --notes-file "$RELEASE_DIR/github-release-body.md"
    assert_publication_receipt "$RELEASE_DIR/npm-publication.json"
    verify_github_release_assets "$RELEASE_DIR/npm-publication.json"
    echo -e "${GREEN}✅ Resumed npm publication and GitHub draft finalization${NC}"
}

# Parse command line arguments
SKIP_CHECKS=false
CREATE_GITHUB_RELEASE=false
PUBLISH_NPM=false
RESUME_PUBLICATION=false
RETRY_NPM_PUBLISH=false
UNIVERSAL=true
INCLUDE_MAC_APP=true
MAC_APP_NOTARIZE=true
MAC_APP_APPCAST=true
REUSE_BUILT_CLI=false
EXPECTED_REUSE_SOURCE_COMMIT=""
RELEASE_PROOF_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-checks)
            SKIP_CHECKS=true
            shift
            ;;
        --create-github-release)
            CREATE_GITHUB_RELEASE=true
            shift
            ;;
        --publish-npm)
            PUBLISH_NPM=true
            shift
            ;;
        --resume-publication)
            RESUME_PUBLICATION=true
            shift
            ;;
        --retry-npm-publish)
            RETRY_NPM_PUBLISH=true
            shift
            ;;
        --reuse-built-cli)
            REUSE_BUILT_CLI=true
            shift
            ;;
        --proof-file)
            RELEASE_PROOF_FILE="${2:-}"
            [[ -n "$RELEASE_PROOF_FILE" ]] || fail "--proof-file requires a path"
            shift 2
            ;;
        --arm64-only)
            UNIVERSAL=false
            shift
            ;;
        --universal)
            UNIVERSAL=true
            shift
            ;;
        --skip-mac-app)
            INCLUDE_MAC_APP=false
            shift
            ;;
        --no-notarize-mac-app)
            MAC_APP_NOTARIZE=false
            shift
            ;;
        --no-appcast)
            MAC_APP_APPCAST=false
            shift
            ;;
        --help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  --skip-checks          Skip pre-release checks"
            echo "  --create-github-release Create draft GitHub release"
            echo "  --publish-npm          Publish to npm after building"
            echo "  --resume-publication   Resume a partial public release from retained verified artifacts"
            echo "  --retry-npm-publish    With resume, explicitly retry an attempted npm publish still returning E404"
            echo "  --reuse-built-cli      Reuse an exact-HEAD signed/notarized CLI after full verification"
            echo "  --proof-file PATH      CI/test proof appended to the source-bound GitHub release body"
            echo "  --arm64-only           Build arm64-only binary"
            echo "  --universal            Build universal (arm64+x86_64) binary (default)"
            echo "  --skip-mac-app         Skip Peekaboo.app zip/DMG, Sparkle appcast, and app checksums"
            echo "  --no-notarize-mac-app  Disable CLI/app/DMG notarization for local builds only"
            echo "  --no-appcast           Do not update appcast.xml"
            echo "  Public GitHub and npm actions must be requested together with --proof-file."
            echo "  After a partial public action, rerun with --resume-publication and the retained release directory."
            echo "  --help                 Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

RELEASE_PROOF_PROVIDED=false
RELEASE_PROOF_SHA256=""
RELEASE_CHECKSUMS_SHA256=""
GITHUB_BODY_SHA256=""
GITHUB_BODY_NPM_METADATA_SHA256=""
PUBLICATION_RECEIPT_SHA256=""
PUBLICATION_RECEIPT_PATH=""
RETAINED_PENDING_RECEIPT_SHA256=""
RELEASE_PREFLIGHT_COMPLETED=false
RELEASE_PUBLICATION_ELIGIBLE=false
if [[ -n "$RELEASE_PROOF_FILE" ]]; then
    [[ "$RELEASE_PROOF_FILE" == /* ]] || RELEASE_PROOF_FILE="$PROJECT_ROOT/$RELEASE_PROOF_FILE"
    [[ -f "$RELEASE_PROOF_FILE" && ! -L "$RELEASE_PROOF_FILE" &&
       "$(stat -f%l "$RELEASE_PROOF_FILE")" == 1 ]] || fail "Release proof must be one regular file"
    RELEASE_PROOF_SIZE=$(stat -f%z "$RELEASE_PROOF_FILE")
    (( RELEASE_PROOF_SIZE > 0 && RELEASE_PROOF_SIZE <= 65536 )) ||
        fail "Release proof must be between 1 byte and 64 KiB"
    RELEASE_PROOF_FILE="$(cd "$(dirname "$RELEASE_PROOF_FILE")" && pwd -P)/$(basename "$RELEASE_PROOF_FILE")"
    case "$RELEASE_PROOF_FILE" in
        "$BUILD_DIR"|"$BUILD_DIR"/*) fail "Release proof must be outside the disposable build directory" ;;
        "$RELEASE_DIR"|"$RELEASE_DIR"/*) fail "Release proof must be outside the disposable release directory" ;;
    esac
    RELEASE_PROOF_SHA256=$(sha256_file "$RELEASE_PROOF_FILE")
    RELEASE_PROOF_PROVIDED=true
fi

validate_publication_options
RELEASE_OPTION_FINGERPRINT="$SKIP_CHECKS|$CREATE_GITHUB_RELEASE|$PUBLISH_NPM|$RESUME_PUBLICATION|$RETRY_NPM_PUBLISH|$UNIVERSAL|$INCLUDE_MAC_APP|$MAC_APP_NOTARIZE|$MAC_APP_APPCAST|$REUSE_BUILT_CLI|$RELEASE_PROOF_FILE|$RELEASE_PROOF_SHA256|$BUILD_DIR|$RELEASE_DIR"

if [ -f "$MAC_RELEASE_MANIFEST" ]; then
    # shellcheck source=/Users/steipete/Projects/Peekaboo/.mac-release.env
    source "$MAC_RELEASE_MANIFEST"
fi
OBSERVED_RELEASE_OPTION_FINGERPRINT="$SKIP_CHECKS|$CREATE_GITHUB_RELEASE|$PUBLISH_NPM|$RESUME_PUBLICATION|$RETRY_NPM_PUBLISH|$UNIVERSAL|$INCLUDE_MAC_APP|$MAC_APP_NOTARIZE|$MAC_APP_APPCAST|$REUSE_BUILT_CLI|$RELEASE_PROOF_FILE|$RELEASE_PROOF_SHA256|$BUILD_DIR|$RELEASE_DIR"
[[ "$RELEASE_OPTION_FINGERPRINT" == "$OBSERVED_RELEASE_OPTION_FINGERPRINT" ]] ||
    fail "Release manifest changed command-line publication authority"
validate_publication_options
CLI_SIGN_IDENTITY="${MAC_RELEASE_CLI_CODESIGN_IDENTITY:-Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)}"
CLI_SIGN_TEAM_ID="${MAC_RELEASE_CLI_CODESIGN_TEAM_ID:-FWJYW4S8P8}"
CLI_SIGN_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$CLI_SIGN_TEAM_ID\""
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-${NOTARYTOOL_KEYCHAIN_PROFILE:-}}"
export NOTARYTOOL_PROFILE

require_command git
require_command node
VERSION=$(node -p "require('$PROJECT_ROOT/package.json').version")
if [[ "$RESUME_PUBLICATION" == true ]]; then
    resume_publication
    exit 0
fi
RELEASE_SOURCE_COMMIT=$(peekaboo_require_source_commit "$PROJECT_ROOT") ||
    fail "Release requires one clean exact source commit"
RELEASE_HELPER_PIN=$(release_helper_pin)
IFS=$'\t' read -r RELEASE_HELPER_COMMIT RELEASE_HELPER_EXECUTABLE_SHA256 \
    RELEASE_HELPER_LIBRARY_SHA256 <<< "$RELEASE_HELPER_PIN"
EXPECTED_REUSE_SOURCE_COMMIT="$RELEASE_SOURCE_COMMIT"
REUSED_CLI_SHA256=""
assert_release_plan

if [ "$REUSE_BUILT_CLI" = true ]; then
    echo -e "\n${BLUE}Verifying reusable CLI before any preflight execution...${NC}"
    verify_binary_artifact \
        "$PROJECT_ROOT/peekaboo" "Reused CLI" true "$RELEASE_SOURCE_COMMIT"
    REUSED_CLI_SHA256=$(sha256_file "$PROJECT_ROOT/peekaboo")
fi

# Step 1: Run pre-release checks (unless skipped)
if [ "$SKIP_CHECKS" = false ]; then
    echo -e "\n${BLUE}Running pre-release checks...${NC}"
    # `prepare-release` is intentionally not runner-wrapped here: it can exceed runner timeouts.
    if [ "$UNIVERSAL" = true ]; then
        PREP_ENV="PEEKABOO_REQUIRE_UNIVERSAL=1"
    else
        PREP_ENV=""
    fi
    # Pin the release identity for the precheck too. Without it, the signing
    # steps it exercises fall back to a bare SIGN_IDENTITY inherited from the
    # operator's login shell, which silently signs with the wrong certificate.
    if [ "$REUSE_BUILT_CLI" = true ]; then
        PREPARE_COMMAND=(node scripts/prepare-release.js --no-build --bin "$PROJECT_ROOT/peekaboo")
    else
        PREPARE_COMMAND=(node scripts/prepare-release.js)
    fi
    # Keep package credentials and the managed codesign PATH shim out of the
    # complete gate. Keychain paths survive for its later signed CLI build.
    if ! terminal_artifact_run_build /usr/bin/env $PREP_ENV MAC_RELEASE_CODESIGN_IDENTITY="$CLI_SIGN_IDENTITY" \
        /bin/bash --noprofile --norc -p -c 'exec "$@"' peekaboo-release-preflight \
        "${PREPARE_COMMAND[@]}"; then
        echo -e "${RED}❌ Pre-release checks failed!${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ All checks passed${NC}"
    RELEASE_PREFLIGHT_COMPLETED=true
fi

assert_release_plan
if [ "$REUSE_BUILT_CLI" = true ]; then
    [[ "$(sha256_file "$PROJECT_ROOT/peekaboo")" == "$REUSED_CLI_SHA256" ]] ||
        fail "Reusable CLI changed during release preflight"
fi

# Step 2: Clean previous build outputs. Do not clear release/ until after
# version metadata is embedded, because release/ contains tracked files.
echo -e "\n${BLUE}Cleaning previous builds...${NC}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Step 3: Use the version frozen by the release plan
echo -e "${BLUE}Building version: ${VERSION}${NC}"

# Step 4: Build binary
if [ "$UNIVERSAL" = true ]; then
    echo -e "\n${BLUE}Building universal binary...${NC}"
    BUILD_SCRIPT="build:swift:all"
    CLI_ARTIFACT_DIR="peekaboo-macos-universal"
    CLI_TARBALL_NAME="peekaboo-macos-universal.tar.gz"
else
    echo -e "\n${BLUE}Building arm64 binary...${NC}"
    BUILD_SCRIPT="build:swift"
    CLI_ARTIFACT_DIR="peekaboo-macos-arm64"
    CLI_TARBALL_NAME="peekaboo-macos-arm64.tar.gz"
fi

if [ "$REUSE_BUILT_CLI" = true ]; then
    echo -e "\n${BLUE}Reusing a fully verified CLI from exact HEAD...${NC}"
    peekaboo_verify_source_commit "$PROJECT_ROOT" "$EXPECTED_REUSE_SOURCE_COMMIT" ||
        fail "Release checkout changed before reusable CLI verification"
    # All non-executing safety gates run inside verify_binary_artifact before
    # the first --version invocation. Reuse always requires online notarization,
    # even when the app build itself was explicitly configured not to notarize.
    verify_binary_artifact \
        "$PROJECT_ROOT/peekaboo" "Reused CLI" true "$EXPECTED_REUSE_SOURCE_COMMIT"
else
    assert_release_plan
    # Keep CLI signing inside the same managed Foundation keychain lane as the app and DMG.
    # A full release can already be inside codesign-run; avoid taking its release lock twice.
    if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
        BUILD_COMMAND=(pnpm run "$BUILD_SCRIPT")
    else
        BUILD_COMMAND=("$PROJECT_ROOT/scripts/mac-release" codesign-run -- pnpm run "$BUILD_SCRIPT")
    fi
    if ! MAC_RELEASE_EXPECTED_HELPER_COMMIT="$RELEASE_HELPER_COMMIT" \
        MAC_RELEASE_EXPECTED_HELPER_EXECUTABLE_SHA256="$RELEASE_HELPER_EXECUTABLE_SHA256" \
        MAC_RELEASE_EXPECTED_HELPER_LIBRARY_SHA256="$RELEASE_HELPER_LIBRARY_SHA256" \
        MAC_RELEASE_CODESIGN_IDENTITY="$CLI_SIGN_IDENTITY" "${BUILD_COMMAND[@]}"; then
        echo -e "${RED}❌ Swift build failed!${NC}"
        exit 1
    fi
    verify_release_binary_entitlements "$PROJECT_ROOT/peekaboo" "Built CLI"
    if [ "$MAC_APP_NOTARIZE" = true ]; then
        echo -e "\n${BLUE}Submitting standalone CLI to Apple notarization...${NC}"
        notarize_cli_binary "$PROJECT_ROOT/peekaboo"
    fi
    verify_binary_artifact "$PROJECT_ROOT/peekaboo" "Built CLI" "$MAC_APP_NOTARIZE" "$RELEASE_SOURCE_COMMIT"
    assert_release_plan
fi

# Step 5: Create release artifacts
echo -e "\n${BLUE}Creating release artifacts...${NC}"
reset_release_output_directory
if [[ "$CREATE_GITHUB_RELEASE" == true && "$PUBLISH_NPM" == true &&
      "$RELEASE_PREFLIGHT_COMPLETED" == true ]]; then
    RELEASE_PUBLICATION_ELIGIBLE=true
fi
write_release_plan

# Create CLI release directory
CLI_RELEASE_DIR="$BUILD_DIR/$CLI_ARTIFACT_DIR"
mkdir -p "$CLI_RELEASE_DIR"

# Copy files for CLI release
cp "$PROJECT_ROOT/peekaboo" "$CLI_RELEASE_DIR/"
for runtime_library in "$PROJECT_ROOT"/libswiftCompatibility*.dylib; do
    [ -e "$runtime_library" ] || continue
    cp "$runtime_library" "$CLI_RELEASE_DIR/"
done
cp "$PROJECT_ROOT/LICENSE" "$CLI_RELEASE_DIR/"
echo "$VERSION" > "$CLI_RELEASE_DIR/VERSION"

# Create minimal README for binary distribution
cat > "$CLI_RELEASE_DIR/README.md" << EOF
# Peekaboo CLI v${VERSION}

Lightning-fast macOS screenshots & AI vision analysis.

## Installation

\`\`\`bash
# Make binary executable
chmod +x peekaboo

# Move to your PATH
sudo mv peekaboo /usr/local/bin/

# Verify installation
peekaboo --version
\`\`\`

## Quick Start

\`\`\`bash
# Capture screenshot
peekaboo see --no-elements --app Safari --path screenshot.png

# List applications
peekaboo app list

# Capture and analyze a window with AI
peekaboo see --app Safari --analyze "What is shown?"
\`\`\`

## Documentation

Full documentation: https://github.com/openclaw/Peekaboo

## License

MIT License - see LICENSE file
EOF

# Create tarball
echo -e "${BLUE}Creating tarball...${NC}"
cd "$BUILD_DIR"
tar -czf "$RELEASE_DIR/$CLI_TARBALL_NAME" "$CLI_ARTIFACT_DIR"

# Create npm package tarball
echo -e "${BLUE}Creating npm package...${NC}"
cd "$PROJECT_ROOT"
NPM_PACK_OUTPUT=$(pnpm pack --pack-destination "$RELEASE_DIR" 2>&1)
NPM_PACKAGE=$(echo "$NPM_PACK_OUTPUT" | grep -o '[^ ]*\.tgz' | tail -1)
NPM_PACKAGE_PATH="$RELEASE_DIR/$(basename "$NPM_PACKAGE")"

if [ -z "$NPM_PACKAGE" ]; then
    echo -e "${RED}❌ Failed to create npm package${NC}"
    exit 1
fi
NPM_PACKAGE_INTEGRITY=$(npm_package_integrity "$NPM_PACKAGE_PATH")

# Step 6: Generate checksums
echo -e "\n${BLUE}Generating checksums...${NC}"
cd "$RELEASE_DIR"

# Generate SHA256 checksums
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$CLI_TARBALL_NAME" > checksums.txt
    shasum -a 256 "$(basename "$NPM_PACKAGE")" >> checksums.txt
    shasum -a 256 "release-plan.json" >> checksums.txt
    if [[ -n "$RELEASE_PROOF_SHA256" ]]; then
        shasum -a 256 "release-proof.md" >> checksums.txt
    fi
else
    echo -e "${YELLOW}⚠️  shasum not found, skipping checksum generation${NC}"
fi

# Step 7: Build/sign/notarize macOS app zip and append checksum
MAC_APP_ZIP_PATH=""
MAC_APP_DMG_PATH=""
if [ "$INCLUDE_MAC_APP" = true ]; then
    echo -e "\n${BLUE}Building Peekaboo.app release zip...${NC}"
    assert_release_plan
    MAC_APP_ARGS=()
    if [ "$MAC_APP_NOTARIZE" = false ]; then
        MAC_APP_ARGS+=(--no-notarize)
    fi
    if [ "$MAC_APP_APPCAST" = false ]; then
        MAC_APP_ARGS+=(--no-appcast)
    fi
    if [ ${#MAC_APP_ARGS[@]} -gt 0 ]; then
        if ! RELEASE_DIR="$RELEASE_DIR" \
            PEEKABOO_RELEASE_SOURCE_COMMIT="$RELEASE_SOURCE_COMMIT" \
            PEEKABOO_RELEASE_VERSION="$VERSION" \
            MAC_RELEASE_EXPECTED_HELPER_COMMIT="$RELEASE_HELPER_COMMIT" \
            MAC_RELEASE_EXPECTED_HELPER_EXECUTABLE_SHA256="$RELEASE_HELPER_EXECUTABLE_SHA256" \
            MAC_RELEASE_EXPECTED_HELPER_LIBRARY_SHA256="$RELEASE_HELPER_LIBRARY_SHA256" \
            "$PROJECT_ROOT/scripts/release-macos-app.sh" "${MAC_APP_ARGS[@]}"; then
            echo -e "${RED}❌ macOS app release failed!${NC}"
            exit 1
        fi
    else
        if ! RELEASE_DIR="$RELEASE_DIR" \
            PEEKABOO_RELEASE_SOURCE_COMMIT="$RELEASE_SOURCE_COMMIT" \
            PEEKABOO_RELEASE_VERSION="$VERSION" \
            MAC_RELEASE_EXPECTED_HELPER_COMMIT="$RELEASE_HELPER_COMMIT" \
            MAC_RELEASE_EXPECTED_HELPER_EXECUTABLE_SHA256="$RELEASE_HELPER_EXECUTABLE_SHA256" \
            MAC_RELEASE_EXPECTED_HELPER_LIBRARY_SHA256="$RELEASE_HELPER_LIBRARY_SHA256" \
            "$PROJECT_ROOT/scripts/release-macos-app.sh"; then
            echo -e "${RED}❌ macOS app release failed!${NC}"
            exit 1
        fi
    fi
    MAC_APP_ZIP_PATH="$RELEASE_DIR/Peekaboo-${VERSION}.app.zip"
    MAC_APP_DMG_PATH="$RELEASE_DIR/Peekaboo-${VERSION}.dmg"
    if [ ! -f "$MAC_APP_ZIP_PATH" ]; then
        echo -e "${RED}❌ Expected macOS app artifact missing: $MAC_APP_ZIP_PATH${NC}"
        exit 1
    fi
    if [ ! -f "$MAC_APP_DMG_PATH" ]; then
        echo -e "${RED}❌ Expected macOS DMG artifact missing: $MAC_APP_DMG_PATH${NC}"
        exit 1
    fi
    if [[ "$MAC_APP_APPCAST" == true ]]; then
        verify_appcast_entry
        RELEASE_APPCAST_SHA256=$(sha256_file "$PROJECT_ROOT/appcast.xml")
    fi
    assert_release_plan
fi

# Step 8: Create release notes
echo -e "\n${BLUE}Generating release notes...${NC}"
validate_tracked_release_notes || fail "Tracked release notes are stale"
cp "$PROJECT_ROOT/release/release-notes.md" "$RELEASE_DIR/release-notes.md"

# Step 9: Verify release artifacts before any publish/upload step
verify_release_artifacts
if [[ "$CREATE_GITHUB_RELEASE" == true || "$PUBLISH_NPM" == true ]]; then
    compose_github_body
    freeze_publication_receipt
fi

# Step 10: Display results
echo -e "\n${GREEN}✅ Release artifacts created successfully!${NC}"
echo -e "${BLUE}Release directory: ${RELEASE_DIR}${NC}"
echo -e "${BLUE}Artifacts:${NC}"
ls -la "$RELEASE_DIR"
if [[ "$PUBLISH_NPM" == true ]]; then
    configure_npm_publication
    confirm_npm_publication
fi

# Step 11: Create GitHub release (if requested)
if [ "$CREATE_GITHUB_RELEASE" = true ]; then
    echo -e "\n${BLUE}Creating GitHub release draft...${NC}"
    
    if ! command -v gh >/dev/null 2>&1; then
        echo -e "${RED}❌ GitHub CLI (gh) not found. Install with: brew install gh${NC}"
        exit 1
    fi

    create_github_release_draft

    assert_publication_receipt
    verify_github_release_assets
    
    echo -e "${GREEN}✅ GitHub release draft created!${NC}"
    echo -e "${BLUE}Edit the release at: https://github.com/openclaw/Peekaboo/releases${NC}"
fi

# Step 12: Publish to npm (if requested)
if [ "$PUBLISH_NPM" = true ]; then
    echo -e "\n${BLUE}Publishing to npm...${NC}"
    require_command gh
    assert_publication_receipt
    [[ "$REUSE_BUILT_CLI" != true || "$(sha256_file "$PROJECT_ROOT/peekaboo")" == "$REUSED_CLI_SHA256" ]] ||
        fail "Reusable CLI changed while awaiting npm confirmation"
    publish_frozen_npm_package
    verify_npm_publication
    compose_github_body "$RELEASE_DIR/npm-publication.json"
    freeze_publication_receipt "$RELEASE_DIR/npm-publication.json"
    assert_publication_receipt "$RELEASE_DIR/npm-publication.json"
    gh release edit "v${VERSION}" --repo "$GITHUB_REPOSITORY" \
      --notes-file "$RELEASE_DIR/github-release-body.md"
    assert_publication_receipt "$RELEASE_DIR/npm-publication.json"
    verify_github_release_assets "$RELEASE_DIR/npm-publication.json"
    echo -e "${GREEN}✅ Published to npm!${NC}"
fi

echo -e "\n${GREEN}🎉 Release build complete!${NC}"
echo -e "${BLUE}Next steps:${NC}"
echo "1. Review artifacts in: $RELEASE_DIR"
echo "2. Test the binary: tar -xzf $RELEASE_DIR/$CLI_TARBALL_NAME && ./$CLI_ARTIFACT_DIR/peekaboo --version"
echo "3. Follow docs/RELEASING.md; use --resume-publication after any partial public action"
echo "4. Update Homebrew formula with new version and SHA256"
