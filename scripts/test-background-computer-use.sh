#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTIFICATION_CATALOG="$ROOT_DIR/scripts/background-computer-use-catalog.json"
CERTIFICATION_REPORTER="$ROOT_DIR/scripts/validate-background-computer-use-report.mjs"
CERTIFICATION_TEST="$ROOT_DIR/tests/background-computer-use-report.test.mjs"
PLAYGROUND_BUNDLE_ID="boo.peekaboo.playground.debug"
SENTINEL_BUNDLE_ID=""
PEEKABOO_BIN="${PEEKABOO_BIN:-}"
ARTIFACT_ROOT=""
PLAYGROUND_APP=""
SKIP_PLAYGROUND_BUILD=false
RUN_FOREGROUND_PHASE=false
SELF_TEST_ONLY=false
NO_REMOTE=false
BRIDGE_SOCKET="${PEEKABOO_CERTIFICATION_BRIDGE_SOCKET:-${PEEKABOO_BRIDGE_SOCKET:-}}"

usage() {
    cat <<'EOF'
Usage: scripts/test-background-computer-use.sh [options]

Deterministically validates that targeted Peekaboo computer-use operations stay
in the background. The optional foreground phase is the only phase allowed to
move the physical cursor or synthesize pointer/wheel events.

Options:
  --bin PATH                 Peekaboo CLI (default: repo debug binary, then PATH)
  --artifacts PATH           Artifact directory (default: .artifacts/background-computer-use/<UTC>)
  --playground-app PATH      Use an existing signed Playground.app
  --skip-playground-build    Require --playground-app and skip xcodebuild
  --foreground-phase        Also run explicit physical-pointer tests
  --no-remote               Force the exact CLI process to use its local TCC grants
  --bridge-socket PATH      Pin every remote command to one exact Bridge host
                            (default: Peekaboo.app's bridge.sock)
  --sentinel-bundle-id ID   Require this app to already be frontmost (default: current app)
  --self-test               Compile and self-test the invariant probe only
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin)
            PEEKABOO_BIN="$2"
            shift 2
            ;;
        --artifacts)
            ARTIFACT_ROOT="$2"
            shift 2
            ;;
        --playground-app)
            PLAYGROUND_APP="$2"
            shift 2
            ;;
        --skip-playground-build)
            SKIP_PLAYGROUND_BUILD=true
            shift
            ;;
        --foreground-phase)
            RUN_FOREGROUND_PHASE=true
            shift
            ;;
        --no-remote)
            NO_REMOTE=true
            shift
            ;;
        --bridge-socket)
            BRIDGE_SOCKET="$2"
            shift 2
            ;;
        --sentinel-bundle-id)
            SENTINEL_BUNDLE_ID="$2"
            shift 2
            ;;
        --self-test)
            SELF_TEST_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if ! $NO_REMOTE && [[ -z "$BRIDGE_SOCKET" ]]; then
    BRIDGE_SOCKET="$HOME/Library/Application Support/Peekaboo/bridge.sock"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This harness requires macOS." >&2
    exit 2
fi

for command_name in jq node rg swiftc xcodebuild codesign security; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 2
    fi
done

CERTIFICATION_INVARIANTS_JSON="$(jq -cer '
    .invariants |
    select(type == "array" and length > 0) |
    select(all(.[]; type == "string" and length > 0)) |
    select((unique | length) == length)
' "$CERTIFICATION_CATALOG")" || {
    echo "Certification catalog must declare unique nonempty invariant names." >&2
    exit 2
}

if [[ -z "$ARTIFACT_ROOT" ]]; then
    ARTIFACT_ROOT="$ROOT_DIR/.artifacts/background-computer-use/$(date -u +%Y%m%dT%H%M%SZ)"
elif [[ "$ARTIFACT_ROOT" != /* ]]; then
    ARTIFACT_ROOT="$ROOT_DIR/$ARTIFACT_ROOT"
fi
if [[ -e "$ARTIFACT_ROOT" && ! -d "$ARTIFACT_ROOT" ]]; then
    echo "Artifact path exists and is not a directory: $ARTIFACT_ROOT" >&2
    exit 2
fi
if [[ -d "$ARTIFACT_ROOT" ]] && \
   [[ -n "$(find "$ARTIFACT_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "Artifact directory must be new or empty: $ARTIFACT_ROOT" >&2
    exit 2
fi
mkdir -p \
    "$ARTIFACT_ROOT" \
    "$ARTIFACT_ROOT/cases" \
    "$ARTIFACT_ROOT/contaminated-attempts" \
    "$ARTIFACT_ROOT/bin"

PROBE_BIN="$ARTIFACT_ROOT/bin/background-computer-use-probe"
swiftc "$ROOT_DIR/scripts/support/background-computer-use-probe.swift" \
    -o "$PROBE_BIN" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework CryptoKit
"$PROBE_BIN" self-test > "$ARTIFACT_ROOT/probe-self-test.json"

same_process_generation() {
    local expected_start_identity="$1"
    local current_start_identity="$2"
    [[ "$expected_start_identity" =~ ^[0-9]+$ ]] && \
        [[ "$current_start_identity" == "$expected_start_identity" ]]
}

refresh_playground_process_receipt() {
    local pid="$1"
    local start_identity="$2"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$start_identity" =~ ^[0-9]+$ ]] || return 1
    PLAYGROUND_PID="$pid"
    PLAYGROUND_PROCESS_START_IDENTITY="$start_identity"
}

read_launch_process_receipt() {
    local result_file="$1"
    local receipt
    LAUNCH_RECEIPT_PID=""
    LAUNCH_RECEIPT_PROCESS_START_IDENTITY=""
    [[ -n "$result_file" && -s "$result_file" ]] || return 1
    receipt="$(jq -er '
        .data as $data |
        if ($data | has("pid")) and ($data | has("process_start_identity")) and
           (($data | has("new_pid")) | not) and (($data | has("new_process_start_identity")) | not)
        then [$data.pid, $data.process_start_identity]
        elif ($data | has("new_pid")) and ($data | has("new_process_start_identity")) and
             (($data | has("pid")) | not) and (($data | has("process_start_identity")) | not)
        then [$data.new_pid, $data.new_process_start_identity]
        else empty
        end as $receipt |
        $receipt[0] as $pid |
        $receipt[1] as $identity |
        select(
            ($pid | type) == "number" and $pid > 0 and ($pid | floor) == $pid and
            ($identity | type) == "number" and $identity > 0 and ($identity | floor) == $identity
        ) |
        $receipt | @tsv
    ' "$result_file")" || return 1
    IFS=$'\t' read -r LAUNCH_RECEIPT_PID LAUNCH_RECEIPT_PROCESS_START_IDENTITY <<< "$receipt"
    [[ "$LAUNCH_RECEIPT_PID" =~ ^[0-9]+$ ]] && \
        [[ "$LAUNCH_RECEIPT_PROCESS_START_IDENTITY" =~ ^[0-9]+$ ]]
}

quit_with_process_receipt() {
    local pid="$1"
    local expected_start_identity="$2"
    local force="$3"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ "$expected_start_identity" =~ ^[0-9]+$ ]] || return 1
    if [[ "$force" == "true" ]]; then
        pb app quit --pid "$pid" \
            --expected-process-start-identity "$expected_start_identity" --force --json
    else
        pb app quit --pid "$pid" \
            --expected-process-start-identity "$expected_start_identity" --json
    fi
}

verified_maximize_result() {
    local result_file="$1"
    local readback_file="$2"
    local sample_file="$3"
    local window_id="$4"
    jq -e --argjson windowID "$window_id" \
        --slurpfile readback "$readback_file" --slurpfile sample "$sample_file" '
        . as $result |
        [$readback[0].data.windows[] | select(.window_id == $windowID)] | first as $window |
        $result.success == true and
        $result.effect == "confirmed" and
        $result.data.action == "maximize" and
        $window != null and
        ($window.bounds.width != 640 or $window.bounds.height != 480) and
        $window.bounds == $result.data.new_bounds and
        any($sample[0].visibleScreenFramesTopLeft[];
            ((.x - $window.bounds.x) | fabs) <= 4 and
            ((.y - $window.bounds.y) | fabs) <= 4 and
            ((.width - $window.bounds.width) | fabs) <= 4 and
            ((.height - $window.bounds.height) | fabs) <= 4)
    ' "$result_file" >/dev/null
}

confirmed_element_scroll_result() {
    local result_file="$1"
    jq -e '
        .success == true and
        .effect == "confirmed" and
        .data.targetPoint.source == "element" and
        .data.totalTicks > 0
    ' "$result_file" >/dev/null
}

certification_command_identity() {
    local root_command="${1:-}"
    shift || true
    case "$root_command" in
        app|capture|menu|window)
            [[ -n "${1:-}" ]] || return 1
            printf '%s %s\n' "$root_command" "$1"
            ;;
        see)
            local argument
            local has_tree=false
            local has_no_elements=false
            for argument in "$@"; do
                [[ "$argument" == "--tree" ]] && has_tree=true
                [[ "$argument" == "--no-elements" ]] && has_no_elements=true
            done
            if $has_tree && $has_no_elements; then
                return 1
            elif $has_tree; then
                printf '%s\n' "see --tree"
            elif $has_no_elements; then
                printf '%s\n' "see --no-elements"
            else
                printf '%s\n' "see"
            fi
            ;;
        action|click|paste|press|scroll|set-value|type)
            printf '%s\n' "$root_command"
            ;;
        *)
            return 1
            ;;
    esac
}

certification_phase_identity() {
    local argument
    for argument in "$@"; do
        case "$argument" in
            --foreground|--foreground=*)
                printf '%s\n' "foreground"
                return 0
                ;;
        esac
    done
    printf '%s\n' "background"
}

monitor_sequence() {
    jq -er '
        .sequence |
        select(type == "number" and . >= 1 and (. | floor) == .)
    ' "$1"
}

wait_for_monitor_advance() {
    local heartbeat_path="$1"
    local previous_sequence="$2"
    local attempts="${3:-100}"
    local current_sequence=""
    for _ in $(seq 1 "$attempts"); do
        current_sequence="$(monitor_sequence "$heartbeat_path" 2>/dev/null || true)"
        if [[ "$current_sequence" =~ ^[0-9]+$ ]] && ((current_sequence > previous_sequence)); then
            return 0
        fi
        sleep 0.01
    done
    return 1
}

monitor_clean_sequence() {
    jq -er '
        .lastCleanSequence |
        select(type == "number" and . >= 1 and (. | floor) == .)
    ' "$1"
}

wait_for_monitor_clean_advance() {
    local heartbeat_path="$1"
    local previous_sequence="$2"
    local attempts="${3:-100}"
    local current_clean_sequence=""
    for _ in $(seq 1 "$attempts"); do
        if jq -e '.contaminationBlocked == true or .inputAttributionAvailable == false' \
            "$heartbeat_path" >/dev/null 2>&1; then
            return 1
        fi
        current_clean_sequence="$(monitor_clean_sequence "$heartbeat_path" 2>/dev/null || true)"
        if [[ "$current_clean_sequence" =~ ^[0-9]+$ ]] && \
           ((current_clean_sequence > previous_sequence)); then
            return 0
        fi
        sleep 0.01
    done
    return 1
}

wait_for_allowed_producer_revision() {
    local heartbeat_path="$1"
    local expected_revision="$2"
    local attempts="${3:-100}"
    for _ in $(seq 1 "$attempts"); do
        if jq -e --argjson expected "$expected_revision" \
            '.allowedProducerRevision == $expected and
             .inputAttributionAvailable == true and
             .contaminationBlocked == false' \
            "$heartbeat_path" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.01
    done
    return 1
}

wait_for_running_command_fence() {
    local heartbeat_path="$1"
    local expected_revision="$2"
    local previous_sequence="$3"
    local attempts="${4:-100}"
    for _ in $(seq 1 "$attempts"); do
        if jq -e \
            --argjson revision "$expected_revision" \
            --argjson previous "$previous_sequence" '
            .phase == "running" and
            .allowedProducerRevision == $revision and
            .inputAttributionAvailable == true and
            .contaminationBlocked == false and
            .lastCleanSequence > $previous
        ' "$heartbeat_path" >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.01
    done
    return 1
}

invariant_results() {
    local violations_path="$1"
    local observed_invariants
    observed_invariants="$(jq -sc '[.[].kind]' "$violations_path")"
    jq -cn \
        --argjson expected "$CERTIFICATION_INVARIANTS_JSON" \
        --argjson observed "$observed_invariants" '
        (($expected + $observed) | unique) |
        map(. as $name | {
            name: $name,
            passed: (($observed | index($name)) == null)
        })
    '
}

contamination_retry_allowed() {
    local case_name="$1"
    local stage="$2"
    local attempt="$3"
    local maximum_attempts="$4"
    ((attempt < maximum_attempts)) || return 1
    [[ "$stage" == "precommand" ]] && return 0
    [[ "$stage" == "active" ]] || return 1
    jq -e --arg id "$case_name" '
        any(.cases[]; .id == $id and .contamination_retry_safe == true)
    ' "$CERTIFICATION_CATALOG" >/dev/null
}

read_pinned_bridge_receipt() {
    local status_file="${1:?Bridge status file required}"
    jq -cer --arg socketPath "$BRIDGE_SOCKET" '
        .data.selected |
        select(.source == "remote" and .socketPath == $socketPath) |
        . as $selected |
        .handshake.hostIdentity as $identity |
        select($identity != null) |
        {
            pid: $identity.processIdentifier,
            startIdentity: (
                $identity.processStartIdentityDecimal //
                ($identity.processStartIdentity | tostring)
            ),
            socketPath: $selected.socketPath,
            sourceCommit: $identity.sourceCommit
        } |
        select(
            (.pid | type) == "number" and .pid > 0 and
            (.startIdentity | type) == "string" and
            (.startIdentity | test("^[0-9]+$")) and
            (.sourceCommit | type) == "string" and
            (.sourceCommit | test("^[0-9a-f]{40}$"))
        )
    ' "$status_file"
}

if $SELF_TEST_ONLY; then
    "$PROBE_BIN" process-identity --pid "$$" \
        --output "$ARTIFACT_ROOT/probe-process-identity.json"
    jq -e --argjson pid "$$" \
        '.pid == $pid and (.startIdentity | type) == "string" and
            (.startIdentity | test("^[1-9][0-9]*$"))' \
        "$ARTIFACT_ROOT/probe-process-identity.json" >/dev/null
    same_process_generation 7 7
    if same_process_generation 7 8 || same_process_generation "" 7; then
        echo "Process-generation cleanup guard self-test failed." >&2
        exit 1
    fi
    BRIDGE_RECEIPT_SELF_TEST="$ARTIFACT_ROOT/bridge-receipt-self-test.json"
    jq -n \
        --arg socketPath "$BRIDGE_SOCKET" \
        '{
            data: {selected: {
                source: "remote",
                socketPath: $socketPath,
                handshake: {hostIdentity: {
                    processIdentifier: 4242,
                    processStartIdentityDecimal: "987654321",
                    sourceCommit: "0123456789abcdef0123456789abcdef01234567"
                }}
            }}
        }' > "$BRIDGE_RECEIPT_SELF_TEST"
    read_pinned_bridge_receipt "$BRIDGE_RECEIPT_SELF_TEST" >/dev/null
    jq --arg mismatchedSocket "${BRIDGE_SOCKET}.rerouted" \
        '.data.selected.socketPath = $mismatchedSocket' \
        "$BRIDGE_RECEIPT_SELF_TEST" > "$BRIDGE_RECEIPT_SELF_TEST.tmp"
    mv "$BRIDGE_RECEIPT_SELF_TEST.tmp" "$BRIDGE_RECEIPT_SELF_TEST"
    if read_pinned_bridge_receipt "$BRIDGE_RECEIPT_SELF_TEST" >/dev/null 2>&1; then
        echo "Pinned Bridge receipt accepted a rerouted socket." >&2
        exit 1
    fi
    if [[ "$(certification_command_identity app launch TextEdit)" != "app launch" ]] || \
       [[ "$(certification_command_identity window maximize --window-id 42)" != "window maximize" ]] || \
       [[ "$(certification_command_identity window close --window-id 42)" != "window close" ]] || \
       [[ "$(certification_command_identity app quit --pid 42)" != "app quit" ]] || \
       [[ "$(certification_command_identity menu click --pid 42 --path 'Fixtures > Open Text Fixture')" != \
          "menu click" ]] || \
       [[ "$(certification_command_identity press return --pid 42)" != "press" ]] || \
       [[ "$(certification_command_identity window list --pid 42)" != "window list" ]] || \
       [[ "$(certification_command_identity see --pid 42)" != "see" ]] || \
       [[ "$(certification_command_identity see --tree --no-screenshot --pid 42)" != "see --tree" ]] || \
       [[ "$(certification_command_identity see --no-elements --pid 42)" != "see --no-elements" ]] || \
       [[ "$(certification_command_identity capture live --pid 42)" != "capture live" ]] || \
       [[ "$(certification_command_identity click --on B1)" != "click" ]] || \
       [[ "$(certification_command_identity type text --pid 42)" != "type" ]] || \
       [[ "$(certification_command_identity paste text --pid 42)" != "paste" ]] || \
       [[ "$(certification_command_identity set-value text --on B1)" != "set-value" ]] || \
       [[ "$(certification_command_identity action AXPress --on B1)" != "action" ]] || \
       [[ "$(certification_command_identity scroll --direction down)" != "scroll" ]] || \
       certification_command_identity see --tree --no-elements >/dev/null || \
       certification_command_identity unknown >/dev/null; then
        echo "Certification command identity self-test failed." >&2
        exit 1
    fi
    if [[ "$(certification_phase_identity click --on B1)" != "background" ]] || \
       [[ "$(certification_phase_identity click --on B1 --foreground)" != "foreground" ]] || \
       [[ "$(certification_phase_identity click --foreground=true --on B1)" != "foreground" ]]; then
        echo "Certification phase identity self-test failed." >&2
        exit 1
    fi
    HEARTBEAT_SELF_TEST="$ARTIFACT_ROOT/heartbeat-self-test.json"
    HEARTBEAT_SELF_TEST_NEXT="$ARTIFACT_ROOT/heartbeat-self-test-next.json"
    printf '%s\n' \
        '{"sequence":1,"timestamp":1,"lastCleanSequence":1,"contaminationBlocked":false,"inputAttributionAvailable":true,"allowedProducerRevision":0,"phase":"setup"}' \
        > "$HEARTBEAT_SELF_TEST"
    (
        sleep 0.03
        printf '%s\n' \
            '{"sequence":2,"timestamp":2,"lastCleanSequence":2,"contaminationBlocked":false,"inputAttributionAvailable":true,"allowedProducerRevision":7,"phase":"running"}' \
            > "$HEARTBEAT_SELF_TEST_NEXT"
        mv "$HEARTBEAT_SELF_TEST_NEXT" "$HEARTBEAT_SELF_TEST"
    ) &
    HEARTBEAT_WRITER_PID=$!
    if ! wait_for_monitor_advance "$HEARTBEAT_SELF_TEST" 1 20; then
        kill "$HEARTBEAT_WRITER_PID" >/dev/null 2>&1 || true
        wait "$HEARTBEAT_WRITER_PID" 2>/dev/null || true
        echo "Monitor heartbeat advance self-test failed." >&2
        exit 1
    fi
    wait "$HEARTBEAT_WRITER_PID"
    if wait_for_monitor_advance "$HEARTBEAT_SELF_TEST" 2 3; then
        echo "Stalled monitor heartbeat self-test failed." >&2
        exit 1
    fi
    if ! wait_for_monitor_clean_advance "$HEARTBEAT_SELF_TEST" 1 3; then
        echo "Clean monitor sample advance self-test failed." >&2
        exit 1
    fi
    if ! wait_for_allowed_producer_revision "$HEARTBEAT_SELF_TEST" 7 3 || \
       wait_for_allowed_producer_revision "$HEARTBEAT_SELF_TEST" 8 3; then
        echo "Allowed event-producer revision self-test failed." >&2
        exit 1
    fi
    if ! wait_for_running_command_fence "$HEARTBEAT_SELF_TEST" 7 1 3 || \
       wait_for_running_command_fence "$HEARTBEAT_SELF_TEST" 7 2 3; then
        echo "Running command fence self-test failed." >&2
        exit 1
    fi
    CONTAMINATED_HEARTBEAT_SELF_TEST="$ARTIFACT_ROOT/heartbeat-contaminated-self-test.json"
    printf '%s\n' \
        '{"sequence":3,"timestamp":3,"lastCleanSequence":2,"contaminationBlocked":true,"inputAttributionAvailable":true,"allowedProducerRevision":7,"phase":"running"}' \
        > "$CONTAMINATED_HEARTBEAT_SELF_TEST"
    if wait_for_monitor_clean_advance "$CONTAMINATED_HEARTBEAT_SELF_TEST" 2 3; then
        echo "Blocked contamination heartbeat self-test failed." >&2
        exit 1
    fi
    INVARIANT_SELF_TEST="$ARTIFACT_ROOT/invariant-self-test.jsonl"
    printf '%s\n' '{"kind":"physical_cursor","expected":"1,1","actual":"2,2"}' \
        > "$INVARIANT_SELF_TEST"
    INVARIANT_RESULTS_SELF_TEST="$(invariant_results "$INVARIANT_SELF_TEST")"
    if ! jq -e \
        --argjson catalog "$CERTIFICATION_INVARIANTS_JSON" '
        ([.[] | select(.name == "physical_cursor" and .passed == false)] | length) == 1 and
        all(.[]; .name as $name | ($catalog | index($name)) != null) and
        ([.[] | select(.passed == false)] | length) == 1
    ' <<< "$INVARIANT_RESULTS_SELF_TEST" >/dev/null; then
        echo "Catalog-projected invariant result self-test failed." >&2
        exit 1
    fi
    if ! contamination_retry_allowed click-id precommand 1 3 || \
       ! contamination_retry_allowed see-text active 1 3 || \
       contamination_retry_allowed click-id active 1 3 || \
       contamination_retry_allowed see-text active 3 3; then
        echo "Contamination replay policy self-test failed." >&2
        exit 1
    fi
    VALID_LAUNCH_RECEIPT="$ARTIFACT_ROOT/valid-launch-receipt.json"
    VALID_RELAUNCH_RECEIPT="$ARTIFACT_ROOT/valid-relaunch-receipt.json"
    MISSING_LAUNCH_RECEIPT="$ARTIFACT_ROOT/missing-launch-receipt.json"
    MISMATCHED_LAUNCH_RECEIPT="$ARTIFACT_ROOT/mismatched-launch-receipt.json"
    printf '%s\n' \
        '{"data":{"pid":101,"process_start_identity":8}}' > "$VALID_LAUNCH_RECEIPT"
    printf '%s\n' \
        '{"data":{"new_pid":102,"new_process_start_identity":9}}' > "$VALID_RELAUNCH_RECEIPT"
    printf '%s\n' '{"data":{"pid":103}}' > "$MISSING_LAUNCH_RECEIPT"
    printf '%s\n' \
        '{"data":{"pid":104,"new_process_start_identity":10}}' > "$MISMATCHED_LAUNCH_RECEIPT"
    if ! read_launch_process_receipt "$VALID_LAUNCH_RECEIPT" || \
       [[ "$LAUNCH_RECEIPT_PID" != 101 || "$LAUNCH_RECEIPT_PROCESS_START_IDENTITY" != 8 ]]; then
        echo "Launch receipt parsing self-test failed." >&2
        exit 1
    fi
    PLAYGROUND_PID=100
    PLAYGROUND_PROCESS_START_IDENTITY=7
    refresh_playground_process_receipt \
        "$LAUNCH_RECEIPT_PID" "$LAUNCH_RECEIPT_PROCESS_START_IDENTITY"
    if [[ "$PLAYGROUND_PID" != 101 || "$PLAYGROUND_PROCESS_START_IDENTITY" != 8 ]] || \
       same_process_generation 7 "$PLAYGROUND_PROCESS_START_IDENTITY" || \
       ! same_process_generation 8 "$PLAYGROUND_PROCESS_START_IDENTITY"; then
        echo "Playground relaunch receipt refresh self-test failed." >&2
        exit 1
    fi
    if refresh_playground_process_receipt 102 ""; then
        echo "Playground relaunch accepted a missing process generation." >&2
        exit 1
    fi
    if ! read_launch_process_receipt "$VALID_RELAUNCH_RECEIPT" || \
       [[ "$LAUNCH_RECEIPT_PID" != 102 || "$LAUNCH_RECEIPT_PROCESS_START_IDENTITY" != 9 ]] || \
       read_launch_process_receipt "$MISSING_LAUNCH_RECEIPT" || \
       read_launch_process_receipt "$MISMATCHED_LAUNCH_RECEIPT"; then
        echo "Relaunch/missing receipt parsing self-test failed." >&2
        exit 1
    fi
    PB_SELF_TEST_CALLS=()
    pb() {
        PB_SELF_TEST_CALLS+=("$*")
    }
    quit_with_process_receipt 101 8 true
    quit_with_process_receipt 102 9 false
    if [[ "${PB_SELF_TEST_CALLS[0]}" != \
        "app quit --pid 101 --expected-process-start-identity 8 --force --json" ]] || \
       [[ "${PB_SELF_TEST_CALLS[1]}" != \
        "app quit --pid 102 --expected-process-start-identity 9 --json" ]] || \
       quit_with_process_receipt 103 "" true; then
        echo "Generation-pinned cleanup command self-test failed." >&2
        exit 1
    fi
    VALID_MAXIMIZE_RESULT="$ARTIFACT_ROOT/valid-maximize-result.json"
    STALE_MAXIMIZE_RESULT="$ARTIFACT_ROOT/stale-maximize-result.json"
    VALID_MAXIMIZE_READBACK="$ARTIFACT_ROOT/valid-maximize-readback.json"
    VALID_MAXIMIZE_SAMPLE="$ARTIFACT_ROOT/valid-maximize-sample.json"
    VALID_SCROLL_RESULT="$ARTIFACT_ROOT/valid-scroll-result.json"
    STALE_SCROLL_RESULT="$ARTIFACT_ROOT/stale-scroll-result.json"
    printf '%s\n' \
        '{"success":true,"effect":"confirmed","data":{"action":"maximize","new_bounds":{"x":0,"y":0,"width":800,"height":600}}}' \
        > "$VALID_MAXIMIZE_RESULT"
    printf '%s\n' \
        '{"success":true,"data":{"success":true,"new_bounds":{"width":800,"height":600}}}' \
        > "$STALE_MAXIMIZE_RESULT"
    printf '%s\n' \
        '{"data":{"windows":[{"window_id":55,"bounds":{"x":0,"y":0,"width":800,"height":600}}]}}' \
        > "$VALID_MAXIMIZE_READBACK"
    printf '%s\n' \
        '{"visibleScreenFramesTopLeft":[{"x":0,"y":0,"width":800,"height":600}]}' \
        > "$VALID_MAXIMIZE_SAMPLE"
    printf '%s\n' \
        '{"success":true,"effect":"confirmed","data":{"targetPoint":{"source":"element"},"totalTicks":1}}' \
        > "$VALID_SCROLL_RESULT"
    printf '%s\n' \
        '{"success":false,"effect":"refused","data":null}' > "$STALE_SCROLL_RESULT"
    if ! verified_maximize_result \
        "$VALID_MAXIMIZE_RESULT" "$VALID_MAXIMIZE_READBACK" "$VALID_MAXIMIZE_SAMPLE" 55 || \
       verified_maximize_result \
        "$STALE_MAXIMIZE_RESULT" "$VALID_MAXIMIZE_READBACK" "$VALID_MAXIMIZE_SAMPLE" 55 || \
       ! confirmed_element_scroll_result "$VALID_SCROLL_RESULT" || \
       confirmed_element_scroll_result "$STALE_SCROLL_RESULT"; then
        echo "Current maximize/scroll result contract self-test failed." >&2
        exit 1
    fi
    node "$CERTIFICATION_REPORTER" \
        --catalog "$CERTIFICATION_CATALOG" \
        --self-test \
        --output "$ARTIFACT_ROOT/certification-self-test.json"
    node --test "$CERTIFICATION_TEST" > "$ARTIFACT_ROOT/certification-tests.tap"
    echo "Probe self-test passed: $ARTIFACT_ROOT/probe-self-test.json"
    exit 0
fi

if [[ -z "$PEEKABOO_BIN" ]]; then
    if [[ -x "$ROOT_DIR/Apps/CLI/.build/debug/peekaboo" ]]; then
        PEEKABOO_BIN="$ROOT_DIR/Apps/CLI/.build/debug/peekaboo"
    else
        PEEKABOO_BIN="$(command -v peekaboo || true)"
    fi
fi
if [[ -z "$PEEKABOO_BIN" || ! -x "$PEEKABOO_BIN" ]]; then
    echo "Peekaboo CLI not found; build it or pass --bin." >&2
    exit 2
fi

pb() {
    if $NO_REMOTE; then
        "$PEEKABOO_BIN" "$@" --no-remote
    else
        "$PEEKABOO_BIN" "$@" --bridge-socket "$BRIDGE_SOCKET"
    fi
}

if $NO_REMOTE; then
    codesign -dv --verbose=2 "$PEEKABOO_BIN" > "$ARTIFACT_ROOT/peekaboo-signature.txt" 2>&1 || true
    if ! rg -q '^TeamIdentifier=' "$ARTIFACT_ROOT/peekaboo-signature.txt" || \
       rg -q '^TeamIdentifier=not set$' "$ARTIFACT_ROOT/peekaboo-signature.txt"; then
        echo "--no-remote requires a team-signed CLI with stable local TCC grants." >&2
        exit 2
    fi
fi

pb --version > "$ARTIFACT_ROOT/peekaboo-version.txt"
pb --version --json > "$ARTIFACT_ROOT/peekaboo-provenance.json"
PEEKABOO_SOURCE_COMMIT="$(jq -er '
    select(.success == true) |
    .data.sourceCommit |
    select(type == "string" and test("^[0-9a-f]{40}$"))
' "$ARTIFACT_ROOT/peekaboo-provenance.json")" || {
    echo "Background certification requires a stamped CLI with one exact 40-hex source commit." >&2
    exit 2
}
pb permissions status --json > "$ARTIFACT_ROOT/permissions.json"
if ! jq -e '
    .success == true and
    ([.data.permissions[] | select(.isRequired == true and .isGranted != true)] | length == 0)
' "$ARTIFACT_ROOT/permissions.json" >/dev/null; then
    echo "Peekaboo is missing a required macOS permission; see $ARTIFACT_ROOT/permissions.json" >&2
    exit 2
fi

EVENT_PRODUCER_SOURCE=local
EVENT_PRODUCER_SOURCE_COMMIT="$PEEKABOO_SOURCE_COMMIT"
REMOTE_EVENT_PRODUCER_JSON=null
if ! $NO_REMOTE; then
    pb bridge status --verbose --json > "$ARTIFACT_ROOT/bridge-event-producer.json"
    REMOTE_EVENT_PRODUCER_JSON="$(read_pinned_bridge_receipt \
        "$ARTIFACT_ROOT/bridge-event-producer.json")" || {
        echo "Pinned Bridge host lacks an exact event-producer source receipt." >&2
        exit 2
    }
    BRIDGE_SOURCE_COMMIT="$(jq -er '.sourceCommit' <<<"$REMOTE_EVENT_PRODUCER_JSON")"
    if [[ "$BRIDGE_SOURCE_COMMIT" != "$PEEKABOO_SOURCE_COMMIT" ]]; then
        echo "CLI and pinned Bridge host were built from different source commits." >&2
        exit 2
    fi
    EVENT_PRODUCER_SOURCE=remote
    EVENT_PRODUCER_SOURCE_COMMIT="$BRIDGE_SOURCE_COMMIT"
fi

build_playground() {
    local derived_data="$ARTIFACT_ROOT/DerivedData"
    local build_log="$ARTIFACT_ROOT/playground-build.log"
    xcodebuild \
        -project "$ROOT_DIR/Apps/Playground/Playground.xcodeproj" \
        -scheme Playground \
        -configuration Debug \
        -derivedDataPath "$derived_data" \
        build CODE_SIGNING_ALLOWED=NO > "$build_log" 2>&1

    PLAYGROUND_APP="$derived_data/Build/Products/Debug/Playground.app"
    local identity="${PEEKABOO_PLAYGROUND_SIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        identity="$(security find-identity -p codesigning -v 2>/dev/null \
            | awk -F'"' '/Developer ID Application: OpenClaw Foundation/ { print $2; exit }')"
    fi
    if [[ -z "$identity" ]]; then
        echo "No OpenClaw Foundation Developer ID Application identity is available." >&2
        return 1
    fi

    codesign --force --deep --options runtime --timestamp --sign "$identity" "$PLAYGROUND_APP"
}

if $SKIP_PLAYGROUND_BUILD; then
    if [[ -z "$PLAYGROUND_APP" ]]; then
        echo "--skip-playground-build requires --playground-app." >&2
        exit 2
    fi
elif [[ -z "$PLAYGROUND_APP" ]]; then
    build_playground
fi

if [[ "$PLAYGROUND_APP" != /* ]]; then
    PLAYGROUND_APP="$ROOT_DIR/$PLAYGROUND_APP"
fi
if [[ ! -d "$PLAYGROUND_APP" ]]; then
    echo "Playground app not found: $PLAYGROUND_APP" >&2
    exit 2
fi
codesign --verify --deep --strict "$PLAYGROUND_APP"
codesign -dv --verbose=2 "$PLAYGROUND_APP" > "$ARTIFACT_ROOT/playground-signature.txt" 2>&1
if ! rg -q '^TeamIdentifier=' "$ARTIFACT_ROOT/playground-signature.txt" || \
   rg -q '^TeamIdentifier=not set$' "$ARTIFACT_ROOT/playground-signature.txt"; then
    echo "Playground must have a team-signed identity, not an ad-hoc signature." >&2
    exit 2
fi

MONITOR_PID=""
PLAYGROUND_PID=""
PLAYGROUND_PROCESS_START_IDENTITY=""
LIFECYCLE_PIDS=()
LIFECYCLE_PROCESS_START_IDENTITIES=()

quit_owned_process() {
    local pid="$1"
    local expected_start_identity="$2"
    local label="$3"
    local force="$4"
    if ! kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    if [[ ! "$expected_start_identity" =~ ^[0-9]+$ ]]; then
        local message="Refusing cleanup for $label PID $pid: process generation changed"
        echo "$message" >&2
        printf '%s\n' "$message" >> "$ARTIFACT_ROOT/cleanup-generation-refusals.txt"
        return 1
    fi

    quit_with_process_receipt "$pid" "$expected_start_identity" "$force" >/dev/null 2>&1 || true
}

cleanup() {
    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" >/dev/null 2>&1 || true
        wait "$MONITOR_PID" 2>/dev/null || true
    fi
    if [[ -n "$PLAYGROUND_PID" ]]; then
        quit_owned_process \
            "$PLAYGROUND_PID" "$PLAYGROUND_PROCESS_START_IDENTITY" playground false || true
        if kill -0 "$PLAYGROUND_PID" 2>/dev/null; then
            quit_owned_process \
                "$PLAYGROUND_PID" "$PLAYGROUND_PROCESS_START_IDENTITY" playground true || true
        fi
    fi
    local lifecycle_index
    for ((lifecycle_index = 0; lifecycle_index < ${#LIFECYCLE_PIDS[@]}; lifecycle_index++)); do
        quit_owned_process \
            "${LIFECYCLE_PIDS[$lifecycle_index]}" \
            "${LIFECYCLE_PROCESS_START_IDENTITIES[$lifecycle_index]}" \
            "lifecycle-$lifecycle_index" true || true
    done
}
trap cleanup EXIT INT TERM

"$PROBE_BIN" sample --output "$ARTIFACT_ROOT/sentinel.json"
SENTINEL_PID="$(jq -r '.frontmostPID // empty' "$ARTIFACT_ROOT/sentinel.json")"
SENTINEL_WINDOW_ID="$(jq -r '.frontmostWindowID // empty' "$ARTIFACT_ROOT/sentinel.json")"
SENTINEL_OBSERVED_BUNDLE_ID="$(jq -r '.frontmostBundleIdentifier // empty' \
    "$ARTIFACT_ROOT/sentinel.json")"
if [[ -z "$SENTINEL_PID" || -z "$SENTINEL_WINDOW_ID" ]]; then
    echo "A foreground sentinel window is required for background certification." >&2
    exit 1
fi
if [[ "$SENTINEL_OBSERVED_BUNDLE_ID" == "$PLAYGROUND_BUNDLE_ID" ]]; then
    echo "A non-Playground foreground sentinel window is required for certification." >&2
    exit 1
fi
if [[ -n "$SENTINEL_BUNDLE_ID" && "$SENTINEL_OBSERVED_BUNDLE_ID" != "$SENTINEL_BUNDLE_ID" ]]; then
    echo "Required sentinel $SENTINEL_BUNDLE_ID is not already frontmost; refusing to activate it." >&2
    exit 1
fi

if "$PROBE_BIN" find-app --bundle-id "$PLAYGROUND_BUNDLE_ID" >/dev/null 2>&1; then
    pb app quit --app "$PLAYGROUND_BUNDLE_ID" --json \
        > "$ARTIFACT_ROOT/playground-quit-existing.json" || true
fi

pb app launch "$PLAYGROUND_APP" --wait-ready --foreground --json \
    > "$ARTIFACT_ROOT/playground-launch.json"
if ! read_launch_process_receipt "$ARTIFACT_ROOT/playground-launch.json" || \
   ! refresh_playground_process_receipt \
       "$LAUNCH_RECEIPT_PID" "$LAUNCH_RECEIPT_PROCESS_START_IDENTITY"; then
    echo "Playground launch did not return a process-generation receipt." >&2
    exit 1
fi
if ! kill -0 "$PLAYGROUND_PID" 2>/dev/null; then
    echo "Playground launch receipt names a process that is no longer running." >&2
    exit 1
fi

pb window focus --pid "$SENTINEL_PID" --window-id "$SENTINEL_WINDOW_ID" --verify --json \
    > "$ARTIFACT_ROOT/sentinel-restore.json"
"$PROBE_BIN" sample --output "$ARTIFACT_ROOT/sentinel-restored.json"
if ! jq -e \
    --argjson pid "$SENTINEL_PID" \
    --argjson windowID "$SENTINEL_WINDOW_ID" \
    '.frontmostPID == $pid and .frontmostWindowID == $windowID' \
    "$ARTIFACT_ROOT/sentinel-restored.json" >/dev/null; then
    echo "Foreground fixture launch did not restore the exact sentinel window." >&2
    exit 1
fi

FAILURES=0
LAST_RESULT=""
LAST_CASE=""

record_failure() {
    echo "FAIL: $1" >&2
    FAILURES=$((FAILURES + 1))
}

abort_current_monitor() {
    if [[ -n "$MONITOR_PID" ]]; then
        kill "$MONITOR_PID" >/dev/null 2>&1 || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
    fi
}

restore_stale_window_bounds() {
    local output_prefix="$1"
    local window_id="$2"
    local pid="$3"
    local x="$4"
    local y="$5"
    local width="$6"
    local height="$7"
    [[ -n "$x" ]] || return 1

    set +e
    pb window set-bounds --pid "$pid" --window-id "$window_id" \
        --x "$x" --y "$y" --width "$width" --height "$height" --json \
        > "$output_prefix-result.json" 2> "$output_prefix-stderr.txt"
    local restore_exit=$?
    pb window list --pid "$pid" --json > "$output_prefix-readback.json"
    local readback_exit=$?
    set -e
    [[ $restore_exit -eq 0 && $readback_exit -eq 0 ]] && \
        jq -e \
            --argjson windowID "$window_id" \
            --argjson x "$x" \
            --argjson y "$y" \
            --argjson width "$width" \
            --argjson height "$height" '
            [.data.windows[] |
                select(.window_id == $windowID) |
                select(
                    .bounds.x == $x and .bounds.y == $y and
                    .bounds.width == $width and .bounds.height == $height)] |
            length == 1
        ' "$output_prefix-readback.json" >/dev/null
}

case_dir_path() {
    printf '%s/cases/%s' "$ARTIFACT_ROOT" "$1"
}

case_summary_path() {
    printf '%s/summary.json' "$(case_dir_path "$1")"
}

record_case_oracle() {
    local case_name="$1"
    local oracle="$2"
    local passed="$3"
    local summary
    summary="$(case_summary_path "$case_name")"
    [[ -f "$summary" ]] || return 1
    jq --arg oracle "$oracle" --argjson passed "$passed" \
        '.oracles[$oracle] = $passed' "$summary" > "$summary.tmp"
    mv "$summary.tmp" "$summary"
    [[ "$passed" == "true" ]]
}

record_last_case_oracle() {
    [[ -n "$LAST_CASE" ]] || return 1
    record_case_oracle "$LAST_CASE" "$1" "$2"
}

run_case() {
    local name="$1"
    local clipboard_policy="$2"
    local expected_exit="$3"
    shift 3

    local setup_window_id=""
    local setup_pid=""
    if [[ "${1:-}" == "--setup-nonmaximized-window" ]]; then
        setup_window_id="$2"
        setup_pid="$3"
        shift 3
    fi
    local stale_window_id=""
    local stale_pid=""
    if [[ "${1:-}" == "--setup-stale-window" ]]; then
        stale_window_id="$2"
        stale_pid="$3"
        shift 3
    fi

    local case_dir="$ARTIFACT_ROOT/cases/$name"
    if ! mkdir "$case_dir"; then
        record_failure "$name reused an existing case artifact directory"
        return 1
    fi
    local before="$case_dir/before.json"
    local after="$case_dir/after.json"
    local monitor="$case_dir/monitor.jsonl"
    local contamination="$case_dir/contamination.jsonl"
    local phase="$case_dir/monitor-phase.txt"
    local allowed_producers="$case_dir/allowed-event-producers.json"
    local ready="$case_dir/monitor.ready"
    local heartbeat="$case_dir/monitor-heartbeat.json"
    local result="$case_dir/result.json"
    local stderr_file="$case_dir/stderr.txt"
    local exit_file="$case_dir/exit-code.txt"
    local summary="$case_dir/summary.json"
    local failed=false
    local case_remote_receipt=null
    local event_producer_stable=true
    local observed_command=""
    local observed_phase=""
    local monitor_progress=true
    local contamination_clear=true
    local nonmaximized_precondition=null
    local snapshot_window_drift=null
    local target_window_restored=null
    local stale_original_x=""
    local stale_original_y=""
    local stale_original_width=""
    local stale_original_height=""
    if ! observed_command="$(certification_command_identity "$@")"; then
        observed_command="unresolved"
        record_failure "$name does not map to one canonical certification command"
        failed=true
    fi
    observed_phase="$(certification_phase_identity "$@")"

    printf '%s\n' setup > "$phase"
    printf '%s\n' '{"revision":0,"producers":[]}' > "$allowed_producers"
    "$PROBE_BIN" sample --output "$before"
    if [[ -z "$(jq -r '.frontmostPID // empty' "$before")" || \
          -z "$(jq -r '.frontmostWindowID // empty' "$before")" || \
          "$(jq -r '.frontmostPID // empty' "$before")" == "$PLAYGROUND_PID" ]]; then
        printf '%s\n' \
            '{"stage":"precommand","reason":"no non-target foreground baseline"}' \
            > "$case_dir/contamination-blocked.json"
        return 1
    fi
    local monitor_args=(
        watch
        --baseline "$before"
        --output "$monitor"
        --contamination-output "$contamination"
        --ready "$ready"
        --heartbeat "$heartbeat"
        --phase "$phase"
        --allowed-producers "$allowed_producers"
        --invariant-names "$CERTIFICATION_INVARIANTS_JSON"
        --interval-ms 10)
    if [[ "$clipboard_policy" == "allow-temporary" ]]; then
        monitor_args+=(--allow-clipboard-mutation)
    fi
    "$PROBE_BIN" "${monitor_args[@]}" &
    MONITOR_PID=$!
    for _ in $(seq 1 100); do
        [[ -f "$ready" ]] && break
        sleep 0.01
    done
    if [[ ! -f "$ready" ]]; then
        abort_current_monitor
        record_failure "$name invariant monitor did not start"
        return 1
    fi
    if ! monitor_sequence "$heartbeat" >/dev/null; then
        abort_current_monitor
        record_failure "$name invariant monitor became ready without a heartbeat"
        return 1
    fi
    if ! wait_for_monitor_clean_advance "$heartbeat" 0; then
        abort_current_monitor
        printf '%s\n' \
            '{"stage":"precommand","reason":"input contaminated initial monitor fence"}' \
            > "$case_dir/contamination-blocked.json"
        return 1
    fi

    if [[ -n "$setup_window_id" ]]; then
        local setup_result="$case_dir/nonmaximized-setup.json"
        local setup_readback="$case_dir/nonmaximized-readback.json"
        set +e
        pb window set-bounds --pid "$setup_pid" --window-id "$setup_window_id" \
            --x 80 --y 80 --width 640 --height 480 --json \
            > "$setup_result" 2> "$case_dir/nonmaximized-setup-stderr.txt"
        local setup_exit=$?
        pb window list --pid "$setup_pid" --json > "$setup_readback"
        local setup_readback_exit=$?
        set -e
        if [[ $setup_readback_exit -eq 0 ]] && jq -e --argjson windowID "$setup_window_id" '
            [.data.windows[] |
                select(.window_id == $windowID) |
                select(.bounds.width == 640 and .bounds.height == 480)] |
            length == 1
        ' "$setup_readback" >/dev/null; then
            nonmaximized_precondition=true
        else
            nonmaximized_precondition=false
            record_failure "$name could not establish a non-maximized 640x480 exact-window precondition (set-bounds exit $setup_exit, readback exit $setup_readback_exit)"
            failed=true
        fi
    fi

    if [[ -n "$stale_window_id" ]]; then
        local stale_original_readback="$case_dir/stale-original-readback.json"
        local stale_resize_result="$case_dir/stale-resize-result.json"
        local stale_resized_readback="$case_dir/stale-resized-readback.json"
        local stale_bounds=""
        set +e
        pb window list --pid "$stale_pid" --json > "$stale_original_readback"
        local stale_inventory_exit=$?
        set -e
        if [[ $stale_inventory_exit -eq 0 ]]; then
            stale_bounds="$(jq -er --argjson windowID "$stale_window_id" '
                [.data.windows[] | select(.window_id == $windowID)] | first as $window |
                select($window != null) |
                [
                    ($window.bounds.x | round),
                    ($window.bounds.y | round),
                    ($window.bounds.width | round),
                    ($window.bounds.height | round)
                ] | @tsv
            ' "$stale_original_readback")" || stale_bounds=""
        fi
        if [[ -n "$stale_bounds" ]]; then
            IFS=$'\t' read -r \
                stale_original_x stale_original_y stale_original_width stale_original_height <<< "$stale_bounds"
            local stale_resized_width=$((stale_original_width + 17))
            local stale_resized_height=$((stale_original_height + 17))
            set +e
            pb window set-bounds --pid "$stale_pid" --window-id "$stale_window_id" \
                --x "$stale_original_x" --y "$stale_original_y" \
                --width "$stale_resized_width" --height "$stale_resized_height" --json \
                > "$stale_resize_result" 2> "$case_dir/stale-resize-stderr.txt"
            local stale_resize_exit=$?
            pb window list --pid "$stale_pid" --json > "$stale_resized_readback"
            local stale_resized_readback_exit=$?
            set -e
            if [[ $stale_resize_exit -eq 0 && $stale_resized_readback_exit -eq 0 ]] && \
               jq -e \
                   --argjson windowID "$stale_window_id" \
                   --argjson x "$stale_original_x" \
                   --argjson y "$stale_original_y" \
                   --argjson width "$stale_resized_width" \
                   --argjson height "$stale_resized_height" '
                    [.data.windows[] |
                        select(.window_id == $windowID) |
                        select(
                            .bounds.x == $x and .bounds.y == $y and
                            .bounds.width == $width and .bounds.height == $height)] |
                    length == 1
               ' "$stale_resized_readback" >/dev/null; then
                snapshot_window_drift=true
            else
                snapshot_window_drift=false
                record_failure "$name could not resize the exact snapshot window before stale-snapshot reuse"
                failed=true
            fi
        else
            snapshot_window_drift=false
            record_failure "$name could not read the exact snapshot window bounds"
            failed=true
        fi
    fi

    local precommand_sequence=""
    precommand_sequence="$(monitor_sequence "$heartbeat" 2>/dev/null || true)"
    if [[ ! "$precommand_sequence" =~ ^[0-9]+$ ]] || \
       ! wait_for_monitor_clean_advance "$heartbeat" "$precommand_sequence"; then
        abort_current_monitor
        if [[ -n "$stale_window_id" ]] && ! restore_stale_window_bounds \
            "$case_dir/precommand-contamination-restore" \
            "$stale_window_id" "$stale_pid" \
            "$stale_original_x" "$stale_original_y" \
            "$stale_original_width" "$stale_original_height"; then
            record_failure "$name could not roll back stale-window setup after contamination"
            return 1
        fi
        printf '%s\n' \
            '{"stage":"precommand","reason":"input contaminated final monitor fence"}' \
            > "$case_dir/contamination-blocked.json"
        return 1
    fi

    if ! $NO_REMOTE; then
        pb bridge status --verbose --json > "$case_dir/bridge-before.json"
        case_remote_receipt="$(read_pinned_bridge_receipt "$case_dir/bridge-before.json")" || {
            abort_current_monitor
            if [[ -n "$stale_window_id" ]]; then
                restore_stale_window_bounds \
                    "$case_dir/bridge-attestation-restore" \
                    "$stale_window_id" "$stale_pid" \
                    "$stale_original_x" "$stale_original_y" \
                    "$stale_original_width" "$stale_original_height" || true
            fi
            record_failure "$name could not attest the pinned Bridge host before dispatch"
            return 1
        }
        if [[ "$case_remote_receipt" != "$REMOTE_EVENT_PRODUCER_JSON" ]]; then
            abort_current_monitor
            if [[ -n "$stale_window_id" ]]; then
                restore_stale_window_bounds \
                    "$case_dir/bridge-generation-restore" \
                    "$stale_window_id" "$stale_pid" \
                    "$stale_original_x" "$stale_original_y" \
                    "$stale_original_width" "$stale_original_height" || true
            fi
            record_failure "$name observed a changed pinned Bridge generation before dispatch"
            return 1
        fi
    fi

    local command_gate="$case_dir/command.ready"
    (
        while [[ ! -f "$command_gate" ]]; do
            sleep 0.001
        done
        if $NO_REMOTE; then
            exec "$PEEKABOO_BIN" "$@" --json --no-remote
        else
            exec "$PEEKABOO_BIN" "$@" --json --bridge-socket "$BRIDGE_SOCKET"
        fi
    ) > "$result" 2> "$stderr_file" &
    local command_pid=$!
    local command_identity="$case_dir/command-process-identity.json"
    if ! "$PROBE_BIN" process-identity --pid "$command_pid" --output "$command_identity"; then
        kill "$command_pid" >/dev/null 2>&1 || true
        wait "$command_pid" 2>/dev/null || true
        abort_current_monitor
        if [[ -n "$stale_window_id" ]] && ! restore_stale_window_bounds \
            "$case_dir/command-identity-restore" \
            "$stale_window_id" "$stale_pid" \
            "$stale_original_x" "$stale_original_y" \
            "$stale_original_width" "$stale_original_height"; then
            record_failure "$name could not roll back stale-window setup after command identity failure"
        fi
        record_failure "$name could not pin the monitored command process generation"
        return 1
    fi
    local command_start_identity
    command_start_identity="$(jq -er '.startIdentity | tostring' "$command_identity")"
    jq -n \
        --argjson revision "$command_pid" \
        --argjson pid "$command_pid" \
        --arg startIdentity "$command_start_identity" \
        --argjson remote "$case_remote_receipt" '
        {
            revision: $revision,
            producers: (
                [{pid: $pid, startIdentity: $startIdentity}] +
                (if $remote == null then [] else [$remote] end)
            )
        }
    ' > "$allowed_producers.tmp"
    mv "$allowed_producers.tmp" "$allowed_producers"
    if ! wait_for_allowed_producer_revision "$heartbeat" "$command_pid"; then
        kill "$command_pid" >/dev/null 2>&1 || true
        wait "$command_pid" 2>/dev/null || true
        abort_current_monitor
        if [[ -n "$stale_window_id" ]] && ! restore_stale_window_bounds \
            "$case_dir/producer-ack-restore" \
            "$stale_window_id" "$stale_pid" \
            "$stale_original_x" "$stale_original_y" \
            "$stale_original_width" "$stale_original_height"; then
            record_failure "$name could not roll back stale-window setup after producer acknowledgement failure"
        fi
        record_failure "$name monitor did not acknowledge the exact event-producer receipt"
        return 1
    fi
    local producer_ack_sequence
    producer_ack_sequence="$(monitor_sequence "$heartbeat" 2>/dev/null || true)"
    printf '%s\n' running > "$phase.tmp"
    mv "$phase.tmp" "$phase"
    if [[ ! "$producer_ack_sequence" =~ ^[0-9]+$ ]] || \
       ! wait_for_running_command_fence \
           "$heartbeat" "$command_pid" "$producer_ack_sequence"; then
        kill "$command_pid" >/dev/null 2>&1 || true
        wait "$command_pid" 2>/dev/null || true
        abort_current_monitor
        if [[ -n "$stale_window_id" ]] && ! restore_stale_window_bounds \
            "$case_dir/armed-contamination-restore" \
            "$stale_window_id" "$stale_pid" \
            "$stale_original_x" "$stale_original_y" \
            "$stale_original_width" "$stale_original_height"; then
            record_failure "$name could not roll back stale-window setup after armed-fence contamination"
            return 1
        fi
        printf '%s\n' \
            '{"stage":"precommand","reason":"input contaminated armed command fence"}' \
            > "$case_dir/contamination-blocked.json"
        return 1
    fi
    if [[ -s "$monitor" ]]; then
        kill "$command_pid" >/dev/null 2>&1 || true
        wait "$command_pid" 2>/dev/null || true
        abort_current_monitor
        if [[ -n "$stale_window_id" ]] && ! restore_stale_window_bounds \
            "$case_dir/predispatch-invariant-restore" \
            "$stale_window_id" "$stale_pid" \
            "$stale_original_x" "$stale_original_y" \
            "$stale_original_width" "$stale_original_height"; then
            record_failure "$name could not roll back stale-window setup after a pre-dispatch invariant violation"
        fi
        record_failure "$name recorded a background invariant violation before command dispatch"
        return 1
    fi
    : > "$command_gate"
    set +e
    wait "$command_pid"
    local command_exit=$?
    set -e
    printf '%s\n' complete > "$phase.tmp"
    mv "$phase.tmp" "$phase"
    printf '%s\n' "$command_exit" > "$exit_file"

    if ! $NO_REMOTE; then
        local post_command_receipt=""
        if ! pb bridge status --verbose --json > "$case_dir/bridge-after.json" ||
           ! post_command_receipt="$(read_pinned_bridge_receipt "$case_dir/bridge-after.json")" ||
           [[ "$post_command_receipt" != "$case_remote_receipt" ]]; then
            event_producer_stable=false
            record_failure "$name could not retain one pinned Bridge generation across dispatch"
            failed=true
        fi
    fi

    if [[ -n "$setup_window_id" ]]; then
        set +e
        pb window list --pid "$setup_pid" --json > "$case_dir/maximize-readback.json"
        set -e
    fi

    if [[ -n "$stale_window_id" ]]; then
        if restore_stale_window_bounds \
            "$case_dir/stale-restore" \
            "$stale_window_id" "$stale_pid" \
            "$stale_original_x" "$stale_original_y" \
            "$stale_original_width" "$stale_original_height"; then
            target_window_restored=true
        else
            target_window_restored=false
        fi
        if [[ "$target_window_restored" != true ]]; then
            record_failure "$name did not restore the exact target window after stale-snapshot proof"
            failed=true
        fi
    fi

    sleep 0.15
    local monitor_sequence_before_final=""
    monitor_sequence_before_final="$(monitor_sequence "$heartbeat" 2>/dev/null || true)"
    if [[ ! "$monitor_sequence_before_final" =~ ^[0-9]+$ ]] || \
       ! wait_for_monitor_advance "$heartbeat" "$monitor_sequence_before_final"; then
        monitor_progress=false
        record_failure "$name invariant monitor did not sample after command completion"
        failed=true
    elif ! wait_for_monitor_clean_advance "$heartbeat" "$monitor_sequence_before_final"; then
        contamination_clear=false
        printf '%s\n' \
            '{"stage":"active","reason":"input contaminated command attempt"}' \
            > "$case_dir/contamination-blocked.json"
        failed=true
    fi
    "$PROBE_BIN" sample --output "$after"
    local monitor_liveness="$monitor_progress"
    local monitor_kill_exit=1
    local monitor_wait_exit=0
    if kill -0 "$MONITOR_PID" >/dev/null 2>&1; then
        set +e
        kill "$MONITOR_PID" >/dev/null 2>&1
        monitor_kill_exit=$?
        wait "$MONITOR_PID" 2>/dev/null
        monitor_wait_exit=$?
        set -e
    else
        set +e
        wait "$MONITOR_PID" 2>/dev/null
        monitor_wait_exit=$?
        set -e
    fi
    if [[ $monitor_kill_exit -ne 0 || $monitor_wait_exit -ne 143 ]]; then
        monitor_liveness=false
        record_failure "$name invariant monitor exited unexpectedly (status $monitor_wait_exit)"
        failed=true
    fi
    MONITOR_PID=""
    LAST_RESULT="$result"
    LAST_CASE="$name"

    local result_contract=true
    local result_success=null
    local effect=null
    local delivery_mode=null
    local error_code=null
    if jq -e 'type == "object"' "$result" >/dev/null 2>&1; then
        result_success="$(jq -c 'if has("success") then .success else null end' "$result")"
        effect="$(jq -c '.effect // null' "$result")"
        delivery_mode="$(jq -c '.data.deliveryMode // .data.delivery_mode // null' "$result")"
        error_code="$(jq -c '.error.code // null' "$result")"
    else
        result_contract=false
    fi
    if [[ "$expected_exit" == "success" ]]; then
        if [[ $command_exit -ne 0 || "$result_success" != "true" ]]; then
            result_contract=false
        fi
    elif [[ "$expected_exit" == "failure" ]]; then
        if [[ $command_exit -eq 0 || "$result_success" != "false" ]]; then
            result_contract=false
        fi
    elif ! { [[ $command_exit -eq 0 && "$result_success" == "true" ]] || \
             [[ $command_exit -ne 0 && "$result_success" == "false" ]]; }; then
        result_contract=false
    fi
    if [[ "$result_contract" == "false" ]]; then
        record_failure "$name command result violated its $expected_exit contract (exit $command_exit)"
        failed=true
    fi

    if [[ -s "$monitor" ]]; then
        local violated_invariants
        violated_invariants="$(jq -sr '[.[].kind] | unique | join(", ")' "$monitor")"
        record_failure "$name violated cataloged background invariant(s): $violated_invariants"
        failed=true
    fi

    local invariant_results_json
    invariant_results_json="$(invariant_results "$monitor")"

    local desktop_restored=true
    if ! jq -e --slurpfile after "$after" '
        .clipboardDigest == $after[0].clipboardDigest and
        ((.peekabooWindowIDs - $after[0].peekabooWindowIDs) | length) == 0 and
        (($after[0].peekabooWindowIDs - .peekabooWindowIDs) | length) == 0
    ' "$before" >/dev/null; then
        record_failure "$name did not restore the stable desktop state"
        desktop_restored=false
        failed=true
    fi
    local clipboard_policy_passed=true
    if [[ "$clipboard_policy" == "unchanged" ]] && \
       ! jq -e --slurpfile after "$after" '.clipboardChangeCount == $after[0].clipboardChangeCount' \
            "$before" >/dev/null; then
        record_failure "$name changed the clipboard"
        clipboard_policy_passed=false
        failed=true
    fi

    jq -n \
        --arg id "$name" \
        --arg surface "cli" \
        --arg command "$observed_command" \
        --arg phase "$observed_phase" \
        --arg expectedExit "$expected_exit" \
        --argjson exitCode "$command_exit" \
        --argjson resultSuccess "$result_success" \
        --argjson effect "$effect" \
        --argjson deliveryMode "$delivery_mode" \
        --argjson errorCode "$error_code" \
        --argjson invariants "$invariant_results_json" \
        --argjson resultContract "$result_contract" \
        --argjson monitorLiveness "$monitor_liveness" \
        --argjson contaminationClear "$contamination_clear" \
        --argjson desktopRestored "$desktop_restored" \
        --argjson clipboardPolicy "$clipboard_policy_passed" \
        --argjson nonmaximizedPrecondition "$nonmaximized_precondition" \
        --argjson snapshotWindowDrift "$snapshot_window_drift" \
        --argjson targetWindowRestored "$target_window_restored" \
        --argjson eventProducer "$case_remote_receipt" \
        --argjson eventProducerStable "$event_producer_stable" \
        '{
            id: $id,
            surface: $surface,
            command: $command,
            phase: $phase,
            expected_exit: $expectedExit,
            exit_code: $exitCode,
            result_success: $resultSuccess,
            effect: $effect,
            delivery_mode: $deliveryMode,
            error_code: $errorCode,
            event_producer: $eventProducer,
            event_producer_stable: $eventProducerStable,
            invariants: $invariants,
            evidence: {
                result_contract: $resultContract,
                monitor_liveness: $monitorLiveness,
                contamination_clear: $contaminationClear,
                desktop_restored: $desktopRestored,
                clipboard_policy: $clipboardPolicy
            },
            oracles: (
                (if $nonmaximizedPrecondition == null then {}
                    else {nonmaximized_precondition: $nonmaximizedPrecondition} end) +
                (if $snapshotWindowDrift == null then {}
                    else {snapshot_window_drift: $snapshotWindowDrift} end) +
                (if $targetWindowRestored == null then {}
                    else {target_window_restored: $targetWindowRestored} end)
            )
        }' > "$summary"

    [[ "$failed" == false ]]
}

run_checked_case() {
    local case_name="$1"
    local attempt=1
    local failures_before_case="$FAILURES"
    local maximum_attempts=3
    while ((attempt <= maximum_attempts)); do
        if run_case "$@"; then
            return 0
        fi

        local case_dir
        case_dir="$(case_dir_path "$case_name")"
        local contamination_marker="$case_dir/contamination-blocked.json"
        [[ -f "$contamination_marker" ]] || return 1

        local contamination_stage
        contamination_stage="$(jq -r '.stage // empty' "$contamination_marker")"
        local contamination_only=true
        if [[ -s "$case_dir/monitor.jsonl" ]]; then
            contamination_only=false
        elif [[ -f "$case_dir/summary.json" ]] && ! jq -e '
            .evidence.result_contract == true and
            .evidence.monitor_liveness == true and
            .evidence.desktop_restored == true and
            .evidence.clipboard_policy == true and
            all(.invariants[]; .passed == true) and
            all(.oracles[]; . == true)
        ' "$case_dir/summary.json" >/dev/null; then
            contamination_only=false
        fi

        if ! contamination_retry_allowed \
            "$case_name" "$contamination_stage" "$attempt" "$maximum_attempts" || \
           [[ "$contamination_only" != true ]]; then
            record_failure \
                "$case_name could not certify because unrelated input contaminated attempt $attempt"
            return 1
        fi

        local archived_attempt="$ARTIFACT_ROOT/contaminated-attempts/$case_name-$attempt"
        mv "$case_dir" "$archived_attempt"
        FAILURES="$failures_before_case"
        echo "RETRY: $case_name excluded contaminated attempt $attempt" >&2
        attempt=$((attempt + 1))
    done
    return 1
}

window_id_from_result() {
    local result_file="$1"
    local title="$2"
    jq -r --arg title "$title" '
        [.. | objects |
            select((.title? // .window_title? // .windowTitle? // "") == $title) |
            (.window_id? // .windowID? // .id?)] |
        map(select(. != null)) | first // empty
    ' "$result_file"
}

snapshot_id_from_result() {
    jq -r '.data.snapshot_id? // .snapshot_id? // empty' "$1"
}

element_id_from_result() {
    local result_file="$1"
    local identifier="$2"
    jq -r --arg identifier "$identifier" '
        [(.data.ui_elements? // .ui_elements? // [])[] |
            select(.identifier == $identifier) | .id] | first // empty
    ' "$result_file"
}

assert_result_contains() {
    local oracle="$1"
    local result_file="$2"
    local expected="$3"
    assert_case_result_contains "$LAST_CASE" "$oracle" "$result_file" "$expected"
}

assert_case_result_contains() {
    local case_name="$1"
    local oracle="$2"
    local result_file="$3"
    local expected="$4"
    if ! jq -e --arg expected "$expected" '[.. | strings] | any(contains($expected))' \
        "$result_file" >/dev/null; then
        record_case_oracle "$case_name" "$oracle" false || true
        record_failure "$case_name did not expose expected app-owned state for $oracle"
        return 1
    fi
    record_case_oracle "$case_name" "$oracle" true
}

assert_background_delivery() {
    local name="$1"
    local result_file="$2"
    if ! jq -e '.data.deliveryMode == "background"' "$result_file" >/dev/null; then
        record_last_case_oracle background_delivery false || true
        record_failure "$name did not report background delivery"
        return 1
    fi
    record_last_case_oracle background_delivery true
}

assert_case_artifacts() {
    local case_name="$1"
    shift
    local artifact
    for artifact in "$@"; do
        if [[ ! -s "$artifact" ]]; then
            record_case_oracle "$case_name" artifact false || true
            record_failure "$case_name did not produce required artifact: $artifact"
            return 1
        fi
    done
    record_case_oracle "$case_name" artifact true
}

assert_snapshot_identifiers() {
    local case_name="$1"
    shift
    local identifier
    for identifier in "$@"; do
        if [[ -z "$identifier" ]]; then
            record_case_oracle "$case_name" snapshot_identifiers false || true
            return 1
        fi
    done
    record_case_oracle "$case_name" snapshot_identifiers true
}

capture_playground_log() {
    local output="$1"
    "$ROOT_DIR/Apps/Playground/scripts/playground-log.sh" --last 10m --all --json \
        --output "$output" >/dev/null
    jq -e 'type == "array"' "$output" >/dev/null
}

playground_log_count() {
    local input="$1"
    local expected="$2"
    jq -r --argjson pid "$PLAYGROUND_PID" --arg expected "$expected" '
        [.[] |
            select(.processID == $pid) |
            select((.eventMessage // "") | contains($expected))] |
        length
    ' "$input"
}

assert_playground_log() {
    local case_name="$1"
    local oracle="$2"
    local input="$3"
    local expected="$4"
    if [[ "$(playground_log_count "$input" "$expected")" -lt 1 ]]; then
        record_case_oracle "$case_name" "$oracle" false || true
        record_failure "$case_name lacked controlled Playground log evidence: $expected"
        return 1
    fi
    record_case_oracle "$case_name" "$oracle" true
}

assert_playground_log_line() {
    local case_name="$1"
    local oracle="$2"
    local input="$3"
    local expected="$4"
    local detail="$5"
    if ! jq -e --argjson pid "$PLAYGROUND_PID" --arg expected "$expected" --arg detail "$detail" '
        any(.[];
            .processID == $pid and
            ((.eventMessage // "") | contains($expected) and contains($detail)))
    ' "$input" >/dev/null; then
        record_case_oracle "$case_name" "$oracle" false || true
        record_failure "$case_name lacked one PID-scoped Playground log line containing both expected values"
        return 1
    fi
    record_case_oracle "$case_name" "$oracle" true
}

assert_playground_log_delta() {
    local case_name="$1"
    local before="$2"
    local after="$3"
    local expected="$4"
    local before_count
    local after_count
    before_count="$(playground_log_count "$before" "$expected")"
    after_count="$(playground_log_count "$after" "$expected")"
    if [[ "$after_count" -le "$before_count" ]]; then
        record_case_oracle "$case_name" playground_log_delta false || true
        record_failure "$case_name did not add a fresh PID-scoped Playground log entry: $expected"
        return 1
    fi
    record_case_oracle "$case_name" playground_log_delta true
}

last_playground_scroll_offset() {
    local input="$1"
    jq -r --argjson pid "$PLAYGROUND_PID" '
        [.[] |
            select(.processID == $pid) |
            (.eventMessage // "") |
            select(contains("Vertical scroll offset")) |
            (try capture("y=(?<value>-?[0-9]+)").value catch empty)] |
        last // empty
    ' "$input"
}

assert_playground_scroll_changed() {
    local case_name="$1"
    local before="$2"
    local after="$3"
    local before_count
    local after_count
    local before_offset
    local after_offset
    before_count="$(playground_log_count "$before" "Vertical scroll offset")"
    after_count="$(playground_log_count "$after" "Vertical scroll offset")"
    before_offset="$(last_playground_scroll_offset "$before")"
    after_offset="$(last_playground_scroll_offset "$after")"
    if [[ "$after_count" -le "$before_count" || -z "$after_offset" || "$after_offset" == "$before_offset" ]]; then
        record_case_oracle "$case_name" scroll_offset_changed false || true
        record_failure "$case_name did not produce an independent Playground scroll-offset change"
        return 1
    fi
    record_case_oracle "$case_name" scroll_offset_changed true
}

read_lifecycle_launch_receipt() {
    local name="$1"
    local result_file="$2"
    if [[ -z "$result_file" || ! -s "$result_file" ]]; then
        record_case_oracle "$name" launch_receipt false || true
        record_failure "$name did not produce a launch receipt"
        LIFECYCLE_PID=""
        LIFECYCLE_WINDOW_ID=""
        LIFECYCLE_PROCESS_START_IDENTITY=""
        return 1
    fi
    if ! read_launch_process_receipt "$result_file"; then
        record_case_oracle "$name" launch_receipt false || true
        record_failure "$name did not return its launch-bound process-generation receipt"
        LIFECYCLE_PID=""
        LIFECYCLE_WINDOW_ID=""
        LIFECYCLE_PROCESS_START_IDENTITY=""
        return 1
    fi
    LIFECYCLE_PID="$LAUNCH_RECEIPT_PID"
    LIFECYCLE_PROCESS_START_IDENTITY="$LAUNCH_RECEIPT_PROCESS_START_IDENTITY"
    LIFECYCLE_WINDOW_ID="$(jq -r '.data.window_ids[0] // empty' "$result_file")"
    if [[ ! "$LIFECYCLE_PID" =~ ^[0-9]+$ ]] || [[ ! "$LIFECYCLE_WINDOW_ID" =~ ^[0-9]+$ ]] || \
       ! jq -e '
           .data.window_ready == true and
           .data.window_identity == "exact" and
           .data.window_count > 0 and
           (.data.window_ids | length) == .data.window_count
       ' "$result_file" >/dev/null; then
        record_case_oracle "$name" launch_receipt false || true
        record_failure "$name did not return a refreshed exact window receipt"
        LIFECYCLE_PID=""
        LIFECYCLE_WINDOW_ID=""
        LIFECYCLE_PROCESS_START_IDENTITY=""
        return 1
    fi
    LIFECYCLE_PIDS+=("$LIFECYCLE_PID")
    LIFECYCLE_PROCESS_START_IDENTITIES+=("$LIFECYCLE_PROCESS_START_IDENTITY")
    record_case_oracle "$name" launch_receipt true
}

assert_lifecycle_quit_outcome() {
    local case_name="$1"
    local result_file="$2"
    local pid="$3"
    local expected_start_identity="$4"
    local identity_file
    identity_file="$(case_dir_path "$case_name")/post-quit-process-identity.json"
    local current_start_identity=""
    local identity_probe_succeeded=false
    if "$PROBE_BIN" process-identity --pid "$pid" --output "$identity_file" 2>/dev/null; then
        current_start_identity="$(jq -r '.startIdentity // empty' "$identity_file")"
        identity_probe_succeeded=true
    fi
    local pid_alive=false
    if kill -0 "$pid" 2>/dev/null; then
        pid_alive=true
    fi
    local passed=false
    if jq -e '
        .success == true and
        .effect == "confirmed" and
        .error == null
    ' "$result_file" >/dev/null && {
        [[ "$pid_alive" == false ]] || {
            [[ "$identity_probe_succeeded" == true ]] &&
                ! same_process_generation "$expected_start_identity" "$current_start_identity"
        }
    }; then
        passed=true
    elif jq -e '
        .success == false and
        .effect == "suspected_noop" and
        .error.code == "INTERACTION_FAILED"
    ' "$result_file" >/dev/null && \
         [[ "$pid_alive" == true ]] && \
         [[ "$identity_probe_succeeded" == true ]] && \
         same_process_generation "$expected_start_identity" "$current_start_identity"; then
        passed=true
    fi
    if [[ "$passed" != true ]]; then
        record_case_oracle "$case_name" process_exit_truth false || true
        record_failure "$case_name did not match an exact quit-result/process-state tuple"
        return 1
    fi
    record_case_oracle "$case_name" process_exit_truth true
}

LIFECYCLE_PID=""
LIFECYCLE_WINDOW_ID=""
LIFECYCLE_PROCESS_START_IDENTITY=""
run_checked_case lifecycle-launch-maximize-close unchanged success \
    app launch TextEdit --new-instance --wait-for-window || true
if read_lifecycle_launch_receipt lifecycle-launch-maximize-close "$LAST_RESULT"; then
    MAXIMIZE_TEXTEDIT_WINDOW_ID="$LIFECYCLE_WINDOW_ID"
    run_checked_case lifecycle-maximize unchanged success \
        --setup-nonmaximized-window "$MAXIMIZE_TEXTEDIT_WINDOW_ID" "$LIFECYCLE_PID" \
        window maximize --window-id "$MAXIMIZE_TEXTEDIT_WINDOW_ID" || true
    if ! verified_maximize_result \
        "$LAST_RESULT" \
        "$(case_dir_path lifecycle-maximize)/maximize-readback.json" \
        "$(case_dir_path lifecycle-maximize)/before.json" \
        "$MAXIMIZE_TEXTEDIT_WINDOW_ID"; then
        record_last_case_oracle verified_bounds false || true
        record_failure "lifecycle-maximize did not return verified settled bounds"
    else
        record_last_case_oracle verified_bounds true
    fi
    run_checked_case lifecycle-close unchanged success \
        window close --window-id "$MAXIMIZE_TEXTEDIT_WINDOW_ID" || true
fi

LIFECYCLE_PID=""
LIFECYCLE_WINDOW_ID=""
LIFECYCLE_PROCESS_START_IDENTITY=""
run_checked_case lifecycle-launch-quit unchanged success \
    app launch TextEdit --new-instance --wait-for-window || true
if read_lifecycle_launch_receipt lifecycle-launch-quit "$LAST_RESULT"; then
    QUIT_TEXTEDIT_PID="$LIFECYCLE_PID"
    QUIT_TEXTEDIT_PROCESS_START_IDENTITY="$LIFECYCLE_PROCESS_START_IDENTITY"
    run_checked_case lifecycle-quit unchanged either \
        app quit --pid "$QUIT_TEXTEDIT_PID" \
        --expected-process-start-identity "$QUIT_TEXTEDIT_PROCESS_START_IDENTITY" || true
    assert_lifecycle_quit_outcome lifecycle-quit "$LAST_RESULT" "$QUIT_TEXTEDIT_PID" \
        "$QUIT_TEXTEDIT_PROCESS_START_IDENTITY" || true
fi

open_fixture() {
    local title="$1"
    local slug="$2"
    run_checked_case "menu-open-$slug" unchanged success \
        menu click --pid "$PLAYGROUND_PID" --path "Fixtures > Open $title" || true
    run_checked_case "list-window-$slug" unchanged success \
        window list --pid "$PLAYGROUND_PID" || true
    OPENED_WINDOW_ID="$(window_id_from_result "$LAST_RESULT" "$title")"
    if [[ -z "$OPENED_WINDOW_ID" ]]; then
        record_last_case_oracle window_discovery false || true
        record_failure "$slug fixture did not open in the background"
    else
        record_last_case_oracle window_discovery true
    fi
}

OPENED_WINDOW_ID=""
open_fixture "Text Fixture" text
TEXT_WINDOW_ID="$OPENED_WINDOW_ID"

if [[ -z "$TEXT_WINDOW_ID" ]]; then
    echo "The Playground text fixture window is unavailable." >&2
    exit 1
fi

run_checked_case see-text unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/text-see.png" || true
TEXT_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
BASIC_FIELD_ID="$(element_id_from_result "$LAST_RESULT" basic-text-field)"
FOCUS_BUTTON_ID="$(element_id_from_result "$LAST_RESULT" focus-basic-button)"
assert_case_artifacts see-text "$ARTIFACT_ROOT/text-see.png" || true
assert_snapshot_identifiers see-text "$TEXT_SNAPSHOT" "$BASIC_FIELD_ID" "$FOCUS_BUTTON_ID" || true
if [[ -z "$TEXT_SNAPSHOT" || -z "$BASIC_FIELD_ID" || -z "$FOCUS_BUTTON_ID" ]]; then
    record_failure "text fixture snapshot was missing deterministic identifiers"
    echo "Cannot continue safely without an exact text snapshot." >&2
    exit 1
fi

run_checked_case inspect-text unchanged success \
    see --tree --no-screenshot --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --max-elements 300 || true
assert_result_contains inspect_text "$LAST_RESULT" "Basic Text Field" || true

run_checked_case screenshot-text unchanged success \
    see --no-elements --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/text-screenshot.png" || true
assert_case_artifacts screenshot-text "$ARTIFACT_ROOT/text-screenshot.png" || true

run_checked_case capture-text unchanged success \
    capture live --pid "$PLAYGROUND_PID" --window-title "Text Fixture" --mode window \
    --duration 1s --idle-fps 2 --active-fps 2 --path "$ARTIFACT_ROOT/text-capture" || true
assert_case_artifacts capture-text \
    "$ARTIFACT_ROOT/text-capture/contact.png" \
    "$ARTIFACT_ROOT/text-capture/metadata.json" || true

FOCUS_LOG_BEFORE="$ARTIFACT_ROOT/playground-focus-before.json"
capture_playground_log "$FOCUS_LOG_BEFORE"
run_checked_case focus-basic-field unchanged success \
    click --on "$FOCUS_BUTTON_ID" --snapshot "$TEXT_SNAPSHOT" \
    --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" || true
assert_background_delivery focus-basic-field "$LAST_RESULT" || true
FOCUS_LOG_AFTER="$ARTIFACT_ROOT/playground-focus-after.json"
capture_playground_log "$FOCUS_LOG_AFTER"
assert_playground_log_delta focus-basic-field "$FOCUS_LOG_BEFORE" "$FOCUS_LOG_AFTER" \
    "Programmatically focused basic field" || true

run_checked_case stale-snapshot unchanged failure \
    --setup-stale-window "$TEXT_WINDOW_ID" "$PLAYGROUND_PID" \
    click --on "$FOCUS_BUTTON_ID" --snapshot "$TEXT_SNAPSHOT" \
    --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" || true

RUN_TOKEN="background-$RANDOM-$$"
TYPE_TOKEN="type-$RUN_TOKEN"
PASTE_TOKEN="paste-$RUN_TOKEN"
SET_TOKEN="set-$RUN_TOKEN"

run_checked_case type-window-selector-rejected unchanged failure \
    type "must-not-route-$RUN_TOKEN" --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" || true
assert_result_contains refusal_guidance "$LAST_RESULT" "cannot safely target a specific window" || true

run_checked_case type-text unchanged success \
    type "$TYPE_TOKEN" --pid "$PLAYGROUND_PID" || true
assert_background_delivery type-text "$LAST_RESULT" || true
run_checked_case press-background-refused unchanged failure \
    press return --pid "$PLAYGROUND_PID" || true
assert_result_contains refusal_guidance "$LAST_RESULT" "require explicit foreground consent" || true
run_checked_case paste-text allow-temporary success \
    paste "$PASTE_TOKEN" --pid "$PLAYGROUND_PID" || true
assert_background_delivery paste-text "$LAST_RESULT" || true

run_checked_case see-text-after-paste unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/text-after-paste.png" || true
assert_case_artifacts see-text-after-paste "$ARTIFACT_ROOT/text-after-paste.png" || true
assert_result_contains paste_readback "$LAST_RESULT" "$PASTE_TOKEN" || true
TEXT_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
BASIC_FIELD_ID="$(element_id_from_result "$LAST_RESULT" basic-text-field)"

run_checked_case set-value unchanged success \
    set-value "$SET_TOKEN" --on "$BASIC_FIELD_ID" --snapshot "$TEXT_SNAPSHOT" || true
run_checked_case see-text-after-set-value unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/text-after-set-value.png" || true
assert_case_artifacts see-text-after-set-value "$ARTIFACT_ROOT/text-after-set-value.png" || true
assert_result_contains set_value_readback "$LAST_RESULT" "$SET_TOKEN" || true

open_fixture "Click Fixture" click
CLICK_WINDOW_ID="$OPENED_WINDOW_ID"
open_fixture "Scroll Fixture" scroll
SCROLL_WINDOW_ID="$OPENED_WINDOW_ID"
if [[ -z "$CLICK_WINDOW_ID" || -z "$SCROLL_WINDOW_ID" ]]; then
    echo "The Playground click or scroll fixture window is unavailable." >&2
    exit 1
fi

run_checked_case see-click unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/click-see.png" || true
CLICK_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
SINGLE_CLICK_ID="$(element_id_from_result "$LAST_RESULT" single-click-button)"
assert_case_artifacts see-click "$ARTIFACT_ROOT/click-see.png" || true
assert_snapshot_identifiers see-click "$CLICK_SNAPSHOT" "$SINGLE_CLICK_ID" || true
if [[ -z "$CLICK_SNAPSHOT" || -z "$SINGLE_CLICK_ID" ]]; then
    record_failure "click fixture snapshot was missing deterministic identifiers"
    echo "Cannot continue safely without an exact click snapshot." >&2
    exit 1
fi
CLICK_LOG_BASELINE="$ARTIFACT_ROOT/playground-click-baseline.json"
capture_playground_log "$CLICK_LOG_BASELINE"

run_checked_case click-id unchanged success \
    click --on "$SINGLE_CLICK_ID" --snapshot "$CLICK_SNAPSHOT" \
    --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" || true
assert_background_delivery click-id "$LAST_RESULT" || true
run_checked_case see-click-after-id unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/click-after-id.png" || true
assert_case_artifacts see-click-after-id "$ARTIFACT_ROOT/click-after-id.png" || true
assert_case_result_contains click-id click_id_readback "$LAST_RESULT" "1 total clicks" || true
CLICK_LOG_AFTER_ID="$ARTIFACT_ROOT/playground-click-after-id.json"
capture_playground_log "$CLICK_LOG_AFTER_ID"
assert_playground_log_delta click-id "$CLICK_LOG_BASELINE" "$CLICK_LOG_AFTER_ID" \
    "Single click on 'Single Click' button" || true
CLICK_QUERY_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"

run_checked_case click-query unchanged success \
    click "Secondary Button" --snapshot "$CLICK_QUERY_SNAPSHOT" \
    --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" || true
assert_background_delivery click-query "$LAST_RESULT" || true
run_checked_case see-click-for-action unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/click-for-action.png" || true
CLICK_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
SINGLE_CLICK_ID="$(element_id_from_result "$LAST_RESULT" single-click-button)"
assert_case_artifacts see-click-for-action "$ARTIFACT_ROOT/click-for-action.png" || true
assert_snapshot_identifiers see-click-for-action "$CLICK_SNAPSHOT" "$SINGLE_CLICK_ID" || true
CLICK_LOG_AFTER_QUERY="$ARTIFACT_ROOT/playground-click-after-query.json"
capture_playground_log "$CLICK_LOG_AFTER_QUERY"
assert_playground_log_delta click-query "$CLICK_LOG_AFTER_ID" "$CLICK_LOG_AFTER_QUERY" \
    "Clicked 'Secondary Button'" || true

run_checked_case action unchanged success \
    action AXPress --on "$SINGLE_CLICK_ID" --snapshot "$CLICK_SNAPSHOT" || true
run_checked_case see-click-after-action unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/click-after-action.png" || true
assert_case_artifacts see-click-after-action "$ARTIFACT_ROOT/click-after-action.png" || true
assert_case_result_contains action action_readback "$LAST_RESULT" "2 total clicks" || true
CLICK_LOG_AFTER_ACTION="$ARTIFACT_ROOT/playground-click-after-action.json"
capture_playground_log "$CLICK_LOG_AFTER_ACTION"
assert_playground_log_delta action "$CLICK_LOG_AFTER_QUERY" "$CLICK_LOG_AFTER_ACTION" \
    "Single click on 'Single Click' button" || true

CLICK_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
SINGLE_CLICK_ID="$(element_id_from_result "$LAST_RESULT" single-click-button)"
run_checked_case unsupported-action unchanged failure \
    action AXDefinitelyUnsupported --on "$SINGLE_CLICK_ID" --snapshot "$CLICK_SNAPSHOT" || true
assert_result_contains refusal_guidance "$LAST_RESULT" "is not supported" || true

run_checked_case see-scroll unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$SCROLL_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/scroll-see.png" || true
SCROLL_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
VERTICAL_SCROLL_ID="$(element_id_from_result "$LAST_RESULT" vertical-scroll)"
assert_case_artifacts see-scroll "$ARTIFACT_ROOT/scroll-see.png" || true
assert_snapshot_identifiers see-scroll "$SCROLL_SNAPSHOT" "$VERTICAL_SCROLL_ID" || true
if [[ -z "$SCROLL_SNAPSHOT" || -z "$VERTICAL_SCROLL_ID" ]]; then
    record_failure "scroll fixture snapshot was missing the vertical scroll target"
else
    SCROLL_LOG_BEFORE="$ARTIFACT_ROOT/playground-scroll-before.json"
    capture_playground_log "$SCROLL_LOG_BEFORE"
    run_checked_case scroll-action-background unchanged success \
        scroll --direction down --amount 1 --delay 0ms --on "$VERTICAL_SCROLL_ID" \
        --snapshot "$SCROLL_SNAPSHOT" --pid "$PLAYGROUND_PID" --window-id "$SCROLL_WINDOW_ID" || true
    if ! confirmed_element_scroll_result "$LAST_RESULT"; then
        record_last_case_oracle confirmed_scroll false || true
        record_failure "scroll-action-background did not confirm exact element scrolling"
    else
        record_last_case_oracle confirmed_scroll true
    fi
    sleep 0.3
    SCROLL_LOG_AFTER="$ARTIFACT_ROOT/playground-scroll-after.json"
    capture_playground_log "$SCROLL_LOG_AFTER"
    assert_playground_scroll_changed scroll-action-background "$SCROLL_LOG_BEFORE" "$SCROLL_LOG_AFTER" || true
fi

sleep 0.3
capture_playground_log "$ARTIFACT_ROOT/playground.json"
assert_playground_log type-text playground_log "$ARTIFACT_ROOT/playground.json" "$TYPE_TOKEN" || true
assert_playground_log paste-text playground_log "$ARTIFACT_ROOT/playground.json" "$PASTE_TOKEN" || true
assert_playground_log set-value playground_log "$ARTIFACT_ROOT/playground.json" "$SET_TOKEN" || true

if $RUN_FOREGROUND_PHASE; then
    FOREGROUND_DIR="$ARTIFACT_ROOT/foreground"
    mkdir -p "$FOREGROUND_DIR"
    pb app switch --to "PID:$PLAYGROUND_PID" --verify --json \
        > "$FOREGROUND_DIR/focus-playground.json"
    "$PROBE_BIN" sample --output "$FOREGROUND_DIR/before.json"
    ORIGINAL_CURSOR="$(jq -r '.cursor.x|tostring + "," + ($ARGS.named.y|tostring)' \
        --argjson y "$(jq '.cursor.y' "$FOREGROUND_DIR/before.json")" "$FOREGROUND_DIR/before.json")"

    pb move --center --foreground --json > "$FOREGROUND_DIR/move.json"
    pb scroll --direction down --amount 1 --foreground --json \
        > "$FOREGROUND_DIR/scroll-down.json"
    pb scroll --direction up --amount 1 --foreground --json \
        > "$FOREGROUND_DIR/scroll-up.json"
    pb move --at "$ORIGINAL_CURSOR" --foreground --json \
        > "$FOREGROUND_DIR/restore-cursor.json"

    pb window focus --pid "$SENTINEL_PID" --window-id "$SENTINEL_WINDOW_ID" --verify --json \
        > "$FOREGROUND_DIR/restore-sentinel.json"
fi

OBSERVED_CERTIFICATION="$ARTIFACT_ROOT/certification-observed.json"
CERTIFICATION_RESULT="$ARTIFACT_ROOT/certification.json"
case_summaries=("$ARTIFACT_ROOT"/cases/*/summary.json)
jq -s \
    --slurpfile probe "$ARTIFACT_ROOT/probe-self-test.json" \
    --arg cliSourceCommit "$PEEKABOO_SOURCE_COMMIT" \
    --arg eventProducerSource "$EVENT_PRODUCER_SOURCE" \
    --arg eventProducerSourceCommit "$EVENT_PRODUCER_SOURCE_COMMIT" \
    --arg requestedBridgeSocket "$BRIDGE_SOCKET" \
    --argjson remoteHost "$REMOTE_EVENT_PRODUCER_JSON" \
    '{
        probe_canary: ($probe[0].success == true),
        provenance: {
            cli_source_commit: $cliSourceCommit,
            event_producer_source: $eventProducerSource,
            event_producer_source_commit: $eventProducerSourceCommit,
            requested_bridge_socket: (
                if $eventProducerSource == "remote" then $requestedBridgeSocket else null end
            ),
            remote_host: $remoteHost
        },
        cases: .
    }' \
    "${case_summaries[@]}" > "$OBSERVED_CERTIFICATION"
set +e
node "$CERTIFICATION_REPORTER" \
    --catalog "$CERTIFICATION_CATALOG" \
    --report "$OBSERVED_CERTIFICATION" \
    --output "$CERTIFICATION_RESULT"
CERTIFICATION_EXIT=$?
set -e
if [[ $CERTIFICATION_EXIT -ne 0 ]]; then
    record_failure "background certification catalog/report validation failed"
fi

CASE_COUNT="$(find "$ARTIFACT_ROOT/cases" -name summary.json -type f | wc -l | tr -d ' ')"
jq -n \
    --arg peekaboo "$(head -n 1 "$ARTIFACT_ROOT/peekaboo-version.txt")" \
    --arg sourceCommit "$PEEKABOO_SOURCE_COMMIT" \
    --arg playgroundBundle "$PLAYGROUND_BUNDLE_ID" \
    --argjson playgroundPID "$PLAYGROUND_PID" \
    --argjson sentinelPID "$SENTINEL_PID" \
    --argjson sentinelWindowID "$SENTINEL_WINDOW_ID" \
    --argjson cases "$CASE_COUNT" \
    --argjson failures "$FAILURES" \
    --argjson foregroundPhase "$RUN_FOREGROUND_PHASE" \
    --slurpfile certification "$CERTIFICATION_RESULT" \
    '{
        success: ($failures == 0),
        peekaboo: $peekaboo,
        source_commit: $sourceCommit,
        playground: {bundle_id: $playgroundBundle, pid: $playgroundPID},
        sentinel: {pid: $sentinelPID, window_id: $sentinelWindowID},
        cases: $cases,
        failures: $failures,
        foreground_phase: $foregroundPhase,
        certification: $certification[0]
    }' > "$ARTIFACT_ROOT/summary.json"

if [[ $FAILURES -ne 0 ]]; then
    echo "$FAILURES background computer-use checks failed; see $ARTIFACT_ROOT" >&2
    exit 1
fi

echo "Background computer-use validation passed ($CASE_COUNT cases): $ARTIFACT_ROOT"
