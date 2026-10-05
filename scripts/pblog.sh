#!/bin/bash

# Default values
LINES=50
TIME="5m"
LEVEL="info"
CATEGORY=""
SEARCH=""
OUTPUT=""
DEBUG=false
FOLLOW=false
ERRORS_ONLY=false
NO_TAIL=false
JSON=false
SUBSYSTEM=""
PRIVATE=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--lines|-l|--last|-c|--category|-s|--search|-o|--output|--subsystem)
            if [[ $# -lt 2 ]]; then
                printf '%s requires a value\n' "$1" >&2
                exit 2
            fi
            ;;
    esac
    case $1 in
        -n|--lines)
            LINES="$2"
            shift 2
            ;;
        -l|--last)
            TIME="$2"
            shift 2
            ;;
        -c|--category)
            CATEGORY="$2"
            shift 2
            ;;
        -s|--search)
            SEARCH="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT="$2"
            shift 2
            ;;
        -d|--debug)
            DEBUG=true
            LEVEL="debug"
            shift
            ;;
        -f|--follow)
            FOLLOW=true
            shift
            ;;
        -e|--errors)
            ERRORS_ONLY=true
            LEVEL="error"
            shift
            ;;
        -p|--private)
            PRIVATE=true
            shift
            ;;
        --all)
            NO_TAIL=true
            shift
            ;;
        --json)
            JSON=true
            shift
            ;;
        --subsystem)
            SUBSYSTEM="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: pblog.sh [options]"
            echo ""
            echo "Options:"
            echo "  -n, --lines NUM      Number of lines to show (default: 50)"
            echo "  -l, --last TIME      Time range to search (default: 5m)"
            echo "  -c, --category CAT   Filter by category"
            echo "  -s, --search TEXT    Search for specific text"
            echo "  -o, --output FILE    Output to file"
            echo "  -d, --debug          Show debug level logs"
            echo "  -f, --follow         Stream logs continuously"
            echo "  -e, --errors         Show only errors"
            echo "  -p, --private        Show private data (requires passwordless sudo)"
            echo "  --all                Show all logs without tail limit"
            echo "  --json               Output in JSON format"
            echo "  --subsystem NAME     Filter by subsystem (default: all Peekaboo subsystems)"
            echo "  -h, --help           Show this help"
            echo ""
            echo "Peekaboo subsystems:"
            echo "  boo.peekaboo.core       - Core services"
            echo "  boo.peekaboo.cli        - CLI tool"
            echo "  boo.peekaboo.inspector  - Inspector app"
            echo "  boo.peekaboo.playground - Playground app"
            echo "  boo.peekaboo.app        - Mac app"
            echo "  boo.peekaboo            - Mac app components"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Build predicate - either specific subsystem or all Peekaboo subsystems
if [[ -n "$SUBSYSTEM" ]]; then
    PREDICATE="subsystem == \"$SUBSYSTEM\""
else
    # Match all Peekaboo-related subsystems
    PREDICATE="(subsystem == \"boo.peekaboo.core\" OR subsystem == \"boo.peekaboo.inspector\" OR subsystem == \"boo.peekaboo.playground\" OR subsystem == \"boo.peekaboo.app\" OR subsystem == \"boo.peekaboo\" OR subsystem == \"boo.peekaboo.axorcist\" OR subsystem == \"boo.peekaboo.cli\")"
fi

if [[ -n "$CATEGORY" ]]; then
    PREDICATE="$PREDICATE AND category == \"$CATEGORY\""
fi

if [[ -n "$SEARCH" ]]; then
    PREDICATE="$PREDICATE AND eventMessage CONTAINS[c] \"$SEARCH\""
fi

# Build command
# Add sudo prefix if private flag is set
SUDO_PREFIX=""
if [[ "$PRIVATE" == true ]]; then
    SUDO_PREFIX="sudo -n "
fi

if [[ "$FOLLOW" == true ]]; then
    CMD="${SUDO_PREFIX}log stream --predicate '$PREDICATE' --level $LEVEL"
else
    # log show uses different flags for log levels
    case $LEVEL in
        debug)
            CMD="${SUDO_PREFIX}log show --predicate '$PREDICATE' --debug --last $TIME"
            ;;
        error)
            # For errors, we need to filter by eventType in the predicate
            PREDICATE="$PREDICATE AND eventType == \"error\""
            CMD="${SUDO_PREFIX}log show --predicate '$PREDICATE' --info --debug --last $TIME"
            ;;
        *)
            CMD="${SUDO_PREFIX}log show --predicate '$PREDICATE' --info --last $TIME"
            ;;
    esac
fi

if [[ "$JSON" == true ]]; then
    CMD="$CMD --style json"
fi

# Execute command
if [[ -n "$OUTPUT" ]]; then
    if [[ "$NO_TAIL" == true ]]; then
        eval $CMD > "$OUTPUT"
    else
        eval $CMD | tail -n $LINES > "$OUTPUT"
    fi
else
    if [[ "$NO_TAIL" == true ]]; then
        eval $CMD
    else
        eval $CMD | tail -n $LINES
    fi
fi