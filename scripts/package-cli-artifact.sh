#!/bin/bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <source-directory> <staging-directory> <release-directory> <version> <architecture>" >&2
    exit 2
fi

SOURCE_DIR="$1"
STAGING_DIR="$2"
RELEASE_DIR="$3"
VERSION="$4"
ARCHITECTURE="$5"
case "$ARCHITECTURE" in
    universal|arm64|x86_64) ;;
    *) echo "Unsupported CLI architecture: $ARCHITECTURE" >&2; exit 2 ;;
esac

ARTIFACT_NAME="peekaboo-macos-$ARCHITECTURE"
CLI_RELEASE_DIR="$STAGING_DIR/$ARTIFACT_NAME"
mkdir "$CLI_RELEASE_DIR"

for source_file in "$SOURCE_DIR/peekaboo" "$SOURCE_DIR"/libswiftCompatibility*.dylib; do
    [ -e "$source_file" ] || continue
    destination="$CLI_RELEASE_DIR/$(basename "$source_file")"
    if [ "$ARCHITECTURE" = universal ] || [ "$(lipo -archs "$source_file")" = "$ARCHITECTURE" ]; then
        cp "$source_file" "$destination"
    else
        # Slice removal preserves the existing per-architecture code signature.
        # Never rewrite the source: npm still packages the universal payload.
        lipo "$source_file" -thin "$ARCHITECTURE" -output "$destination"
        chmod "$(stat -f%Lp "$source_file")" "$destination"
    fi
done
[ -x "$CLI_RELEASE_DIR/peekaboo" ] || {
    echo "CLI missing or not executable: $SOURCE_DIR/peekaboo" >&2
    exit 1
}
cp "$SOURCE_DIR/LICENSE" "$CLI_RELEASE_DIR/"
printf '%s\n' "$VERSION" > "$CLI_RELEASE_DIR/VERSION"

cat > "$CLI_RELEASE_DIR/README.md" << EOF
# Peekaboo CLI v${VERSION}

Lightning-fast macOS screenshots & AI vision analysis.

Architecture: ${ARCHITECTURE}. Choose arm64 for Apple silicon, x86_64 for Intel, or universal for both.

## Installation

\`\`\`bash
# Make binary executable
chmod +x peekaboo

# Install the CLI and its required runtime libraries together
install_dir=/usr/local/bin
sudo mkdir -p "\$install_dir"
sudo install -m 755 peekaboo "\$install_dir/"
for library in libswiftCompatibility*.dylib; do
    [ -f "\$library" ] || continue
    sudo install -m 755 "\$library" "\$install_dir/"
done

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

tar -czf "$RELEASE_DIR/$ARTIFACT_NAME.tar.gz" -C "$STAGING_DIR" "$ARTIFACT_NAME"
