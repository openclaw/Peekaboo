#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-playground-log-wrapper.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/scripts" "$TEST_DIR/Apps/Playground/scripts"
cp "$ROOT_DIR/scripts/playground-log.sh" "$TEST_DIR/scripts/"
cat > "$TEST_DIR/Apps/Playground/scripts/playground-log.sh" <<'TARGET'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
exit 7
TARGET
chmod +x "$TEST_DIR/Apps/Playground/scripts/playground-log.sh"
status=0
bash "$TEST_DIR/scripts/playground-log.sh" --search 'two words' --last 10m > "$TEST_DIR/result" 2> "$TEST_DIR/error" || status=$?
[[ "$status" == 7 ]] || { cat "$TEST_DIR/error" >&2; echo 'Wrapper did not forward target exit status' >&2; exit 1; }
printf '<--search>\n<two words>\n<--last>\n<10m>\n' > "$TEST_DIR/expected"
cmp "$TEST_DIR/expected" "$TEST_DIR/result"
rm "$TEST_DIR/Apps/Playground/scripts/playground-log.sh"
if bash "$TEST_DIR/scripts/playground-log.sh" --help > "$TEST_DIR/missing" 2>&1; then
  echo 'Missing target unexpectedly succeeded' >&2; exit 1
fi
printf 'test-playground-log-wrapper: ok\n'
