#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-tree-manifest-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'test-artifact-tree-manifest: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_DIR/tree/bin"
printf 'payload\n' > "$TEST_DIR/tree/bin/tool"
chmod 755 "$TEST_DIR/tree/bin/tool"
ln -s bin/tool "$TEST_DIR/tree/current"

/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/tree" > "$TEST_DIR/one.json"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/tree" > "$TEST_DIR/two.json"
cmp -s "$TEST_DIR/one.json" "$TEST_DIR/two.json" || fail 'manifest is not deterministic'
jq -e '
  .version == 1 and
  ([.entries[] | select(.path == "bin/tool" and .type == "file" and .mode == "0755" and
    (.sha256 | test("^[0-9a-f]{64}$")))] | length) == 1 and
  ([.entries[] | select(.path == "current" and .type == "symlink" and .target == "bin/tool")] | length) == 1
' "$TEST_DIR/one.json" >/dev/null || fail 'file mode/content or symlink target was not bound'

before="$(shasum -a 256 "$TEST_DIR/one.json" | awk '{print $1}')"
chmod 700 "$TEST_DIR/tree/bin/tool"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/tree" > "$TEST_DIR/changed.json"
after="$(shasum -a 256 "$TEST_DIR/changed.json" | awk '{print $1}')"
[[ "$before" != "$after" ]] || fail 'mode-only mutation did not change the manifest digest'

printf 'extra\n' > "$TEST_DIR/tree/extra"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/tree" > "$TEST_DIR/added.json"
[[ "$(shasum -a 256 "$TEST_DIR/added.json" | awk '{print $1}')" != "$after" ]] || \
  fail 'added nested file did not change the manifest digest'
find "$TEST_DIR/tree/extra" -delete
printf 'replacement\n' > "$TEST_DIR/tree/bin/tool"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/tree" > "$TEST_DIR/substituted.json"
[[ "$(shasum -a 256 "$TEST_DIR/substituted.json" | awk '{print $1}')" != "$after" ]] || \
  fail 'substituted nested file did not change the manifest digest'
find "$TEST_DIR/tree/current" -delete
ln -s bin/missing "$TEST_DIR/tree/current"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/tree" > "$TEST_DIR/retargeted.json"
[[ "$(shasum -a 256 "$TEST_DIR/retargeted.json" | awk '{print $1}')" != \
  "$(shasum -a 256 "$TEST_DIR/substituted.json" | awk '{print $1}')" ]] || \
  fail 'retargeted symlink did not change the manifest digest'

ln -s ../outside "$TEST_DIR/tree/escape"
if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/tree" >/dev/null 2>&1; then
  fail 'root-escaping symlink was accepted'
fi
ln -s "$TEST_DIR/tree" "$TEST_DIR/root-link"
if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/root-link" >/dev/null 2>&1; then
  fail 'symlink artifact root was accepted'
fi

printf 'test-artifact-tree-manifest: ok\n'
