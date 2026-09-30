#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=$(mktemp -d /tmp/peekaboo-swift-runtime-test.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

EXPORTS_TOOL="$ROOT_DIR/scripts/swift-runtime-exports.py"
SDK="$TEST_DIR/SDK/MacOSX15.0.sdk"
BASELINES="$TEST_DIR/baselines"
mkdir -p "$SDK/usr/lib/swift"

sdk_identity() {
    python3 - "$1" "$2" <<'PY'
import json
from pathlib import Path
import plistlib
import sys

sdk, version = Path(sys.argv[1]), sys.argv[2]
(sdk / 'SDKSettings.json').write_text(json.dumps({'Version': version, 'CanonicalName': 'macosx' + version}))
system = sdk / 'System/Library/CoreServices'
system.mkdir(parents=True, exist_ok=True)
(system / 'SystemVersion.plist').write_bytes(plistlib.dumps({'ProductBuildVersion': 'FixtureBuild'}))
PY
}

verify_fixture() {
    "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" --runtime-baseline-dir "$BASELINES" "$@"
}

expect_refusal() {
    local message="$1"
    shift
    if "$@" >"$TEST_DIR/refusal" 2>&1; then
        echo "Expected refusal: $message" >&2
        exit 1
    fi
    if ! grep -Fq -- "$message" "$TEST_DIR/refusal"; then
        cat "$TEST_DIR/refusal" >&2
        echo "Missing refusal message: $message" >&2
        exit 1
    fi
}

sdk_identity "$SDK" 15.0
cat > "$SDK/usr/lib/swift/libswiftCore.tbd" <<'EOF'
--- !tapi-tbd
tbd-version: 4
targets: [ arm64e-macos, x86_64-macos, arm64-maccatalyst ]
install-name: '/usr/lib/swift/libswiftCore.dylib'
exports:
  - targets: [ arm64e-macos, x86_64-macos ]
    symbols: [ '_swift_initBorrow', _swift_initBorrowRelated,
               '_quoted''symbol', '$ld$previous$synthetic$directive', ]
    weak-symbols: [ _weakExport ]
    thread-local-symbols: [ _threadLocalExport ]
    objc-classes: [ 'FixtureClass' ]
    objc-eh-types: [ FixtureException ]
    objc-ivars: [ 'FixtureClass.value' ]
  - targets: [ x86_64-macos ]
    symbols: [ _swift_intelOnly ]
  - targets: [ arm64e-macos ]
    symbols: [ _swift_armOnly ]
  - targets: [ arm64-maccatalyst, x86_64-maccatalyst, x86_64h-macos, arm64-ios ]
    symbols: [ _swift_ignoredTarget ]
reexports:
  - targets: [ arm64e-macos, x86_64-macos ]
    symbols: [ _symbolReexport ]
...
EOF
cat > "$SDK/usr/lib/swift/libswift_errno.tbd" <<'EOF'
--- !tapi-tbd
tbd-version: 4
targets: [ arm64e-macos, x86_64-macos ]
install-name: '/usr/lib/swift/libswift_errno.dylib'
reexported-libraries:
  - targets: [ arm64e-macos, x86_64-macos ]
    libraries: [ '/usr/lib/swift/libswift_DarwinFoundation1.dylib', ]
...
EOF
cat > "$SDK/usr/lib/swift/libswift_DarwinFoundation1.tbd" <<'EOF'
--- !tapi-tbd
tbd-version: 4
targets: [ arm64e-macos, x86_64-macos ]
install-name: '/usr/lib/swift/libswift_DarwinFoundation1.dylib'
reexported-libraries:
  - targets: [ arm64e-macos, x86_64-macos ]
    libraries: [ '/usr/lib/swift/libswift_errno.dylib' ]
exports:
  - targets: [ arm64e-macos, x86_64-macos ]
    symbols: [ _swift_reexportedEntry ]
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-macos, x86_64-macos ]
install-name: '/usr/lib/swift/libswiftSecondDocument.dylib'
exports:
  - targets: [ arm64-macos, x86_64-macos ]
    symbols: [ _secondDocument ]
--- !tapi-tbd
tbd-version: 4
targets: [ arm64-maccatalyst ]
install-name: '/usr/lib/swift/libswiftIgnored.dylib'
exports:
  - targets: [ arm64-maccatalyst ]
    symbols: [ _ignoredLibrary ]
...
EOF
python3 "$EXPORTS_TOOL" generate --sdk "$SDK" --output "$BASELINES/macos-15.0.exports"
python3 "$EXPORTS_TOOL" check --sdk "$SDK" --baseline "$BASELINES/macos-15.0.exports"
python3 - "$BASELINES/macos-15.0.exports" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
lines = set(text.splitlines())
assert {'* _swift_initBorrow', '* _swift_initBorrowRelated', "* _quoted'symbol",
        '* _weakExport', '* _threadLocalExport', '* _symbolReexport',
        '* _OBJC_CLASS_$_FixtureClass', '* _OBJC_METACLASS_$_FixtureClass',
        '* _OBJC_EHTYPE_$_FixtureException', '* _OBJC_IVAR_$_FixtureClass.value',
        'arm64 _swift_armOnly', 'x86_64 _swift_intelOnly',
        '[libswiftSecondDocument]', '* _secondDocument',
        'reexport * libswift_DarwinFoundation1', 'reexport * libswift_errno'} <= lines
assert '$ld$' not in text and '_swift_ignoredTarget' not in text and 'libswiftIgnored' not in text
PY

# Regenerate a second baseline with the errno edge removed; symbols remain in Foundation1.
cp -R "$SDK" "$TEST_DIR/NoReexport.sdk"
sed '/^reexported-libraries:/,$d' "$SDK/usr/lib/swift/libswift_errno.tbd" \
    > "$TEST_DIR/NoReexport.sdk/usr/lib/swift/libswift_errno.tbd"
python3 "$EXPORTS_TOOL" generate --sdk "$TEST_DIR/NoReexport.sdk" \
    --output "$TEST_DIR/no-reexport/macos-15.0.exports"

# Link inert fixtures against a synthetic runtime; never execute them or alter the system runtime.
printf '%s\n' 'void swift_initBorrow(void) {}' 'void swift_initBorrowRelated(void) {}' \
    'void swift_futureRuntimeEntry(void) {}' 'void swift_intelOnly(void) {}' \
    'void swift_armOnly(void) {}' 'void swift_ignoredTarget(void) {}' > "$TEST_DIR/Runtime.c"
printf '%s\n' 'extern void swift_initBorrow(void);' \
    'int main(void) { swift_initBorrow(); return 0; }' > "$TEST_DIR/Strong.c"
printf '%s\n' 'extern void swift_initBorrow(void) __attribute__((weak_import));' \
    'int main(void) { if (swift_initBorrow) swift_initBorrow(); return 0; }' > "$TEST_DIR/Weak.c"
printf '%s\n' 'extern void swift_initBorrowRelated(void);' \
    'int main(void) { swift_initBorrowRelated(); return 0; }' > "$TEST_DIR/Related.c"
printf '%s\n' 'extern void swift_futureRuntimeEntry(void);' \
    'int main(void) { swift_futureRuntimeEntry(); return 0; }' > "$TEST_DIR/Future.c"
printf '%s\n' 'extern void swift_futureRuntimeEntry(void) __attribute__((weak_import));' \
    'int main(void) { if (swift_futureRuntimeEntry) swift_futureRuntimeEntry(); return 0; }' > "$TEST_DIR/FutureWeak.c"
for entry in intelOnly armOnly ignoredTarget reexportedEntry compatibilityEntry; do
    printf 'extern void swift_%s(void);\nint main(void) { swift_%s(); return 0; }\n' "$entry" "$entry" \
        > "$TEST_DIR/$entry.c"
done
printf '%s\n' 'void swift_reexportedEntry(void) {}' > "$TEST_DIR/Foundation.c"
printf '%s\n' 'void synthetic_errno(void) {}' > "$TEST_DIR/Errno.c"
printf '%s\n' 'void swift_compatibilityEntry(void) {}' > "$TEST_DIR/Compatibility.c"
for architecture in arm64 x86_64; do
    mkdir "$TEST_DIR/$architecture"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 -dynamiclib "$TEST_DIR/Runtime.c" \
        -install_name /usr/lib/swift/libswiftCore.dylib -o "$TEST_DIR/$architecture/libswiftCore.dylib"
    for kind in Strong Weak Related Future FutureWeak intelOnly armOnly ignoredTarget; do
        xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 "$TEST_DIR/$kind.c" \
            -L"$TEST_DIR/$architecture" -lswiftCore -o "$TEST_DIR/$kind-$architecture"
    done
    if verify_fixture \
        "$TEST_DIR/Strong-$architecture" "$TEST_DIR" >"$TEST_DIR/refusal" 2>&1; then
        echo "Verifier accepted an unsupported strong Swift runtime import ($architecture)" >&2
        exit 1
    fi
    grep -Fq 'Unsupported strong macOS 27 Swift runtime import: _swift_initBorrow' "$TEST_DIR/refusal"
    verify_fixture "$TEST_DIR/Weak-$architecture" "$TEST_DIR"
    verify_fixture "$TEST_DIR/Related-$architecture" "$TEST_DIR"
    verify_fixture "$TEST_DIR/$architecture/libswiftCore.dylib" "$TEST_DIR"

    expect_refusal 'Strong Swift runtime imports missing from' \
        verify_fixture "$TEST_DIR/Future-$architecture" "$TEST_DIR"
    grep -Fxq "  $architecture libswiftCore _swift_futureRuntimeEntry" "$TEST_DIR/refusal"
    verify_fixture "$TEST_DIR/FutureWeak-$architecture" "$TEST_DIR"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 "$TEST_DIR/Related.c" \
        -L"$TEST_DIR/$architecture" -lswiftCore -Wl,-flat_namespace -o "$TEST_DIR/Flat-$architecture"
    expect_refusal "$architecture unrecognized or unattributed undefined symbol: (undefined) external" \
        verify_fixture "$TEST_DIR/Flat-$architecture" "$TEST_DIR"

    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 -dynamiclib "$TEST_DIR/Runtime.c" \
        -install_name /usr/lib/swift/libswiftFutureKit.dylib -o "$TEST_DIR/$architecture/libswiftFutureKit.dylib"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 "$TEST_DIR/Future.c" \
        -L"$TEST_DIR/$architecture" -lswiftFutureKit -o "$TEST_DIR/FutureKit-$architecture"
    expect_refusal "$architecture libswiftFutureKit _swift_futureRuntimeEntry" \
        verify_fixture "$TEST_DIR/FutureKit-$architecture" "$TEST_DIR"

    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 -dynamiclib "$TEST_DIR/Foundation.c" \
        -install_name /usr/lib/swift/libswift_DarwinFoundation1.dylib \
        -o "$TEST_DIR/$architecture/libswift_DarwinFoundation1.dylib"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 -dynamiclib "$TEST_DIR/Errno.c" \
        -install_name /usr/lib/swift/libswift_errno.dylib \
        -Wl,-reexport_library,"$TEST_DIR/$architecture/libswift_DarwinFoundation1.dylib" \
        -o "$TEST_DIR/$architecture/libswift_errno.dylib"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 "$TEST_DIR/reexportedEntry.c" \
        -L"$TEST_DIR/$architecture" -lswift_errno -o "$TEST_DIR/Reexport-$architecture"
    nm -arch "$architecture" -m -u "$TEST_DIR/Reexport-$architecture" > "$TEST_DIR/reexport-nm"
    grep -Fq '_swift_reexportedEntry (from libswift_errno)' "$TEST_DIR/reexport-nm"
    verify_fixture "$TEST_DIR/Reexport-$architecture" "$TEST_DIR"
    expect_refusal "$architecture libswift_errno _swift_reexportedEntry" \
        "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" --runtime-baseline-dir "$TEST_DIR/no-reexport" \
        "$TEST_DIR/Reexport-$architecture" "$TEST_DIR"

    if [ "$architecture" = x86_64 ]; then
        supported=intelOnly
        unsupported=armOnly
    else
        supported=armOnly
        unsupported=intelOnly
    fi
    verify_fixture "$TEST_DIR/$supported-$architecture" "$TEST_DIR"
    expect_refusal "$architecture libswiftCore _swift_$unsupported" \
        verify_fixture "$TEST_DIR/$unsupported-$architecture" "$TEST_DIR"
    expect_refusal "$architecture libswiftCore _swift_ignoredTarget" \
        verify_fixture "$TEST_DIR/ignoredTarget-$architecture" "$TEST_DIR"

    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 -dynamiclib "$TEST_DIR/Compatibility.c" \
        -install_name @rpath/libswiftCompatibilityTest.dylib \
        -o "$TEST_DIR/$architecture/libswiftCompatibilityTest.dylib"
    codesign --force --sign - "$TEST_DIR/$architecture/libswiftCompatibilityTest.dylib"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 "$TEST_DIR/compatibilityEntry.c" \
        -L"$TEST_DIR/$architecture" -lswiftCompatibilityTest -Wl,-rpath,@loader_path \
        -o "$TEST_DIR/$architecture/Compatibility"
    verify_fixture "$TEST_DIR/$architecture/Compatibility" "$TEST_DIR/$architecture"
done
for strong_architecture in arm64 x86_64; do
    if [ "$strong_architecture" = arm64 ]; then weak_architecture=x86_64; else weak_architecture=arm64; fi
    lipo -create "$TEST_DIR/Strong-$strong_architecture" "$TEST_DIR/Weak-$weak_architecture" \
        -output "$TEST_DIR/mixed-universal"
    if verify_fixture \
        "$TEST_DIR/mixed-universal" "$TEST_DIR" >"$TEST_DIR/refusal" 2>&1; then
        echo "Verifier missed the unsupported $strong_architecture import in a universal binary" >&2
        exit 1
    fi
    grep -Fq 'Unsupported strong macOS 27 Swift runtime import: _swift_initBorrow' "$TEST_DIR/refusal"

    lipo -create "$TEST_DIR/Future-$strong_architecture" "$TEST_DIR/FutureWeak-$weak_architecture" \
        -output "$TEST_DIR/future-mixed-universal"
    expect_refusal 'Strong Swift runtime imports missing from' \
        verify_fixture "$TEST_DIR/future-mixed-universal" "$TEST_DIR"
    grep -Fxq "  $strong_architecture libswiftCore _swift_futureRuntimeEntry" "$TEST_DIR/refusal"
    if grep -Eq "^  $weak_architecture " "$TEST_DIR/refusal"; then
        echo "Verifier reported the weak slice of a mixed universal binary" >&2
        exit 1
    fi
done

printf '%s\n' 'not a Mach-O executable' > "$TEST_DIR/invalid-binary"
chmod +x "$TEST_DIR/invalid-binary"
if verify_fixture \
    "$TEST_DIR/invalid-binary" "$TEST_DIR" >"$TEST_DIR/refusal" 2>&1; then
    echo "Verifier accepted failed symbol inspection" >&2
    exit 1
fi
grep -Fq 'Unable to inspect Swift runtime imports' "$TEST_DIR/refusal"

# Selection ignores baselines below the deployment target and prefers the oldest eligible SDK.
cp -R "$SDK" "$TEST_DIR/Selection.sdk"
for sdk_version in 14.0 15.0 26.0; do
    sdk_identity "$TEST_DIR/Selection.sdk" "$sdk_version"
    python3 "$EXPORTS_TOOL" generate --sdk "$TEST_DIR/Selection.sdk" \
        --output "$TEST_DIR/selection/macos-$sdk_version.exports"
done
python3 "$EXPORTS_TOOL" audit --baseline-dir "$TEST_DIR/selection" "$TEST_DIR/Related-arm64" \
    > "$TEST_DIR/selection-output"
grep -Fq "Swift runtime baseline: macOS 15.0 (FixtureBuild, Selection.sdk) from $TEST_DIR/selection/macos-15.0.exports" \
    "$TEST_DIR/selection-output"
mkdir "$TEST_DIR/too-old" "$TEST_DIR/duplicate"
cp "$TEST_DIR/selection/macos-14.0.exports" "$TEST_DIR/too-old/"
expect_refusal 'No Swift runtime baseline covers' \
    python3 "$EXPORTS_TOOL" audit --baseline-dir "$TEST_DIR/too-old" "$TEST_DIR/Related-arm64"
cp "$BASELINES/macos-15.0.exports" "$TEST_DIR/duplicate/one.exports"
cp "$BASELINES/macos-15.0.exports" "$TEST_DIR/duplicate/two.exports"
expect_refusal 'duplicate baseline version' \
    python3 "$EXPORTS_TOOL" audit --baseline-dir "$TEST_DIR/duplicate" "$TEST_DIR/Related-arm64"

# Unsupported schema additions must fail closed instead of silently dropping exports.
cp -R "$SDK" "$TEST_DIR/Invalid.sdk"
invalid_tbd="$TEST_DIR/Invalid.sdk/usr/lib/swift/libswiftCore.tbd"
sed '/^tbd-version:/a\
unknown-top-level: 1\
' "$SDK/usr/lib/swift/libswiftCore.tbd" > "$invalid_tbd"
expect_refusal 'unknown tbd top-level key: unknown-top-level' \
    python3 "$EXPORTS_TOOL" generate --sdk "$TEST_DIR/Invalid.sdk" --output "$TEST_DIR/invalid.exports"
sed 's/    weak-symbols:/    unknown-export-field:/' "$SDK/usr/lib/swift/libswiftCore.tbd" > "$invalid_tbd"
expect_refusal 'unknown tbd item field: unknown-export-field' \
    python3 "$EXPORTS_TOOL" generate --sdk "$TEST_DIR/Invalid.sdk" --output "$TEST_DIR/invalid.exports"
printf '%s\n' '{"tapi_tbd_version": 5}' > "$invalid_tbd"
expect_refusal 'JSON/v5 tbd is unsupported' \
    python3 "$EXPORTS_TOOL" generate --sdk "$TEST_DIR/Invalid.sdk" --output "$TEST_DIR/invalid.exports"

real_baseline="$ROOT_DIR/scripts/swift-runtime-baselines/macos-26.5.exports"
python3 "$EXPORTS_TOOL" check --installed --baseline "$real_baseline"
awk '/^\[/ { core = ($0 == "[libswiftCore]") } core { print }' "$real_baseline" > "$TEST_DIR/core-exports"
if grep -Eq '^(\*|arm64|x86_64) _swift_initBorrow$' "$TEST_DIR/core-exports"; then
    echo "Real baseline unexpectedly exports _swift_initBorrow from libswiftCore" >&2
    exit 1
fi
grep -Fxq '* _swift_retain' "$TEST_DIR/core-exports"

printf '%s\n' 'print(OutputSpan<UInt8>.self)' > "$TEST_DIR/SpanProbe.swift"
xcrun swiftc \
    -target "$(uname -m)-apple-macosx15.0" \
    -Xlinker -rpath \
    -Xlinker @loader_path \
    "$TEST_DIR/SpanProbe.swift" \
    -o "$TEST_DIR/span-probe"

if ! otool -L "$TEST_DIR/span-probe" | grep -Fq '@rpath/libswiftCompatibility'; then
    echo "test-swift-runtime-libraries: active toolchain emitted no compatibility dependency; skipped"
    exit 0
fi

if "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" "$TEST_DIR/span-probe" "$TEST_DIR" >/dev/null 2>&1; then
    echo "Verifier accepted a dangling Swift compatibility dependency" >&2
    exit 1
fi

"$ROOT_DIR/scripts/copy-swift-runtime-libraries.sh" "$TEST_DIR/span-probe" "$TEST_DIR"
"$TEST_DIR/span-probe" >/dev/null

echo "test-swift-runtime-libraries: ok"
