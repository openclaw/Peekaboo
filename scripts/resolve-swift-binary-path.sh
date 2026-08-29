#!/bin/bash

# Shared by the universal build and its architecture-based binary lookups.
SWIFT_X86_64_TARGET_ARGS=(--triple x86_64-apple-macosx15.0)
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <package-path> <architecture> <configuration> <binary-name>" >&2
    exit 2
fi

PACKAGE_PATH="$1"
ARCHITECTURE="$2"
CONFIGURATION="$3"
BINARY_NAME="$4"
TARGET_ARGS=(--arch "$ARCHITECTURE")
if [[ "$ARCHITECTURE" == x86_64 ]]; then
    TARGET_ARGS=("${SWIFT_X86_64_TARGET_ARGS[@]}")
fi

BIN_DIRECTORY=$(
    cd "$PACKAGE_PATH"
    swift build "${TARGET_ARGS[@]}" -c "$CONFIGURATION" --show-bin-path
)
BINARY_PATH="$BIN_DIRECTORY/$BINARY_NAME"

if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Swift build completed but $BINARY_NAME was not found at $BINARY_PATH" >&2
    exit 1
fi

printf '%s\n' "$BINARY_PATH"
