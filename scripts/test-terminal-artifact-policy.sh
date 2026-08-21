#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERMINAL_ARTIFACT_ROOT="$ROOT_DIR"
export TERMINAL_ARTIFACT_ROOT
# shellcheck source=scripts/terminal-artifact-policy.sh
source "$ROOT_DIR/scripts/terminal-artifact-policy.sh"
TEST_DIR="$(mktemp -d /tmp/peekaboo-terminal-policy-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

mkdir -p "$TEST_DIR/Fixture.app/Contents/Resources"
printf 'fixture\n' > "$TEST_DIR/Fixture.app/Contents/Resources/value"
terminal_artifact_zip_app_exact "$TEST_DIR/Fixture.app" "$TEST_DIR/fixture.zip" "$TEST_DIR/tree.json"

/usr/bin/xattr -w com.openclaw.peekaboo.fixture value "$TEST_DIR/Fixture.app/Contents/Resources/value"
if terminal_artifact_assert_no_xattrs "$TEST_DIR/Fixture.app"; then
  printf 'test-terminal-artifact-policy: xattr was accepted\n' >&2
  exit 1
fi
/usr/bin/xattr -d com.openclaw.peekaboo.fixture "$TEST_DIR/Fixture.app/Contents/Resources/value"

mkdir -p "$TEST_DIR/appledouble/__MACOSX"
printf 'extra\n' > "$TEST_DIR/appledouble/__MACOSX/._Fixture"
(cd "$TEST_DIR/appledouble" && /usr/bin/zip -qr "$TEST_DIR/appledouble.zip" .)
terminal_artifact_zip_has_appledouble "$TEST_DIR/appledouble.zip" || {
  printf 'test-terminal-artifact-policy: AppleDouble entry was accepted\n' >&2
  exit 1
}

printf 'test-terminal-artifact-policy: ok\n'
