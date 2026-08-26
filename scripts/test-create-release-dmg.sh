#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-dmg-test.XXXXXX)"
FIXTURE_MOUNT=""

cleanup() {
  if [[ -n "$FIXTURE_MOUNT" && -d "$FIXTURE_MOUNT" ]]; then
    hdiutil detach "$FIXTURE_MOUNT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

FAKE_BIN="$TEST_DIR/bin"
COUNTER_FILE="$TEST_DIR/detach-count"
UV_ARGS_FILE="$TEST_DIR/uv-args"
DMG_PATH="$TEST_DIR/Peekaboo-3.9.5.dmg"
BUILT_DMG_PATH="$TEST_DIR/Peekaboo-3.9.5-built.dmg"
BAD_DMG_PATH="$TEST_DIR/Peekaboo-3.9.5-bad-xattrs.dmg"
BAD_DMG_OUTPUT="$TEST_DIR/bad-xattrs-output"
APP_ZIP="$TEST_DIR/Peekaboo-3.9.5.app.zip"
BACKGROUND="$TEST_DIR/dmg-background.png"
mkdir -p "$FAKE_BIN"
touch "$DMG_PATH" "$BAD_DMG_PATH" "$APP_ZIP" "$BACKGROUND"
APP_TEMPLATE="$TEST_DIR/app-template/Peekaboo.app"
mkdir -p "$APP_TEMPLATE/Contents/MacOS" "$APP_TEMPLATE/Contents/Resources"
plutil -create xml1 "$APP_TEMPLATE/Contents/Info.plist"
plutil -insert CFBundleShortVersionString -string 3.9.5 "$APP_TEMPLATE/Contents/Info.plist"
touch "$APP_TEMPLATE/Contents/MacOS/Peekaboo" "$APP_TEMPLATE/Contents/Resources/AppIcon.icns"
chmod 755 "$APP_TEMPLATE/Contents/MacOS/Peekaboo"
APP_TREE_MANIFEST="$TEST_DIR/app-tree.json"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$APP_TEMPLATE" > "$APP_TREE_MANIFEST"
APP_TREE_SHA256="$(shasum -a 256 "$APP_TREE_MANIFEST" | awk '{print $1}')"

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
    cp -R "${PEEKABOO_TEST_APP_TEMPLATE:?}" "$mount_dir/Peekaboo.app"
    if [[ "${PEEKABOO_TEST_ATTACH_FINDERINFO:-}" == "1" ]]; then
      /usr/bin/SetFile -a E "$mount_dir/Peekaboo.app"
    fi
    ln -s /Applications "$mount_dir/Applications"
    touch \
      "$mount_dir/.background.png" \
      "$mount_dir/.DS_Store" \
      "$mount_dir/.VolumeIcon.icns"
    ;;
  detach)
    mount_dir="$2"
    if [[ "${PEEKABOO_TEST_DETACH_IMMEDIATE:-}" == "1" ]]; then
      find "$mount_dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
      rmdir "$mount_dir"
      exit 0
    fi
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
mkdir -p "$destination"
cp -R "${PEEKABOO_TEST_APP_TEMPLATE:?}" "$destination/Peekaboo.app"
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
PEEKABOO_TEST_APP_TEMPLATE="$APP_TEMPLATE" \
  PATH="$FAKE_BIN:$PATH" \
  "$ROOT_DIR/scripts/create-release-dmg.sh" \
  --version 3.9.5 \
  --background "$BACKGROUND" \
  --no-notarize \
  --expected-app-tree-sha256 "$APP_TREE_SHA256" \
  --verify-only "$DMG_PATH" >/dev/null

[[ "$(<"$COUNTER_FILE")" == "3" ]] || {
  printf 'Expected detach to succeed on attempt 3\n' >&2
  exit 1
}

MUTATED_TEMPLATE="$TEST_DIR/mutated-template/Peekaboo.app"
mkdir -p "$(dirname "$MUTATED_TEMPLATE")"
cp -R "$APP_TEMPLATE" "$MUTATED_TEMPLATE"
printf 'changed nested bytes\n' >> "$MUTATED_TEMPLATE/Contents/MacOS/Peekaboo"
if PEEKABOO_TEST_DETACH_IMMEDIATE=1 \
  PEEKABOO_TEST_APP_TEMPLATE="$MUTATED_TEMPLATE" \
  PATH="$FAKE_BIN:$PATH" \
  "$ROOT_DIR/scripts/create-release-dmg.sh" \
  --version 3.9.5 --background "$BACKGROUND" --no-notarize \
  --expected-app-tree-sha256 "$APP_TREE_SHA256" \
  --verify-only "$DMG_PATH" >"$TEST_DIR/tree-mismatch.out" 2>&1; then
  printf 'Expected DMG app tree mismatch to fail\n' >&2
  exit 1
fi
rg -Fq 'DMG embedded app tree differs from the source app zip' "$TEST_DIR/tree-mismatch.out"

if PEEKABOO_TEST_ATTACH_FINDERINFO=1 \
  PEEKABOO_TEST_DETACH_IMMEDIATE=1 \
  PEEKABOO_TEST_APP_TEMPLATE="$APP_TEMPLATE" \
  PATH="$FAKE_BIN:$PATH" \
  "$ROOT_DIR/scripts/create-release-dmg.sh" \
  --version 3.9.5 \
  --background "$BACKGROUND" \
  --no-notarize \
  --expected-app-tree-sha256 "$APP_TREE_SHA256" \
  --verify-only "$BAD_DMG_PATH" >"$BAD_DMG_OUTPUT" 2>&1; then
  printf 'Expected FinderInfo-contaminated app verification to fail\n' >&2
  exit 1
fi
rg -Fq 'Disallowed code xattrs found' "$BAD_DMG_OUTPUT"
rg -Fq 'com.apple.FinderInfo' "$BAD_DMG_OUTPUT"

PEEKABOO_TEST_DETACH_COUNTER="$COUNTER_FILE" \
PEEKABOO_TEST_UV_ARGS="$UV_ARGS_FILE" \
PEEKABOO_TEST_APP_TEMPLATE="$APP_TEMPLATE" \
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
assert settings.get("hide_extensions", []) == []
assert settings["format"] == "UDZO"
assert settings["filesystem"] == "HFS+"
PY

rg -Fq '"dmgbuild==1.6.7"' "$ROOT_DIR/scripts/dmgbuild-runner.py"
rg -Fq '"ds-store==1.3.3"' "$ROOT_DIR/scripts/dmgbuild-runner.py"
rg -Fq '"mac-alias==2.2.3"' "$ROOT_DIR/scripts/dmgbuild-runner.py"
rg -Fq 'uv --no-config run --locked "$DMGBUILD_RUNNER"' "$ROOT_DIR/scripts/create-release-dmg.sh"
[[ -f "$ROOT_DIR/scripts/dmgbuild-runner.py.lock" ]]

FIXTURE_DIR="$TEST_DIR/fixture"
FIXTURE_DMG="$TEST_DIR/Peekaboo-Fixture.dmg"
FIXTURE_MOUNT="$TEST_DIR/fixture-mount"
mkdir -p "$FIXTURE_DIR/Peekaboo.app/Contents/MacOS" "$FIXTURE_MOUNT"
printf 'fixture\n' >"$FIXTURE_DIR/Peekaboo.app/Contents/MacOS/Peekaboo"
chmod 755 "$FIXTURE_DIR/Peekaboo.app/Contents/MacOS/Peekaboo"

env \
  -u APP_STORE_CONNECT_API_KEY_P8 \
  -u APP_STORE_CONNECT_KEY_ID \
  -u APP_STORE_CONNECT_ISSUER_ID \
  -u NPM_TOKEN \
  -u OP_SERVICE_ACCOUNT_TOKEN \
  -u MOLTY_OP_SERVICE_ACCOUNT_TOKEN \
  uv --no-config run --locked "$ROOT_DIR/scripts/dmgbuild-runner.py" \
  --no-hidpi \
  --detach-retries 5 \
  --settings "$ROOT_DIR/scripts/dmgbuild-settings.py" \
  -D 'app_name=Peekaboo' \
  -D "app_path=$FIXTURE_DIR/Peekaboo.app" \
  -D "background=$ROOT_DIR/assets/dmg-background.png" \
  -D "volume_icon=$ROOT_DIR/assets/dmg-background.png" \
  'Peekaboo Fixture' \
  "$FIXTURE_DMG" >/dev/null

hdiutil attach -readonly -nobrowse -noautoopen \
  -mountpoint "$FIXTURE_MOUNT" "$FIXTURE_DMG" >/dev/null
[[ -L "$FIXTURE_MOUNT/Applications" ]]
[[ "$(readlink "$FIXTURE_MOUNT/Applications")" == "/Applications" ]]
cmp "$ROOT_DIR/assets/dmg-background.png" "$FIXTURE_MOUNT/.background.png"
[[ -f "$FIXTURE_MOUNT/.VolumeIcon.icns" ]]
[[ -f "$FIXTURE_MOUNT/.DS_Store" ]]

fixture_xattrs="$(xattr -r "$FIXTURE_MOUNT/Peekaboo.app")"
if printf '%s\n' "$fixture_xattrs" | rg -q ': com\.apple\.(FinderInfo|ResourceFork)$'; then
  printf 'Fixture app contains disallowed Finder metadata or a resource fork\n' >&2
  printf '%s\n' "$fixture_xattrs" >&2
  exit 1
fi

uv --no-config run \
  --with 'ds-store==1.3.3' \
  --with 'mac-alias==2.2.3' \
  python - "$FIXTURE_MOUNT/.DS_Store" <<'PY'
from ds_store import DSStore
import sys

records = {}
with DSStore.open(sys.argv[1], "r") as store:
    for entry in store:
        records[(entry.filename, entry.code)] = entry.value

assert records[(".", b"bwsp")]["WindowBounds"] == "{{200, 120}, {720, 460}}"
icon_view = records[(".", b"icvp")]
assert icon_view["backgroundType"] == 2
assert icon_view["iconSize"] == 128.0
assert icon_view["textSize"] == 13.0
assert records[("Peekaboo.app", b"Iloc")] == (180, 230)
assert records[("Applications", b"Iloc")] == (540, 230)
PY

hdiutil detach "$FIXTURE_MOUNT" -quiet
rmdir "$FIXTURE_MOUNT"
FIXTURE_MOUNT=""

printf 'test-create-release-dmg: ok\n'
