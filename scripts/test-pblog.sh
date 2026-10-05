#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-pblog-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/log" <<'MOCK'
#!/usr/bin/env bash
printf '<%s>\n' "$@"
MOCK
chmod +x "$TEST_DIR/bin/log"
export PATH="$TEST_DIR/bin:$PATH"
# Ordinary apostrophes must remain part of the predicate, not shell syntax.
bash "$ROOT_DIR/scripts/pblog.sh" --all --search "couldn't open" > "$TEST_DIR/result"
rg -F 'eventMessage CONTAINS[c] "couldn' "$TEST_DIR/result" >/dev/null
# Quotes and backslashes need predicate escaping; command-looking text stays data.
search='a "quoted" path\name; $(echo accidental)'
bash "$ROOT_DIR/scripts/pblog.sh" --all --search "$search" --category 'a"b' --subsystem 'boo\name' --last '10 m' --json > "$TEST_DIR/result"
rg -F 'eventMessage CONTAINS[c] "a \"quoted\" path\\name; $(echo accidental)"' "$TEST_DIR/result" >/dev/null
rg -F 'category == "a\"b"' "$TEST_DIR/result" >/dev/null
rg -F 'subsystem == "boo\\name"' "$TEST_DIR/result" >/dev/null
rg -Fx '<10 m>' "$TEST_DIR/result" >/dev/null
rg -Fx '<json>' "$TEST_DIR/result" >/dev/null
bash "$ROOT_DIR/scripts/pblog.sh" --follow --all --debug > "$TEST_DIR/result"
rg -Fx '<stream>' "$TEST_DIR/result" >/dev/null
rg -Fx '<debug>' "$TEST_DIR/result" >/dev/null
printf 'test-pblog: ok\n'
