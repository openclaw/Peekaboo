#!/bin/bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <executable> <runtime-library-directory>" >&2
    exit 2
fi

EXECUTABLE_PATH="$1"
LIBRARY_DIR="$2"
EXPECTED_IDENTITY="${MAC_RELEASE_CODESIGN_IDENTITY:-}"
EXPECTED_TEAM_ID="${MAC_RELEASE_CODESIGN_TEAM_ID:-}"

[ -x "$EXECUTABLE_PATH" ] || {
    echo "Executable missing or not executable: $EXECUTABLE_PATH" >&2
    exit 1
}

# An availability-qualified Swift Ref can still emit this strong runtime import.
# The Span back-deployment library does not provide it; dyld fails before main on macOS 26 and earlier.
undefined_symbols=$(nm -arch all -m -u "$EXECUTABLE_PATH") || {
    echo "Unable to inspect Swift runtime imports: $EXECUTABLE_PATH" >&2
    exit 1
}
if awk '/\(undefined\)/ && !/ weak / && / _swift_initBorrow([[:space:]]|$)/ { found = 1 }
    END { exit !found }' <<< "$undefined_symbols"; then
    echo "Unsupported strong macOS 27 Swift runtime import: _swift_initBorrow ($EXECUTABLE_PATH)" >&2
    exit 1
fi

compatibility_dependencies=$(otool -L "$EXECUTABLE_PATH" | awk '
    $1 ~ /^@rpath\/libswiftCompatibility.*\.dylib$/ { print $1 }
')

if [ -z "$compatibility_dependencies" ]; then
    echo "No Swift compatibility runtime dependencies: $EXECUTABLE_PATH"
    exit 0
fi

loader_rpath_found=false
while IFS= read -r rpath; do
    case "$rpath" in
        @loader_path|@executable_path)
            loader_rpath_found=true
            ;;
    esac
done < <(otool -l "$EXECUTABLE_PATH" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
')

if [ "$loader_rpath_found" != true ]; then
    echo "Swift compatibility dependency has no executable-relative LC_RPATH: $EXECUTABLE_PATH" >&2
    exit 1
fi

binary_architectures=$(lipo -archs "$EXECUTABLE_PATH")
while IFS= read -r dependency; do
    [ -n "$dependency" ] || continue
    library_name=${dependency#@rpath/}
    library_path="$LIBRARY_DIR/$library_name"

    [ -f "$library_path" ] || {
        echo "Dangling Swift compatibility dependency: $dependency (missing $library_path)" >&2
        exit 1
    }
    codesign --verify --strict --verbose=2 "$library_path"

    if [ -n "$EXPECTED_IDENTITY" ] && [ "$EXPECTED_IDENTITY" != "-" ]; then
        authority=$(codesign -dv --verbose=4 "$library_path" 2>&1 | sed -n 's/^Authority=//p' | sed -n '1p')
        [ "$authority" = "$EXPECTED_IDENTITY" ] || {
            echo "Swift compatibility library signer mismatch: expected '$EXPECTED_IDENTITY', got '$authority'" >&2
            exit 1
        }
    fi

    if [ -n "$EXPECTED_TEAM_ID" ]; then
        team_id=$(codesign -dv --verbose=4 "$library_path" 2>&1 | sed -n 's/^TeamIdentifier=//p' | sed -n '1p')
        [ "$team_id" = "$EXPECTED_TEAM_ID" ] || {
            echo "Swift compatibility library TeamIdentifier mismatch: expected '$EXPECTED_TEAM_ID', got '$team_id'" >&2
            exit 1
        }
    fi

    library_architectures=$(lipo -archs "$library_path")
    for architecture in $binary_architectures; do
        case " $library_architectures " in
            *" $architecture "*) ;;
            *)
                echo "Swift compatibility library is missing $architecture: $library_path" >&2
                exit 1
                ;;
        esac
    done

    echo "Resolved Swift compatibility dependency: $dependency -> $library_path"
done <<< "$compatibility_dependencies"
