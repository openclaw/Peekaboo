#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(node -p "require('$ROOT_DIR/package.json').version")
ARTIFACT_DIR=$(mktemp -d /tmp/peekaboo-extracted-artifact.XXXXXX)
trap 'rm -rf "$ARTIFACT_DIR"' EXIT

if [ "${PEEKABOO_BUILD_ARTIFACT:-true}" = true ]; then
    SIGN_IDENTITY=- CODESIGN_TIMESTAMP=off "$ROOT_DIR/scripts/build-swift-universal.sh"
fi

RELEASE_DIR="$ARTIFACT_DIR/peekaboo-macos-universal"
EXTRACT_DIR="$ARTIFACT_DIR/extracted"
mkdir -p "$RELEASE_DIR" "$EXTRACT_DIR"

cp "$ROOT_DIR/peekaboo" "$RELEASE_DIR/"
for runtime_library in "$ROOT_DIR"/libswiftCompatibility*.dylib; do
    [ -e "$runtime_library" ] || continue
    cp "$runtime_library" "$RELEASE_DIR/"
done
cp "$ROOT_DIR/LICENSE" "$ROOT_DIR/README.md" "$RELEASE_DIR/"
printf '%s\n' "$VERSION" > "$RELEASE_DIR/VERSION"

ARCHIVE_PATH="$ARTIFACT_DIR/peekaboo-macos-universal.tar.gz"
tar -czf "$ARCHIVE_PATH" -C "$ARTIFACT_DIR" peekaboo-macos-universal
tar -xzf "$ARCHIVE_PATH" -C "$EXTRACT_DIR"

EXTRACTED_DIR="$EXTRACT_DIR/peekaboo-macos-universal"
"$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" "$EXTRACTED_DIR/peekaboo" "$EXTRACTED_DIR"
VERSION_OUTPUT_1=$("$EXTRACTED_DIR/peekaboo" --version)
sleep 1
VERSION_OUTPUT_2=$("$EXTRACTED_DIR/peekaboo" --version)
[ "$VERSION_OUTPUT_1" = "$VERSION_OUTPUT_2" ] || {
    echo "Extracted CLI version output changed between invocations" >&2
    exit 1
}
printf '%s\n' "$VERSION_OUTPUT_1" | grep -Fq "Peekaboo $VERSION"
if printf '%s\n' "$VERSION_OUTPUT_1" | grep -Fq "unknown"; then
    echo "Extracted release CLI is missing embedded build metadata" >&2
    exit 1
fi

echo "test-extracted-cli-artifact: ok"
