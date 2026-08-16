#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/source-provenance.sh"

EXPECTED_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
[[ "$(peekaboo_source_commit_from_repo "$ROOT_DIR")" == "$EXPECTED_COMMIT" ]]
[[ "$(peekaboo_short_source_commit "$EXPECTED_COMMIT")" == "${EXPECTED_COMMIT:0:9}" ]]

PROVENANCE_TEST_REPOSITORY="$(mktemp -d /tmp/peekaboo-source-test.XXXXXX)"
[[ "$(peekaboo_source_commit_from_repo "$PROVENANCE_TEST_REPOSITORY")" == unknown ]]
[[ "$(peekaboo_debug_source_commit "$PROVENANCE_TEST_REPOSITORY")" == unknown ]]
[[ "$(peekaboo_source_dirty_suffix "$PROVENANCE_TEST_REPOSITORY")" == -dirty ]]
if peekaboo_require_source_commit "$PROVENANCE_TEST_REPOSITORY" >/dev/null 2>&1; then
  echo "stamped source resolution unexpectedly accepted a non-repository" >&2
  exit 1
fi
git -C "$PROVENANCE_TEST_REPOSITORY" init -q
git -C "$PROVENANCE_TEST_REPOSITORY" \
  -c user.name=Peekaboo -c user.email=peekaboo@example.invalid \
  commit -q --allow-empty -m initial
TEST_COMMIT="$(git -C "$PROVENANCE_TEST_REPOSITORY" rev-parse HEAD)"
HISTORICAL_COMMIT=0123456789abcdef0123456789abcdef01234567
[[ "$(peekaboo_require_source_commit "$PROVENANCE_TEST_REPOSITORY")" == "$TEST_COMMIT" ]]
[[ "$(peekaboo_debug_source_commit "$PROVENANCE_TEST_REPOSITORY")" == "$TEST_COMMIT" ]]
[[ -z "$(peekaboo_source_dirty_suffix "$PROVENANCE_TEST_REPOSITORY")" ]]
[[ "$(PEEKABOO_REQUIRE_SOURCE_PROVENANCE=1 \
  peekaboo_debug_source_commit "$PROVENANCE_TEST_REPOSITORY")" == "$TEST_COMMIT" ]]
peekaboo_validate_artifact_source_commit "$PROVENANCE_TEST_REPOSITORY" "$TEST_COMMIT" "$TEST_COMMIT"
peekaboo_validate_artifact_source_commit "$PROVENANCE_TEST_REPOSITORY" "$HISTORICAL_COMMIT" ""
if peekaboo_validate_artifact_source_commit \
  "$PROVENANCE_TEST_REPOSITORY" "$HISTORICAL_COMMIT" "$TEST_COMMIT"; then
  echo "current-checkout validation unexpectedly accepted a historical artifact" >&2
  exit 1
else
  [[ "$?" -eq 5 ]]
fi
if peekaboo_validate_artifact_source_commit "$PROVENANCE_TEST_REPOSITORY" unknown ""; then
  echo "verify-only validation unexpectedly accepted an unstamped artifact" >&2
  exit 1
else
  [[ "$?" -eq 2 ]]
fi
mv "$PROVENANCE_TEST_REPOSITORY/.git/index" "$PROVENANCE_TEST_REPOSITORY/.git/index.saved"
mkdir "$PROVENANCE_TEST_REPOSITORY/.git/index"
if peekaboo_require_source_commit "$PROVENANCE_TEST_REPOSITORY" >/dev/null 2>&1; then
  echo "stamped source resolution ignored a Git status failure" >&2
  exit 1
fi
[[ "$(peekaboo_debug_source_commit "$PROVENANCE_TEST_REPOSITORY")" == unknown ]]
if PEEKABOO_REQUIRE_SOURCE_PROVENANCE=1 \
  peekaboo_debug_source_commit "$PROVENANCE_TEST_REPOSITORY" >/dev/null 2>&1; then
  echo "strict debug source resolution ignored a Git status failure" >&2
  exit 1
fi
[[ "$(peekaboo_source_dirty_suffix "$PROVENANCE_TEST_REPOSITORY")" == -dirty ]]
rmdir "$PROVENANCE_TEST_REPOSITORY/.git/index"
mv "$PROVENANCE_TEST_REPOSITORY/.git/index.saved" "$PROVENANCE_TEST_REPOSITORY/.git/index"
touch "$PROVENANCE_TEST_REPOSITORY/untracked-build-input"
if peekaboo_require_source_commit "$PROVENANCE_TEST_REPOSITORY" >/dev/null 2>&1; then
  echo "stamped source resolution unexpectedly accepted a dirty repository" >&2
  exit 1
fi
[[ "$(peekaboo_debug_source_commit "$PROVENANCE_TEST_REPOSITORY")" == unknown ]]
if PEEKABOO_REQUIRE_SOURCE_PROVENANCE=1 \
  peekaboo_debug_source_commit "$PROVENANCE_TEST_REPOSITORY" >/dev/null 2>&1; then
  echo "strict debug source resolution unexpectedly accepted a dirty repository" >&2
  exit 1
fi
[[ "$(peekaboo_source_dirty_suffix "$PROVENANCE_TEST_REPOSITORY")" == -dirty ]]
peekaboo_validate_artifact_source_commit "$PROVENANCE_TEST_REPOSITORY" "$HISTORICAL_COMMIT" ""
if peekaboo_validate_artifact_source_commit \
  "$PROVENANCE_TEST_REPOSITORY" "$TEST_COMMIT" "$TEST_COMMIT" >/dev/null 2>&1; then
  echo "current-checkout validation unexpectedly accepted a dirty repository" >&2
  exit 1
else
  [[ "$?" -eq 4 ]]
fi
rm -rf "$PROVENANCE_TEST_REPOSITORY"

for malformed in \
  '' unknown abc1234 \
  0123456789abcdef0123456789abcdef0123456g \
  0123456789ABCDEF0123456789ABCDEF01234567 \
  0123456789abcdef0123456789abcdef01234567-dirty; do
  if peekaboo_is_exact_source_commit "$malformed"; then
    echo "unexpected valid source commit: $malformed" >&2
    exit 1
  fi
done

for build_script in \
  "$ROOT_DIR/scripts/build-swift-arm.sh" \
  "$ROOT_DIR/scripts/build-swift-universal.sh"; do
  rg -Fq 'PeekabooSourceCommit' "$build_script"
  rg -Fq 'peekaboo_require_source_commit' "$build_script"
  rg -Fq 'peekaboo_verify_source_commit' "$build_script"
  if rg -q 'rev-parse[[:space:]]+--short' "$build_script"; then
    echo "short-only source commit stamping remains in $build_script" >&2
    exit 1
  fi
done

rg -Fq 'peekaboo_debug_source_commit' "$ROOT_DIR/scripts/build-swift-debug.sh"
rg -Fq 'peekaboo_source_commit_from_repo' "$ROOT_DIR/scripts/build-swift-debug.sh"
rg -Fq 'peekaboo_source_dirty_suffix' "$ROOT_DIR/scripts/build-swift-debug.sh"
rg -Fq 'peekaboo_verify_source_commit' "$ROOT_DIR/scripts/build-swift-debug.sh"

rg -Fq '<key>PeekabooSourceCommit</key>' "$ROOT_DIR/Apps/CLI/Sources/Resources/Info.plist"
rg -Fq '<string>unknown</string>' "$ROOT_DIR/Apps/CLI/Sources/Resources/Info.plist"
rg -Fq '<string>$(PEEKABOO_SOURCE_COMMIT)</string>' "$ROOT_DIR/Apps/Mac/Peekaboo/Info.plist"
rg -Fq 'PEEKABOO_SOURCE_COMMIT = unknown;' "$ROOT_DIR/Apps/Mac/Peekaboo.xcodeproj/project.pbxproj"
rg -Fq 'PEEKABOO_SOURCE_COMMIT="$SOURCE_COMMIT"' "$ROOT_DIR/scripts/build-mac-debug.sh"
rg -Fq 'peekaboo_debug_source_commit' "$ROOT_DIR/scripts/build-mac-debug.sh"
rg -Fq 'PEEKABOO_SOURCE_COMMIT="$SOURCE_COMMIT"' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'source "$ROOT/scripts/source-provenance.sh"' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'SOURCE_COMMIT="$(peekaboo_require_source_commit "$ROOT")"' \
  "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'SOURCE_COMMIT=""' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'if [[ -z "$VERIFY_ONLY_ZIP" ]]; then' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'peekaboo_validate_artifact_source_commit' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'App has no exact 40-hex source commit' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'App source commit does not match the release root' "$ROOT_DIR/scripts/release-macos-app.sh"
rg -Fq 'sourceCommit' "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'source_commit' "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'bridge-before.json' "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'bridge-after.json' "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq '.socketPath == $socketPath' "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'requested_bridge_socket' "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'event_producer_stable' "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq -- '--bridge-socket "$ARTIFACT_ROOT/explicit-bridge.sock"' \
  "$ROOT_DIR/scripts/test-background-certification.sh"
rg -Fq 'exec "$PEEKABOO_BIN" "$@" --json --no-remote' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'exec "$PEEKABOO_BIN" "$@" --json --bridge-socket "$BRIDGE_SOCKET"' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq -- '--physical-input-observational' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq -- '--cursor-observational' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq -- '--execution-nonce "$RUN_EXECUTION_NONCE"' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq -- '--monitor-instance-id "$monitor_instance_id"' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq -- '--history-commitment "$history_commitment"' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'source_artifacts: $sourceArtifacts' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'cli_executable_sha256: $cliExecutableSHA256' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'bridge_executable_sha256: $bridgeExecutableSHA256' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'monitor_receipt: {' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'PeekabooPlaygroundSource.json' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'open -g -n "$application_path"' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'type "$TYPE_TOKEN" --clear --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID"' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"
rg -Fq 'press return --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID"' \
  "$ROOT_DIR/scripts/test-background-computer-use.sh"

echo "test-source-provenance: ok"
