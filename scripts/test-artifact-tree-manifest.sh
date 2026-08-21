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

node "$ROOT_DIR/scripts/artifact-tree-manifest.mjs" "$TEST_DIR/tree" > "$TEST_DIR/one.json"
node "$ROOT_DIR/scripts/artifact-tree-manifest.mjs" "$TEST_DIR/tree" > "$TEST_DIR/two.json"
cmp -s "$TEST_DIR/one.json" "$TEST_DIR/two.json" || fail 'manifest is not deterministic'
jq -e '
  .version == 1 and
  ([.entries[] | select(.path == "bin/tool" and .type == "file" and .mode == "0755" and
    (.sha256 | test("^[0-9a-f]{64}$")))] | length) == 1 and
  ([.entries[] | select(.path == "current" and .type == "symlink" and .target == "bin/tool")] | length) == 1
' "$TEST_DIR/one.json" >/dev/null || fail 'file mode/content or symlink target was not bound'

before="$(shasum -a 256 "$TEST_DIR/one.json" | awk '{print $1}')"
chmod 700 "$TEST_DIR/tree/bin/tool"
node "$ROOT_DIR/scripts/artifact-tree-manifest.mjs" "$TEST_DIR/tree" > "$TEST_DIR/changed.json"
after="$(shasum -a 256 "$TEST_DIR/changed.json" | awk '{print $1}')"
[[ "$before" != "$after" ]] || fail 'mode-only mutation did not change the manifest digest'

printf 'test-artifact-tree-manifest: ok\n'
