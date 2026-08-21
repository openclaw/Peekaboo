#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-macho-info-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

cat > "$TEST_DIR/info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>9.8.7-beta.2</string>
<key>PeekabooSourceCommit</key><string>0123456789abcdef0123456789abcdef01234567</string>
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

source_commit="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" \
  --binary "$TEST_DIR/fixture" --key PeekabooSourceCommit)"
version="$("$ROOT_DIR/scripts/read-macho-info-plist.sh" \
  --binary "$TEST_DIR/fixture" --key CFBundleShortVersionString)"
[[ "$source_commit" == 0123456789abcdef0123456789abcdef01234567 ]]
[[ "$version" == 9.8.7-beta.2 ]]

/usr/bin/sed 's/9\.8\.7-beta\.2/9.8.8/' "$TEST_DIR/info.plist" > "$TEST_DIR/info-mismatch.plist"
/usr/bin/clang -arch x86_64 "$TEST_DIR/main.c" \
  -Wl,-sectcreate,__TEXT,__info_plist,"$TEST_DIR/info-mismatch.plist" \
  -o "$TEST_DIR/mismatch-x86_64"
/usr/bin/lipo -create "$TEST_DIR/fixture-arm64" "$TEST_DIR/mismatch-x86_64" \
  -output "$TEST_DIR/mismatch"
if "$ROOT_DIR/scripts/read-macho-info-plist.sh" \
  --binary "$TEST_DIR/mismatch" --key CFBundleShortVersionString >/dev/null 2>&1; then
  printf 'test-read-macho-info-plist: mismatched universal slice was accepted\n' >&2
  exit 1
fi

/usr/bin/clang -arch arm64 "$TEST_DIR/main.c" \
  -Wl,-sectcreate,__DATA,__info_plist,"$TEST_DIR/info.plist" \
  -o "$TEST_DIR/decoy"
if "$ROOT_DIR/scripts/read-macho-info-plist.sh" \
  --binary "$TEST_DIR/decoy" --key CFBundleShortVersionString >/dev/null 2>&1; then
  printf 'test-read-macho-info-plist: non-__TEXT decoy section was accepted\n' >&2
  exit 1
fi
printf 'test-read-macho-info-plist: ok\n'
