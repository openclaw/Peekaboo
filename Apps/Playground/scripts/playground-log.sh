#!/bin/bash

set -o pipefail

# Peekaboo Playground Log Viewer
# A pblog-inspired utility for viewing Playground app logs

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
SHOW_ALL_CATEGORIES=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--lines|-l|--last|-c|--category|-s|--search|-o|--output)
            if [[ $# -lt 2 ]]; then
                printf 'playground-log.sh: %s requires a value\n' "$1" >&2
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
        --all)
            NO_TAIL=true
            shift
            ;;
        --json)
            JSON=true
            shift
            ;;
        --categories)
            SHOW_ALL_CATEGORIES=true
            shift
            ;;
        -h|--help)
            echo "Peekaboo Playground Log Viewer"
            echo "Usage: playground-log.sh [options]"
            echo ""
            echo "Options:"
            echo "  -n, --lines NUM      Completed text-query line limit (default: 50)"
            echo "  -l, --last TIME      Time range to search (default: 5m)"
            echo "  -c, --category CAT   Filter by category (Click, Text, Menu, etc.)"
            echo "  -s, --search TEXT    Search for specific text"
            echo "  -o, --output FILE    Output to file"
            echo "  -d, --debug          Show debug level logs"
            echo "  -f, --follow         Stream logs continuously"
            echo "  -e, --errors         Show only errors"
            echo "  --all                Show all logs without tail limit"
            echo "  --json               Preserve JSON framing without a line limit"
            echo "  --categories         List available categories"
            echo "  -h, --help           Show this help"
            echo ""
            echo "Categories:"
            echo "  Click     - Button clicks, toggles, click areas"
            echo "  Text      - Text input, field changes"
            echo "  Menu      - Menu selections, context menus"
            echo "  Window    - Window operations"
            echo "  Scroll    - Scroll events"
            echo "  Drag      - Drag and drop operations"
            echo "  Keyboard  - Key presses, hotkeys"
            echo "  Focus     - Focus changes"
            echo "  Gesture   - Swipes, pinches, rotations"
            echo "  Control   - Sliders, pickers, other controls"
            echo "  Space     - Space list/move/switch events"
            echo "  App       - Application events"
            echo "  MCP       - MCP tool invocations"
            echo ""
            echo "Examples:"
            echo "  playground-log.sh                           # Show last 50 lines from past 5 minutes"
            echo "  playground-log.sh -f                       # Stream logs continuously"
            echo "  playground-log.sh -c Click -n 100          # Show 100 Click category logs"
            echo "  playground-log.sh -s \"button clicked\"      # Search for specific text"
            echo "  playground-log.sh -e                       # Show only errors"
            echo "  playground-log.sh -d -l 30m                # Debug logs from last 30 minutes"
            echo "  playground-log.sh --all -o playground.log  # Export all logs to file"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use -h or --help for usage information." >&2
            exit 1
            ;;
    esac
done

# Show available categories if requested
if [[ "$SHOW_ALL_CATEGORIES" == true ]]; then
    echo "Available log categories for Peekaboo Playground:"
    echo ""
    echo -e "${BLUE}Click${NC}     - Button clicks, toggles, click areas"
    echo -e "${GREEN}Text${NC}      - Text input, field changes"
    echo -e "${PURPLE}Menu${NC}      - Menu selections, context menus"
    echo -e "${YELLOW}Window${NC}    - Window operations"
    echo -e "${CYAN}Scroll${NC}    - Scroll events"
    echo -e "${RED}Drag${NC}      - Drag and drop operations"
    echo -e "${YELLOW}Keyboard${NC}  - Key presses, hotkeys"
    echo -e "${BLUE}Focus${NC}     - Focus changes"
    echo -e "${RED}Gesture${NC}   - Swipes, pinches, rotations"
    echo -e "${GREEN}Control${NC}   - Sliders, pickers, other controls"
    echo -e "${CYAN}Space${NC}     - Space list/move/switch events"
    echo -e "${PURPLE}App${NC}       - Application events"
    echo -e "${CYAN}MCP${NC}       - MCP tool invocations"
    exit 0
fi

predicate_literal() {
    PREDICATE_LITERAL="${1//\\/\\\\}"
    PREDICATE_LITERAL="${PREDICATE_LITERAL//\"/\\\"}"
}

# Build predicate - using PeekabooPlayground's subsystem
PREDICATE="subsystem == \"boo.peekaboo.playground\""

if [[ -n "$CATEGORY" ]]; then
    predicate_literal "$CATEGORY"
    PREDICATE="$PREDICATE AND category == \"$PREDICATE_LITERAL\""
fi

if [[ -n "$SEARCH" ]]; then
    predicate_literal "$SEARCH"
    PREDICATE="$PREDICATE AND eventMessage CONTAINS[c] \"$PREDICATE_LITERAL\""
fi

# Build command
if [[ "$FOLLOW" == true ]]; then
    CMD=(log stream --predicate "$PREDICATE" --level "$LEVEL")
else
    # log show uses different flags for log levels
    case $LEVEL in
        debug)
            CMD=(log show --predicate "$PREDICATE" --debug --last "$TIME")
            ;;
        error)
            PREDICATE="$PREDICATE AND logType == \"error\""
            CMD=(log show --predicate "$PREDICATE" --info --debug --last "$TIME")
            ;;
        *)
            CMD=(log show --predicate "$PREDICATE" --info --last "$TIME")
            ;;
    esac
fi

if [[ "$JSON" == true ]]; then
    CMD+=(--style json)
fi

# Add color formatting function for non-JSON output
format_output() {
    local line color
    if [[ "$JSON" == true ]]; then
        cat
    else
        while IFS= read -r line; do
            # Color-code different categories
            if [[ $line =~ \[Click\] ]]; then
                color="$BLUE"
            elif [[ $line =~ \[Text\] ]]; then
                color="$GREEN"
            elif [[ $line =~ \[Menu\] ]]; then
                color="$PURPLE"
            elif [[ $line =~ \[Window\] ]]; then
                color="$YELLOW"
            elif [[ $line =~ \[Scroll\] ]]; then
                color="$CYAN"
            elif [[ $line =~ \[Space\] ]]; then
                color="$CYAN"
            elif [[ $line =~ \[Drag\] ]]; then
                color="$RED"
            elif [[ $line =~ \[Keyboard\] ]]; then
                color="$YELLOW"
            elif [[ $line =~ \[Focus\] ]]; then
                color="$BLUE"
            elif [[ $line =~ \[Gesture\] ]]; then
                color="$RED"
            elif [[ $line =~ \[Control\] ]]; then
                color="$GREEN"
            elif [[ $line =~ \[App\] ]]; then
                color="$PURPLE"
            elif [[ $line =~ \[MCP\] ]]; then
                color="$CYAN"
            else
                printf '%s\n' "$line"
                continue
            fi
            printf '%b%s%b\n' "$color" "$line" "$NC"
        done
    fi
}

# Physical-line tailing corrupts JSON and holds live events until EOF.
if [[ "$JSON" == true || "$FOLLOW" == true ]]; then
    NO_TAIL=true
fi

# Show header unless outputting to file or JSON
if [[ -z "$OUTPUT" && "$JSON" != true ]]; then
    echo -e "${BLUE}Peekaboo Playground Log Viewer${NC}"
    echo "Subsystem: boo.peekaboo.playground"
    if [[ -n "$CATEGORY" ]]; then
        echo "Category: $CATEGORY"
    fi
    if [[ -n "$SEARCH" ]]; then
        echo "Search: $SEARCH"
    fi
    if [[ "$FOLLOW" == true ]]; then
        echo "Mode: streaming (no line limit)"
    else
        echo "Time range: $TIME"
        if [[ "$NO_TAIL" == true ]]; then
            echo "Lines: all"
        else
            echo "Lines: $LINES"
        fi
    fi
    echo "---"
fi

# Execute command
if [[ -n "$OUTPUT" ]]; then
    if [[ "$NO_TAIL" == true ]]; then
        "${CMD[@]}" > "$OUTPUT" || exit "$?"
        echo "Logs saved to: $OUTPUT"
    else
        "${CMD[@]}" | tail -n "$LINES" > "$OUTPUT" || exit "$?"
        echo "Last $LINES lines saved to: $OUTPUT"
    fi
else
    if [[ "$NO_TAIL" == true ]]; then
        "${CMD[@]}" | format_output
    else
        "${CMD[@]}" | tail -n "$LINES" | format_output
    fi
fi
