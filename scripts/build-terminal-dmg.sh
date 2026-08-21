#!/usr/bin/env bash

# Construct an unsigned terminal DMG from an already signed/notarized app. The
# caller signs and notarizes the DMG in separate narrow credential lanes.

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"

APP_BUNDLE=""
OUTPUT_DMG=""
VERSION=""
BACKGROUND="$ROOT_DIR/assets/dmg-background.png"

fail() {
  printf 'build-terminal-dmg: %s\n' "$*" >&2
  exit 1
}

case "${PEEKABOO_TERMINAL_TEST_MODE:-0}" in
  1|true|yes|on)
    UV_BIN="${TERMINAL_DMG_UV_BIN:?test uv required}"
    CODESIGN_BIN="${TERMINAL_DMG_CODESIGN_BIN:?test codesign required}"
    XCRUN_BIN="${TERMINAL_DMG_XCRUN_BIN:?test xcrun required}"
    VERIFY_NATIVE_BIN="${TERMINAL_DMG_VERIFY_NATIVE_BIN:?test native verifier required}"
    SIPS_BIN="${TERMINAL_DMG_SIPS_BIN:?test sips required}"
    HDIUTIL_BIN="${TERMINAL_DMG_HDIUTIL_BIN:?test hdiutil required}"
    ;;
  0|false|no|off|'')
    for override_name in TERMINAL_DMG_UV_BIN TERMINAL_DMG_CODESIGN_BIN TERMINAL_DMG_XCRUN_BIN \
      TERMINAL_DMG_VERIFY_NATIVE_BIN TERMINAL_DMG_SIPS_BIN TERMINAL_DMG_HDIUTIL_BIN; do
      [[ -z "${!override_name+x}" ]] || fail "$override_name is test-only"
    done
    UV_BIN="$(command -v uv || true)"
    UV_BIN="$(realpath "$UV_BIN" 2>/dev/null || true)"
    case "$UV_BIN" in /opt/homebrew/*|/usr/local/*) ;; *) fail "untrusted uv binary: ${UV_BIN:-missing}" ;; esac
    CODESIGN_BIN=/usr/bin/codesign
    XCRUN_BIN=/usr/bin/xcrun
    VERIFY_NATIVE_BIN="$ROOT_DIR/scripts/verify-native-only-app.sh"
    SIPS_BIN=/usr/bin/sips
    HDIUTIL_BIN=/usr/bin/hdiutil
    ;;
  *) fail 'PEEKABOO_TERMINAL_TEST_MODE must be boolean' ;;
esac

while (($# > 0)); do
  case "$1" in
    --app) APP_BUNDLE="$2"; shift 2 ;;
    --output) OUTPUT_DMG="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --background) BACKGROUND="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: scripts/build-terminal-dmg.sh --app PATH --output PATH --version VERSION\n'
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done

terminal_artifact_assert_build_env_is_clean || fail 'DMG construction environment is credentialed'
[[ "$APP_BUNDLE" == /* && -d "$APP_BUNDLE" && ! -L "$APP_BUNDLE" ]] || fail 'invalid app path'
[[ "$OUTPUT_DMG" == /* && ! -e "$OUTPUT_DMG" && ! -L "$OUTPUT_DMG" ]] || fail 'invalid output path'
[[ -n "$VERSION" ]] || fail '--version is required'
[[ -f "$BACKGROUND" ]] || fail "background missing: $BACKGROUND"
[[ -n "$UV_BIN" && -x "$UV_BIN" ]] || fail 'uv is required'

"$CODESIGN_BIN" --verify --deep --strict --check-notarization -R=notarized --verbose=2 "$APP_BUNDLE"
"$XCRUN_BIN" stapler validate "$APP_BUNDLE"
"$VERIFY_NATIVE_BIN" --app "$APP_BUNDLE"

background_width="$("$SIPS_BIN" -g pixelWidth "$BACKGROUND" | awk '/pixelWidth/{print $2}')"
background_height="$("$SIPS_BIN" -g pixelHeight "$BACKGROUND" | awk '/pixelHeight/{print $2}')"
[[ "$background_width" == 720 && "$background_height" == 460 ]] || fail 'background must be 720x460'

volume_icon="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
[[ -f "$volume_icon" ]] || fail "volume icon missing: $volume_icon"
mkdir -p "$(dirname "$OUTPUT_DMG")"
terminal_artifact_run_build "$UV_BIN" --no-config run --locked "$ROOT_DIR/scripts/dmgbuild-runner.py" \
  --no-hidpi \
  --detach-retries 5 \
  --settings "$ROOT_DIR/scripts/dmgbuild-settings.py" \
  -D app_name=Peekaboo \
  -D "app_path=$APP_BUNDLE" \
  -D "background=$BACKGROUND" \
  -D "volume_icon=$volume_icon" \
  "Peekaboo $VERSION" \
  "$OUTPUT_DMG"

[[ -f "$OUTPUT_DMG" ]] || fail 'dmgbuild produced no output'
"$HDIUTIL_BIN" verify "$OUTPUT_DMG" >/dev/null
printf 'Unsigned DMG: %s\n' "$OUTPUT_DMG"
