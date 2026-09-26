#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR=$(mktemp -d /tmp/peekaboo-swift-runtime-test.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT

# Link inert fixtures against a synthetic runtime; never execute them or alter the system runtime.
printf '%s\n' 'void swift_initBorrow(void) {}' 'void swift_initBorrowRelated(void) {}' > "$TEST_DIR/Runtime.c"
printf '%s\n' 'extern void swift_initBorrow(void);' \
    'int main(void) { swift_initBorrow(); return 0; }' > "$TEST_DIR/Strong.c"
printf '%s\n' 'extern void swift_initBorrow(void) __attribute__((weak_import));' \
    'int main(void) { if (swift_initBorrow) swift_initBorrow(); return 0; }' > "$TEST_DIR/Weak.c"
printf '%s\n' 'extern void swift_initBorrowRelated(void);' \
    'int main(void) { swift_initBorrowRelated(); return 0; }' > "$TEST_DIR/Related.c"
for architecture in arm64 x86_64; do
    mkdir "$TEST_DIR/$architecture"
    xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 -dynamiclib "$TEST_DIR/Runtime.c" \
        -install_name /usr/lib/swift/libswiftCore.dylib -o "$TEST_DIR/$architecture/libswiftCore.dylib"
    for kind in Strong Weak Related; do
        xcrun clang -arch "$architecture" -mmacosx-version-min=15.0 "$TEST_DIR/$kind.c" \
            -L"$TEST_DIR/$architecture" -lswiftCore -o "$TEST_DIR/$kind-$architecture"
    done
    if "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" \
        "$TEST_DIR/Strong-$architecture" "$TEST_DIR" >"$TEST_DIR/refusal" 2>&1; then
        echo "Verifier accepted an unsupported strong Swift runtime import ($architecture)" >&2
        exit 1
    fi
    grep -Fq 'Unsupported strong macOS 27 Swift runtime import: _swift_initBorrow' "$TEST_DIR/refusal"
    "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" "$TEST_DIR/Weak-$architecture" "$TEST_DIR"
    "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" "$TEST_DIR/Related-$architecture" "$TEST_DIR"
    "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" "$TEST_DIR/$architecture/libswiftCore.dylib" "$TEST_DIR"
done
for strong_architecture in arm64 x86_64; do
    if [ "$strong_architecture" = arm64 ]; then weak_architecture=x86_64; else weak_architecture=arm64; fi
    lipo -create "$TEST_DIR/Strong-$strong_architecture" "$TEST_DIR/Weak-$weak_architecture" \
        -output "$TEST_DIR/mixed-universal"
    if "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" \
        "$TEST_DIR/mixed-universal" "$TEST_DIR" >"$TEST_DIR/refusal" 2>&1; then
        echo "Verifier missed the unsupported $strong_architecture import in a universal binary" >&2
        exit 1
    fi
    grep -Fq 'Unsupported strong macOS 27 Swift runtime import: _swift_initBorrow' "$TEST_DIR/refusal"
done

printf '%s\n' 'not a Mach-O executable' > "$TEST_DIR/invalid-binary"
chmod +x "$TEST_DIR/invalid-binary"
if "$ROOT_DIR/scripts/verify-swift-runtime-libraries.sh" \
    "$TEST_DIR/invalid-binary" "$TEST_DIR" >"$TEST_DIR/refusal" 2>&1; then
    echo "Verifier accepted failed symbol inspection" >&2
    exit 1
fi
grep -Fq 'Unable to inspect Swift runtime imports' "$TEST_DIR/refusal"

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
