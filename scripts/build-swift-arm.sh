#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.
set -o pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SWIFT_PROJECT_PATH="$PROJECT_ROOT/Apps/CLI"
FINAL_BINARY_NAME="peekaboo"
FINAL_BINARY_PATH="$PROJECT_ROOT/$FINAL_BINARY_NAME"
SIGN_IDENTITY="${MAC_RELEASE_CODESIGN_IDENTITY:-${SIGN_IDENTITY:-}}"
CODESIGN_BIN="${MAC_RELEASE_CODESIGN_BIN:-codesign}"
CODESIGN_TIMESTAMP="${CODESIGN_TIMESTAMP:-auto}"

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
            TIMESTAMP_ARG="--timestamp"
            ;;
        0|off|no|false)
            TIMESTAMP_ARG="--timestamp=none"
            ;;
        auto)
            if [[ "$SIGN_IDENTITY" == *"Developer ID Application"* ]]; then
                TIMESTAMP_ARG="--timestamp"
            fi
            ;;
        *)
            echo "ERROR: Unknown CODESIGN_TIMESTAMP value: $CODESIGN_TIMESTAMP (use auto|on|off)" >&2
            exit 1
            ;;
    esac
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
    set_plist_value "$output" "PeekabooGitCommit" "$GIT_COMMIT$GIT_DIRTY"
    set_plist_value "$output" "PeekabooGitCommitDate" "$GIT_COMMIT_DATE"
    set_plist_value "$output" "PeekabooGitBranch" "$GIT_BRANCH"
    set_plist_value "$output" "PeekabooBuildDate" "$BUILD_DATE"

    export PEEKABOO_CLI_INFO_PLIST_PATH="$output"
}

# Swift compiler flags for size optimization.
# Keep WMO off by default; Swift 6.3.2 can hang or crash the release build here.
# Override SWIFT_OPTIMIZATION_FLAGS when explicitly testing a different compiler.
SWIFT_OPTIMIZATION_FLAGS="${SWIFT_OPTIMIZATION_FLAGS:--Xswiftc -Osize -Xlinker -dead_strip}"

echo "🧹 Cleaning previous build artifacts..."
(cd "$SWIFT_PROJECT_PATH" && swift package reset) || echo "'swift package reset' encountered an issue, attempting rm -rf..."
rm -rf "$SWIFT_PROJECT_PATH/.build"
rm -f "$FINAL_BINARY_PATH.tmp"

echo "📦 Reading version from version.json..."
VERSION=$(node -p "require('$PROJECT_ROOT/version.json').version")
echo "Version: $VERSION"

# Get git information
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_DATE=$(git show -s --format=%ci HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_DIRTY=$(git diff --quiet && git diff --cached --quiet || echo "-dirty")
BUILD_DATE=$(date -Iseconds)

echo "🧾 Embedding version metadata in Info.plist..."
generate_info_plist

echo "🏗️ Building for arm64 (Apple Silicon) only..."
(
    cd "$SWIFT_PROJECT_PATH"
    swift build --arch arm64 -c release $SWIFT_OPTIMIZATION_FLAGS 2>&1 | pipe_build_output
)
ARM64_BUILD_BINARY=$(bash "$PROJECT_ROOT/scripts/resolve-swift-binary-path.sh" \
    "$SWIFT_PROJECT_PATH" arm64 release "$FINAL_BINARY_NAME")
cp "$ARM64_BUILD_BINARY" "$FINAL_BINARY_PATH.tmp"
echo "✅ arm64 build complete"

echo "🤏 Stripping symbols for further size reduction..."
# -S: Remove debugging symbols
# -x: Remove non-global symbols
# -u: Save symbols of undefined references
# Note: LC_UUID is preserved by not using -no_uuid during linking
strip -Sxu "$FINAL_BINARY_PATH.tmp"

echo "🔏 Code signing the binary..."
ENTITLEMENTS_PATH="$SWIFT_PROJECT_PATH/Sources/Resources/peekaboo.entitlements"
resolve_signing_identity
resolve_timestamp_arg
"$CODESIGN_BIN" --force --sign "$SIGN_IDENTITY" \
    --options runtime \
    $TIMESTAMP_ARG \
    --identifier "boo.peekaboo.peekaboo" \
    --entitlements "$ENTITLEMENTS_PATH" \
    "$FINAL_BINARY_PATH.tmp"
echo "✅ Signed with identity: $SIGN_IDENTITY"

# Verify the signature and embedded info
echo "🔍 Verifying code signature..."
"$CODESIGN_BIN" -dv "$FINAL_BINARY_PATH.tmp" 2>&1 | grep -E "Identifier=|Signature"

# Replace the old binary with the new one
mv "$FINAL_BINARY_PATH.tmp" "$FINAL_BINARY_PATH"

echo "🔍 Verifying final binary..."
lipo -info "$FINAL_BINARY_PATH"
ls -lh "$FINAL_BINARY_PATH"

echo "🎉 ARM64 binary '$FINAL_BINARY_PATH' created and optimized successfully!"
