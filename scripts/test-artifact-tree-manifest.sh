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

mkdir -p "$TEST_DIR/framework/Versions/A"
printf 'framework fixture\n' > "$TEST_DIR/framework/Versions/A/value"
ln -s A "$TEST_DIR/framework/Versions/Current"
ln -s Versions/Current/../A/value "$TEST_DIR/framework/current"
ln -s Versions/Current/missing "$TEST_DIR/framework/dangling"
[[ "$(cat "$TEST_DIR/framework/current")" == 'framework fixture' ]] || fail 'native framework link fixture failed'
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/framework" >"$TEST_DIR/framework.json"
jq -e '([.entries[] | select(.type == "symlink")] | length) == 3' "$TEST_DIR/framework.json" >/dev/null || fail 'safe composed/dangling links changed'
# Absolute spelling must preserve native component resolution, including aliases
# and noncanonical prefixes such as '/tmp/./...'.
ln -s "$TEST_DIR/./framework/Versions/Current/../A/value" "$TEST_DIR/framework/absolute"
ln -s "$TEST_DIR/./framework/Versions/Current/missing" "$TEST_DIR/framework/absolute-dangling"
ln -s "$TEST_DIR/./framework/Versions/Current" "$TEST_DIR/framework/absolute-alias"
ln -s absolute-alias/value "$TEST_DIR/framework/nested-absolute"
[[ "$(cat "$TEST_DIR/framework/absolute")" == 'framework fixture' ]] || fail 'native absolute framework link fixture failed'
[[ "$(cat "$TEST_DIR/framework/nested-absolute")" == 'framework fixture' ]] || fail 'native nested absolute link fixture failed'
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/framework" >"$TEST_DIR/absolute-framework.json"
jq -e '([.entries[] | select(.type == "symlink")] | length) == 7' "$TEST_DIR/absolute-framework.json" >/dev/null || fail 'safe absolute/dangling links changed'

printf 'owned absolute outside fixture\n' > "$TEST_DIR/outside"
for spelling in "$TEST_DIR/./absolute-composed" "$TEST_DIR/unused/../absolute-composed"; do
  mkdir -p "$TEST_DIR/absolute-composed" "$TEST_DIR/unused"
  rm -f "$TEST_DIR/absolute-composed/alias" "$TEST_DIR/absolute-composed/escape"
  ln -s . "$TEST_DIR/absolute-composed/alias"
  ln -s "$spelling/alias/../outside" "$TEST_DIR/absolute-composed/escape"
  [[ "$(cat "$TEST_DIR/absolute-composed/escape")" == 'owned absolute outside fixture' ]] || fail 'native absolute composed-link fixture did not escape'
  if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/absolute-composed" >"$TEST_DIR/absolute-composed.json" 2>"$TEST_DIR/absolute-composed.err"; then
    fail 'absolute composed root-escaping symlink was accepted'
  fi
  grep -q 'symlink escapes root' "$TEST_DIR/absolute-composed.err" || fail 'absolute composed symlink diagnostic missing'
done

mkdir -p "$TEST_DIR/nested-absolute"
ln -s "$TEST_DIR/./nested-absolute" "$TEST_DIR/nested-absolute/alias"
ln -s alias/../outside "$TEST_DIR/nested-absolute/escape"
[[ "$(cat "$TEST_DIR/nested-absolute/escape")" == 'owned absolute outside fixture' ]] || fail 'native nested absolute fixture did not escape'
if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/nested-absolute" >"$TEST_DIR/nested-absolute.json" 2>"$TEST_DIR/nested-absolute.err"; then
  fail 'nested absolute composed root-escaping symlink was accepted'
fi
grep -q 'symlink escapes root' "$TEST_DIR/nested-absolute.err" || fail 'nested absolute diagnostic missing'

physical_test_dir="$(cd "$TEST_DIR" && pwd -P)"
for link_count in 32 33; do
  chain="$physical_test_dir/chain-$link_count"
  mkdir -p "$chain"
  printf 'boundary\n' > "$chain/value"
  for ((index = link_count; index >= 1; index--)); do
    target="link-$((index + 1))"
    [[ "$index" -ne "$link_count" ]] || target=value
    ln -s "$target" "$chain/link-$index"
  done
  if [[ "$link_count" -eq 32 ]]; then
    [[ "$(cat "$chain/link-1")" == boundary ]] || fail 'native 32-link chain was not readable'
    /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$chain" > "$TEST_DIR/chain-32.json"
  else
    /usr/bin/ruby -e 'begin; File.read(ARGV.fetch(0)); abort("native 33-link chain was accepted"); rescue Errno::ELOOP; end' "$chain/link-1"
    if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$chain" > "$TEST_DIR/chain-33.json" 2> "$TEST_DIR/chain-33.err"; then
      fail 'native-unreadable 33-link chain was accepted by the manifest'
    fi
    grep -q 'symlink expansion limit exceeded' "$TEST_DIR/chain-33.err" || fail 'chain limit diagnostic missing'
  fi
done
printf 'test-artifact-tree-manifest: PASS native 32-link acceptance and 33-link refusal\n'

mkdir -p "$TEST_DIR/prefix/artifact" "$TEST_DIR/prefix/other/deep" "$TEST_DIR/prefix/other/artifact"
printf 'owned prefix outside artifact\n' > "$TEST_DIR/prefix/other/artifact/value"
ln -s "$physical_test_dir/prefix/other/deep" "$TEST_DIR/prefix/trampoline"
ln -s "$physical_test_dir/prefix/trampoline/../artifact/value" "$TEST_DIR/prefix/artifact/escape"
[[ "$(cat "$TEST_DIR/prefix/artifact/escape")" == 'owned prefix outside artifact' ]] || fail 'native prefix escape fixture failed'
if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$physical_test_dir/prefix/artifact" > "$TEST_DIR/prefix.json" 2> "$TEST_DIR/prefix.err"; then
  fail 'absolute prefix alias escaped the physical artifact root'
fi
grep -q 'symlink escapes root' "$TEST_DIR/prefix.err" || fail 'absolute prefix escape diagnostic missing'

mkdir -p "$TEST_DIR/cycle"
ln -s second "$TEST_DIR/cycle/first"
ln -s first "$TEST_DIR/cycle/second"
if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/cycle" >"$TEST_DIR/cycle.json" 2>"$TEST_DIR/cycle.err"; then
  fail 'cyclic symlink was accepted'
fi
grep -q 'symlink expansion limit exceeded' "$TEST_DIR/cycle.err" || fail 'cycle diagnostic missing'

mkdir -p "$TEST_DIR/composed"
printf 'owned outside fixture\n' > "$TEST_DIR/outside"
ln -s . "$TEST_DIR/composed/alias"
ln -s alias/../outside "$TEST_DIR/composed/escape"
[[ "$(cat "$TEST_DIR/composed/escape")" == 'owned outside fixture' ]] || fail 'native composed-link fixture did not escape'
if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/composed" >"$TEST_DIR/composed.json" 2>"$TEST_DIR/composed.err"; then
  fail 'composed root-escaping symlink was accepted'
fi
grep -q 'symlink escapes root' "$TEST_DIR/composed.err" || fail 'composed symlink diagnostic missing'

ln -s ../outside "$TEST_DIR/tree/escape"
if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/tree" >/dev/null 2>&1; then
  fail 'root-escaping symlink was accepted'
fi
ln -s "$TEST_DIR/tree" "$TEST_DIR/root-link"
if /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$TEST_DIR/root-link" >/dev/null 2>&1; then
  fail 'symlink artifact root was accepted'
fi

printf 'test-artifact-tree-manifest: ok\n'
