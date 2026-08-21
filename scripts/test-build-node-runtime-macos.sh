#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"
for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do unset "$secret_name"; done
TEST_DIR="$(mktemp -d /tmp/peekaboo-node-runtime-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
printf '#include <stdio.h>\nint main(void){puts("v24.15.0");return 0;}\n' > "$TEST_DIR/node.c"
printf 'fixture license\n' > "$TEST_DIR/LICENSE"

for pair in arm64:arm64 x64:x86_64; do
  label="${pair%%:*}"
  arch="${pair#*:}"
  root="$TEST_DIR/node-v24.15.0-darwin-$label"
  mkdir -p "$root/bin"
  /usr/bin/clang -arch "$arch" "$TEST_DIR/node.c" -o "$root/bin/node"
  cp "$TEST_DIR/LICENSE" "$root/LICENSE"
  /usr/bin/tar -czf "$TEST_DIR/$label.tar.gz" -C "$TEST_DIR" "node-v24.15.0-darwin-$label"
done

sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
output="$TEST_DIR/PeekabooQualificationNode.app"
/usr/bin/lipo -create \
  "$TEST_DIR/node-v24.15.0-darwin-arm64/bin/node" "$TEST_DIR/node-v24.15.0-darwin-x64/bin/node" \
  -output "$TEST_DIR/expected-node"
PEEKABOO_TERMINAL_TEST_MODE=1 \
NODE_RUNTIME_ARM64_ARCHIVE="$TEST_DIR/arm64.tar.gz" \
NODE_RUNTIME_X64_ARCHIVE="$TEST_DIR/x64.tar.gz" \
NODE_RUNTIME_ARM64_ARCHIVE_SHA="$(sha "$TEST_DIR/arm64.tar.gz")" \
NODE_RUNTIME_X64_ARCHIVE_SHA="$(sha "$TEST_DIR/x64.tar.gz")" \
NODE_RUNTIME_ARM64_BINARY_SHA="$(sha "$TEST_DIR/node-v24.15.0-darwin-arm64/bin/node")" \
NODE_RUNTIME_X64_BINARY_SHA="$(sha "$TEST_DIR/node-v24.15.0-darwin-x64/bin/node")" \
NODE_RUNTIME_LICENSE_SHA="$(sha "$TEST_DIR/LICENSE")" \
NODE_RUNTIME_UNIVERSAL_BINARY_SHA="$(sha "$TEST_DIR/expected-node")" \
NODE_RUNTIME_UNIVERSAL_BINARY_SIZE="$(/usr/bin/stat -f%z "$TEST_DIR/expected-node")" \
  "$ROOT_DIR/scripts/build-node-runtime-macos.sh" --output-app "$output" >/dev/null

[[ " $(/usr/bin/lipo -archs "$output/Contents/MacOS/node") " == *' arm64 '* ]]
[[ " $(/usr/bin/lipo -archs "$output/Contents/MacOS/node") " == *' x86_64 '* ]]
jq -e '
  .runtime_version == "24.15.0" and .identifier == "boo.peekaboo.qualification-node" and
  .inputs.arm64.url == "https://nodejs.org/dist/v24.15.0/node-v24.15.0-darwin-arm64.tar.gz" and
  .inputs.x86_64.url == "https://nodejs.org/dist/v24.15.0/node-v24.15.0-darwin-x64.tar.gz" and
  (.universal_binary_sha256 | test("^[0-9a-f]{64}$")) and .universal_binary_size > 0 and
  .architectures == ["arm64", "x86_64"] and
  .entitlements.path == "Contents/Resources/qualification-node.entitlements" and
  (.entitlements.sha256 | test("^[0-9a-f]{64}$"))
' "$output/Contents/Resources/PeekabooQualificationNodeSource.json" >/dev/null

if NODE_RUNTIME_ARM64_ARCHIVE="$TEST_DIR/arm64.tar.gz" \
  "$ROOT_DIR/scripts/build-node-runtime-macos.sh" --output-app "$TEST_DIR/rejected.app" >/dev/null 2>&1; then
  printf 'test-build-node-runtime-macos: production accepted input override\n' >&2
  exit 1
fi
printf 'test-build-node-runtime-macos: ok\n'
