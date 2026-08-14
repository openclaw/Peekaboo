#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT="$(mktemp -d /tmp/peekaboo-background-certification.XXXXXX)"
trap 'rm -rf "$ARTIFACT_ROOT"' EXIT

"$ROOT_DIR/scripts/test-background-computer-use.sh" \
  --self-test \
  --bridge-socket "$ARTIFACT_ROOT/explicit-bridge.sock" \
  --artifacts "$ARTIFACT_ROOT/harness"
node --test "$ROOT_DIR/tests/background-computer-use-report.test.mjs"
node --test "$ROOT_DIR/tests/dual-controller-overlap-report.test.mjs"
"$ROOT_DIR/scripts/test-dual-controller-overlap.sh" \
  --self-test \
  --artifacts "$ARTIFACT_ROOT/dual-controller-overlap"
