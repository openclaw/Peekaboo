#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_ROOT=""
REMOVE_ARTIFACT_ROOT=false

usage() {
    cat <<'EOF'
Usage: scripts/test-background-certification.sh [--artifacts PATH]

Runs the deterministic background-certification gate. When PATH is supplied,
it must name a new or empty directory and is retained after the gate completes.
EOF
}

if [[ $# -gt 0 ]]; then
    if [[ $# -ne 2 || "$1" != "--artifacts" || -z "$2" || "$2" == --* ]]; then
        usage >&2
        exit 2
    fi
    ARTIFACT_ROOT="$2"
fi

if [[ -z "$ARTIFACT_ROOT" ]]; then
    ARTIFACT_ROOT="$(mktemp -d /tmp/peekaboo-background-certification.XXXXXX)"
    REMOVE_ARTIFACT_ROOT=true
else
    if [[ "$ARTIFACT_ROOT" != /* ]]; then
        ARTIFACT_ROOT="$ROOT_DIR/$ARTIFACT_ROOT"
    fi
    if [[ -e "$ARTIFACT_ROOT" && ! -d "$ARTIFACT_ROOT" ]]; then
        printf 'Artifact path is not a directory: %s\n' "$ARTIFACT_ROOT" >&2
        exit 2
    fi
    mkdir -p "$ARTIFACT_ROOT"
    if ! ARTIFACT_ENTRY="$(node -e '
        const fs = require("node:fs");
        const directory = fs.opendirSync(process.argv[1]);
        const entry = directory.readSync();
        directory.closeSync();
        if (entry) process.stdout.write(entry.name);
    ' "$ARTIFACT_ROOT" 2>/dev/null)"; then
        printf 'Cannot inspect artifact directory: %s\n' "$ARTIFACT_ROOT" >&2
        exit 2
    fi
    if [[ -n "$ARTIFACT_ENTRY" ]]; then
        printf 'Artifact directory must be new or empty: %s\n' "$ARTIFACT_ROOT" >&2
        exit 2
    fi
    ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd -P)"
    chmod 700 "$ARTIFACT_ROOT"
fi

cleanup() {
    if $REMOVE_ARTIFACT_ROOT && [[ "$ARTIFACT_ROOT" == /tmp/peekaboo-background-certification.* ]]; then
        rm -rf -- "$ARTIFACT_ROOT"
    fi
}
trap cleanup EXIT

"$ROOT_DIR/scripts/test-background-computer-use.sh" \
  --self-test \
  --bridge-socket "$ARTIFACT_ROOT/explicit-bridge.sock" \
  --artifacts "$ARTIFACT_ROOT/harness"
node --test "$ROOT_DIR/tests/background-computer-use-report.test.mjs"
node --test "$ROOT_DIR/tests/multi-target-certification.test.mjs"
node --test "$ROOT_DIR/tests/live-multi-target-certification-coordinator.test.mjs"
node --test "$ROOT_DIR/scripts/final-qualification/test/qualification-tools.test.mjs"

if ! $REMOVE_ARTIFACT_ROOT; then
    printf 'Background certification self-test passed: %s\n' "$ARTIFACT_ROOT"
fi
