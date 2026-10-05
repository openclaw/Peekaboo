#!/usr/bin/env bash
set -euo pipefail
unset MAC_RELEASE_CODESIGN_IDENTITY MAC_RELEASE_CODESIGN_TEAM_ID
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-runtime-slice-rpaths.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
SDK="$TEST_DIR/SDK/MacOSX15.0.sdk"
mkdir -p "$SDK/usr/lib/swift"
printf '{"Version":"15.0","CanonicalName":"macosx15.0"}\n' > "$SDK/SDKSettings.json"
cat > "$SDK/usr/lib/swift/libswiftCore.tbd" <<'TBD'
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-macos, x86_64-macos ]
install-name: '/usr/lib/swift/libswiftCore.dylib'
...
TBD
printf 'void fixture(void) {}\n' > "$TEST_DIR/runtime.c"
printf 'extern void fixture(void); int main(void) { fixture(); return 0; }\n' > "$TEST_DIR/main.c"
for arch in arm64 x86_64; do
  mkdir "$TEST_DIR/$arch"
  xcrun clang -arch "$arch" -mmacosx-version-min=15.0 -Wl,-adhoc_codesign -dynamiclib "$TEST_DIR/runtime.c" \
    -install_name @rpath/libswiftCompatibilityFixture.dylib -o "$TEST_DIR/$arch/libswiftCompatibilityFixture.dylib"
  xcrun clang -arch "$arch" -mmacosx-version-min=15.0 "$TEST_DIR/main.c" -L"$TEST_DIR/$arch" \
    -lswiftCompatibilityFixture -Wl,-rpath,@loader_path -o "$TEST_DIR/$arch/good"
  xcrun clang -arch "$arch" -mmacosx-version-min=15.0 "$TEST_DIR/main.c" -L"$TEST_DIR/$arch" \
    -lswiftCompatibilityFixture -o "$TEST_DIR/$arch/no-rpath"
done
lipo -create "$TEST_DIR/arm64/libswiftCompatibilityFixture.dylib" "$TEST_DIR/x86_64/libswiftCompatibilityFixture.dylib" \
  -output "$TEST_DIR/libswiftCompatibilityFixture.dylib"
# Both permutations prove that another architecture's rpath cannot hide the defect.
for broken_arch in arm64 x86_64; do
  other_arch=arm64
  [[ "$broken_arch" != arm64 ]] || other_arch=x86_64
  lipo -create "$TEST_DIR/$broken_arch/no-rpath" "$TEST_DIR/$other_arch/good" -output "$TEST_DIR/broken"
  if "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" --runtime-sdk-root "$TEST_DIR/SDK" \
    "$TEST_DIR/broken" "$TEST_DIR" > "$TEST_DIR/result" 2>&1; then
    echo "Verifier accepted missing $broken_arch compatibility rpath" >&2; exit 1
  fi
  if ! rg -F "$broken_arch" "$TEST_DIR/result" >/dev/null ||
    ! rg -F 'no executable-relative LC_RPATH' "$TEST_DIR/result" >/dev/null; then
    cat "$TEST_DIR/result" >&2; exit 1
  fi
done
lipo -create "$TEST_DIR/arm64/good" "$TEST_DIR/x86_64/good" -output "$TEST_DIR/good"
"$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" --runtime-sdk-root "$TEST_DIR/SDK" \
  "$TEST_DIR/good" "$TEST_DIR" > "$TEST_DIR/result" 2>&1
printf 'test-swift-runtime-slice-rpaths: ok\n'
