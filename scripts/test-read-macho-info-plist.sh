#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-macho-info-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'test-read-macho-info-plist: %s\n' "$*" >&2
  exit 1
}

assert_key() {
  local actual
  actual="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$1" --key "$2")"
  [[ "$actual" == "$3" ]] || fail "unexpected $2 in ${1##*/}"
}

assert_plist() {
  local actual
  actual="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" --binary "$1")"
  [[ "$actual" == "$(<"$2")" ]] || fail "unexpected full plist in ${1##*/}"
}

assert_rejected() {
  local diagnostic="$1"
  shift
  if "$ROOT_DIR/scripts/read-macho-info-plist.sh" "$@" >"$TEST_DIR/output" 2>"$TEST_DIR/error"; then
    fail 'invalid embedded plist was accepted'
  fi
  [[ ! -s "$TEST_DIR/output" ]] || fail 'failed inspection emitted a value'
  /usr/bin/grep -Fq "$diagnostic" "$TEST_DIR/error" || fail "missing diagnostic: $diagnostic"
}

cat > "$TEST_DIR/info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>9.8.7-beta.2</string>
<key>PeekabooSourceCommit</key><string>0123456789abcdef0123456789abcdef01234567</string>
<key>EmptyValue</key><string></string>
</dict></plist>
PLIST
printf 'int main(void) { return 0; }\n' > "$TEST_DIR/main.c"
/usr/bin/clang -arch arm64 "$TEST_DIR/main.c" \
  -Wl,-sectcreate,__TEXT,__info_plist,"$TEST_DIR/info.plist" \
  -o "$TEST_DIR/fixture-arm64"
/usr/bin/clang -arch x86_64 "$TEST_DIR/main.c" \
  -Wl,-sectcreate,__TEXT,__info_plist,"$TEST_DIR/info.plist" \
  -o "$TEST_DIR/fixture-x86_64"
/usr/bin/lipo -create "$TEST_DIR/fixture-arm64" "$TEST_DIR/fixture-x86_64" -output "$TEST_DIR/fixture"
/usr/bin/lipo -create "$TEST_DIR/fixture-arm64" -output "$TEST_DIR/fixture-fat-arm64"

for fixture in fixture-arm64 fixture-x86_64 fixture fixture-fat-arm64; do
  assert_key "$TEST_DIR/$fixture" PeekabooSourceCommit 0123456789abcdef0123456789abcdef01234567
  assert_key "$TEST_DIR/$fixture" CFBundleShortVersionString 9.8.7-beta.2
  assert_key "$TEST_DIR/$fixture" EmptyValue ''
  assert_plist "$TEST_DIR/$fixture" "$TEST_DIR/info.plist"
  assert_rejected 'embedded Info.plist key missing: MissingKey' --binary "$TEST_DIR/$fixture" --key MissingKey
done

/usr/bin/sed 's/9\.8\.7-beta\.2/9.8.8/' "$TEST_DIR/info.plist" > "$TEST_DIR/info-mismatch.plist"
/usr/bin/clang -arch x86_64 "$TEST_DIR/main.c" \
  -Wl,-sectcreate,__TEXT,__info_plist,"$TEST_DIR/info-mismatch.plist" \
  -o "$TEST_DIR/mismatch-x86_64"
/usr/bin/lipo -create "$TEST_DIR/fixture-arm64" "$TEST_DIR/mismatch-x86_64" \
  -output "$TEST_DIR/mismatch"
assert_rejected 'embedded Info.plist differs for architecture' \
  --binary "$TEST_DIR/mismatch" --key CFBundleShortVersionString
assert_rejected 'embedded Info.plist differs for architecture' --binary "$TEST_DIR/mismatch"
# A selected key may agree even when another key differs between slices.
assert_key "$TEST_DIR/mismatch" PeekabooSourceCommit 0123456789abcdef0123456789abcdef01234567

/usr/bin/sed 's/<string><\/string>/<string>nonempty<\/string>/' \
  "$TEST_DIR/info.plist" > "$TEST_DIR/info-nonempty.plist"
for architecture in arm64 x86_64; do
  /usr/bin/clang -arch "$architecture" "$TEST_DIR/main.c" \
    -Wl,-sectcreate,__TEXT,__info_plist,"$TEST_DIR/info-nonempty.plist" \
    -o "$TEST_DIR/nonempty-$architecture"
done
# Cover both empty-first and empty-last regardless of lipo's slice ordering.
/usr/bin/lipo -create "$TEST_DIR/fixture-arm64" "$TEST_DIR/nonempty-x86_64" \
  -output "$TEST_DIR/empty-arm64"
/usr/bin/lipo -create "$TEST_DIR/nonempty-arm64" "$TEST_DIR/fixture-x86_64" \
  -output "$TEST_DIR/empty-x86_64"
for fixture in empty-arm64 empty-x86_64; do
  assert_rejected 'embedded Info.plist differs for architecture' --binary "$TEST_DIR/$fixture" --key EmptyValue
done

/usr/bin/clang -arch arm64 "$TEST_DIR/main.c" \
  -Wl,-sectcreate,__DATA,__info_plist,"$TEST_DIR/info.plist" \
  -o "$TEST_DIR/decoy"
assert_rejected 'must have exactly one __TEXT,__info_plist section' \
  --binary "$TEST_DIR/decoy" --key CFBundleShortVersionString
printf 'test-read-macho-info-plist: ok\n'
