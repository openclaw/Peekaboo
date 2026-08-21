#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-controller-source-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
FIXTURE_ROOT="$TEST_DIR/repo"
mkdir -p "$FIXTURE_ROOT/scripts" "$FIXTURE_ROOT/src"
cp "$ROOT_DIR/scripts/controller-source-manifest.mjs" "$FIXTURE_ROOT/scripts/"
printf 'committed\n' > "$FIXTURE_ROOT/src/controller.swift"
source_sha="$(/usr/bin/shasum -a 256 "$FIXTURE_ROOT/src/controller.swift" | /usr/bin/awk '{print $1}')"
cat > "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json" <<EOF
{"current_build_source":{"controller_source_manifest":[{"path":"src/controller.swift","sha256":"$source_sha"}]}}
EOF
git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" config user.name 'Peekaboo Test'
git -C "$FIXTURE_ROOT" config user.email 'peekaboo-test@example.invalid'
git -C "$FIXTURE_ROOT" add .
git -C "$FIXTURE_ROOT" commit -qm fixture
source_commit="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"

node "$FIXTURE_ROOT/scripts/controller-source-manifest.mjs" --source-commit "$source_commit" > "$TEST_DIR/receipt.json"
jq -e --arg sourceSHA "$source_sha" '
  .version == 1 and .catalog_path == "scripts/multi-target-certification-catalog.json" and
  .files == [{path: "src/controller.swift", sha256: $sourceSHA}] and
  (.aggregate_sha256 | test("^[0-9a-f]{64}$"))
' "$TEST_DIR/receipt.json" >/dev/null

printf 'dirty worktree bytes\n' > "$FIXTURE_ROOT/src/controller.swift"
node "$FIXTURE_ROOT/scripts/controller-source-manifest.mjs" --source-commit "$source_commit" \
  > "$TEST_DIR/committed-receipt.json"
cmp -s "$TEST_DIR/receipt.json" "$TEST_DIR/committed-receipt.json" || {
  printf 'test-controller-source-manifest: worktree bytes changed committed receipt\n' >&2
  exit 1
}

cat > "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json" <<EOF
{"current_build_source":{"controller_source_manifest":[{"path":"../escape","sha256":"$source_sha"}]}}
EOF
git -C "$FIXTURE_ROOT" add .
git -C "$FIXTURE_ROOT" commit -qm unsafe
if node "$FIXTURE_ROOT/scripts/controller-source-manifest.mjs" \
  --source-commit "$(git -C "$FIXTURE_ROOT" rev-parse HEAD)" >/dev/null 2>&1; then
  printf 'test-controller-source-manifest: escaping source path was accepted\n' >&2
  exit 1
fi

printf 'test-controller-source-manifest: ok\n'
