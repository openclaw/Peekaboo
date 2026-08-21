#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-terminal-notary-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
LOG_FILE="$TEST_DIR/invocations"
CLI_ARTIFACT="$TEST_DIR/peekaboo"
APP_ARTIFACT="$TEST_DIR/Playground.app"

fail() {
  printf 'test-notarize-terminal-artifact: %s\n' "$*" >&2
  exit 1
}

cp /usr/bin/true "$CLI_ARTIFACT"
mkdir -p "$APP_ARTIFACT/Contents/MacOS"
cp /usr/bin/true "$APP_ARTIFACT/Contents/MacOS/Playground"

cat > "$TEST_DIR/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ditto %s\n' "$*" >> "${LOG_FILE:?}"
output="${!#}"
printf 'zip\n' > "$output"
EOF
cat > "$TEST_DIR/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "${LOG_FILE:?}"
if [[ "${1:-}" == notarytool ]]; then
  printf '{"id":"fixture-submission","status":"Accepted"}\n'
fi
EOF
cat > "$TEST_DIR/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >> "${LOG_FILE:?}"
EOF
chmod 755 "$TEST_DIR/ditto" "$TEST_DIR/xcrun" "$TEST_DIR/codesign"
export LOG_FILE

for kind_and_path in "cli:$CLI_ARTIFACT" "app:$APP_ARTIFACT"; do
  kind="${kind_and_path%%:*}"
  path="${kind_and_path#*:}"
  TERMINAL_NOTARY_XCRUN_BIN="$TEST_DIR/xcrun" \
    TERMINAL_NOTARY_DITTO_BIN="$TEST_DIR/ditto" \
    TERMINAL_NOTARY_CODESIGN_BIN="$TEST_DIR/codesign" \
    "$ROOT_DIR/scripts/notarize-terminal-artifact.sh" \
    --kind "$kind" \
    --artifact "$path" \
    --notary-profile fixture \
    --result "$TEST_DIR/$kind-result.json" >/dev/null
  jq -e --arg kind "$kind" '
    . == {version: 1, kind: $kind, id: "fixture-submission", status: "Accepted"}
  ' "$TEST_DIR/$kind-result.json" >/dev/null || fail "$kind result receipt is incomplete"
done

[[ "$(grep -Fc -- '--no-s3-acceleration' "$LOG_FILE")" == 2 ]] || \
  fail 'notary submissions did not disable S3 acceleration'
[[ "$(grep -Fc 'xcrun notarytool history' "$LOG_FILE")" == 2 ]] || \
  fail 'notary credentials were not proven with history before submission'
grep -Fq 'xcrun stapler staple' "$LOG_FILE" || fail 'app ticket was not stapled'
grep -Fq 'xcrun stapler validate' "$LOG_FILE" || fail 'app ticket was not validated'
[[ "$(grep -Fc 'codesign --verify' "$LOG_FILE")" == 2 ]] || \
  fail 'online notarization was not verified for both artifact kinds'

printf 'test-notarize-terminal-artifact: ok\n'
