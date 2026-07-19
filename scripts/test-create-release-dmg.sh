#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-dmg-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
COUNTER_FILE="$TEST_DIR/detach-count"
DMG_PATH="$TEST_DIR/Peekaboo-3.9.5.dmg"
BACKGROUND="$TEST_DIR/dmg-background.png"
mkdir -p "$FAKE_BIN"
touch "$DMG_PATH" "$BACKGROUND"

cat >"$FAKE_BIN/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-dv" ]]; then
  printf '%s\n' \
    'Authority=Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)' \
    'TeamIdentifier=FWJYW4S8P8' >&2
fi
EOF

cat >"$FAKE_BIN/hdiutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  verify)
    exit 0
    ;;
  attach)
    shift
    mount_dir=""
    while (($# > 0)); do
      if [[ "$1" == "-mountpoint" ]]; then
        mount_dir="$2"
        break
      fi
      shift
    done
    [[ -n "$mount_dir" ]]
    mkdir -p "$mount_dir/Peekaboo.app/Contents/MacOS" "$mount_dir/.background"
    plutil -create xml1 "$mount_dir/Peekaboo.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 3.9.5 \
      "$mount_dir/Peekaboo.app/Contents/Info.plist"
    touch "$mount_dir/Peekaboo.app/Contents/MacOS/Peekaboo"
    chmod +x "$mount_dir/Peekaboo.app/Contents/MacOS/Peekaboo"
    ln -s /Applications "$mount_dir/Applications"
    touch \
      "$mount_dir/.background/dmg-background.png" \
      "$mount_dir/.DS_Store" \
      "$mount_dir/.VolumeIcon.icns"
    ;;
  detach)
    mount_dir="$2"
    count=0
    [[ ! -f "$PEEKABOO_TEST_DETACH_COUNTER" ]] || count="$(<"$PEEKABOO_TEST_DETACH_COUNTER")"
    count=$((count + 1))
    printf '%s\n' "$count" >"$PEEKABOO_TEST_DETACH_COUNTER"
    if ((count < 3)); then
      exit 16
    fi
    find "$mount_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    ;;
  *)
    printf 'Unexpected hdiutil arguments: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF

cat >"$FAKE_BIN/file" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-b" && "${2:-}" == */Contents/MacOS/Peekaboo ]]; then
  printf 'Mach-O 64-bit executable\n'
else
  /usr/bin/file "$@"
fi
EOF

cat >"$FAKE_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FAKE_BIN/spctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

cat >"$FAKE_BIN/xcrun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

chmod +x "$FAKE_BIN"/*

PEEKABOO_TEST_DETACH_COUNTER="$COUNTER_FILE" \
  PATH="$FAKE_BIN:$PATH" \
  "$ROOT_DIR/scripts/create-release-dmg.sh" \
  --version 3.9.5 \
  --background "$BACKGROUND" \
  --no-notarize \
  --verify-only "$DMG_PATH" >/dev/null

[[ "$(<"$COUNTER_FILE")" == "3" ]] || {
  printf 'Expected detach to succeed on attempt 3\n' >&2
  exit 1
}

printf 'test-create-release-dmg: ok\n'
