#!/usr/bin/env bash
set -euo pipefail

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

cp "$ROOT_DIR/scripts/release-binaries.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/native-only-policy.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/source-provenance.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/release-version.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/release-driver-contract.mjs" "$FIXTURE_ROOT/scripts/"

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
cat >"$FIXTURE_ROOT/.gitignore" <<'IGNORE'
/build/
/peekaboo
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
printf '%s\n' "${PEEKABOO_REUSE_TEST_ARCHS:-x86_64 arm64}"
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
cp peekaboo "$package_root/package/peekaboo"
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
chmod +x "$FIXTURE_ROOT/peekaboo"
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
      ./scripts/release-binaries.sh --reuse-built-cli --skip-mac-app --no-appcast
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
run_release "$FIXTURE_COMMIT" >"$TEST_ROOT/success.out" 2>&1
grep -Fq 'Release artifacts created successfully' "$TEST_ROOT/success.out"
[[ "$(shasum -a 256 "$FIXTURE_ROOT/peekaboo" | awk '{print $1}')" == "$candidate_sha_before" ]]

first_candidate=$(grep -n -m1 '^candidate-executed$' "$VERIFY_LOG" | cut -d: -f1)
for required_gate in \
  file-macho codesign-verify signer-requirement entitlements native-imports native-strings \
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
