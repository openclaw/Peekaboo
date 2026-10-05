#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-controller-source-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
FIXTURE_ROOT="$TEST_DIR/repo"
mkdir -p "$FIXTURE_ROOT/scripts" "$FIXTURE_ROOT/src"
cp "${PEEKABOO_CONTROLLER_SOURCE_HELPER:-$ROOT_DIR/scripts/controller-source-manifest.mjs}" \
  "$FIXTURE_ROOT/scripts/controller-source-manifest.mjs"

run_manifest() {
  node - "$FIXTURE_ROOT/scripts/controller-source-manifest.mjs" "$@" <<'NODE'
const {spawnSync} = require('node:child_process');
const result = spawnSync(process.execPath, process.argv.slice(2), {encoding: 'utf8', timeout: 3000});
process.stdout.write(result.stdout ?? '');
process.stderr.write(result.stderr ?? '');
if (result.error || result.signal) {
  process.stderr.write(`Manifest fixture did not exit normally: ${result.error?.message ?? result.signal}\n`);
  process.exit(1);
}
process.exit(result.status ?? 1);
NODE
}

expect_refusal() {
  local expected="$1"
  shift
  if run_manifest "$@" >"$TEST_DIR/refusal.json" 2>"$TEST_DIR/refusal.err"; then
    printf 'test-controller-source-manifest: expected refusal: %s\n' "$expected" >&2
    exit 1
  fi
  test ! -s "$TEST_DIR/refusal.json"
  grep -Fq -- "$expected" "$TEST_DIR/refusal.err"
}
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

run_manifest --source-commit "$source_commit" > "$TEST_DIR/receipt.json"
jq -e --arg sourceSHA "$source_sha" '
  .version == 1 and .catalog_path == "scripts/multi-target-certification-catalog.json" and
  .files == [{path: "src/controller.swift", sha256: $sourceSHA}] and
  (.aggregate_sha256 | test("^[0-9a-f]{64}$"))
' "$TEST_DIR/receipt.json" >/dev/null

printf 'dirty worktree bytes\n' > "$FIXTURE_ROOT/src/controller.swift"
run_manifest --source-commit "$source_commit" \
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
expect_refusal 'controller source path is unsafe' --source-commit "$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"

# A committed symlink's blob is the link target, not the controller source bytes.
# Matching that blob's hash must not qualify a symlink as executable source.
printf 'outside fixture\n' > "$TEST_DIR/outside"
rm "$FIXTURE_ROOT/src/controller.swift"
ln -s "$TEST_DIR/outside" "$FIXTURE_ROOT/src/controller.swift"
link_sha="$(printf '%s' "$TEST_DIR/outside" | shasum -a 256 | awk '{print $1}')"
cat > "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json" <<EOF
{"current_build_source":{"controller_source_manifest":[{"path":"src/controller.swift","sha256":"$link_sha"}]}}
EOF
git -C "$FIXTURE_ROOT" add .
git -C "$FIXTURE_ROOT" commit -qm symlink
expect_refusal 'not a regular source blob' --source-commit "$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
# Worktree mode must also reject a symlink even if target bytes have the expected digest.
outside_sha="$(shasum -a 256 "$TEST_DIR/outside" | awk '{print $1}')"
cat > "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json" <<EOF
{"current_build_source":{"controller_source_manifest":[{"path":"src/controller.swift","sha256":"$outside_sha"}]}}
EOF
expect_refusal 'symlinked or not a regular source file'

# Frozen receipts remain tied to their original regular blobs, not later filesystem types.
run_manifest --source-commit "$source_commit" > "$TEST_DIR/frozen-after-symlink.json"
cmp "$TEST_DIR/receipt.json" "$TEST_DIR/frozen-after-symlink.json"

rm "$FIXTURE_ROOT/src/controller.swift"
printf 'committed\n' > "$FIXTURE_ROOT/src/controller.swift"
chmod +x "$FIXTURE_ROOT/src/controller.swift"
cat > "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json" <<EOF
{"current_build_source":{"controller_source_manifest":[{"path":"src/controller.swift","sha256":"$source_sha"}]}}
EOF
run_manifest > "$TEST_DIR/executable-worktree.json"
cmp "$TEST_DIR/receipt.json" "$TEST_DIR/executable-worktree.json"
git -C "$FIXTURE_ROOT" add src/controller.swift scripts/multi-target-certification-catalog.json
git -C "$FIXTURE_ROOT" commit -qm executable
run_manifest --source-commit "$(git -C "$FIXTURE_ROOT" rev-parse HEAD)" > "$TEST_DIR/executable-commit.json"
cmp "$TEST_DIR/receipt.json" "$TEST_DIR/executable-commit.json"

mv "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json" "$TEST_DIR/catalog.json"
ln -s "$TEST_DIR/catalog.json" "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json"
expect_refusal 'symlinked or not a regular source file'
rm "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json"
mv "$TEST_DIR/catalog.json" "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json"

mv "$FIXTURE_ROOT/src" "$TEST_DIR/source-dir"
ln -s "$TEST_DIR/source-dir" "$FIXTURE_ROOT/src"
expect_refusal 'symlinked or not a regular source file'
rm "$FIXTURE_ROOT/src"
mv "$TEST_DIR/source-dir" "$FIXTURE_ROOT/src"

rm "$FIXTURE_ROOT/src/controller.swift"
mkdir "$FIXTURE_ROOT/src/controller.swift"
expect_refusal 'symlinked or not a regular source file'
rmdir "$FIXTURE_ROOT/src/controller.swift"
mkfifo "$FIXTURE_ROOT/src/controller.swift"
expect_refusal 'symlinked or not a regular source file'

# A one-child directory must not qualify even when the catalog matches its tree-listing bytes.
rm "$FIXTURE_ROOT/src/controller.swift"
mkdir "$FIXTURE_ROOT/src/controller.swift"
printf 'owned source bytes\n' > "$FIXTURE_ROOT/src/controller.swift/only.swift"
git -C "$FIXTURE_ROOT" add .
git -C "$FIXTURE_ROOT" commit -qm directory
directory_commit="$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"
git -C "$FIXTURE_ROOT" ls-tree "$directory_commit" -- src/controller.swift | grep -q '^040000 tree '
git -C "$FIXTURE_ROOT" ls-tree "$directory_commit" -- src/controller.swift/ | grep -q '^100644 blob '
git -C "$FIXTURE_ROOT" show "$directory_commit:src/controller.swift" > "$TEST_DIR/tree-listing"
tree_sha="$(shasum -a 256 "$TEST_DIR/tree-listing" | awk '{print $1}')"
cat > "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json" <<EOF
{"current_build_source":{"controller_source_manifest":[{"path":"src/controller.swift","sha256":"$tree_sha"}]}}
EOF
git -C "$FIXTURE_ROOT" add scripts/multi-target-certification-catalog.json
git -C "$FIXTURE_ROOT" commit -qm directory-catalog
expect_refusal 'not a regular source blob' --source-commit "$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"

# The spelling that expands the directory is refused by path validation before Git reads it.
cat > "$FIXTURE_ROOT/scripts/multi-target-certification-catalog.json" <<EOF
{"current_build_source":{"controller_source_manifest":[{"path":"src/controller.swift/","sha256":"$tree_sha"}]}}
EOF
git -C "$FIXTURE_ROOT" add scripts/multi-target-certification-catalog.json
git -C "$FIXTURE_ROOT" commit -qm trailing-slash-catalog
expect_refusal 'controller source path is unsafe' --source-commit "$(git -C "$FIXTURE_ROOT" rev-parse HEAD)"

printf 'test-controller-source-manifest: ok\n'
