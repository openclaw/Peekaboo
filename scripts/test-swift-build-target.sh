#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-swift-target-test.XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
  printf 'test-swift-build-target: %s\n' "$*" >&2
  exit 1
}

mkdir -p "$TEST_DIR/fake tools" "$TEST_DIR/package with spaces" "$TEST_DIR/bin with spaces"
SWIFT_PROJECT_PATH="$(cd "$TEST_DIR/package with spaces" && pwd -P)"
export FAKE_SWIFT_BIN_DIRECTORY="$TEST_DIR/bin with spaces"
export FAKE_SWIFT_ARGV="$TEST_DIR/argv" FAKE_SWIFT_CWD="$TEST_DIR/cwd"
export FAKE_SWIFT_EXIT=0
cat > "$TEST_DIR/fake tools/swift" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\0' "$@" > "$FAKE_SWIFT_ARGV"
printf '%s\n' "$PWD" > "$FAKE_SWIFT_CWD"
if [[ "$FAKE_SWIFT_EXIT" != 0 ]]; then
  printf 'synthetic Swift failure\n' >&2
  printf '%s\n' "$FAKE_SWIFT_BIN_DIRECTORY"
  exit "$FAKE_SWIFT_EXIT"
fi
if [[ "$*" == *--show-bin-path* ]]; then
  printf '%s\n' "$FAKE_SWIFT_BIN_DIRECTORY"
fi
EOF
chmod 755 "$TEST_DIR/fake tools/swift"
# This fixture owns compiler argv only. The workspace helper's source/configuration
# gates are exercised separately by test-swift-workspace.py, with no real checkout setup.
PROJECT_ROOT="$TEST_DIR"
export PROJECT_ROOT
cat > "$TEST_DIR/fake tools/python3" <<'EOF'
#!/bin/bash
set -euo pipefail
[[ "$1" == "$PROJECT_ROOT/scripts/setup-swift-workspace.py" && "$2" == run && "$3" == --release && "$4" == -- ]]
shift 4
exec "$@"
EOF
chmod 755 "$TEST_DIR/fake tools/python3"
export PATH="$TEST_DIR/fake tools:/usr/bin:/bin"
[[ "$(command -v swift)" == "$TEST_DIR/fake tools/swift" ]] || fail 'Swift must be the fixture executable'

assert_argv() {
  printf '%s\0' "$@" > "$TEST_DIR/expected-argv"
  cmp -s "$TEST_DIR/expected-argv" "$FAKE_SWIFT_ARGV" || fail 'Swift argv changed'
  [[ "$(<"$FAKE_SWIFT_CWD")" == "$SWIFT_PROJECT_PATH" ]] || fail 'Swift ran outside the requested package'
}

build_script="$ROOT_DIR/scripts/build-swift-universal.sh"
# shellcheck disable=SC2016 # Match the literal source statement.
grep -Fxq 'source "$PROJECT_ROOT/scripts/resolve-swift-binary-path.sh"' "$build_script" || \
  fail 'universal compilation does not load the shared target'
set +u # The universal builder does not enable nounset.
shell_options="$-"
# shellcheck source=scripts/resolve-swift-binary-path.sh
source "$ROOT_DIR/scripts/resolve-swift-binary-path.sh"
[[ "$-" == "$shell_options" && ! -e "$FAKE_SWIFT_ARGV" ]] || fail 'sourcing the target had side effects'
set -u
minimum_macos="$(sed -n 's/^[[:space:]]*\.macOS(\.v\([0-9][0-9]*\)),[[:space:]]*$/\1/p' \
  "$ROOT_DIR/Apps/CLI/Package.swift")"
[[ "$minimum_macos" == 15 && "${#SWIFT_X86_64_TARGET_ARGS[@]}" == 2 &&
   "${SWIFT_X86_64_TARGET_ARGS[0]}" == --triple &&
   "${SWIFT_X86_64_TARGET_ARGS[1]}" == "x86_64-apple-macosx${minimum_macos}.0" ]] || \
  fail 'Intel target and the CLI package minimum must agree on macOS 15.0'

# Execute only the actual compile subshells with fake Swift, never the wrapper's
# reset, provenance, signing, or packaging phases.
# shellcheck disable=SC2329 # Called by the extracted compile subshells.
pipe_build_output() { cat; }
# shellcheck disable=SC2034 # Consumed by the extracted compile subshells.
SWIFT_RESOLUTION_ARGS=(--only-use-versions-from-resolved-file)
# shellcheck disable=SC2034 # Consumed by the extracted compile subshells.
SWIFT_OPTIMIZATION_FLAGS='-Xswiftc -Osize -Xlinker -dead_strip'
for architecture in arm64 x86_64; do
  awk -v architecture="$architecture" '
    index($0, "Building for " architecture " ") { found = 1; next }
    found && /^\($/ { printing = 1 }
    printing { print }
    printing && /^\)$/ { complete = 1; exit }
    END { if (!complete) exit 1 }
  ' "$build_script" > "$TEST_DIR/compile-snippet.sh" || fail "missing $architecture compile subshell"
  # shellcheck source=/dev/null
  source "$TEST_DIR/compile-snippet.sh"
  if [[ "$architecture" == x86_64 ]]; then
    expected_target=(--triple x86_64-apple-macosx15.0)
  else
    expected_target=(--arch arm64)
  fi
  assert_argv build --only-use-versions-from-resolved-file "${expected_target[@]}" \
    -c release -Xswiftc -Osize -Xlinker -dead_strip

  # Keep the four-argument architecture contract, including both CLI products.
  for configuration in release debug; do
    for binary_name in peekaboo peekaboo-certification-controller; do
      : > "$FAKE_SWIFT_BIN_DIRECTORY/$binary_name"
      actual_path="$(/bin/bash "$ROOT_DIR/scripts/resolve-swift-binary-path.sh" \
        "$SWIFT_PROJECT_PATH" "$architecture" "$configuration" "$binary_name")"
      [[ "$actual_path" == "$FAKE_SWIFT_BIN_DIRECTORY/$binary_name" ]] || fail 'lookup changed the binary path'
      assert_argv build "${expected_target[@]}" -c "$configuration" --show-bin-path
    done
  done

  result=0
  /bin/bash "$ROOT_DIR/scripts/resolve-swift-binary-path.sh" \
    "$SWIFT_PROJECT_PATH" "$architecture" release 'missing binary' \
    > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr" || result=$?
  [[ "$result" == 1 && ! -s "$TEST_DIR/stdout" ]] || fail 'missing binary did not fail closed'
  grep -Fq "missing binary was not found at $FAKE_SWIFT_BIN_DIRECTORY/missing binary" "$TEST_DIR/stderr" || \
    fail 'missing binary diagnostic lost its path'
  assert_argv build "${expected_target[@]}" -c release --show-bin-path

  result=0
  FAKE_SWIFT_EXIT=37 /bin/bash "$ROOT_DIR/scripts/resolve-swift-binary-path.sh" \
    "$SWIFT_PROJECT_PATH" "$architecture" release peekaboo \
    > "$TEST_DIR/stdout" 2> "$TEST_DIR/stderr" || result=$?
  [[ "$result" == 37 && ! -s "$TEST_DIR/stdout" && "$(<"$TEST_DIR/stderr")" == 'synthetic Swift failure' ]] || \
    fail 'failed Swift lookup accepted its output or changed the exit/diagnostic'
  assert_argv build "${expected_target[@]}" -c release --show-bin-path
done

printf 'test-swift-build-target: ok (fake Swift only)\n'
