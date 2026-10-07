#!/bin/bash
set -euo pipefail

VERIFIER_ARGS=()
if [ "${1:-}" = --standalone ]; then
    VERIFIER_ARGS=(--standalone)
    shift
fi

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 [--standalone] <executable> <destination-directory>" >&2
    exit 2
fi

EXECUTABLE_PATH="$1"
DESTINATION_DIR="$2"
SIGN_IDENTITY="${MAC_RELEASE_CODESIGN_IDENTITY:-${SIGN_IDENTITY:-}}"
# An ambient SIGN_IDENTITY from the operator's login shell is a legitimate
# interface, but it must never substitute for a release identity unnoticed.
if [ -z "${MAC_RELEASE_CODESIGN_IDENTITY:-}" ] && [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "copy-swift-runtime-libraries: using inherited SIGN_IDENTITY '$SIGN_IDENTITY'" >&2
fi
CODESIGN_BIN="${MAC_RELEASE_CODESIGN_BIN:-codesign}"
CODESIGN_TIMESTAMP="${CODESIGN_TIMESTAMP:-auto}"
CODESIGN_TIMESTAMP_URL="${CODESIGN_TIMESTAMP_URL:-http://timestamp.apple.com/ts01}"
CODESIGN_KEYCHAIN="${MAC_RELEASE_CODESIGN_KEYCHAIN:-${CODESIGN_KEYCHAIN:-}}"

[ -x "$EXECUTABLE_PATH" ] || {
    echo "Executable missing or not executable: $EXECUTABLE_PATH" >&2
    exit 1
}
command -v xcrun >/dev/null 2>&1 || {
    echo "xcrun is required to package Swift back-deployment libraries" >&2
    exit 1
}

mkdir -p "$DESTINATION_DIR"

# Remove compatibility libraries left by an earlier build before asking the
# active Swift toolchain for the exact set required by this executable.
for existing_library in "$DESTINATION_DIR"/libswiftCompatibility*.dylib; do
    [ -e "$existing_library" ] || continue
    rm -f -- "$existing_library"
done

xcrun swift-stdlib-tool \
    --copy \
    --scan-executable "$EXECUTABLE_PATH" \
    --platform macosx \
    --destination "$DESTINATION_DIR"

if [ -n "$SIGN_IDENTITY" ]; then
    TIMESTAMP_ARG="--timestamp=none"
    case "$CODESIGN_TIMESTAMP" in
        1|on|yes|true)
            TIMESTAMP_ARG="--timestamp=$CODESIGN_TIMESTAMP_URL"
            ;;
        0|off|no|false)
            ;;
        auto)
            if [[ "$SIGN_IDENTITY" == *"Developer ID Application"* ]]; then
                TIMESTAMP_ARG="--timestamp=$CODESIGN_TIMESTAMP_URL"
            fi
            ;;
        *)
            echo "Unknown CODESIGN_TIMESTAMP value: $CODESIGN_TIMESTAMP" >&2
            exit 1
            ;;
    esac

    for runtime_library in "$DESTINATION_DIR"/libswiftCompatibility*.dylib; do
        [ -e "$runtime_library" ] || continue
        if [ -n "$CODESIGN_KEYCHAIN" ]; then
            MAC_RELEASE_CODESIGN_BIN="$CODESIGN_BIN" "$(dirname "$0")/codesign-with-retry.sh" --force --sign "$SIGN_IDENTITY" \
                --keychain "$CODESIGN_KEYCHAIN" \
                --options runtime \
                $TIMESTAMP_ARG \
                "$runtime_library"
        else
            MAC_RELEASE_CODESIGN_BIN="$CODESIGN_BIN" "$(dirname "$0")/codesign-with-retry.sh" --force --sign "$SIGN_IDENTITY" \
                --options runtime \
                $TIMESTAMP_ARG \
                "$runtime_library"
        fi
    done
fi

"$(dirname "$0")/verify-swift-runtime-libraries.sh" ${VERIFIER_ARGS[@]+"${VERIFIER_ARGS[@]}"} "$EXECUTABLE_PATH" "$DESTINATION_DIR"
