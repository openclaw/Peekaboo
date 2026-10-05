#!/bin/bash

# Wrapper script for Playground logging utility
# This allows running playground-log.sh from the project root

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAYGROUND_LOG="$SCRIPT_DIR/../Apps/Playground/scripts/playground-log.sh"

if [[ ! -f "$PLAYGROUND_LOG" ]]; then
    echo "Error: Playground log script not found at $PLAYGROUND_LOG" >&2
    echo "Make sure the Playground app is built and the script exists." >&2
    exit 1
fi

# Forward all arguments to the actual script
exec "$PLAYGROUND_LOG" "$@"
