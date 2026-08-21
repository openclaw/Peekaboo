#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"
for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do unset "$secret_name"; done
TEST_DIR="$(mktemp -d /tmp/peekaboo-terminal-dmg-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
APP="$TEST_DIR/Peekaboo.app"
mkdir -p "$APP/Contents/Resources"
printf 'icon\n' > "$APP/Contents/Resources/AppIcon.icns"

for tool in codesign xcrun verify-native hdiutil; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TEST_DIR/$tool"
  chmod 755 "$TEST_DIR/$tool"
done
cat > "$TEST_DIR/sips" <<'EOF'
#!/usr/bin/env bash
case "$*" in *pixelWidth*) printf 'pixelWidth: 720\n' ;; *) printf 'pixelHeight: 460\n' ;; esac
EOF
cat > "$TEST_DIR/uv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "${ROOT_DIR:?}/scripts/terminal-artifact-env.sh"
terminal_artifact_assert_build_env_is_clean
printf 'dmg\n' > "${!#}"
EOF
chmod 755 "$TEST_DIR/sips" "$TEST_DIR/uv"
export ROOT_DIR

run_fixture() {
  PEEKABOO_TERMINAL_TEST_MODE=1 \
  TERMINAL_DMG_UV_BIN="$TEST_DIR/uv" \
  TERMINAL_DMG_CODESIGN_BIN="$TEST_DIR/codesign" \
  TERMINAL_DMG_XCRUN_BIN="$TEST_DIR/xcrun" \
  TERMINAL_DMG_VERIFY_NATIVE_BIN="$TEST_DIR/verify-native" \
  TERMINAL_DMG_SIPS_BIN="$TEST_DIR/sips" \
  TERMINAL_DMG_HDIUTIL_BIN="$TEST_DIR/hdiutil" \
    "$ROOT_DIR/scripts/build-terminal-dmg.sh" --app "$APP" --version 9.9.9 "$@"
}

run_fixture --output "$TEST_DIR/output.dmg" >/dev/null
[[ -f "$TEST_DIR/output.dmg" ]]
if APP_STORE_CONNECT_API_KEY_P8=secret run_fixture --output "$TEST_DIR/secret.dmg" >/dev/null 2>&1; then
  printf 'test-build-terminal-dmg: credentialed construction succeeded\n' >&2
  exit 1
fi
[[ ! -e "$TEST_DIR/secret.dmg" ]]
if TERMINAL_DMG_UV_BIN="$TEST_DIR/uv" "$ROOT_DIR/scripts/build-terminal-dmg.sh" --help >/dev/null 2>&1; then
  printf 'test-build-terminal-dmg: production accepted tool override\n' >&2
  exit 1
fi
printf 'test-build-terminal-dmg: ok\n'
