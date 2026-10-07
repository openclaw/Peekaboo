#!/bin/bash
set -euo pipefail

INSPECTION_ONLY=false
if [[ "$#" -eq 1 && "${1:-}" == --inspection-only ]]; then
    INSPECTION_ONLY=true
    shift
fi
if [[ "$#" -ne 0 ]]; then
    echo "Usage: $0 [--inspection-only]" >&2
    exit 2
fi

# The release preflight exports the publication signer for its signed CLI build; these fixtures are
# ad-hoc signed, so the verifier must not inherit that expectation.
unset MAC_RELEASE_CODESIGN_IDENTITY MAC_RELEASE_CODESIGN_TEAM_ID SIGN_IDENTITY

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
bash "$ROOT_DIR/scripts/test-swift-runtime-slice-rpaths.sh"
TEST_DIR=$(mktemp -d /tmp/peekaboo-swift-runtime-test.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

EXPORTS_TOOL="$ROOT_DIR/scripts/swift-runtime-exports.py"
SDK="$TEST_DIR/SDK/MacOSX15.0.sdk"
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
    "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" --runtime-sdk-root "$TEST_DIR/SDK" "$@"
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
python3 -B - "$EXPORTS_TOOL" "$SDK" <<'PY'
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location('swift_runtime_exports', sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
libraries = {}
for path in sorted((Path(sys.argv[2]) / 'usr/lib/swift').glob('*.tbd')):
    module.parse_tbd(path, path.read_bytes(), libraries)
for arch in module.ARCHES:
    assert {"_quoted'symbol", '_threadLocalExport', '_OBJC_CLASS_$_FixtureClass',
            '_OBJC_METACLASS_$_FixtureClass', '_OBJC_EHTYPE_$_FixtureException',
            '_OBJC_IVAR_$_FixtureClass.value'} <= libraries['libswiftCore'].symbols[arch]
    symbols = set().union(*(lib.symbols[arch] for lib in libraries.values()))
    assert not any(symbol.startswith('$ld$') for symbol in symbols)
    assert '_swift_ignoredTarget' not in symbols and '_ignoredLibrary' not in symbols
PY

# Remove the errno edge in a second SDK; symbols remain in Foundation1.
mkdir "$TEST_DIR/NoReexportRoot"
cp -R "$SDK" "$TEST_DIR/NoReexportRoot/MacOSX15.0.sdk"
sed '/^reexported-libraries:/,$d' "$SDK/usr/lib/swift/libswift_errno.tbd" \
    > "$TEST_DIR/NoReexportRoot/MacOSX15.0.sdk/usr/lib/swift/libswift_errno.tbd"

# Link inert fixtures against a synthetic runtime; never execute them or alter the system runtime.
printf '%s\n' 'void swift_initBorrow(void) {}' 'void swift_initBorrowRelated(void) {}' \
    'void swift_futureRuntimeEntry(void) {}' 'void swift_intelOnly(void) {}' \
    'void swift_armOnly(void) {}' 'void swift_ignoredTarget(void) {}' \
    'void weakExport(void) {}' 'void symbolReexport(void) {}' > "$TEST_DIR/Runtime.c"
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
for entry in weakExport symbolReexport secondDocument; do
    printf 'extern void %s(void);\nint main(void) { %s(); return 0; }\n' "$entry" "$entry" \
        > "$TEST_DIR/$entry.c"
done
printf '%s\n' 'void secondDocument(void) {}' > "$TEST_DIR/SecondDocumentRuntime.c"
printf '%s\n' 'void swift_reexportedEntry(void) {}' > "$TEST_DIR/Foundation.c"
printf '%s\n' 'void synthetic_errno(void) {}' > "$TEST_DIR/Errno.c"
printf '%s\n' 'void swift_compatibilityEntry(void) {}' > "$TEST_DIR/Compatibility.c"
for architecture in arm64 x86_64; do
    mkdir "$TEST_DIR/$architecture"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 -dynamiclib "$TEST_DIR/Runtime.c" \
        -install_name /usr/lib/swift/libswiftCore.dylib -o "$TEST_DIR/$architecture/libswiftCore.dylib"
    for kind in Strong Weak Related Future FutureWeak intelOnly armOnly ignoredTarget weakExport symbolReexport; do
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
    verify_fixture "$TEST_DIR/weakExport-$architecture" "$TEST_DIR"
    verify_fixture "$TEST_DIR/symbolReexport-$architecture" "$TEST_DIR"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 -dynamiclib "$TEST_DIR/SecondDocumentRuntime.c" \
        -install_name /usr/lib/swift/libswiftSecondDocument.dylib \
        -o "$TEST_DIR/$architecture/libswiftSecondDocument.dylib"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 "$TEST_DIR/secondDocument.c" \
        -L"$TEST_DIR/$architecture" -lswiftSecondDocument -o "$TEST_DIR/SecondDocument-$architecture"
    verify_fixture "$TEST_DIR/SecondDocument-$architecture" "$TEST_DIR"

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
        "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" --runtime-sdk-root "$TEST_DIR/NoReexportRoot" \
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
# Some nm versions return success for this text fixture; the subsequent native
# architecture inspection must still reject it before any runtime audit passes.
if ! grep -Fq 'Unable to inspect Swift runtime imports' "$TEST_DIR/refusal" &&
   ! grep -Fxq "swift-runtime-exports: command failed: lipo -archs $TEST_DIR/invalid-binary" "$TEST_DIR/refusal"; then
    cat "$TEST_DIR/refusal" >&2
    echo "Invalid executable lacked a known native inspection refusal" >&2
    exit 1
fi

# Selection ignores SDKs below the deployment target or at/above the deliberate macOS 27 limit.
mkdir "$TEST_DIR/selection"
for sdk_version in 14.0 15.0 26.0 27.0; do
    selection_sdk="$TEST_DIR/selection/MacOSX$sdk_version.sdk"
    cp -R "$SDK" "$selection_sdk"
    sdk_identity "$selection_sdk" "$sdk_version"
done
python3 "$EXPORTS_TOOL" audit --sdk-root "$TEST_DIR/selection" "$TEST_DIR/Related-arm64" \
    > "$TEST_DIR/selection-output" 2> "$TEST_DIR/selection-candidates"
selection_sdk=$(cd "$TEST_DIR/selection/MacOSX15.0.sdk" && pwd -P)
grep -Fq "Swift runtime baseline: macOS 15.0 (FixtureBuild) $selection_sdk sha256:" \
    "$TEST_DIR/selection-output"
grep -Fq 'ineligible (below minimum macOS 15.0)' "$TEST_DIR/selection-candidates"
grep -Fq 'ineligible (not older than macOS 27)' "$TEST_DIR/selection-candidates"
mkdir "$TEST_DIR/ineligible" "$TEST_DIR/only-27" "$TEST_DIR/duplicate"
cp -R "$TEST_DIR/selection/MacOSX14.0.sdk" "$TEST_DIR/ineligible/"
cp -R "$TEST_DIR/selection/MacOSX27.0.sdk" "$TEST_DIR/ineligible/"
cp -R "$TEST_DIR/selection/MacOSX27.0.sdk" "$TEST_DIR/only-27/"
for sdk_root in "$TEST_DIR/ineligible" "$TEST_DIR/only-27"; do
    expect_refusal 'No eligible macOS SDK for the Swift runtime audit:' \
        python3 "$EXPORTS_TOOL" audit --sdk-root "$sdk_root" "$TEST_DIR/Related-arm64"
    grep -Fq 'minimum macOS 15.0, SDK must predate macOS 27' "$TEST_DIR/refusal"
    grep -Fq 'install Command Line Tools or an Xcode' "$TEST_DIR/refusal"
done

# Equal version/build SDKs use the first realpath, irrespective of creation order or aliases.
cp -R "$SDK" "$TEST_DIR/duplicate/Last.sdk"
cp -R "$SDK" "$TEST_DIR/duplicate/First.sdk"
ln -s Last.sdk "$TEST_DIR/duplicate/Alias.sdk"
python3 "$EXPORTS_TOOL" audit --sdk-root "$TEST_DIR/only-27" --sdk-root "$TEST_DIR/duplicate" \
    "$TEST_DIR/Related-arm64" > "$TEST_DIR/duplicate-output" 2> "$TEST_DIR/duplicate-candidates"
first_sdk=$(cd "$TEST_DIR/duplicate/First.sdk" && pwd -P)
grep -Fq "Swift runtime baseline: macOS 15.0 (FixtureBuild) $first_sdk sha256:" \
    "$TEST_DIR/duplicate-output"
[ "$(grep -c 'candidate .*Last.sdk: 15.0' "$TEST_DIR/duplicate-candidates")" -eq 1 ]

# Unsupported schema additions must fail closed instead of silently dropping exports.
mkdir "$TEST_DIR/InvalidRoot"
cp -R "$SDK" "$TEST_DIR/InvalidRoot/MacOSX15.0.sdk"
invalid_tbd="$TEST_DIR/InvalidRoot/MacOSX15.0.sdk/usr/lib/swift/libswiftCore.tbd"
sed '/^tbd-version:/a\
unknown-top-level: 1\
' "$SDK/usr/lib/swift/libswiftCore.tbd" > "$invalid_tbd"
expect_refusal 'unknown tbd top-level key: unknown-top-level' \
    python3 "$EXPORTS_TOOL" audit --sdk-root "$TEST_DIR/InvalidRoot" "$TEST_DIR/Related-arm64"
sed 's/    weak-symbols:/    unknown-export-field:/' "$SDK/usr/lib/swift/libswiftCore.tbd" > "$invalid_tbd"
expect_refusal 'unknown tbd item field: unknown-export-field' \
    python3 "$EXPORTS_TOOL" audit --sdk-root "$TEST_DIR/InvalidRoot" "$TEST_DIR/Related-arm64"
printf '%s\n' '{"tapi_tbd_version": 5}' > "$invalid_tbd"
expect_refusal 'JSON/v5 tbd is unsupported' \
    python3 "$EXPORTS_TOOL" audit --sdk-root "$TEST_DIR/InvalidRoot" "$TEST_DIR/Related-arm64"

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
if [[ "$INSPECTION_ONLY" == true ]]; then
    echo "test-swift-runtime-libraries: inspection checks passed (real-runtime execution omitted by request)"
else
    "$TEST_DIR/span-probe" >/dev/null
    echo "test-swift-runtime-libraries: ok"
fi
