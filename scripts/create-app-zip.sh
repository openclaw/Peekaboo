#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: scripts/create-app-zip.sh APP ZIP\n' >&2
  exit 1
fi

# Omit filesystem metadata/AppleDouble without altering the signed, stapled source tree.
[[ ! -d "$2" ]] || { printf 'ZIP destination is a directory: %s\n' "$2" >&2; exit 1; }
# The temporary directory shares the destination filesystem, so the final move is atomic.
ZIP_TEMP_DIR="$(mktemp -d "$(dirname "$2")/.peekaboo-app-zip.XXXXXX")"
trap 'rm -rf "$ZIP_TEMP_DIR"' EXIT
ZIP_TEMP="$ZIP_TEMP_DIR/archive.zip"
/usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$1" "$ZIP_TEMP"
mv -f "$ZIP_TEMP" "$2"
