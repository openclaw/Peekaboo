#!/bin/bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <package-path> <architecture> <configuration> <binary-name>" >&2
    exit 2
fi

PACKAGE_PATH="$1"
ARCHITECTURE="$2"
CONFIGURATION="$3"
BINARY_NAME="$4"

BIN_DIRECTORY=$(
    cd "$PACKAGE_PATH"
    swift build --arch "$ARCHITECTURE" -c "$CONFIGURATION" --show-bin-path
)
BINARY_PATH="$BIN_DIRECTORY/$BINARY_NAME"

if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Swift build completed but $BINARY_NAME was not found at $BINARY_PATH" >&2
    exit 1
fi

printf '%s\n' "$BINARY_PATH"
