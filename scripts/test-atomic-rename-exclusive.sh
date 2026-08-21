#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-atomic-rename-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
chmod 700 "$TEST_DIR"

printf 'file\n' > "$TEST_DIR/file-source"
chmod 600 "$TEST_DIR/file-source"
"$ROOT_DIR/scripts/atomic-rename-exclusive.rb" "$TEST_DIR/file-source" "$TEST_DIR/file-output"
[[ ! -e "$TEST_DIR/file-source" && "$(<"$TEST_DIR/file-output")" == file ]]

mkdir "$TEST_DIR/directory-source"
chmod 700 "$TEST_DIR/directory-source"
printf 'nested\n' > "$TEST_DIR/directory-source/value"
"$ROOT_DIR/scripts/atomic-rename-exclusive.rb" \
  "$TEST_DIR/directory-source" "$TEST_DIR/directory-output"
[[ ! -e "$TEST_DIR/directory-source" && "$(<"$TEST_DIR/directory-output/value")" == nested ]]

printf 'source\n' > "$TEST_DIR/collision-source"
printf 'destination\n' > "$TEST_DIR/collision-output"
chmod 600 "$TEST_DIR/collision-source" "$TEST_DIR/collision-output"
if "$ROOT_DIR/scripts/atomic-rename-exclusive.rb" \
  "$TEST_DIR/collision-source" "$TEST_DIR/collision-output" >/dev/null 2>&1; then
  printf 'test-atomic-rename-exclusive: existing destination was overwritten\n' >&2
  exit 1
fi
[[ "$(<"$TEST_DIR/collision-source")" == source && "$(<"$TEST_DIR/collision-output")" == destination ]]

ln -s collision-source "$TEST_DIR/symlink-source"
if "$ROOT_DIR/scripts/atomic-rename-exclusive.rb" \
  "$TEST_DIR/symlink-source" "$TEST_DIR/symlink-output" >/dev/null 2>&1; then
  printf 'test-atomic-rename-exclusive: symlink source was published\n' >&2
  exit 1
fi
[[ -L "$TEST_DIR/symlink-source" && ! -e "$TEST_DIR/symlink-output" ]]

printf 'test-atomic-rename-exclusive: ok\n'
