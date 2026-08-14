#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-dmg-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

FAKE_BIN="$TEST_DIR/bin"
COUNTER_FILE="$TEST_DIR/detach-count"
UV_ARGS_FILE="$TEST_DIR/uv-args"
DMG_PATH="$TEST_DIR/Peekaboo-3.9.5.dmg"
BUILT_DMG_PATH="$TEST_DIR/Peekaboo-3.9.5-built.dmg"
APP_ZIP="$TEST_DIR/Peekaboo-3.9.5.app.zip"
BACKGROUND="$TEST_DIR/dmg-background.png"
mkdir -p "$FAKE_BIN"
touch "$DMG_PATH" "$APP_ZIP" "$BACKGROUND"

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
    mkdir -p "$mount_dir/Peekaboo.app/Contents/MacOS"
    plutil -create xml1 "$mount_dir/Peekaboo.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string 3.9.5 \
      "$mount_dir/Peekaboo.app/Contents/Info.plist"
    touch "$mount_dir/Peekaboo.app/Contents/MacOS/Peekaboo"
    chmod 755 "$mount_dir/Peekaboo.app/Contents/MacOS/Peekaboo"
    ln -s /Applications "$mount_dir/Applications"
    touch \
      "$mount_dir/.background.png" \
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

cat >"$FAKE_BIN/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

destination=""
for argument in "$@"; do
  destination="$argument"
done
[[ -n "$destination" ]]
mkdir -p "$destination/Peekaboo.app/Contents/MacOS" "$destination/Peekaboo.app/Contents/Resources"
plutil -create xml1 "$destination/Peekaboo.app/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 3.9.5 \
  "$destination/Peekaboo.app/Contents/Info.plist"
touch \
  "$destination/Peekaboo.app/Contents/MacOS/Peekaboo" \
  "$destination/Peekaboo.app/Contents/Resources/AppIcon.icns"
chmod 755 "$destination/Peekaboo.app/Contents/MacOS/Peekaboo"
EOF

cat >"$FAKE_BIN/sips" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$*" in
  *pixelWidth*) printf '  pixelWidth: 720\n' ;;
  *pixelHeight*) printf '  pixelHeight: 460\n' ;;
  *) exit 1 ;;
esac
EOF

cat >"$FAKE_BIN/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

for secret_name in \
  APP_STORE_CONNECT_API_KEY_P8 \
  APP_STORE_CONNECT_KEY_ID \
  APP_STORE_CONNECT_ISSUER_ID \
  NPM_TOKEN \
  OP_SERVICE_ACCOUNT_TOKEN \
  MOLTY_OP_SERVICE_ACCOUNT_TOKEN; do
  [[ -z "${!secret_name+x}" ]] || exit 89
done

[[ "$1" == "--no-config" ]]
[[ "$2" == "run" ]]
[[ "$3" == "--locked" ]]
[[ "$4" == */scripts/dmgbuild-runner.py ]]
printf '%s\n' "$@" >"$PEEKABOO_TEST_UV_ARGS"
output=""
for argument in "$@"; do
  output="$argument"
done
[[ "$output" == *.dmg ]]
touch "$output"
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

PEEKABOO_TEST_DETACH_COUNTER="$COUNTER_FILE" \
PEEKABOO_TEST_UV_ARGS="$UV_ARGS_FILE" \
APP_STORE_CONNECT_API_KEY_P8=fixture-p8 \
APP_STORE_CONNECT_KEY_ID=fixture-key-id \
APP_STORE_CONNECT_ISSUER_ID=fixture-issuer \
NPM_TOKEN=fixture-npm-token \
OP_SERVICE_ACCOUNT_TOKEN=fixture-op-token \
MOLTY_OP_SERVICE_ACCOUNT_TOKEN=fixture-old-op-token \
  PATH="$FAKE_BIN:$PATH" \
  "$ROOT_DIR/scripts/create-release-dmg.sh" \
  --version 3.9.5 \
  --app-zip "$APP_ZIP" \
  --output "$BUILT_DMG_PATH" \
  --background "$BACKGROUND" \
  --no-notarize >/dev/null

[[ -f "$BUILT_DMG_PATH" ]]
rg -Fxq -- '--no-hidpi' "$UV_ARGS_FILE"
rg -Fxq -- '--detach-retries' "$UV_ARGS_FILE"
rg -Fxq -- 'app_name=Peekaboo' "$UV_ARGS_FILE"
rg -q '^app_path=/tmp/peekaboo-dmg\.[^/]+/source/Peekaboo\.app$' "$UV_ARGS_FILE"
rg -Fxq -- "background=$BACKGROUND" "$UV_ARGS_FILE"
rg -Fq -- 'volume_icon=' "$UV_ARGS_FILE"
rg -Fxq -- 'Peekaboo 3.9.5' "$UV_ARGS_FILE"
rg -Fxq -- "$BUILT_DMG_PATH" "$UV_ARGS_FILE"

python3 - "$ROOT_DIR/scripts/dmgbuild-settings.py" <<'PY'
import runpy
import sys

settings = runpy.run_path(
    sys.argv[1],
    init_globals={
        "defines": {
            "app_name": "Peekaboo",
            "app_path": "/tmp/Peekaboo.app",
            "background": "/tmp/background.png",
            "volume_icon": "/tmp/AppIcon.icns",
        }
    },
)

assert settings["files"] == [("/tmp/Peekaboo.app", "Peekaboo.app")]
assert settings["symlinks"] == {"Applications": "/Applications"}
assert settings["icon"] == "/tmp/AppIcon.icns"
assert settings["background"] == "/tmp/background.png"
assert settings["window_rect"] == ((200, 120), (720, 460))
assert settings["text_size"] == 13
assert settings["icon_size"] == 128
assert settings["icon_locations"] == {
    "Peekaboo.app": (180, 230),
    "Applications": (540, 230),
}
assert settings["hide_extensions"] == ["Peekaboo.app"]
assert settings["format"] == "UDZO"
assert settings["filesystem"] == "HFS+"
PY

rg -Fq '"dmgbuild==1.6.7"' "$ROOT_DIR/scripts/dmgbuild-runner.py"
rg -Fq '"ds-store==1.3.3"' "$ROOT_DIR/scripts/dmgbuild-runner.py"
rg -Fq '"mac-alias==2.2.3"' "$ROOT_DIR/scripts/dmgbuild-runner.py"
rg -Fq 'uv --no-config run --locked "$DMGBUILD_RUNNER"' "$ROOT_DIR/scripts/create-release-dmg.sh"
[[ -f "$ROOT_DIR/scripts/dmgbuild-runner.py.lock" ]]

printf 'test-create-release-dmg: ok\n'
