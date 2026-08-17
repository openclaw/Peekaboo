#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    cat <<'EOF'
Usage: scripts/test-dual-controller-overlap.sh [--self-test]

This compatibility entry point preserves the documented pre-v4 workflow name.

  --self-test   Run the replacement deterministic background-certification gate
  -h, --help    Show this migration help

Live dual-controller execution now requires one closed owner-private plan:

  node scripts/run-live-multi-target-certification.mjs \
    --plan /private/path/to/live-coordinator-plan.json

The old live flags cannot be translated safely because the v4 coordinator also
requires exact controller builds, process generations, code identities, targets,
timeouts, monitor state, and external foreground marker paths.
EOF
}

if [[ $# -eq 1 && "$1" == "--self-test" ]]; then
    printf '%s\n' \
        'Deprecated entry point: running scripts/test-background-certification.sh.' >&2
    exec "$ROOT_DIR/scripts/test-background-certification.sh"
fi
if [[ $# -eq 1 && ("$1" == "-h" || "$1" == "--help") ]]; then
    usage
    exit 0
fi

usage >&2
exit 2
