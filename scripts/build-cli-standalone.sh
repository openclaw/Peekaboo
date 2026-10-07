#!/bin/bash

# Build the Peekaboo Swift CLI as a standalone binary
# This script builds the CLI independently of the Node.js MCP server

set -e
set -o pipefail

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

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Building Peekaboo Swift CLI...${NC}"

# Change to the CLI directory
cd "$(dirname "$0")/../Apps/CLI"

# Build for release with optimizations
echo -e "${BLUE}Building release version...${NC}"
python3 ../../scripts/setup-swift-workspace.py run -- swift build -c release 2>&1 | pipe_build_output

# Get the build output path
BUILD_PATH=".build/release/peekaboo"

if [ -f "$BUILD_PATH" ]; then
    echo -e "${GREEN}✅ Build successful!${NC}"
    echo -e "${BLUE}Binary location: $(pwd)/$BUILD_PATH${NC}"
    
    # Collect the exact compatibility libraries required by this standalone binary.
    ../../scripts/copy-swift-runtime-libraries.sh --standalone "$BUILD_PATH" "$(dirname "$BUILD_PATH")"

    # Show binary info
    echo -e "\n${BLUE}Binary info:${NC}"
    file "$BUILD_PATH"
    echo "Size: $(du -h "$BUILD_PATH" | cut -f1)"
    
    # Optionally copy to a more convenient location
    if [ "$1" == "--install" ]; then
        echo -e "\n${BLUE}Installing to /usr/local/bin...${NC}"
        sudo install -m 755 "$BUILD_PATH" /usr/local/bin/peekaboo
        for library in "$(dirname "$BUILD_PATH")"/libswiftCompatibility*.dylib; do
            [ -f "$library" ] || continue
            sudo install -m 755 "$library" /usr/local/bin/
        done
        echo -e "${GREEN}✅ Installed to /usr/local/bin/peekaboo${NC}"
    else
        echo -e "\n${BLUE}To install system-wide, run:${NC}"
        echo "  $0 --install"
        echo "Keep the binary and its compatibility libraries together when copying manually."
    fi
    
    echo -e "\n${BLUE}To see usage:${NC}"
    echo "  $BUILD_PATH --help"
else
    echo -e "${RED}❌ Build failed!${NC}"
    exit 1
fi
