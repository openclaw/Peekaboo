#!/bin/bash
set -e

# Script to manually update the Homebrew formula with new version and SHA256

BLUE='\033[0;34m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FORMULA_PATH="$PROJECT_ROOT/homebrew/peekaboo.rb"

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <version> <sha256>"
    echo "Example: $0 2.0.1 abc123def456..."
    exit 1
fi

VERSION="$1"
SHA256="$2"

echo -e "${BLUE}Updating Homebrew formula...${NC}"
echo "Version: $VERSION"
echo "SHA256: $SHA256"

# Update the formula
sed -i.bak "s|url \".*\"|url \"https://github.com/openclaw/Peekaboo/releases/download/v${VERSION}/peekaboo-macos-universal.tar.gz\"|" "$FORMULA_PATH"
sed -i.bak "s|sha256 \".*\"|sha256 \"${SHA256}\"|" "$FORMULA_PATH"
sed -i.bak "s|version \".*\"|version \"${VERSION}\"|" "$FORMULA_PATH"

# Remove backup files
rm -f "$FORMULA_PATH.bak"

echo -e "${GREEN}✅ Formula updated!${NC}"
echo -e "${BLUE}Updated formula at: $FORMULA_PATH${NC}"

# Show the diff
echo -e "\n${BLUE}Changes:${NC}"
git diff "$FORMULA_PATH"

echo -e "\n${BLUE}Next steps:${NC}"
echo "1. Review the changes above"
echo "2. Commit: git add homebrew/peekaboo.rb && git commit -m \"Update Homebrew formula to v${VERSION}\""
echo "3. Push to openclaw/homebrew-tap"
