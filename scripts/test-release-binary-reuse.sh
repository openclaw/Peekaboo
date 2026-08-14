#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d /tmp/peekaboo-release-reuse-test.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT

FIXTURE_ROOT="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
VERIFY_LOG="$TEST_ROOT/verify.log"
mkdir -p "$FIXTURE_ROOT/scripts" "$FAKE_BIN"

cp "$ROOT_DIR/scripts/release-binaries.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/native-only-policy.sh" "$FIXTURE_ROOT/scripts/"
cp "$ROOT_DIR/scripts/source-provenance.sh" "$FIXTURE_ROOT/scripts/"

cat >"$FIXTURE_ROOT/package.json" <<'JSON'
{"name":"peekaboo-release-reuse-fixture","version":"9.9.9"}
JSON
cat >"$FIXTURE_ROOT/CHANGELOG.md" <<'CHANGELOG'
## 9.9.9 - 2026-08-13

- Test release.
CHANGELOG
printf '%s\n' 'fixture license' >"$FIXTURE_ROOT/LICENSE"
cat >"$FIXTURE_ROOT/.gitignore" <<'IGNORE'
/build/
/release/
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
      PEEKABOO_REUSE_TEST_SOURCE_COMMIT="$1" \
      PEEKABOO_REUSE_TEST_ENTITLEMENTS="${2:-safe}" \
      PEEKABOO_REUSE_TEST_ARCHS="${3:-x86_64 arm64}" \
      ./scripts/release-binaries.sh --skip-checks --reuse-built-cli --skip-mac-app --no-appcast
  )
}

touch "$FIXTURE_ROOT/untracked-input"
: >"$VERIFY_LOG"
if run_release "$FIXTURE_COMMIT" >"$TEST_ROOT/dirty.out" 2>&1; then
  echo 'reuse unexpectedly accepted a dirty release checkout' >&2
  exit 1
fi
grep -Fq 'full release checkout is clean' "$TEST_ROOT/dirty.out"
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
run_release "$FIXTURE_COMMIT" >"$TEST_ROOT/success.out" 2>&1
grep -Fq 'Release artifacts created successfully' "$TEST_ROOT/success.out"

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

printf '%s\n' 'test-release-binary-reuse: ok'
