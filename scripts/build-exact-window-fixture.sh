#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_APP="${1:?Usage: build-exact-window-fixture.sh /absolute/new/ExactWindowCapture.app}"
[[ "$OUTPUT_APP" == /* && ! -e "$OUTPUT_APP" && ! -L "$OUTPUT_APP" ]] || {
  echo 'Output must be a new absolute app path.' >&2
  exit 2
}
mkdir -p "$OUTPUT_APP/Contents/MacOS"
cat > "$OUTPUT_APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>boo.peekaboo.fixture.exact-window</string>
  <key>CFBundleName</key><string>ExactWindowCapture</string>
  <key>CFBundleExecutable</key><string>ExactWindowCapture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF
xcrun swiftc -parse-as-library -swift-version 6 -target "$(uname -m)-apple-macos15.0" \
  "$ROOT_DIR/Apps/CLI/TestFixtures/ExactWindowCapture/main.swift" \
  -o "$OUTPUT_APP/Contents/MacOS/ExactWindowCapture"
printf 'Built only; sign with the approved Developer ID before launch: %s\n' "$OUTPUT_APP"
