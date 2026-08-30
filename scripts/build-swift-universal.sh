#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SWIFT_PROJECT_PATH="$PROJECT_ROOT/Apps/CLI"
# shellcheck source=scripts/source-provenance.sh
source "$PROJECT_ROOT/scripts/source-provenance.sh"
# shellcheck source=scripts/resolve-swift-binary-path.sh
source "$PROJECT_ROOT/scripts/resolve-swift-binary-path.sh"
FINAL_BINARY_NAME="peekaboo"
FINAL_BINARY_PATH="$PROJECT_ROOT/$FINAL_BINARY_NAME"
SIGN_IDENTITY="${MAC_RELEASE_CODESIGN_IDENTITY:-${SIGN_IDENTITY:-}}"
CODESIGN_BIN="${MAC_RELEASE_CODESIGN_BIN:-codesign}"
CODESIGN_TIMESTAMP="${CODESIGN_TIMESTAMP:-auto}"
CODESIGN_TIMESTAMP_URL="${CODESIGN_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"
CODESIGN_KEYCHAIN="${MAC_RELEASE_CODESIGN_KEYCHAIN:-${CODESIGN_KEYCHAIN:-}}"

ARM64_BINARY_TEMP="$PROJECT_ROOT/${FINAL_BINARY_NAME}-arm64"
X86_64_BINARY_TEMP="$PROJECT_ROOT/${FINAL_BINARY_NAME}-x86_64"

# Swift compiler flags for size optimization.
# SwiftPM controls WMO; Swift 6.3.2 can hang or crash release builds here.
# Override SWIFT_OPTIMIZATION_FLAGS when explicitly testing a different compiler.
SWIFT_OPTIMIZATION_FLAGS="${SWIFT_OPTIMIZATION_FLAGS:--Xswiftc -Osize -Xlinker -dead_strip}"
SWIFT_RESOLUTION_ARGS=()
case "${PEEKABOO_USE_RESOLVED_VERSIONS:-0}" in
    1|true|yes|on)
        SWIFT_RESOLUTION_ARGS=(--only-use-versions-from-resolved-file)
        ;;
    0|false|no|off|'') ;;
    *)
        echo "ERROR: Invalid PEEKABOO_USE_RESOLVED_VERSIONS value: ${PEEKABOO_USE_RESOLVED_VERSIONS}" >&2
        exit 1
        ;;
esac

if command -v xcbeautify >/dev/null 2>&1; then
    USE_XCBEAUTIFY=1
else
    USE_XCBEAUTIFY=0
fi

pipe_build_output() {
    if [[ "$USE_XCBEAUTIFY" -eq 1 ]]; then
        xcbeautify "$@"
    else
        cat
    fi
}

select_identity() {
    local preferred available first
    preferred="$(security find-identity -p codesigning -v 2>/dev/null \
        | awk -F'\"' '/Developer ID Application/ { print $2; exit }')"
    if [ -n "$preferred" ]; then
        echo "$preferred"
        return
    fi
    available="$(security find-identity -p codesigning -v 2>/dev/null \
        | sed -n 's/.*\"\\(.*\\)\"/\\1/p')"
    if [ -n "$available" ]; then
        first="$(printf '%s\n' "$available" | head -n1)"
        echo "$first"
        return
    fi
    return 1
}

resolve_signing_identity() {
    if [ -n "$SIGN_IDENTITY" ]; then
        return 0
    fi
    if ! SIGN_IDENTITY="$(select_identity)"; then
        echo "ERROR: No signing identity found. Set SIGN_IDENTITY to a valid codesigning certificate." >&2
        exit 1
    fi
}

resolve_timestamp_arg() {
    TIMESTAMP_ARG="--timestamp=none"
    case "$CODESIGN_TIMESTAMP" in
        1|on|yes|true)
            TIMESTAMP_ARG="--timestamp=$CODESIGN_TIMESTAMP_URL"
            ;;
        0|off|no|false)
            TIMESTAMP_ARG="--timestamp=none"
            ;;
        auto)
            if [[ "$SIGN_IDENTITY" == *"Developer ID Application"* ]]; then
                TIMESTAMP_ARG="--timestamp=$CODESIGN_TIMESTAMP_URL"
            fi
            ;;
        *)
            echo "ERROR: Unknown CODESIGN_TIMESTAMP value: $CODESIGN_TIMESTAMP (use auto|on|off)" >&2
            exit 1
            ;;
    esac
}

resolve_keychain_args() {
    CODESIGN_KEYCHAIN_ARGS=()
    if [ -n "$CODESIGN_KEYCHAIN" ]; then
        CODESIGN_KEYCHAIN_ARGS=(--keychain "$CODESIGN_KEYCHAIN")
    fi
}

set_plist_value() {
    local plist="$1"
    local key="$2"
    local value="$3"
    /usr/libexec/PlistBuddy -c "Delete :$key" "$plist" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :$key string" "$plist" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Set :$key '$value'" "$plist"
}

generate_info_plist() {
    local template="$SWIFT_PROJECT_PATH/Sources/Resources/Info.plist"
    local output="$SWIFT_PROJECT_PATH/.generated/PeekabooCLI-Info.plist"
    mkdir -p "$SWIFT_PROJECT_PATH/.generated"
    cp "$template" "$output"

    local display="Peekaboo $VERSION"
    set_plist_value "$output" "CFBundleShortVersionString" "$VERSION"
    set_plist_value "$output" "CFBundleVersion" "$VERSION"
    set_plist_value "$output" "PeekabooVersionDisplayString" "$display"
    set_plist_value "$output" "PeekabooGitCommit" "$GIT_COMMIT_SHORT$GIT_DIRTY"
    set_plist_value "$output" "PeekabooSourceCommit" "$SOURCE_COMMIT"
    set_plist_value "$output" "PeekabooGitCommitDate" "$GIT_COMMIT_DATE"
    set_plist_value "$output" "PeekabooGitBranch" "$GIT_BRANCH"
    set_plist_value "$output" "PeekabooBuildDate" "$BUILD_DATE"
    if [[ -n "${PEEKABOO_CERTIFICATION_SOURCE_MANIFEST_SHA256:-}" ]]; then
        set_plist_value "$output" "PeekabooCertificationSourceManifestSHA256" \
            "$PEEKABOO_CERTIFICATION_SOURCE_MANIFEST_SHA256"
    fi
    if [[ -n "${PEEKABOO_CERTIFICATION_CATALOG_SHA256:-}" ]]; then
        set_plist_value "$output" "PeekabooCertificationCatalogSHA256" \
            "$PEEKABOO_CERTIFICATION_CATALOG_SHA256"
    fi

    export PEEKABOO_CLI_INFO_PLIST_PATH="$output"
}

echo "🧹 Cleaning previous build artifacts..."
python3 "$PROJECT_ROOT/scripts/setup-swift-workspace.py" setup
(cd "$SWIFT_PROJECT_PATH" && swift package reset) || echo "'swift package reset' encountered an issue, attempting rm -rf..."
rm -rf "$SWIFT_PROJECT_PATH/.build"
rm -f "$ARM64_BINARY_TEMP" "$X86_64_BINARY_TEMP" "$FINAL_BINARY_PATH.tmp"
for existing_library in "$PROJECT_ROOT"/libswiftCompatibility*.dylib; do
    [ -e "$existing_library" ] || continue
    rm -f -- "$existing_library"
done

echo "📦 Reading version from version.json..."
VERSION=$(node -p "require('$PROJECT_ROOT/version.json').version")
echo "Version: $VERSION"

# Get git information. Keep the historical short value for human display while
# certification consumes the separate immutable full source commit.
SOURCE_COMMIT=$(peekaboo_require_source_commit "$PROJECT_ROOT")
GIT_COMMIT_SHORT=$(peekaboo_short_source_commit "$SOURCE_COMMIT")
GIT_COMMIT_DATE=$(git show -s --format=%ci HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_DIRTY=$(git diff --quiet && git diff --cached --quiet || echo "-dirty")
BUILD_DATE=$(date -Iseconds)

echo "🧾 Embedding version metadata in Info.plist..."
generate_info_plist

echo "🏗️ Building for arm64 (Apple Silicon)..."
(
    cd "$SWIFT_PROJECT_PATH"
    python3 "$PROJECT_ROOT/scripts/setup-swift-workspace.py" run --release -- \
        swift build "${SWIFT_RESOLUTION_ARGS[@]}" --arch arm64 -c release $SWIFT_OPTIMIZATION_FLAGS 2>&1 | pipe_build_output
)
ARM64_BUILD_BINARY=$(bash "$PROJECT_ROOT/scripts/resolve-swift-binary-path.sh" \
    "$SWIFT_PROJECT_PATH" arm64 release "$FINAL_BINARY_NAME")
cp "$ARM64_BUILD_BINARY" "$ARM64_BINARY_TEMP"
echo "✅ arm64 build complete: $ARM64_BINARY_TEMP"

echo "🏗️ Building for x86_64 (Intel)..."
(
    cd "$SWIFT_PROJECT_PATH"
    python3 "$PROJECT_ROOT/scripts/setup-swift-workspace.py" run --release -- \
        swift build "${SWIFT_RESOLUTION_ARGS[@]}" "${SWIFT_X86_64_TARGET_ARGS[@]}" -c release $SWIFT_OPTIMIZATION_FLAGS 2>&1 | pipe_build_output
)
X86_64_BUILD_BINARY=$(bash "$PROJECT_ROOT/scripts/resolve-swift-binary-path.sh" \
    "$SWIFT_PROJECT_PATH" x86_64 release "$FINAL_BINARY_NAME")
cp "$X86_64_BUILD_BINARY" "$X86_64_BINARY_TEMP"
peekaboo_verify_source_commit "$PROJECT_ROOT" "$SOURCE_COMMIT"
echo "✅ x86_64 build complete: $X86_64_BINARY_TEMP"

echo "🔗 Creating universal binary..."
lipo -create -output "$FINAL_BINARY_PATH.tmp" "$ARM64_BINARY_TEMP" "$X86_64_BINARY_TEMP"

echo "🤏 Stripping symbols for further size reduction..."
# -S: Remove debugging symbols
# -x: Remove non-global symbols
# -u: Save symbols of undefined references
# Note: LC_UUID is preserved by not using -no_uuid during linking
strip -Sxu "$FINAL_BINARY_PATH.tmp"

echo "🔏 Code signing the universal binary..."
resolve_signing_identity
resolve_timestamp_arg
resolve_keychain_args
MAC_RELEASE_CODESIGN_BIN="$CODESIGN_BIN" "$PROJECT_ROOT/scripts/codesign-with-retry.sh" --force --sign "$SIGN_IDENTITY" \
    "${CODESIGN_KEYCHAIN_ARGS[@]}" \
    --options runtime \
    $TIMESTAMP_ARG \
    --identifier "boo.peekaboo.peekaboo" \
    "$FINAL_BINARY_PATH.tmp"
echo "✅ Signed with identity: $SIGN_IDENTITY"

# Verify the signature and embedded info
echo "🔍 Verifying code signature..."
"$CODESIGN_BIN" -dv "$FINAL_BINARY_PATH.tmp" 2>&1 | grep -E "Identifier=|Signature"

# Replace the old binary with the new one
mv "$FINAL_BINARY_PATH.tmp" "$FINAL_BINARY_PATH"

echo "📚 Packaging Swift back-deployment libraries..."
"$PROJECT_ROOT/scripts/copy-swift-runtime-libraries.sh" "$FINAL_BINARY_PATH" "$PROJECT_ROOT"

echo "🗑️ Cleaning up temporary architecture-specific binaries..."
rm -f "$ARM64_BINARY_TEMP" "$X86_64_BINARY_TEMP"

echo "🔍 Verifying final universal binary..."
lipo -info "$FINAL_BINARY_PATH"
ls -lh "$FINAL_BINARY_PATH"

echo "🎉 Universal binary '$FINAL_BINARY_PATH' created and optimized successfully!" 
