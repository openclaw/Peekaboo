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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
RELEASE_DIR="${RELEASE_DIR:-$BUILD_DIR/release}"
MAC_RELEASE_MANIFEST="${MAC_RELEASE_MANIFEST:-$PROJECT_ROOT/.mac-release.env}"
if [ -f "$MAC_RELEASE_MANIFEST" ]; then
    # shellcheck source=/Users/steipete/Projects/Peekaboo/.mac-release.env
    source "$MAC_RELEASE_MANIFEST"
fi
CLI_SIGN_IDENTITY="${MAC_RELEASE_CLI_CODESIGN_IDENTITY:-Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)}"
CLI_SIGN_TEAM_ID="${MAC_RELEASE_CLI_CODESIGN_TEAM_ID:-FWJYW4S8P8}"
CLI_SIGN_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$CLI_SIGN_TEAM_ID\""
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-${NOTARYTOOL_KEYCHAIN_PROFILE:-}}"
export NOTARYTOOL_PROFILE

echo -e "${BLUE}🚀 Peekaboo Release Build Script${NC}"

fail() {
    echo -e "${RED}❌ $*${NC}" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 not found"
}

verify_binary_artifact() {
    local binary_path="$1"
    local label="$2"
    local version_output
    local binary_size
    local lipo_output
    local authority
    local team_id

    [ -x "$binary_path" ] || fail "$label binary missing or not executable: $binary_path"
    binary_size=$(stat -f%z "$binary_path")
    (( binary_size > 1000000 )) || fail "$label binary is unexpectedly small: $binary_size bytes"
    file "$binary_path" | grep -q 'Mach-O' || fail "$label binary is not Mach-O: $binary_path"
    codesign --verify --strict --verbose=2 "$binary_path"
    codesign --verify --strict -R="$CLI_SIGN_REQUIREMENT" "$binary_path"
    authority=$(codesign -dv --verbose=4 "$binary_path" 2>&1 | sed -n 's/^Authority=//p' | head -1)
    team_id=$(codesign -dv --verbose=4 "$binary_path" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)
    [ "$authority" = "$CLI_SIGN_IDENTITY" ] ||
        fail "$label signer mismatch: expected '$CLI_SIGN_IDENTITY', got '$authority'"
    [ "$team_id" = "$CLI_SIGN_TEAM_ID" ] ||
        fail "$label TeamIdentifier mismatch: expected '$CLI_SIGN_TEAM_ID', got '$team_id'"
    if [ "$MAC_APP_NOTARIZE" = true ]; then
        codesign --verify --strict --check-notarization -R=notarized --verbose=2 "$binary_path"
    fi

    if command -v lipo >/dev/null 2>&1; then
        lipo_output=$(lipo -info "$binary_path")
        if [ "$UNIVERSAL" = true ]; then
            printf '%s\n' "$lipo_output" | grep -q 'x86_64' || fail "$label binary is missing x86_64 slice"
            printf '%s\n' "$lipo_output" | grep -q 'arm64' || fail "$label binary is missing arm64 slice"
        else
            printf '%s\n' "$lipo_output" | grep -q 'arm64' || fail "$label binary is missing arm64 slice"
        fi
    fi

    version_output=$("$binary_path" --version)
    printf '%s\n' "$version_output" | grep -Fq "Peekaboo $VERSION" ||
        fail "$label version output does not contain Peekaboo $VERSION: $version_output"
    if printf '%s\n' "$version_output" | grep -Fq -- '-dirty'; then
        fail "$label was built from a dirty tree: $version_output"
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

    local app_zip_name
    local app_zip_length
    app_zip_name=$(basename "$MAC_APP_ZIP_PATH")
    app_zip_length=$(stat -f%z "$MAC_APP_ZIP_PATH")

    VERSION="$VERSION" \
    APPCAST_PATH="$PROJECT_ROOT/appcast.xml" \
    APP_ZIP_NAME="$app_zip_name" \
    APP_ZIP_LENGTH="$app_zip_length" \
    node <<'EOF'
const fs = require("node:fs");

const xml = fs.readFileSync(process.env.APPCAST_PATH, "utf8");
const version = process.env.VERSION;
const items = xml.match(/    <item>[\s\S]*?    <\/item>/g) ?? [];
const matches = items.filter((item) => item.includes(`sparkle:shortVersionString="${version}"`));

if (matches.length !== 1) {
  throw new Error(`Expected exactly one appcast item for ${version}, found ${matches.length}`);
}

const item = matches[0];
const expectedUrl = `https://github.com/openclaw/Peekaboo/releases/download/v${version}/${process.env.APP_ZIP_NAME}`;
const required = [
  [`url="${expectedUrl}"`, "asset URL"],
  [`length="${process.env.APP_ZIP_LENGTH}"`, "asset length"],
  [`sparkle:shortVersionString="${version}"`, "short version"],
  ["sparkle:edSignature=", "Sparkle EdDSA signature"],
];

for (const [needle, label] of required) {
  if (!item.includes(needle)) {
    throw new Error(`Appcast ${version} item missing ${label}: ${needle}`);
  }
}
EOF

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
    if [ "$INCLUDE_MAC_APP" = true ]; then
        grep -Fq "  $(basename "$MAC_APP_ZIP_PATH")" "$checksum_path" ||
            fail "checksums.txt missing $(basename "$MAC_APP_ZIP_PATH")"
        grep -Fq "  $(basename "$MAC_APP_DMG_PATH")" "$checksum_path" ||
            fail "checksums.txt missing $(basename "$MAC_APP_DMG_PATH")"
    fi
}

verify_release_artifacts() {
    echo -e "\n${BLUE}Verifying release artifacts...${NC}"
    require_command tar
    require_command shasum
    require_command file
    require_command codesign

    verify_cli_tarball "$RELEASE_DIR/$CLI_TARBALL_NAME"
    verify_npm_tarball "$NPM_PACKAGE_PATH"
    verify_checksums_file

    if [ "$INCLUDE_MAC_APP" = true ]; then
        MAC_VERIFY_ARGS=(--version "$VERSION" --verify-only "$MAC_APP_ZIP_PATH")
        if [ "$MAC_APP_NOTARIZE" = false ]; then
            MAC_VERIFY_ARGS+=(--no-notarize)
        fi
        "$PROJECT_ROOT/scripts/release-macos-app.sh" "${MAC_VERIFY_ARGS[@]}"
        DMG_VERIFY_ARGS=(--version "$VERSION" --verify-only "$MAC_APP_DMG_PATH")
        if [ "$MAC_APP_NOTARIZE" = false ]; then
            DMG_VERIFY_ARGS+=(--no-notarize)
        fi
        "$PROJECT_ROOT/scripts/create-release-dmg.sh" "${DMG_VERIFY_ARGS[@]}"
        verify_appcast_entry
    fi

    echo -e "${GREEN}✅ Release artifact verification passed${NC}"
}

verify_github_release_assets() {
    local expected_assets_json
    local release_json
    local expected_assets

    echo -e "\n${BLUE}Verifying GitHub release assets...${NC}"
    expected_assets=(
        "$CLI_TARBALL_NAME=$(stat -f%z "$RELEASE_DIR/$CLI_TARBALL_NAME")"
        "$(basename "$NPM_PACKAGE_PATH")=$(stat -f%z "$NPM_PACKAGE_PATH")"
        "checksums.txt=$(stat -f%z "$RELEASE_DIR/checksums.txt")"
    )
    if [ -n "$MAC_APP_ZIP_PATH" ]; then
        expected_assets+=("$(basename "$MAC_APP_ZIP_PATH")=$(stat -f%z "$MAC_APP_ZIP_PATH")")
        expected_assets+=("$(basename "$MAC_APP_DMG_PATH")=$(stat -f%z "$MAC_APP_DMG_PATH")")
    fi
    expected_assets_json=$(node -e '
const assets = Object.fromEntries(process.argv.slice(1).map((entry) => {
  const index = entry.lastIndexOf("=");
  return [entry.slice(0, index), Number(entry.slice(index + 1))];
}));
console.log(JSON.stringify(assets));
' "${expected_assets[@]}")

    release_json=$(gh release view "v${VERSION}" --json isDraft,tagName,assets)
    VERSION="$VERSION" EXPECTED_ASSETS_JSON="$expected_assets_json" RELEASE_JSON="$release_json" node <<'EOF'
const expected = JSON.parse(process.env.EXPECTED_ASSETS_JSON);
const release = JSON.parse(process.env.RELEASE_JSON);

if (release.tagName !== `v${process.env.VERSION}`) {
  throw new Error(`Unexpected release tag: ${release.tagName}`);
}

const assets = release.assets ?? [];
for (const [name, size] of Object.entries(expected)) {
  const asset = assets.find((entry) => entry.name === name);
  if (!asset) {
    throw new Error(`GitHub release asset missing: ${name}`);
  }
  if (asset.size !== size) {
    throw new Error(`GitHub release asset size mismatch for ${name}: expected ${size}, got ${asset.size}`);
  }
}
EOF
    echo -e "${GREEN}✅ GitHub release assets verified${NC}"
}

# Parse command line arguments
SKIP_CHECKS=false
CREATE_GITHUB_RELEASE=false
PUBLISH_NPM=false
UNIVERSAL=true
INCLUDE_MAC_APP=true
MAC_APP_NOTARIZE=true
MAC_APP_APPCAST=true

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
            echo "  --arm64-only           Build arm64-only binary"
            echo "  --universal            Build universal (arm64+x86_64) binary (default)"
            echo "  --skip-mac-app         Skip Peekaboo.app zip/DMG, Sparkle appcast, and app checksums"
            echo "  --no-notarize-mac-app  Build/sign app zip without Apple notarization"
            echo "  --no-appcast           Do not update appcast.xml"
            echo "  --help                 Show this help message"
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# Step 1: Run pre-release checks (unless skipped)
if [ "$SKIP_CHECKS" = false ]; then
    echo -e "\n${BLUE}Running pre-release checks...${NC}"
    # `prepare-release` is intentionally not runner-wrapped here: it can exceed runner timeouts.
    if [ "$UNIVERSAL" = true ]; then
        PREP_ENV="PEEKABOO_REQUIRE_UNIVERSAL=1"
    else
        PREP_ENV=""
    fi
    if ! env $PREP_ENV node scripts/prepare-release.js; then
        echo -e "${RED}❌ Pre-release checks failed!${NC}"
        exit 1
    fi
    echo -e "${GREEN}✅ All checks passed${NC}"
fi

# Step 2: Clean previous build outputs. Do not clear release/ until after
# version metadata is embedded, because release/ contains tracked files.
echo -e "\n${BLUE}Cleaning previous builds...${NC}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Step 3: Read version from package.json
VERSION=$(node -p "require('$PROJECT_ROOT/package.json').version")
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

# Keep CLI signing inside the same managed Foundation keychain lane as the app and DMG.
# A full release can already be inside codesign-run; avoid taking its release lock twice.
if [ -n "${CODESIGN_KEYCHAIN:-}" ]; then
    BUILD_COMMAND=(pnpm run "$BUILD_SCRIPT")
else
    BUILD_COMMAND=("$PROJECT_ROOT/scripts/mac-release" codesign-run -- pnpm run "$BUILD_SCRIPT")
fi
if ! MAC_RELEASE_CODESIGN_IDENTITY="$CLI_SIGN_IDENTITY" "${BUILD_COMMAND[@]}"; then
    echo -e "${RED}❌ Swift build failed!${NC}"
    exit 1
fi
if [ "$MAC_APP_NOTARIZE" = true ]; then
    echo -e "\n${BLUE}Submitting standalone CLI to Apple notarization...${NC}"
    notarize_cli_binary "$PROJECT_ROOT/peekaboo"
fi
verify_binary_artifact "$PROJECT_ROOT/peekaboo" "Built CLI"

# Step 5: Create release artifacts
echo -e "\n${BLUE}Creating release artifacts...${NC}"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR"

# Create CLI release directory
CLI_RELEASE_DIR="$BUILD_DIR/$CLI_ARTIFACT_DIR"
mkdir -p "$CLI_RELEASE_DIR"

# Copy files for CLI release
cp "$PROJECT_ROOT/peekaboo" "$CLI_RELEASE_DIR/"
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
peekaboo image --app Safari --path screenshot.png

# List applications
peekaboo list apps

# Capture and analyze a window with AI
peekaboo image --app Safari --analyze "What is shown?"
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

# Step 6: Generate checksums
echo -e "\n${BLUE}Generating checksums...${NC}"
cd "$RELEASE_DIR"

# Generate SHA256 checksums
if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$CLI_TARBALL_NAME" > checksums.txt
    shasum -a 256 "$(basename "$NPM_PACKAGE")" >> checksums.txt
else
    echo -e "${YELLOW}⚠️  shasum not found, skipping checksum generation${NC}"
fi

# Step 7: Build/sign/notarize macOS app zip and append checksum
MAC_APP_ZIP_PATH=""
MAC_APP_DMG_PATH=""
if [ "$INCLUDE_MAC_APP" = true ]; then
    echo -e "\n${BLUE}Building Peekaboo.app release zip...${NC}"
    MAC_APP_ARGS=()
    if [ "$MAC_APP_NOTARIZE" = false ]; then
        MAC_APP_ARGS+=(--no-notarize)
    fi
    if [ "$MAC_APP_APPCAST" = false ]; then
        MAC_APP_ARGS+=(--no-appcast)
    fi
    if [ ${#MAC_APP_ARGS[@]} -gt 0 ]; then
        if ! RELEASE_DIR="$RELEASE_DIR" "$PROJECT_ROOT/scripts/release-macos-app.sh" "${MAC_APP_ARGS[@]}"; then
            echo -e "${RED}❌ macOS app release failed!${NC}"
            exit 1
        fi
    else
        if ! RELEASE_DIR="$RELEASE_DIR" "$PROJECT_ROOT/scripts/release-macos-app.sh"; then
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
fi

# Step 8: Create release notes
echo -e "\n${BLUE}Generating release notes...${NC}"
if ! awk -v version="$VERSION" '
    $0 ~ "^## \\[?" version "\\]?" {
        in_section = 1
        found = 1
        print
        next
    }
    in_section && /^## / {
        exit
    }
    in_section {
        print
    }
    END {
        if (!found) {
            exit 1
        }
    }
' "$PROJECT_ROOT/CHANGELOG.md" > "$RELEASE_DIR/release-notes.md"; then
    echo -e "${RED}❌ Could not extract v${VERSION} notes from CHANGELOG.md${NC}"
    exit 1
fi
perl -0pi -e 's/\n+\z/\n/' "$RELEASE_DIR/release-notes.md"

# Step 9: Verify release artifacts before any publish/upload step
verify_release_artifacts

# Step 10: Display results
echo -e "\n${GREEN}✅ Release artifacts created successfully!${NC}"
echo -e "${BLUE}Release directory: ${RELEASE_DIR}${NC}"
echo -e "${BLUE}Artifacts:${NC}"
ls -la "$RELEASE_DIR"

# Step 11: Create GitHub release (if requested)
if [ "$CREATE_GITHUB_RELEASE" = true ]; then
    echo -e "\n${BLUE}Creating GitHub release draft...${NC}"
    
    if ! command -v gh >/dev/null 2>&1; then
        echo -e "${RED}❌ GitHub CLI (gh) not found. Install with: brew install gh${NC}"
        exit 1
    fi

    RELEASE_ASSETS=(
        "$RELEASE_DIR/$CLI_TARBALL_NAME"
        "$NPM_PACKAGE_PATH"
    )
    if [ -n "$MAC_APP_ZIP_PATH" ]; then
        RELEASE_ASSETS+=("$MAC_APP_ZIP_PATH")
        RELEASE_ASSETS+=("$MAC_APP_DMG_PATH")
    fi
    RELEASE_ASSETS+=("$RELEASE_DIR/checksums.txt")

    # Create release
    gh release create "v${VERSION}" \
        --draft \
        --title "v${VERSION}" \
        --notes-file "$RELEASE_DIR/release-notes.md" \
        "${RELEASE_ASSETS[@]}"

    verify_github_release_assets
    
    echo -e "${GREEN}✅ GitHub release draft created!${NC}"
    echo -e "${BLUE}Edit the release at: https://github.com/openclaw/Peekaboo/releases${NC}"
fi

# Step 12: Publish to npm (if requested)
if [ "$PUBLISH_NPM" = true ]; then
    echo -e "\n${BLUE}Publishing to npm...${NC}"
    NPM_TAG=""
    if [[ "$VERSION" == *"-"* ]]; then
        NPM_TAG="beta"
    fi
    
    # Confirm before publishing
    if [ -n "$NPM_TAG" ]; then
        echo -e "${YELLOW}About to publish @steipete/peekaboo@${VERSION} to npm (tag: ${NPM_TAG})${NC}"
    else
        echo -e "${YELLOW}About to publish @steipete/peekaboo@${VERSION} to npm${NC}"
    fi
    read -p "Continue? (y/N) " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if [ -n "$NPM_TAG" ]; then
            pnpm publish "$NPM_PACKAGE_PATH" --tag "$NPM_TAG" --no-git-checks
        else
            pnpm publish "$NPM_PACKAGE_PATH" --no-git-checks
        fi
        echo -e "${GREEN}✅ Published to npm!${NC}"
    else
        echo -e "${YELLOW}Skipped npm publish${NC}"
    fi
fi

echo -e "\n${GREEN}🎉 Release build complete!${NC}"
echo -e "${BLUE}Next steps:${NC}"
echo "1. Review artifacts in: $RELEASE_DIR"
echo "2. Test the binary: tar -xzf $RELEASE_DIR/$CLI_TARBALL_NAME && ./$CLI_ARTIFACT_DIR/peekaboo --version"
if [ "$CREATE_GITHUB_RELEASE" = false ]; then
    echo "3. Create GitHub release: $0 --create-github-release"
fi
if [ "$PUBLISH_NPM" = false ]; then
    echo "4. Publish to npm: $0 --publish-npm"
fi
echo "5. Update Homebrew formula with new version and SHA256"
