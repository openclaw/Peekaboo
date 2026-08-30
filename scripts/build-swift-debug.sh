#!/bin/bash
set -e
set -o pipefail

PROJECT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SWIFT_PROJECT_PATH="$PROJECT_ROOT/Apps/CLI"
# shellcheck source=scripts/source-provenance.sh
source "$PROJECT_ROOT/scripts/source-provenance.sh"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
CODESIGN_TIMESTAMP="${CODESIGN_TIMESTAMP:-auto}"
CODESIGN_TIMESTAMP_URL="${CODESIGN_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"

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

    export PEEKABOO_CLI_INFO_PLIST_PATH="$output"
}

# Parse arguments
CLEAN_BUILD=false
if [[ "$1" == "--clean" ]]; then
    CLEAN_BUILD=true
fi

# Only clean if requested
python3 "$PROJECT_ROOT/scripts/setup-swift-workspace.py" setup
if [[ "$CLEAN_BUILD" == "true" ]]; then
    echo "🧹 Cleaning previous build artifacts..."
    rm -rf "$SWIFT_PROJECT_PATH/.build"
    (cd "$SWIFT_PROJECT_PATH" && swift package reset 2>/dev/null || true)
fi

echo "📦 Reading version from version.json..."
VERSION=$(node -p "require('$PROJECT_ROOT/version.json').version" 2>/dev/null || echo "3.0.0-dev")

# Get git information. Keep the historical short value for human display while
# certification consumes the separate immutable full source commit.
SOURCE_COMMIT=$(peekaboo_debug_source_commit "$PROJECT_ROOT")
HUMAN_SOURCE_COMMIT=$(peekaboo_source_commit_from_repo "$PROJECT_ROOT")
GIT_COMMIT_SHORT=$(peekaboo_short_source_commit "$HUMAN_SOURCE_COMMIT")
GIT_COMMIT_DATE=$(git show -s --format=%ci HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_DIRTY=$(peekaboo_source_dirty_suffix "$PROJECT_ROOT")
BUILD_DATE=$(date -Iseconds)

echo "🧾 Embedding version metadata in Info.plist..."
generate_info_plist

if [[ "$CLEAN_BUILD" == "true" ]]; then
    echo "🏗️ Building for debug (clean build)..."
else
    echo "🏗️ Building for debug (incremental)..."
fi

(
    cd "$SWIFT_PROJECT_PATH"
    python3 "$PROJECT_ROOT/scripts/setup-swift-workspace.py" run -- swift build 2>&1 | pipe_build_output
)
if peekaboo_is_exact_source_commit "$SOURCE_COMMIT"; then
    peekaboo_verify_source_commit "$PROJECT_ROOT" "$SOURCE_COMMIT"
fi

echo "🔏 Code signing the debug binary..."
PROJECT_NAME="peekaboo"
DEBUG_BINARY_PATH="$SWIFT_PROJECT_PATH/.build/debug/$PROJECT_NAME"
ENTITLEMENTS_PATH="$SWIFT_PROJECT_PATH/Sources/Resources/peekaboo.entitlements"

resolve_signing_identity
resolve_timestamp_arg
if [[ -f "$ENTITLEMENTS_PATH" ]]; then
    "$PROJECT_ROOT/scripts/codesign-with-retry.sh" --force --sign "$SIGN_IDENTITY" \
        --options runtime \
        $TIMESTAMP_ARG \
        --identifier "boo.peekaboo" \
        --entitlements "$ENTITLEMENTS_PATH" \
        "$DEBUG_BINARY_PATH"
    echo "✅ Debug binary signed with entitlements"
else
    echo "⚠️  Entitlements file not found, signing without entitlements"
    "$PROJECT_ROOT/scripts/codesign-with-retry.sh" --force --sign "$SIGN_IDENTITY" \
        --options runtime \
        $TIMESTAMP_ARG \
        --identifier "boo.peekaboo" \
        "$DEBUG_BINARY_PATH"
fi

echo "📦 Copying binary to project root..."
cp "$DEBUG_BINARY_PATH" "$PROJECT_ROOT/peekaboo"
echo "✅ Debug build complete"
