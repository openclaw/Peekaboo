#!/usr/bin/env bash
set -euo pipefail

# Fixture releases must never inherit the real publication output or manifest.
unset RELEASE_DIR MAC_RELEASE_MANIFEST

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/peekaboo-release-reuse-test.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"
mkdir -p "$FIXTURE_ROOT"
FIXTURE_ROOT="$(cd "$FIXTURE_ROOT" && pwd -P)"
FAKE_BIN="$TEST_ROOT/bin"
VERIFY_LOG="$TEST_ROOT/verify.log"
NODE_LOG="$TEST_ROOT/node.log"
mkdir -p "$FIXTURE_ROOT/scripts" "$FAKE_BIN"

cp "$ROOT_DIR/scripts/release-binaries.sh" "$ROOT_DIR/scripts/package-cli-artifact.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/native-only-policy.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/source-provenance.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/release-version.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/release-driver-contract.mjs" "$FIXTURE_ROOT/scripts/"

# This fixture owns driver/reuse control flow, not environment isolation. Keep
# fake tools reachable here; actual sanitizer coverage lives in the environment
# and release-preflight contract tests, without a production PATH override.
cat >"$FIXTURE_ROOT/scripts/terminal-artifact-env.sh" <<'ENV_STUB'
terminal_artifact_run_build() { "$@"; }
ENV_STUB

cat >"$FIXTURE_ROOT/scripts/build-terminal-artifacts.sh" <<'HELPER'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == check-helper ]]
printf '%s\n' \
  'mac-release helper: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  'mac-release helper executable sha256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
  'mac-release helper library sha256: cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
HELPER
chmod +x "$FIXTURE_ROOT/scripts/build-terminal-artifacts.sh"

# Records the non-reuse CLI build's credential-runner request, then stops the release.
cat >"$FIXTURE_ROOT/scripts/mac-release" <<'MAC_RELEASE'
#!/usr/bin/env bash
printf 'mac-release %s caller-path=%s\n' "$*" "${MAC_RELEASE_CALLER_PATH:-unset}" >>"${PEEKABOO_REUSE_TEST_LOG:?}"
exit 1
MAC_RELEASE
chmod +x "$FIXTURE_ROOT/scripts/mac-release"

cat >"$FIXTURE_ROOT/package.json" <<'JSON'
{"name":"peekaboo-release-reuse-fixture","version":"9.9.9"}
JSON
cat >"$FIXTURE_ROOT/CHANGELOG.md" <<'CHANGELOG'
## [9.9.9] - 2026-08-13

- Test release.
CHANGELOG
mkdir -p "$FIXTURE_ROOT/release"
cp "$FIXTURE_ROOT/CHANGELOG.md" "$FIXTURE_ROOT/release/release-notes.md"
printf '%s\n' 'fixture license' >"$FIXTURE_ROOT/LICENSE"
printf '%s\n' 'original appcast' >"$FIXTURE_ROOT/appcast.xml"
cat >"$FIXTURE_ROOT/.gitignore" <<'IGNORE'
/build/
/peekaboo
/libswiftCompatibility*.dylib
IGNORE

cat >"$FIXTURE_ROOT/scripts/verify-swift-runtime-libraries.sh" <<'RUNTIME'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' runtime-libraries >>"${PEEKABOO_REUSE_TEST_LOG:?}"
RUNTIME
chmod +x "$FIXTURE_ROOT/scripts/verify-swift-runtime-libraries.sh"

cat >"$FAKE_BIN/file" <<'FILE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' file-macho >>"${PEEKABOO_REUSE_TEST_LOG:?}"
printf '%s: Mach-O universal binary with 2 architectures\n' "$1"
if [[ "${PEEKABOO_REUSE_TEST_FILE_OUTPUT:-single}" == error ]]; then
  exit 86
fi
if [[ "${PEEKABOO_REUSE_TEST_FILE_OUTPUT:-single}" == extended ]]; then
  sleep 0.05
  printf '%65536s\n' ''
  printf '%s\n' file-output-drained >>"${PEEKABOO_REUSE_TEST_LOG:?}"
fi
FILE

cat >"$FAKE_BIN/codesign" <<'CODESIGN'
#!/usr/bin/env bash
set -euo pipefail
args=" $* "
if [[ "$args" == *" -d --entitlements :- "* ]]; then
  printf '%s\n' entitlements >>"${PEEKABOO_REUSE_TEST_LOG:?}"
  if [[ "${PEEKABOO_REUSE_TEST_ENTITLEMENTS:-safe}" == forbidden ]]; then
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>'
  else
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict/></plist>'
  fi
elif [[ "$args" == *" -dv --verbose=4 "* ]]; then
  printf '%s\n' signer-metadata >>"${PEEKABOO_REUSE_TEST_LOG:?}"
  printf '%s\n' \
    'Authority=Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)' \
    'TeamIdentifier=FWJYW4S8P8'
elif [[ "$args" == *" --check-notarization "* ]]; then
  printf '%s\n' online-notarization >>"${PEEKABOO_REUSE_TEST_LOG:?}"
elif [[ "$args" == *" -R=anchor apple generic and certificate leaf[subject.OU] = \"FWJYW4S8P8\" "* ]]; then
  printf '%s\n' signer-requirement >>"${PEEKABOO_REUSE_TEST_LOG:?}"
else
  printf '%s\n' codesign-verify >>"${PEEKABOO_REUSE_TEST_LOG:?}"
fi
CODESIGN

cat >"$FAKE_BIN/lipo" <<'LIPO'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' architectures >>"${PEEKABOO_REUSE_TEST_LOG:?}"
if [[ "$1" == -archs ]]; then
  architecture=$(sed -n 's/^# fixture-architecture: //p' "$2")
  printf '%s\n' "${architecture:-${PEEKABOO_REUSE_TEST_ARCHS:-x86_64 arm64}}"
else
  [[ "$2" == -thin && "$4" == -output ]]
  cp "$1" "$5"
  printf '\n# fixture-architecture: %s\n' "$3" >> "$5"
fi
LIPO

cat >"$FAKE_BIN/nm" <<'NM'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' native-imports >>"${PEEKABOO_REUSE_TEST_LOG:?}"
printf '%s\n' '                 U _harmless'
NM

cat >"$FAKE_BIN/strings" <<'STRINGS'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' native-strings >>"${PEEKABOO_REUSE_TEST_LOG:?}"
printf '%s\n' 'harmless fixture string'
STRINGS

cat >"$FAKE_BIN/pnpm" <<'PNPM'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == pack && "$2" == --pack-destination ]]
destination=$3
package_root=$(mktemp -d /tmp/peekaboo-reuse-npm.XXXXXX)
trap 'rm -rf "$package_root"' EXIT
mkdir -p "$package_root/package"
cp peekaboo libswiftCompatibility*.dylib "$package_root/package/"
tar -czf "$destination/peekaboo-release-reuse-fixture-9.9.9.tgz" -C "$package_root" package
printf '%s\n' "$destination/peekaboo-release-reuse-fixture-9.9.9.tgz"
PNPM

REAL_NODE="$(command -v node)"
cat >"$FAKE_BIN/node" <<'NODE'
#!/usr/bin/env bash
set -euo pipefail
printf 'node-call %s\n' "$*" >> "${PEEKABOO_REUSE_NODE_LOG:?}"
if [[ "${2:-}" == publication-options ]]; then
  payload="$(cat)"
  printf 'publication-options %s\n' "$payload" >> "${PEEKABOO_REUSE_NODE_LOG:?}"
  exec "${PEEKABOO_REUSE_REAL_NODE:?}" "$@" <<< "$payload"
fi
if [[ "${1:-}" == scripts/prepare-release.js ]]; then
  printf 'prepare-release %s\n' "$*" >> "${PEEKABOO_REUSE_TEST_LOG:?}"
  if [[ "${PEEKABOO_REUSE_MUTATE_DURING_PREFLIGHT:-0}" == 1 ]]; then
    printf '%s\n' '# preflight mutation' >> peekaboo
  fi
  exit 0
fi
exec "${PEEKABOO_REUSE_REAL_NODE:?}" "$@"
NODE
chmod +x "$FAKE_BIN"/*

git -C "$FIXTURE_ROOT" init -q
git -C "$FIXTURE_ROOT" add .
mkdir -p "$TEST_ROOT/no-hooks"
git -C "$FIXTURE_ROOT" \
  -c user.name=Peekaboo \
  -c user.email=peekaboo@example.invalid \
  -c commit.gpgSign=false \
  -c core.hooksPath="$TEST_ROOT/no-hooks" \
  commit -q --no-gpg-sign -m fixture
FIXTURE_COMMIT=$(git -C "$FIXTURE_ROOT" rev-parse HEAD)

cat >"$FIXTURE_ROOT/peekaboo" <<'CANDIDATE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' candidate-executed >>"${PEEKABOO_REUSE_TEST_LOG:?}"
if [[ " $* " == *" --json "* ]]; then
  printf '{"data":{"sourceCommit":"%s"}}\n' "${PEEKABOO_REUSE_TEST_SOURCE_COMMIT:?}"
else
  printf 'Peekaboo 9.9.9 (%s)\n' "${PEEKABOO_REUSE_TEST_SOURCE_COMMIT:?}"
fi
exit 0
CANDIDATE
printf 'fixture runtime library\n' > "$FIXTURE_ROOT/libswiftCompatibilitySpan.dylib"
chmod +x "$FIXTURE_ROOT/peekaboo" "$FIXTURE_ROOT/libswiftCompatibilitySpan.dylib"
# Release candidates must be meaningfully sized; pad this executable with shell
# comments without changing its behavior.
dd if=/dev/zero bs=1048576 count=2 2>/dev/null | tr '\0' '#' >>"$FIXTURE_ROOT/peekaboo"

run_release() {
  (
    cd "$FIXTURE_ROOT"
    PATH="$FAKE_BIN:$PATH" \
      PEEKABOO_NM_BIN="$FAKE_BIN/nm" \
      PEEKABOO_STRINGS_BIN="$FAKE_BIN/strings" \
      PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
      PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" \
      PEEKABOO_REUSE_TEST_SOURCE_COMMIT="$1" \
      PEEKABOO_REUSE_TEST_ENTITLEMENTS="${2:-safe}" \
      PEEKABOO_REUSE_TEST_ARCHS="${3:-x86_64 arm64}" \
      PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
      PEEKABOO_REUSE_MUTATE_DURING_PREFLIGHT="${4:-0}" \
      PEEKABOO_REUSE_TEST_FILE_OUTPUT="${5:-single}" \
      ./scripts/release-binaries.sh --reuse-built-cli --skip-mac-app --no-appcast "${@:6}"
  )
}

touch "$FIXTURE_ROOT/untracked-input"
: >"$VERIFY_LOG"
if run_release "$FIXTURE_COMMIT" >"$TEST_ROOT/dirty.out" 2>&1; then
  echo 'reuse unexpectedly accepted a dirty release checkout' >&2
  exit 1
fi
grep -Fq 'one clean exact source commit' "$TEST_ROOT/dirty.out"
[[ ! -s "$VERIFY_LOG" ]]
rm -f "$FIXTURE_ROOT/untracked-input"

: >"$VERIFY_LOG"
if run_release "$FIXTURE_COMMIT" safe 'x86_64 arm64' 0 error >"$TEST_ROOT/file-error.out" 2>&1; then
  echo 'reuse accepted a failed file inspection after matching Mach-O output' >&2
  exit 1
fi
grep -Fq 'binary is not Mach-O' "$TEST_ROOT/file-error.out"
if grep -Fq candidate-executed "$VERIFY_LOG"; then
  echo 'candidate was executed after file inspection failed' >&2
  exit 1
fi

: >"$VERIFY_LOG"
if run_release "$FIXTURE_COMMIT" forbidden >"$TEST_ROOT/entitlements.out" 2>&1; then
  echo 'reuse unexpectedly accepted a candidate with forbidden entitlements' >&2
  exit 1
fi
grep -Fq 'requests forbidden debug or Apple Events entitlements' "$TEST_ROOT/entitlements.out"
if grep -Fq candidate-executed "$VERIFY_LOG"; then
  echo 'candidate with forbidden entitlements was executed' >&2
  exit 1
fi

: >"$VERIFY_LOG"
if run_release "$FIXTURE_COMMIT" safe x86_64h >"$TEST_ROOT/architectures.out" 2>&1; then
  echo 'reuse unexpectedly accepted a candidate without exact universal architecture tokens' >&2
  exit 1
fi
grep -Fq 'binary is missing x86_64 slice' "$TEST_ROOT/architectures.out"
if grep -Fq candidate-executed "$VERIFY_LOG"; then
  echo 'candidate with invalid architecture tokens was executed' >&2
  exit 1
fi

: >"$VERIFY_LOG"
MISMATCH_COMMIT=0123456789abcdef0123456789abcdef01234567
if run_release "$MISMATCH_COMMIT" >"$TEST_ROOT/mismatch.out" 2>&1; then
  echo 'reuse unexpectedly accepted a candidate from another source commit' >&2
  exit 1
fi
grep -Fq "source mismatch: expected $FIXTURE_COMMIT, got $MISMATCH_COMMIT" "$TEST_ROOT/mismatch.out"
grep -Fq candidate-executed "$VERIFY_LOG"

: >"$VERIFY_LOG"
candidate_sha_before="$(shasum -a 256 "$FIXTURE_ROOT/peekaboo" | awk '{print $1}')"
if ! run_release "$FIXTURE_COMMIT" safe 'x86_64 arm64' 0 extended >"$TEST_ROOT/success.out" 2>&1; then
  echo 'reuse rejected a valid Mach-O candidate with extended file output' >&2
  exit 1
fi
grep -Fq 'Release artifacts created successfully' "$TEST_ROOT/success.out"
[[ "$(shasum -a 256 "$FIXTURE_ROOT/peekaboo" | awk '{print $1}')" == "$candidate_sha_before" ]]
[[ "$(cat "$FIXTURE_ROOT/libswiftCompatibilitySpan.dylib")" == 'fixture runtime library' ]]

# The real producer must package both binary and runtime slices without changing npm inputs.
for architecture in universal arm64 x86_64; do
  archive="$FIXTURE_ROOT/build/release/peekaboo-macos-$architecture.tar.gz"
  extract="$TEST_ROOT/extracted-$architecture"
  mkdir "$extract"
  tar -xzf "$archive" -C "$extract"
  payload="$extract/peekaboo-macos-$architecture"
  for name in peekaboo libswiftCompatibilitySpan.dylib; do
    if [[ "$architecture" == universal ]]; then
      cmp "$FIXTURE_ROOT/$name" "$payload/$name"
    else
      grep -Fx "# fixture-architecture: $architecture" "$payload/$name" >/dev/null
    fi
  done
  # shellcheck disable=SC2016
  grep -Fx '    sudo install -m 755 "$library" "$install_dir/"' "$payload/README.md" >/dev/null
done
mkdir "$TEST_ROOT/extracted-npm"
tar -xzf "$FIXTURE_ROOT/build/release/peekaboo-release-reuse-fixture-9.9.9.tgz" -C "$TEST_ROOT/extracted-npm"
for name in peekaboo libswiftCompatibilitySpan.dylib; do
  cmp "$FIXTURE_ROOT/$name" "$TEST_ROOT/extracted-npm/package/$name"
done

# App packaging changes the tracked feed before these archive consumers run.
# Exercise that real transition with the driver's frozen-feed state check.
(
  export PATH="$FAKE_BIN:$PATH"
  export PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" PEEKABOO_REUSE_NODE_LOG="$NODE_LOG"
  export PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" PEEKABOO_REUSE_TEST_SOURCE_COMMIT="$FIXTURE_COMMIT"
  export PEEKABOO_NM_BIN="$FAKE_BIN/nm" PEEKABOO_STRINGS_BIN="$FAKE_BIN/strings"
  source "$FIXTURE_ROOT/scripts/source-provenance.sh"
  source "$FIXTURE_ROOT/scripts/native-only-policy.sh"
  fail() { echo "$*" >&2; exit 1; }
  require_command() { command -v "$1" >/dev/null || fail "Missing $1"; }
  # Refused archives exit before normal cleanup; keep them under the fixture trap.
  mktemp() {
    case "${2:-}" in
      /tmp/peekaboo-cli-verify.*|/tmp/peekaboo-npm-verify.*)
        command mktemp "$1" "$TEST_ROOT/${2##*/}" ;;
      *) command mktemp "$@" ;;
    esac
  }
  for function_name in sha256_file verify_release_source_state verify_release_binary_entitlements \
    verify_release_binary_apple_events_policy verify_binary_artifact verify_cli_tarball verify_npm_tarball; do
    sed -n "/^$function_name() {$/,/^}$/p" "$FIXTURE_ROOT/scripts/release-binaries.sh" >> "$TEST_ROOT/archive-source-checks.sh"
  done
  source "$TEST_ROOT/archive-source-checks.sh"
  PROJECT_ROOT="$FIXTURE_ROOT"
  RELEASE_CONTRACT="$FIXTURE_ROOT/scripts/release-driver-contract.mjs"
  RELEASE_SOURCE_COMMIT="$FIXTURE_COMMIT"
  VERSION=9.9.9
  CLI_ARCHITECTURES=(universal arm64 x86_64)
  CLI_SIGN_IDENTITY='Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)'
  CLI_SIGN_TEAM_ID=FWJYW4S8P8
  CLI_SIGN_REQUIREMENT='anchor apple generic and certificate leaf[subject.OU] = "FWJYW4S8P8"'
  MAC_APP_NOTARIZE=true
  printf '%s\n' 'generated appcast' > "$FIXTURE_ROOT/appcast.xml"
  RELEASE_APPCAST_SHA256=$(sha256_file "$FIXTURE_ROOT/appcast.xml")
  for architecture in universal arm64 x86_64; do
    verify_cli_tarball "$FIXTURE_ROOT/build/release/peekaboo-macos-$architecture.tar.gz" "$architecture"
  done
  verify_npm_tarball "$FIXTURE_ROOT/build/release/peekaboo-release-reuse-fixture-9.9.9.tgz"

  assert_source_refused() {
    local label="$1" expected="$2"
    shift 2
    if ("$@") > "$TEST_ROOT/$label.out" 2>&1; then
      fail "$label accepted an invalid publication source"
    fi
    grep -Fq "$expected" "$TEST_ROOT/$label.out" || fail "$label failed for the wrong reason"
  }
  archive="$FIXTURE_ROOT/build/release/peekaboo-macos-universal.tar.gz"
  npm_archive="$FIXTURE_ROOT/build/release/peekaboo-release-reuse-fixture-9.9.9.tgz"
  printf '%s\n' 'tampered appcast' > "$FIXTURE_ROOT/appcast.xml"
  assert_source_refused changed-appcast 'checkout changed' verify_cli_tarball "$archive" universal
  printf '%s\n' 'generated appcast' > "$FIXTURE_ROOT/appcast.xml"
  touch "$FIXTURE_ROOT/untracked-input"
  assert_source_refused untracked-after-appcast 'checkout changed' verify_cli_tarball "$archive" universal
  rm -f "$FIXTURE_ROOT/untracked-input"
  printf '%s\n' 'changed license' > "$FIXTURE_ROOT/LICENSE"
  assert_source_refused tracked-after-appcast 'checkout changed' verify_npm_tarball "$npm_archive"
  printf '%s\n' 'fixture license' > "$FIXTURE_ROOT/LICENSE"
  PEEKABOO_REUSE_TEST_SOURCE_COMMIT="$MISMATCH_COMMIT"
  assert_source_refused cli-stamp-after-appcast 'source mismatch' verify_cli_tarball "$archive" universal
  assert_source_refused npm-stamp-after-appcast 'source mismatch' verify_npm_tarball "$npm_archive"
  PEEKABOO_REUSE_TEST_SOURCE_COMMIT="$FIXTURE_COMMIT"
  RELEASE_SOURCE_COMMIT="$MISMATCH_COMMIT"
  assert_source_refused head-after-appcast 'checkout changed' verify_cli_tarball "$archive" universal
  printf '%s\n' 'original appcast' > "$FIXTURE_ROOT/appcast.xml"
  printf 'archive source checks: frozen appcast accepted; changed feed, source, and stamps refused\n'
)

# These same consumers are used by new publication and retained-publication resume.
# Functions and their variables are loaded from the exact driver under test.
# shellcheck disable=SC1091,SC2034,SC2329
(
  set -euo pipefail
  fail() { echo "$*" >&2; exit 1; }
  node() { "$REAL_NODE" "$@"; }
  for function_name in sha256_file verify_checksums_file expected_release_assets_json prepare_release_assets \
    select_release_asset_uploads verify_github_release_assets; do
    sed -n "/^$function_name() {$/,/^}$/p" "$FIXTURE_ROOT/scripts/release-binaries.sh" >> "$TEST_ROOT/driver-consumers.sh"
  done
  source "$TEST_ROOT/driver-consumers.sh"
  RELEASE_DIR="$FIXTURE_ROOT/build/release"
  CLI_ARCHITECTURES=(universal arm64 x86_64)
  NPM_PACKAGE_PATH="$RELEASE_DIR/peekaboo-release-reuse-fixture-9.9.9.tgz"
  RELEASE_PROOF_SHA256=""
  INCLUDE_MAC_APP=false
  MAC_APP_ZIP_PATH=""
  verify_checksums_file
  expected_release_assets_json > "$TEST_ROOT/assets.json"
  prepare_release_assets
  printf '%s\n' "${RELEASE_ASSETS[@]}" > "$TEST_ROOT/upload-assets.txt"
  "$REAL_NODE" --input-type=module - "$TEST_ROOT/assets.json" "$TEST_ROOT/upload-assets.txt" <<'ASSETS'
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
const inventory = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const uploads = fs.readFileSync(process.argv[3], 'utf8').trim().split('\n').map(value => path.basename(value));
assert.deepEqual(uploads.sort(), Object.keys(inventory).sort());
for (const architecture of ['universal', 'arm64', 'x86_64']) {
  assert.ok(inventory['peekaboo-macos-' + architecture + '.tar.gz']);
}
ASSETS
  cp "$RELEASE_DIR/checksums.txt" "$TEST_ROOT/checksums-original"
  sed '/peekaboo-macos-x86_64.tar.gz/d' "$TEST_ROOT/checksums-original" > "$RELEASE_DIR/checksums.txt"
  if (verify_checksums_file) > "$TEST_ROOT/missing-thin-checksum.out" 2>&1; then
    echo 'release accepted an omitted thin archive checksum' >&2
    exit 1
  fi
  grep -F 'missing peekaboo-macos-x86_64.tar.gz' "$TEST_ROOT/missing-thin-checksum.out" >/dev/null
  cp "$TEST_ROOT/checksums-original" "$RELEASE_DIR/checksums.txt"

  GITHUB_RELEASE_REPAIR_ASSETS=(checksums.txt peekaboo-macos-arm64.tar.gz)
  select_release_asset_uploads
  [[ ${#RELEASE_ASSET_UPLOADS[@]} -eq 2 ]]
  [[ "${RELEASE_ASSET_UPLOADS[0]}" == "$RELEASE_DIR/peekaboo-macos-arm64.tar.gz" ]]
  [[ "${RELEASE_ASSET_UPLOADS[1]}" == "$RELEASE_DIR/checksums.txt" ]]
  GITHUB_RELEASE_REPAIR_ASSETS=()
  select_release_asset_uploads
  [[ ${#RELEASE_ASSET_UPLOADS[@]} -eq 0 ]]
  GITHUB_RELEASE_REPAIR_ASSETS=(unknown.tar.gz)
  if (select_release_asset_uploads) > "$TEST_ROOT/unknown-repair.out" 2>&1; then
    fail 'release accepted an unknown repair asset'
  fi
  grep -Fq 'unknown.tar.gz matches 0 local release assets' "$TEST_ROOT/unknown-repair.out"
  GITHUB_RELEASE_REPAIR_ASSETS=(checksums.txt)
  RELEASE_ASSETS+=("$TEST_ROOT/checksums.txt")
  if (select_release_asset_uploads) > "$TEST_ROOT/ambiguous-repair.out" 2>&1; then
    fail 'release accepted an ambiguous repair asset'
  fi
  grep -Fq 'checksums.txt matches 2 local release assets' "$TEST_ROOT/ambiguous-repair.out"
  prepare_release_assets

  BLUE='' GREEN='' NC=''
  VERSION=9.9.9
  GITHUB_HOST=github.com
  RELEASE_SOURCE_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  RELEASE_CONTRACT="$FIXTURE_ROOT/scripts/release-driver-contract.mjs"
  PUBLICATION_RECEIPT_PATH="$TEST_ROOT/repair-receipt.json"
  assert_publication_receipt() { :; }
  github_tag_commit() { printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; }
  github_release_api_path() { printf '%s\n' repos/openclaw/Peekaboo/releases/1; }
  gh() {
    [[ $# -eq 4 && "$1" == api && "$2" == --hostname && "$3" == github.com &&
      "$4" == repos/openclaw/Peekaboo/releases/1 ]] || fail 'unexpected GitHub API arguments'
    cat "$TEST_ROOT/repair-release.json"
  }
  node --input-type=module - "$TEST_ROOT/assets.json" "$PUBLICATION_RECEIPT_PATH" \
    "$TEST_ROOT/repair-release.json" <<'REPAIR'
import fs from 'node:fs';
const assets = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
fs.writeFileSync(process.argv[3], JSON.stringify({ assets }));
fs.writeFileSync(process.argv[4], JSON.stringify({
  tag_name: 'v9.9.9', draft: true,
  assets: Object.entries(assets).map(([name, asset]) => ({ name, size: asset.size, digest: `sha256:${asset.sha256}` })),
}));
REPAIR
  verify_github_release_assets '' true true
  [[ ${#GITHUB_RELEASE_REPAIR_ASSETS[@]} -eq 0 ]]
  cp "$TEST_ROOT/repair-release.json" "$TEST_ROOT/intact-release.json"
  node --input-type=module - "$TEST_ROOT/repair-release.json" <<'REPAIR'
import fs from 'node:fs';
const file = process.argv[2];
const release = JSON.parse(fs.readFileSync(file, 'utf8'));
release.assets = release.assets.filter(asset => asset.name !== 'peekaboo-macos-arm64.tar.gz');
release.assets.find(asset => asset.name === 'checksums.txt').digest = 'sha256:wrong';
fs.writeFileSync(file, JSON.stringify(release));
REPAIR
  verify_github_release_assets '' true true
  [[ ${#GITHUB_RELEASE_REPAIR_ASSETS[@]} -eq 2 ]]
  [[ "${GITHUB_RELEASE_REPAIR_ASSETS[0]}" == checksums.txt ]]
  [[ "${GITHUB_RELEASE_REPAIR_ASSETS[1]}" == peekaboo-macos-arm64.tar.gz ]]
  # Run outside an `if` so errexit remains active inside the strict verifier.
  set +e
  (set -euo pipefail; verify_github_release_assets '' true) > "$TEST_ROOT/strict-repair.out" 2>&1
  strict_result=$?
  set -e
  [[ "$strict_result" -ne 0 ]] || fail 'strict verification accepted mismatching assets'
  grep -Fq 'GitHub release asset inventory differs' "$TEST_ROOT/strict-repair.out"
  cp "$TEST_ROOT/intact-release.json" "$TEST_ROOT/repair-release.json"
  verify_github_release_assets '' true
  [[ ${#GITHUB_RELEASE_REPAIR_ASSETS[@]} -eq 0 ]]
  node -e '
const fs = require("fs"), file = process.argv[1], release = JSON.parse(fs.readFileSync(file));
release.assets.push(release.assets[0]);
fs.writeFileSync(file, JSON.stringify(release));
' "$TEST_ROOT/repair-release.json"
  if (verify_github_release_assets '' true true) > "$TEST_ROOT/invalid-repair.out" 2>&1; then
    fail 'repair verification accepted duplicate assets'
  fi
  grep -Fq 'GitHub release contains an unexpected asset that cannot be repaired' "$TEST_ROOT/invalid-repair.out"
  grep -Fq 'GitHub release verification failed' "$TEST_ROOT/invalid-repair.out"
  printf 'draft asset repair: exact selection, empty arrays, strict verification, and fail-closed checks passed\n'
)

# Exercise resume itself while all publication actions remain logged stubs.
# shellcheck disable=SC1091,SC2034,SC2329
(
  set -euo pipefail
  node() { "$REAL_NODE" "$@"; }
  fail() { echo "$*" >&2; exit 1; }
  for function_name in resume_publication prepare_release_assets select_release_asset_uploads; do
    sed -n "/^$function_name() {$/,/^}$/p" "$FIXTURE_ROOT/scripts/release-binaries.sh" >> "$TEST_ROOT/resume-functions.sh"
  done
  source "$TEST_ROOT/resume-functions.sh"
  RELEASE_DIR="$FIXTURE_ROOT/build/release"
  CLI_ARCHITECTURES=(universal arm64 x86_64)
  NPM_PACKAGE_PATH="$RELEASE_DIR/peekaboo-release-reuse-fixture-9.9.9.tgz"
  RELEASE_PROOF_SHA256='' MAC_APP_ZIP_PATH=''
  BLUE='' GREEN='' NC=''
  VERSION=9.9.9
  GITHUB_REPOSITORY=github.com/openclaw/Peekaboo
  RETRY_NPM_PUBLISH=false
  log() {
    printf '%s' "$1" >> "$RESUME_LOG"
    shift
    if [[ $# -gt 0 ]]; then printf ' <%s>' "$@" >> "$RESUME_LOG"; fi
    printf '\n' >> "$RESUME_LOG"
  }
  require_command() { log require_command "$@"; }
  load_retained_release_state() { log load_retained_release_state "$@"; }
  npm_publication_exists() { log npm_publication_exists "$@"; [[ "$npm_exists" == true ]]; }
  verify_npm_publication() { log verify_npm_publication "$@"; }
  compose_github_body() { log compose_github_body "$@"; }
  freeze_publication_receipt() { log freeze_publication_receipt "$@"; }
  assert_publication_receipt() { log assert_publication_receipt "$@"; }
  github_release_exists() { log github_release_exists "$@"; return 0; }
  validate_npm_publish_attempt() { log validate_npm_publish_attempt "$@"; return 1; }
  activate_retained_pending_receipt() { log activate_retained_pending_receipt "$@"; }
  configure_npm_publication() { log configure_npm_publication "$@"; }
  confirm_npm_publication() { log confirm_npm_publication "$@"; }
  publish_frozen_npm_package() { log publish_frozen_npm_package "$@"; }
  gh() { log gh "$@"; }
  verify_github_release_assets() {
    log verify_github_release_assets "$@"
    GITHUB_RELEASE_REPAIR_ASSETS=()
    if [[ "${3:-}" == true && ${#test_repair_names[@]} -gt 0 ]]; then
      GITHUB_RELEASE_REPAIR_ASSETS=("${test_repair_names[@]}")
    fi
  }
  for npm_exists in true false; do
    for repair_case in intact partial; do
      RESUME_LOG="$TEST_ROOT/resume-$npm_exists-$repair_case.log"
      test_repair_names=()
      if [[ "$repair_case" == partial ]]; then
        test_repair_names=(checksums.txt peekaboo-macos-arm64.tar.gz)
      fi
      resume_publication > "$TEST_ROOT/resume-$npm_exists-$repair_case.out"
      if [[ "$repair_case" == intact ]]; then
        grep -Fq 'All 6 draft assets match the frozen receipt; upload skipped' "$TEST_ROOT/resume-$npm_exists-$repair_case.out"
      else
        grep -Fq 'Re-uploading 2 of 6 draft assets: checksums.txt peekaboo-macos-arm64.tar.gz' \
          "$TEST_ROOT/resume-$npm_exists-$repair_case.out"
      fi
    done
  done
  node --input-type=module - "$TEST_ROOT" "$RELEASE_DIR" <<'RESUME'
import assert from 'node:assert/strict';
import fs from 'node:fs';
const [root, dir] = process.argv.slice(2);
const call = (name, ...args) => name + args.map(arg => ` <${arg}>`).join('');
const metadata = `${dir}/npm-publication.json`;
for (const published of [true, false]) {
  for (const repair of ['intact', 'partial']) {
    const lines = fs.readFileSync(`${root}/resume-${published}-${repair}.log`, 'utf8').trim().split('\n');
    const expected = [call('require_command', 'gh'), 'load_retained_release_state', 'npm_publication_exists'];
    if (published) {
      expected.push('verify_npm_publication', call('compose_github_body', metadata),
        call('freeze_publication_receipt', metadata));
    } else {
      expected.push('validate_npm_publish_attempt', 'compose_github_body', 'activate_retained_pending_receipt',
        'configure_npm_publication', 'confirm_npm_publication');
    }
    expected.push('github_release_exists', call('verify_github_release_assets', published ? metadata : '', 'true', 'true'));
    if (repair === 'partial') {
      expected.push(call('gh', 'release', 'upload', 'v9.9.9', `${dir}/peekaboo-macos-arm64.tar.gz`,
        `${dir}/checksums.txt`, '--repo', 'github.com/openclaw/Peekaboo', '--clobber'));
    }
    expected.push(call('verify_github_release_assets', published ? metadata : '', 'true'));
    if (!published) {
      expected.push('publish_frozen_npm_package', 'verify_npm_publication', call('compose_github_body', metadata),
        call('freeze_publication_receipt', metadata));
    }
    expected.push(call('assert_publication_receipt', metadata),
      call('gh', 'release', 'edit', 'v9.9.9', '--repo', 'github.com/openclaw/Peekaboo',
        '--notes-file', `${dir}/github-release-body.md`),
      call('assert_publication_receipt', metadata), call('verify_github_release_assets', metadata));
    assert.deepEqual(lines, expected, `${published}/${repair}`);
  }
}
RESUME
  printf 'resume publication: intact and partial drafts passed with npm published and pending\n'
)

first_candidate=$(grep -n -m1 '^candidate-executed$' "$VERIFY_LOG" | cut -d: -f1)
for required_gate in \
  file-macho file-output-drained codesign-verify signer-requirement entitlements native-imports native-strings \
  runtime-libraries signer-metadata online-notarization architectures; do
  gate_line=$(grep -n -m1 "^${required_gate}$" "$VERIFY_LOG" | cut -d: -f1)
  [[ -n "$gate_line" && "$gate_line" -lt "$first_candidate" ]] || {
    echo "release candidate executed before $required_gate verification" >&2
    exit 1
  }
done

prepare_line=$(grep -n -m1 '^prepare-release ' "$VERIFY_LOG" | cut -d: -f1)
[[ -n "$prepare_line" && "$prepare_line" -gt "$first_candidate" ]] || {
  echo 'full no-build preflight ran before reusable CLI safety verification' >&2
  exit 1
}
grep -Fq "prepare-release scripts/prepare-release.js --no-build --bin $FIXTURE_ROOT/peekaboo" "$VERIFY_LOG"
if grep -Eq 'pnpm run build:swift|build-swift-(arm|universal)' "$VERIFY_LOG"; then
  echo 'reuse lane rebuilt the CLI' >&2
  exit 1
fi

if ! run_release "$FIXTURE_COMMIT" safe arm64 0 single --arm64-only >"$TEST_ROOT/arm64-only.out" 2>&1; then
  echo 'local arm64-only packaging rejected an already-thin CLI' >&2
  exit 1
fi
[[ -f "$FIXTURE_ROOT/build/release/peekaboo-macos-arm64.tar.gz" ]]
[[ ! -e "$FIXTURE_ROOT/build/release/peekaboo-macos-universal.tar.gz" ]]
[[ ! -e "$FIXTURE_ROOT/build/release/peekaboo-macos-x86_64.tar.gz" ]]
mkdir "$TEST_ROOT/extracted-arm64-only"
tar -xzf "$FIXTURE_ROOT/build/release/peekaboo-macos-arm64.tar.gz" -C "$TEST_ROOT/extracted-arm64-only"
for name in peekaboo libswiftCompatibilitySpan.dylib; do
  cmp "$FIXTURE_ROOT/$name" "$TEST_ROOT/extracted-arm64-only/peekaboo-macos-arm64/$name"
done

cp "$FIXTURE_ROOT/peekaboo" "$TEST_ROOT/candidate-before-mutation"
: >"$VERIFY_LOG"
if run_release "$FIXTURE_COMMIT" safe 'x86_64 arm64' 1 >"$TEST_ROOT/preflight-mutation.out" 2>&1; then
  echo 'reuse accepted candidate mutation during no-build preflight' >&2
  exit 1
fi
grep -Fq 'Reusable CLI changed during release preflight' "$TEST_ROOT/preflight-mutation.out"
cp "$TEST_ROOT/candidate-before-mutation" "$FIXTURE_ROOT/peekaboo"
chmod +x "$FIXTURE_ROOT/peekaboo"

for public_action in --create-github-release --publish-npm; do
  for unsafe_option in --skip-checks --arm64-only --skip-mac-app --no-notarize-mac-app --no-appcast; do
    : >"$VERIFY_LOG"
    : >"$NODE_LOG"
    if (
      cd "$FIXTURE_ROOT"
      PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
        PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" \
        PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
        ./scripts/release-binaries.sh "$public_action" "$unsafe_option"
    ) >"$TEST_ROOT/unsafe.out" 2>&1; then
      echo "public release accepted unsafe option: $public_action $unsafe_option" >&2
      exit 1
    fi
    grep -Fq -- "$unsafe_option" "$TEST_ROOT/unsafe.out"
    [[ ! -s "$VERIFY_LOG" ]]
    grep -Fq 'release-driver-contract.mjs publication-options' "$NODE_LOG"
    if grep -Fq 'prepare-release.js' "$NODE_LOG"; then
      echo 'unsafe publication options reached preflight' >&2
      exit 1
    fi
  done
  : >"$VERIFY_LOG"
  : >"$NODE_LOG"
  if (
    cd "$FIXTURE_ROOT"
    PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
      PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
      ./scripts/release-binaries.sh "$public_action"
  ) >"$TEST_ROOT/missing-proof.out" 2>&1; then
    echo "public release accepted missing proof: $public_action" >&2
    exit 1
  fi
  grep -Fq -- '--proof-file' "$TEST_ROOT/missing-proof.out"
  [[ ! -s "$VERIFY_LOG" ]]
done

printf 'reviewed proof\n' > "$TEST_ROOT/public-proof.md"
run_public_release() {
  (
    cd "$FIXTURE_ROOT"
    /usr/bin/env -u NPM_TOKEN -u CODESIGN_KEYCHAIN -u MAC_RELEASE_CALLER_PATH "$@" \
      PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
      PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
      ./scripts/release-binaries.sh --create-github-release --publish-npm \
      --proof-file "$TEST_ROOT/public-proof.md"
  )
}

# npm publication happens after the full build; its token must be checked first.
: >"$VERIFY_LOG"
: >"$NODE_LOG"
if run_public_release >"$TEST_ROOT/missing-npm-token.out" 2>&1; then
  echo 'public release accepted a missing NPM_TOKEN' >&2
  exit 1
fi
grep -Fq 'NPM_TOKEN is required for --publish-npm' "$TEST_ROOT/missing-npm-token.out"
[[ ! -s "$VERIFY_LOG" ]]
if grep -Fq 'prepare-release.js' "$NODE_LOG"; then
  echo 'missing NPM_TOKEN reached the release preflight' >&2
  exit 1
fi

# scripts/mac-release narrows PATH before the helper records the child PATH.
for caller_path in default /fixture/bin:/usr/bin:/bin; do
  : >"$VERIFY_LOG"
  caller_env=()
  expected_caller_path=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
  if [[ "$caller_path" != default ]]; then
    caller_env=("MAC_RELEASE_CALLER_PATH=$caller_path")
    expected_caller_path=$caller_path
  fi
  if run_public_release NPM_TOKEN=fixture-token ${caller_env[@]+"${caller_env[@]}"} \
    >"$TEST_ROOT/npm-token.out" 2>&1; then
    echo 'fixture public release unexpectedly passed the stubbed CLI build' >&2
    exit 1
  fi
  if grep -Fq 'NPM_TOKEN is required' "$TEST_ROOT/npm-token.out"; then
    echo 'public release rejected a present NPM_TOKEN' >&2
    exit 1
  fi
  grep -Fq 'prepare-release scripts/prepare-release.js' "$VERIFY_LOG"
  grep -Fxq "mac-release codesign-run -- pnpm run build:swift:all caller-path=$expected_caller_path" \
    "$VERIFY_LOG" || {
    echo "CLI build codesign-run did not receive caller PATH $expected_caller_path" >&2
    exit 1
  }
done

mkdir -p "$FIXTURE_ROOT/build"
printf 'reviewed proof\n' > "$FIXTURE_ROOT/build/proof.md"
: >"$VERIFY_LOG"
if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    ./scripts/release-binaries.sh --create-github-release --proof-file build/proof.md
) >"$TEST_ROOT/build-proof.out" 2>&1; then
  echo 'public release accepted proof inside the disposable build directory' >&2
  exit 1
fi
grep -Fq 'outside the disposable build directory' "$TEST_ROOT/build-proof.out"
[[ ! -s "$VERIFY_LOG" ]]

custom_release_dir="$TEST_ROOT/custom-release"
mkdir -p "$custom_release_dir"
custom_release_dir="$(cd "$custom_release_dir" && pwd -P)"
printf 'peekaboo-release-output-v1:%s:%s\n' "$FIXTURE_ROOT" "$custom_release_dir" > \
  "$custom_release_dir/.peekaboo-release-output"
printf 'reviewed proof\n' > "$custom_release_dir/proof.md"
: >"$VERIFY_LOG"
if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    RELEASE_DIR="$custom_release_dir" \
    ./scripts/release-binaries.sh --create-github-release --proof-file "$custom_release_dir/proof.md"
) >"$TEST_ROOT/release-proof.out" 2>&1; then
  echo 'public release accepted proof inside the disposable custom release directory' >&2
  exit 1
fi
grep -Fq 'outside the disposable release directory' "$TEST_ROOT/release-proof.out"
[[ ! -s "$VERIFY_LOG" ]]

: >"$VERIFY_LOG"
: >"$NODE_LOG"
if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    RELEASE_DIR="$TEST_ROOT/resume-empty" \
    ./scripts/release-binaries.sh --resume-publication
) >"$TEST_ROOT/resume-empty.out" 2>&1; then
  echo 'resume unexpectedly accepted a missing retained release plan' >&2
  exit 1
fi
grep -Fq 'Retained release plan is missing' "$TEST_ROOT/resume-empty.out"
[[ ! -s "$VERIFY_LOG" ]]
if grep -Fq 'prepare-release.js' "$NODE_LOG"; then
  echo 'resume unexpectedly entered the build preflight' >&2
  exit 1
fi

if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    ./scripts/release-binaries.sh --resume-publication --create-github-release
) >"$TEST_ROOT/resume-flags.out" 2>&1; then
  echo 'resume unexpectedly accepted create/publish flags' >&2
  exit 1
fi
grep -Fq 'cannot be combined' "$TEST_ROOT/resume-flags.out"

if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    ./scripts/release-binaries.sh --retry-npm-publish
) >"$TEST_ROOT/retry-flags.out" 2>&1; then
  echo 'npm retry unexpectedly ran without resume mode' >&2
  exit 1
fi
grep -Fq 'requires --resume-publication' "$TEST_ROOT/retry-flags.out"

printf 'local proof\n' > "$TEST_ROOT/local-proof.md"
if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    ./scripts/release-binaries.sh --proof-file "$TEST_ROOT/local-proof.md"
) >"$TEST_ROOT/local-proof.out" 2>&1; then
  echo 'non-public build unexpectedly accepted a publication proof' >&2
  exit 1
fi
grep -Fq -- '--proof-file requires a public release action' "$TEST_ROOT/local-proof.out"

ineligible_dir="$TEST_ROOT/ineligible-release"
mkdir -p "$ineligible_dir"
ineligible_dir="$(cd "$ineligible_dir" && pwd -P)"
printf 'peekaboo-release-output-v1:%s:%s\n' "$FIXTURE_ROOT" "$ineligible_dir" > \
  "$ineligible_dir/.peekaboo-release-output"
printf 'retained proof\n' > "$ineligible_dir/release-proof.md"
ineligible_proof_sha=$(shasum -a 256 "$ineligible_dir/release-proof.md" | awk '{print $1}')
printf '%s\n' \
  "{\"sourceCommit\":\"$FIXTURE_COMMIT\",\"version\":\"9.9.9\",\"helperCommit\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"helperExecutableSHA256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"helperLibrarySHA256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"proofSHA256\":\"$ineligible_proof_sha\",\"preflightCompleted\":false,\"publicationEligible\":false}" |
  "$REAL_NODE" "$FIXTURE_ROOT/scripts/release-driver-contract.mjs" release-plan > \
    "$ineligible_dir/release-plan.json"
if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    RELEASE_DIR="$ineligible_dir" ./scripts/release-binaries.sh --resume-publication
) >"$TEST_ROOT/ineligible-resume.out" 2>&1; then
  echo 'resume unexpectedly accepted a plan without completed public preflight' >&2
  exit 1
fi
grep -Fq 'Retained release plan is not eligible for publication' "$TEST_ROOT/ineligible-resume.out"

release_victim="$TEST_ROOT/release-victim"
release_link="$TEST_ROOT/release-link"
mkdir -p "$release_victim"
printf 'must survive\n' > "$release_victim/sentinel"
ln -s "$release_victim" "$release_link"
if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    RELEASE_DIR="$release_link" ./scripts/release-binaries.sh
) >"$TEST_ROOT/release-link.out" 2>&1; then
  echo 'release unexpectedly accepted a symlinked output directory' >&2
  exit 1
fi
grep -Fq 'Release directory must not be a symlink' "$TEST_ROOT/release-link.out"
grep -Fq 'must survive' "$release_victim/sentinel"

broad_release_dir="$TEST_ROOT/broad-release-dir"
mkdir -p "$broad_release_dir"
printf 'unowned data\n' > "$broad_release_dir/sentinel"
if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    RELEASE_DIR="$broad_release_dir" ./scripts/release-binaries.sh
) >"$TEST_ROOT/broad-release.out" 2>&1; then
  echo 'release unexpectedly accepted an unmarked existing custom directory' >&2
  exit 1
fi
grep -Fq 'lacks the exact Peekaboo output marker' "$TEST_ROOT/broad-release.out"
grep -Fq 'unowned data' "$broad_release_dir/sentinel"

if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    RELEASE_DIR=/private/tmp ./scripts/release-binaries.sh
) >"$TEST_ROOT/shallow-release.out" 2>&1; then
  echo 'release unexpectedly accepted a broad shallow output directory' >&2
  exit 1
fi
grep -Eq 'dedicated narrow output path|too broad for recursive cleanup' "$TEST_ROOT/shallow-release.out"

if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    RELEASE_DIR="$FIXTURE_ROOT/build/new/../.." ./scripts/release-binaries.sh
) >"$TEST_ROOT/parent-release.out" 2>&1; then
  echo 'release unexpectedly accepted parent-directory output components' >&2
  exit 1
fi
grep -Fq 'must not contain parent or current-directory components' "$TEST_ROOT/parent-release.out"

redirect_manifest="$TEST_ROOT/redirect-release.env"
printf 'NPM_REGISTRY=https://registry.example.invalid\n' > "$redirect_manifest"
: >"$VERIFY_LOG"
if (
  cd "$FIXTURE_ROOT"
  PATH="$FAKE_BIN:$PATH" PEEKABOO_REUSE_REAL_NODE="$REAL_NODE" \
    PEEKABOO_REUSE_NODE_LOG="$NODE_LOG" PEEKABOO_REUSE_TEST_LOG="$VERIFY_LOG" \
    MAC_RELEASE_MANIFEST="$redirect_manifest" ./scripts/release-binaries.sh
) >"$TEST_ROOT/redirect-release.out" 2>&1; then
  echo 'release manifest unexpectedly redirected a canonical publication endpoint' >&2
  exit 1
fi
grep -Fq 'NPM_REGISTRY: readonly variable' "$TEST_ROOT/redirect-release.out"
[[ ! -s "$VERIFY_LOG" ]]

printf '%s\n' 'test-release-binary-reuse: ok'
