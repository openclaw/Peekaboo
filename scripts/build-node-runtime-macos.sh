#!/usr/bin/env bash

# Build the exact universal Node runtime used by terminal qualification. Inputs
# are official pinned Node archives; no PATH or OpenClaw runtime is accepted.

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"
terminal_artifact_assert_build_env_is_clean || {
  printf 'build-node-runtime-macos: credentialed build environment\n' >&2
  exit 1
}

NODE_VERSION=24.15.0
ARM64_URL=https://nodejs.org/dist/v24.15.0/node-v24.15.0-darwin-arm64.tar.gz
X64_URL=https://nodejs.org/dist/v24.15.0/node-v24.15.0-darwin-x64.tar.gz
ARM64_ARCHIVE_SHA=372331b969779ab5d15b949884fc6eaf88d5afe87bde8ba881d6400b9100ffc4
X64_ARCHIVE_SHA=ffd5ee293467927f3ee731a553eb88fd1f48cf74eebc2d74a6babe4af228673b
ARM64_BINARY_SHA=3200fbd9f7fd4410426dd541e10d1ab829d3472f270d743c7fabd1696c03fe32
X64_BINARY_SHA=2a249a6a7015b0555c3448a77d226c1f3c8f62bd133d89044a2e1518cd16c4b3
LICENSE_SHA=4573185d56580da2b890ba34a85a409257640f1c5632eade4300137266194d18
UNIVERSAL_BINARY_SHA=f638dd249d1df9ff89764a312a510c55250f23ce40e977ac8b68a295161d6f3a
UNIVERSAL_BINARY_SIZE=242234784
ENTITLEMENTS_PATH="$ROOT_DIR/scripts/qualification-node.entitlements"
OUTPUT_APP=""
TEST_MODE="${PEEKABOO_TERMINAL_TEST_MODE:-0}"

fail() {
  printf 'build-node-runtime-macos: %s\n' "$*" >&2
  exit 1
}

while (($# > 0)); do
  case "$1" in
    --output-app) OUTPUT_APP="$2"; shift 2 ;;
    -h|--help)
      printf 'Usage: scripts/build-node-runtime-macos.sh --output-app ABSOLUTE_PATH\n'
      exit 0
      ;;
    *) fail "unknown argument: $1" ;;
  esac
done
[[ "$OUTPUT_APP" == /* && ! -e "$OUTPUT_APP" && ! -L "$OUTPUT_APP" ]] || fail 'output app must be new and absolute'

case "$TEST_MODE" in
  1|true|yes|on)
    ARM64_ARCHIVE="${NODE_RUNTIME_ARM64_ARCHIVE:?test arm64 archive required}"
    X64_ARCHIVE="${NODE_RUNTIME_X64_ARCHIVE:?test x64 archive required}"
    ARM64_ARCHIVE_SHA="${NODE_RUNTIME_ARM64_ARCHIVE_SHA:?}"
    X64_ARCHIVE_SHA="${NODE_RUNTIME_X64_ARCHIVE_SHA:?}"
    ARM64_BINARY_SHA="${NODE_RUNTIME_ARM64_BINARY_SHA:?}"
    X64_BINARY_SHA="${NODE_RUNTIME_X64_BINARY_SHA:?}"
    LICENSE_SHA="${NODE_RUNTIME_LICENSE_SHA:?}"
    UNIVERSAL_BINARY_SHA="${NODE_RUNTIME_UNIVERSAL_BINARY_SHA:?}"
    UNIVERSAL_BINARY_SIZE="${NODE_RUNTIME_UNIVERSAL_BINARY_SIZE:?}"
    ;;
  0|false|no|off|'')
    for override_name in NODE_RUNTIME_ARM64_ARCHIVE NODE_RUNTIME_X64_ARCHIVE NODE_RUNTIME_ARM64_ARCHIVE_SHA \
      NODE_RUNTIME_X64_ARCHIVE_SHA NODE_RUNTIME_ARM64_BINARY_SHA NODE_RUNTIME_X64_BINARY_SHA \
      NODE_RUNTIME_LICENSE_SHA NODE_RUNTIME_UNIVERSAL_BINARY_SHA NODE_RUNTIME_UNIVERSAL_BINARY_SIZE; do
      [[ -z "${!override_name+x}" ]] || fail "$override_name is test-only"
    done
    download_root="$(mktemp -d /tmp/peekaboo-node-download.XXXXXX)"
    ARM64_ARCHIVE="$download_root/arm64.tar.gz"
    X64_ARCHIVE="$download_root/x64.tar.gz"
    /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
      "$ARM64_URL" -o "$ARM64_ARCHIVE"
    /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
      "$X64_URL" -o "$X64_ARCHIVE"
    ;;
  *) fail 'PEEKABOO_TERMINAL_TEST_MODE must be boolean' ;;
esac

work_root="$(mktemp -d /tmp/peekaboo-node-runtime.XXXXXX)"
cleanup() {
  rm -rf -- "$work_root"
  [[ -z "${download_root:-}" ]] || rm -rf -- "$download_root"
}
trap cleanup EXIT

verify_sha() {
  local path="$1"
  local expected="$2"
  [[ "$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')" == "$expected" ]] || \
    fail "hash mismatch: $path"
}
verify_sha "$ARM64_ARCHIVE" "$ARM64_ARCHIVE_SHA"
verify_sha "$X64_ARCHIVE" "$X64_ARCHIVE_SHA"

mkdir -p "$work_root/arm64" "$work_root/x64"
/usr/bin/tar -xzf "$ARM64_ARCHIVE" -C "$work_root/arm64"
/usr/bin/tar -xzf "$X64_ARCHIVE" -C "$work_root/x64"
arm64_root="$work_root/arm64/node-v$NODE_VERSION-darwin-arm64"
x64_root="$work_root/x64/node-v$NODE_VERSION-darwin-x64"
arm64_binary="$arm64_root/bin/node"
x64_binary="$x64_root/bin/node"
[[ -x "$arm64_binary" && -x "$x64_binary" ]] || fail 'input Node binary missing'
verify_sha "$arm64_binary" "$ARM64_BINARY_SHA"
verify_sha "$x64_binary" "$X64_BINARY_SHA"
verify_sha "$arm64_root/LICENSE" "$LICENSE_SHA"
verify_sha "$x64_root/LICENSE" "$LICENSE_SHA"
[[ -f "$ENTITLEMENTS_PATH" && ! -L "$ENTITLEMENTS_PATH" ]] || fail 'qualification Node entitlements missing'
ENTITLEMENTS_SHA="$(/usr/bin/shasum -a 256 "$ENTITLEMENTS_PATH" | /usr/bin/awk '{print $1}')"
/usr/bin/cmp -s "$arm64_root/LICENSE" "$x64_root/LICENSE" || fail 'Node licenses differ by architecture'
[[ "$(/usr/bin/lipo -archs "$arm64_binary")" == arm64 ]] || fail 'arm64 input is not thin arm64'
[[ "$(/usr/bin/lipo -archs "$x64_binary")" == x86_64 ]] || fail 'x64 input is not thin x86_64'

app="$work_root/PeekabooQualificationNode.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
/usr/bin/lipo -create -output "$app/Contents/MacOS/node" "$arm64_binary" "$x64_binary"
[[ " $(/usr/bin/lipo -archs "$app/Contents/MacOS/node") " == *' arm64 '* && \
  " $(/usr/bin/lipo -archs "$app/Contents/MacOS/node") " == *' x86_64 '* ]] || fail 'universal Node is incomplete'
verify_sha "$app/Contents/MacOS/node" "$UNIVERSAL_BINARY_SHA"
[[ "$(/usr/bin/stat -f%z "$app/Contents/MacOS/node")" == "$UNIVERSAL_BINARY_SIZE" ]] || \
  fail 'universal Node size mismatch'
cp "$arm64_root/LICENSE" "$app/Contents/Resources/LICENSE"
cp "$ENTITLEMENTS_PATH" "$app/Contents/Resources/qualification-node.entitlements"
cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>node</string>
<key>CFBundleIdentifier</key><string>boo.peekaboo.qualification-node</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>PeekabooQualificationNode</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$NODE_VERSION</string>
<key>CFBundleVersion</key><string>241500</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
</dict></plist>
EOF
jq -n \
    --arg version "$NODE_VERSION" --arg licenseSHA "$LICENSE_SHA" --arg entitlementsSHA "$ENTITLEMENTS_SHA" \
    --arg universalSHA "$UNIVERSAL_BINARY_SHA" \
  --argjson universalSize "$UNIVERSAL_BINARY_SIZE" \
  --arg armURL "$ARM64_URL" --arg armArchiveSHA "$ARM64_ARCHIVE_SHA" --arg armBinarySHA "$ARM64_BINARY_SHA" \
  --arg x64URL "$X64_URL" --arg x64ArchiveSHA "$X64_ARCHIVE_SHA" --arg x64BinarySHA "$X64_BINARY_SHA" '
    {version: 1, runtime_version: $version, identifier: "boo.peekaboo.qualification-node",
     executable_path: "Contents/MacOS/node", universal_binary_sha256: $universalSHA,
     universal_binary_size: $universalSize, architectures: ["arm64", "x86_64"],
     license: {path: "Contents/Resources/LICENSE", sha256: $licenseSHA},
     entitlements: {path: "Contents/Resources/qualification-node.entitlements", sha256: $entitlementsSHA},
     inputs: {arm64: {url: $armURL, archive_sha256: $armArchiveSHA, binary_sha256: $armBinarySHA},
       x86_64: {url: $x64URL, archive_sha256: $x64ArchiveSHA, binary_sha256: $x64BinarySHA}}}
  ' > "$app/Contents/Resources/PeekabooQualificationNodeSource.json"
mkdir -p "$(dirname "$OUTPUT_APP")"
/usr/bin/ditto "$app" "$OUTPUT_APP"
printf 'Node runtime app: %s\n' "$OUTPUT_APP"
