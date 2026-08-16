#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CATALOG="$ROOT_DIR/scripts/dual-controller-overlap-catalog.json"
REPORTER="$ROOT_DIR/scripts/validate-dual-controller-overlap-report.mjs"
PROBE_SOURCE="$ROOT_DIR/scripts/support/background-computer-use-probe.swift"
PEEKABOO_BIN="${PEEKABOO_BIN:-}"
BRIDGE_SOCKET="${PEEKABOO_BRIDGE_SOCKET:-}"
TEXTEDIT_APP="/System/Applications/TextEdit.app"
TEXTEDIT_EXECUTABLE=""
ARTIFACT_ROOT=""
SENTINEL_PID=""
SENTINEL_WINDOW_ID=""
SELF_TEST_ONLY=false
MONITOR_PID=""
WATCHDOG_PID=""
OVERLAP_WITNESS_PID=""
CLIENT_A_PID=""
CLIENT_B_PID=""
CLIENT_A_RECEIPT_PID=""
CLIENT_B_RECEIPT_PID=""
CLIENT_A_IDENTITY=""
CLIENT_B_IDENTITY=""
TARGET_A_PID=""
TARGET_A_IDENTITY=""
TARGET_B_PID=""
TARGET_B_IDENTITY=""
CLEANUP_COMPLETE=false
CLEANUP_STARTED=false
PENDING_LAUNCHER_PID=""
OPERATION_TIMEOUT_SECONDS="${PEEKABOO_OVERLAP_OPERATION_TIMEOUT_SECONDS:-30}"
CONTROLLED_OPERATION_HANDOFF_SECONDS=1
MUTATION_BOUNDED_OPERATION_COUNT=3
OBSERVATION_BOUNDED_OPERATION_COUNT=6
INITIAL_READBACK_REMAINING_OPERATION_COUNT="$OBSERVATION_BOUNDED_OPERATION_COUNT"
OVERLAP_WITNESS_REMAINING_OPERATION_COUNT=$((OBSERVATION_BOUNDED_OPERATION_COUNT + 2))
WORKFLOW_REMAINING_OPERATION_COUNT=$((4 * MUTATION_BOUNDED_OPERATION_COUNT + \
    3 * OBSERVATION_BOUNDED_OPERATION_COUNT))
FINAL_READBACK_REMAINING_OPERATION_COUNT="$OBSERVATION_BOUNDED_OPERATION_COUNT"
RESTORATION_REMAINING_OPERATION_COUNT=$((MUTATION_BOUNDED_OPERATION_COUNT + \
    2 * OBSERVATION_BOUNDED_OPERATION_COUNT))

usage() {
    cat <<'EOF'
Usage: scripts/test-dual-controller-overlap.sh [options]

Runs two independent Peekaboo clients through one exact signed Bridge host.
Both clients mutate different launch-owned TextEdit windows in the background
while an independently selected sentinel PID/window must remain foreground.

Protocol 1.29 receipt carriage is present, but live mode remains reserved until
the harness can invoke a first-party validator for every exported listener-,
session-, request-, response-, and rollover-bound receipt artifact.
The future live invocation will require PEEKABOO_RUN_DUAL_CONTROLLER_OVERLAP=1 and:
  --bin PATH                 Signed current Peekaboo CLI
  --bridge-socket PATH       Exact signed current Bridge socket
  --sentinel-pid PID         Already-running sentinel process
  --sentinel-window-id ID    Exact sentinel WindowServer window

Options:
  --textedit-app PATH        TextEdit.app path (default: /System/Applications/TextEdit.app)
  --artifacts PATH           New/empty private artifact directory
  --self-test                Compile the monitor and run contract tests only
  -h, --help                 Show help

PEEKABOO_OVERLAP_OPERATION_TIMEOUT_SECONDS sets the per-command deadline
(default 30; accepted range 1 through 300).

Physical cursor movement is recorded but never fails this cell. Focus/top-window,
global Peekaboo input, clipboard change count, and visible Peekaboo overlays remain
strict invariants. No AppleScript, JXA, System Events, or clipboard content is used.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bin|--bridge-socket|--sentinel-pid|--sentinel-window-id|--textedit-app|--artifacts)
            option="$1"
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || {
                printf 'Option requires a value: %s\n' "$option" >&2
                exit 2
            }
            case "$option" in
                --bin) PEEKABOO_BIN="$2" ;;
                --bridge-socket) BRIDGE_SOCKET="$2" ;;
                --sentinel-pid) SENTINEL_PID="$2" ;;
                --sentinel-window-id) SENTINEL_WINDOW_ID="$2" ;;
                --textedit-app) TEXTEDIT_APP="$2" ;;
                --artifacts) ARTIFACT_ROOT="$2" ;;
            esac
            shift 2
            ;;
        --self-test) SELF_TEST_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$ARTIFACT_ROOT" ]]; then
    ARTIFACT_ROOT="$ROOT_DIR/.artifacts/dual-controller-overlap/$(date -u +%Y%m%dT%H%M%SZ)"
elif [[ "$ARTIFACT_ROOT" != /* ]]; then
    ARTIFACT_ROOT="$ROOT_DIR/$ARTIFACT_ROOT"
fi
if [[ -e "$ARTIFACT_ROOT" && ! -d "$ARTIFACT_ROOT" ]]; then
    printf 'Artifact path is not a directory: %s\n' "$ARTIFACT_ROOT" >&2
    exit 2
fi
if [[ -d "$ARTIFACT_ROOT" ]] && \
   [[ -n "$(find "$ARTIFACT_ROOT" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    printf 'Artifact directory must be new or empty: %s\n' "$ARTIFACT_ROOT" >&2
    exit 2
fi
mkdir -p "$ARTIFACT_ROOT/bin" "$ARTIFACT_ROOT/controllers" "$ARTIFACT_ROOT/results"
ARTIFACT_ROOT="$(cd "$ARTIFACT_ROOT" && pwd -P)"
chmod 700 "$ARTIFACT_ROOT" "$ARTIFACT_ROOT/bin" "$ARTIFACT_ROOT/controllers" "$ARTIFACT_ROOT/results"

for command_name in awk jq node plutil ps rg shasum swiftc uuidgen; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$command_name" >&2
        exit 2
    }
done
if ! [[ "$OPERATION_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || ((OPERATION_TIMEOUT_SECONDS > 300)); then
    printf '%s\n' 'PEEKABOO_OVERLAP_OPERATION_TIMEOUT_SECONDS must be an integer from 1 through 300.' >&2
    exit 2
fi

write_owned_generation_receipt() {
    local pid="$1"
    local identity="$2"
    local ownership_result="$3"
    local temporary="$ownership_result.tmp"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$identity" =~ ^[1-9][0-9]*$ ]] || return 1
    jq -n --argjson pid "$pid" --arg identity "$identity" \
        '{pid: $pid, start_identity: $identity}' > "$temporary"
    mv "$temporary" "$ownership_result"
}

persist_owned_generation() {
    local id="$1"
    local pid="$2"
    local identity="$3"
    local ownership_result="$4"
    [[ "$id" == A || "$id" == B ]] || return 1
    write_owned_generation_receipt "$pid" "$identity" "$ownership_result"
    if [[ "$id" == A ]]; then
        TARGET_A_PID="$pid"
        TARGET_A_IDENTITY="$identity"
    else
        TARGET_B_PID="$pid"
        TARGET_B_IDENTITY="$identity"
    fi
}

run_launch_ownership_self_test() {
    persist_owned_generation A 4242 987654321 \
        "$ARTIFACT_ROOT/results/launch-ownership-self-test-a.json"
    persist_owned_generation B 5252 123456789 \
        "$ARTIFACT_ROOT/results/launch-ownership-self-test-b.json"
    jq -n --argjson success "$([[ "$TARGET_A_PID" == 4242 && \
        "$TARGET_A_IDENTITY" == 987654321 && "$TARGET_B_PID" == 5252 && \
        "$TARGET_B_IDENTITY" == 123456789 ]] && \
        printf true || printf false)" \
        --argjson pid "$TARGET_A_PID" --arg identity "$TARGET_A_IDENTITY" \
        --argjson secondPID "$TARGET_B_PID" --arg secondIdentity "$TARGET_B_IDENTITY" '
        {
            success: $success,
            cleanup_received: {pid: $pid, start_identity: $identity},
            second_cleanup_received: {pid: $secondPID, start_identity: $secondIdentity}
        }
    '
}

PROBE_BIN="$ARTIFACT_ROOT/bin/background-computer-use-probe"
swiftc "$PROBE_SOURCE" -o "$PROBE_BIN" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CryptoKit
"$PROBE_BIN" self-test > "$ARTIFACT_ROOT/probe-self-test.json"

pb() {
    local prefix
    prefix="$ARTIFACT_ROOT/results/bounded-pb-$(uuidgen | tr '[:upper:]' '[:lower:]')"
    if ! spawn_controlled_cli "$prefix" "$PEEKABOO_BIN" "$@" --bridge-socket "$BRIDGE_SOCKET"; then
        [[ ! -f "$prefix.stderr" ]] || cat "$prefix.stderr" >&2
        return 1
    fi
    local command_pid="$SPAWNED_PID"
    local command_identity="$SPAWNED_IDENTITY"
    local command_resumed_at="$SPAWNED_RESUMED_AT"
    local inflight="$SPAWNED_INFLIGHT"
    local command_exit=0
    set +e
    wait_for_spawned_cli "$command_pid" "$command_identity" "$prefix" "$command_resumed_at"
    command_exit=$?
    set -e
    rm -f "$inflight"
    [[ ! -f "$prefix.json" ]] || cat "$prefix.json"
    [[ ! -f "$prefix.stderr" ]] || cat "$prefix.stderr" >&2
    return "$command_exit"
}

process_generation_state() {
    local pid="$1"
    local identity="$2"
    local current state
    if ! state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')"; then
        kill -0 "$pid" >/dev/null 2>&1 && return 2
        return 1
    fi
    [[ -n "$state" ]] || {
        kill -0 "$pid" >/dev/null 2>&1 && return 2
        return 1
    }
    [[ "$state" != Z* ]] || return 1
    if ! current="$("$PROBE_BIN" process-identity --pid "$pid" 2>/dev/null | \
        jq -er '.startIdentity | tostring' 2>/dev/null)"; then
        kill -0 "$pid" >/dev/null 2>&1 && return 2
        return 1
    fi
    [[ "$current" == "$identity" ]] && return 0
    return 1
}

process_alive() {
    process_generation_state "$1" "$2"
}

owned_generation_gone() {
    local pid="$1"
    local identity="$2"
    local state=0
    process_generation_state "$pid" "$identity" || state=$?
    case "$state" in
        0) return 1 ;;
        1) return 0 ;;
        *) return 2 ;;
    esac
}

terminate_owned_generation_directly() {
    local id="$1"
    local pid="$2"
    local identity="$3"
    local reason="$4"
    local output="$ARTIFACT_ROOT/results/cleanup-${id}-direct.json"
    local term_sent=false kill_sent=false
    local parent_pid generation_state=0
    parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    process_generation_state "$pid" "$identity" || generation_state=$?
    if [[ $generation_state -eq 0 ]]; then
        kill "$pid" >/dev/null 2>&1 || true
        term_sent=true
        for _ in $(seq 1 100); do
            owned_generation_gone "$pid" "$identity" && break
            sleep 0.01
        done
    fi
    generation_state=0
    process_generation_state "$pid" "$identity" || generation_state=$?
    if [[ $generation_state -eq 0 || ($generation_state -eq 2 && "$parent_pid" == "$$") ]]; then
        kill -KILL "$pid" >/dev/null 2>&1 || true
        kill_sent=true
        for _ in $(seq 1 100); do
            owned_generation_gone "$pid" "$identity" && break
            sleep 0.01
        done
    fi
    local gone=false
    owned_generation_gone "$pid" "$identity" && gone=true
    if $gone; then
        wait "$pid" >/dev/null 2>&1 || true
    fi
    jq -n --arg id "$id" --argjson pid "$pid" --arg identity "$identity" \
        --arg reason "$reason" --argjson termSent "$term_sent" \
        --argjson killSent "$kill_sent" --argjson gone "$gone" '
        {
            id: $id,
            pid: $pid,
            start_identity: $identity,
            reason: $reason,
            term_sent: $termSent,
            kill_sent: $killSent,
            gone: $gone
        }
    ' > "$output"
    $gone
}

quit_owned_target() {
    local id="$1"
    local pid="$2"
    local identity="$3"
    [[ "$pid" =~ ^[1-9][0-9]*$ && "$identity" =~ ^[1-9][0-9]*$ ]] || return 0
    local gone_status=0
    owned_generation_gone "$pid" "$identity" || gone_status=$?
    [[ $gone_status -ne 0 ]] || return 0
    if [[ $gone_status -eq 2 ]]; then
        terminate_owned_generation_directly "$id" "$pid" "$identity" generation_unknown || true
        return 1
    fi
    if ! capture_host_receipt "$ARTIFACT_ROOT/results/cleanup-${id}-host-before.json"; then
        terminate_owned_generation_directly "$id" "$pid" "$identity" bridge_unavailable || true
        return 1
    fi
    local quit_exit=0
    pb app quit --pid "$pid" --expected-process-start-identity "$identity" --force --json \
        > "$ARTIFACT_ROOT/results/cleanup-${id}.json" 2> "$ARTIFACT_ROOT/results/cleanup-${id}.stderr" || \
        quit_exit=$?
    for _ in $(seq 1 150); do
        gone_status=0
        owned_generation_gone "$pid" "$identity" || gone_status=$?
        if [[ $gone_status -eq 0 ]]; then
            wait "$pid" >/dev/null 2>&1 || true
            if [[ $quit_exit -eq 0 ]] && \
               jq -e '.success == true' "$ARTIFACT_ROOT/results/cleanup-${id}.json" >/dev/null && \
               capture_host_receipt "$ARTIFACT_ROOT/results/cleanup-${id}-host-after.json"; then
                return 0
            fi
            terminate_owned_generation_directly "$id" "$pid" "$identity" bridge_cleanup_unverified || true
            return 1
        fi
        if [[ $gone_status -eq 2 ]]; then
            terminate_owned_generation_directly "$id" "$pid" "$identity" generation_unknown || true
            return 1
        fi
        sleep 0.02
    done
    terminate_owned_generation_directly "$id" "$pid" "$identity" bridge_cleanup_incomplete || true
    return 1
}

quit_recovery_targets() {
    local receipt pid identity index=0 failed=false
    while IFS= read -r receipt; do
        [[ -n "$receipt" ]] || continue
        pid="$(jq -er '.pid' "$receipt" 2>/dev/null || true)"
        identity="$(jq -er '.start_identity' "$receipt" 2>/dev/null || true)"
        [[ "$pid" =~ ^[1-9][0-9]*$ && "$identity" =~ ^[1-9][0-9]*$ ]] || continue
        index=$((index + 1))
        quit_owned_target "recovery-${index}" "$pid" "$identity" || failed=true
    done < <(find "$ARTIFACT_ROOT/controllers" -maxdepth 1 -type f -name 'owned-target-*.json' -print)
    ! $failed
}

stop_inflight_operations() {
    local receipt pid identity owner_pid failed=false
    while IFS= read -r receipt; do
        [[ -n "$receipt" ]] || continue
        pid="$(jq -er '.pid' "$receipt" 2>/dev/null || true)"
        identity="$(jq -er '.start_identity' "$receipt" 2>/dev/null || true)"
        owner_pid="$(jq -er '.owner_pid // empty' "$receipt" 2>/dev/null || true)"
        [[ "$pid" =~ ^[1-9][0-9]*$ && "$identity" =~ ^[1-9][0-9]*$ ]] || continue
        if process_alive "$pid" "$identity"; then
            kill "$pid" >/dev/null 2>&1 || true
            for _ in $(seq 1 100); do
                owned_generation_gone "$pid" "$identity" && break
                sleep 0.01
            done
            local post_term_state=0 parent_pid
            process_generation_state "$pid" "$identity" || post_term_state=$?
            parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
            if [[ $post_term_state -eq 0 || \
                  ($post_term_state -eq 2 && "$owner_pid" =~ ^[1-9][0-9]*$ && "$parent_pid" == "$owner_pid") ]]; then
                kill -KILL "$pid" >/dev/null 2>&1 || true
                for _ in $(seq 1 100); do
                    owned_generation_gone "$pid" "$identity" && break
                    sleep 0.01
                done
            elif [[ $post_term_state -eq 2 ]]; then
                failed=true
            fi
            if ! owned_generation_gone "$pid" "$identity"; then
                printf 'Inflight client generation survived cleanup: %s:%s\n' "$pid" "$identity" >&2
                failed=true
            fi
        else
            local generation_state=0
            process_generation_state "$pid" "$identity" || generation_state=$?
            if [[ $generation_state -eq 2 ]]; then
                local parent_pid
                parent_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
                if [[ "$owner_pid" =~ ^[1-9][0-9]*$ && "$parent_pid" == "$owner_pid" ]]; then
                    kill -KILL "$pid" >/dev/null 2>&1 || true
                    wait "$pid" >/dev/null 2>&1 || true
                    owned_generation_gone "$pid" "$identity" || failed=true
                else
                    failed=true
                fi
            elif [[ $generation_state -ne 1 ]]; then
                failed=true
            fi
        fi
    done < <(find "$ARTIFACT_ROOT/controllers" -maxdepth 1 -type f -name 'inflight-*.json' -print)
    ! $failed
}

freeze_and_register_controller_children() {
    local controller_pid="$1"
    [[ "$controller_pid" =~ ^[1-9][0-9]*$ ]] || return 0
    kill -STOP "$controller_pid" >/dev/null 2>&1 || return 0
    local child_pid identity_result identity receipt
    while IFS= read -r child_pid; do
        [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] || continue
        identity_result="$ARTIFACT_ROOT/controllers/emergency-${controller_pid}-${child_pid}-identity.json"
        if "$PROBE_BIN" process-identity --pid "$child_pid" --output "$identity_result" 2>/dev/null; then
            identity="$(jq -er '.startIdentity' "$identity_result" 2>/dev/null || true)"
            if [[ "$identity" =~ ^[1-9][0-9]*$ ]]; then
                receipt="$ARTIFACT_ROOT/controllers/inflight-emergency-${child_pid}-${identity}.json"
                jq -n --argjson pid "$child_pid" --arg startIdentity "$identity" \
                    --argjson ownerPID "$controller_pid" '
                    {pid: $pid, start_identity: $startIdentity, owner_pid: $ownerPID}
                ' > "$receipt.tmp"
                mv "$receipt.tmp" "$receipt"
                continue
            fi
        fi
        kill -KILL "$child_pid" >/dev/null 2>&1 || true
        jq -n --argjson pid "$child_pid" --argjson ownerPID "$controller_pid" '
            {pid: $pid, owner_pid: $ownerPID, reason: "identity_unavailable_before_wrapper_cleanup"}
        ' > "$ARTIFACT_ROOT/controllers/emergency-kill-${controller_pid}-${child_pid}.json"
    done < <(ps -axo pid=,ppid= | awk -v parent="$controller_pid" '$2 == parent {print $1}')
}

read_pending_focus_state() {
    local heartbeat_path="${1:?Heartbeat path required}"
    jq -r '
        if has("pendingFocusedWindowChange") and
            (.pendingFocusedWindowChange | type) == "boolean"
        then .pendingFocusedWindowChange
        else true
        end
    ' "$heartbeat_path"
}

finish_monitoring() {
    local pre_cleanup_sequence="$1"
    local final_sample_path="$2"
    local settled=false watchdog_exit=0 sample_succeeded=true
    if [[ ! "$MONITOR_PID" =~ ^[1-9][0-9]*$ ]]; then
        if [[ "$WATCHDOG_PID" =~ ^[1-9][0-9]*$ ]]; then
            kill -KILL "$WATCHDOG_PID" >/dev/null 2>&1 || true
            wait "$WATCHDOG_PID" >/dev/null 2>&1 || true
            WATCHDOG_PID=""
        fi
        return 0
    fi
    if ! kill -0 "$MONITOR_PID" >/dev/null 2>&1; then
        printf '%s\n' 'Invariant monitor exited before cleanup completed.' >&2
        if [[ "$WATCHDOG_PID" =~ ^[1-9][0-9]*$ ]]; then
            : > "$ARTIFACT_ROOT/monitor-watchdog.stop"
            wait "$WATCHDOG_PID" >/dev/null 2>&1 || true
            WATCHDOG_PID=""
        fi
        MONITOR_PID=""
        return 1
    fi
    "$PROBE_BIN" sample --no-clipboard-digest --output "$final_sample_path" || sample_succeeded=false
    for _ in $(seq 1 100); do
        local current_sequence heartbeat_timestamp pending_activations pending_focus final_sample_timestamp
        current_sequence="$(jq -r '.sequence // 0' "$ARTIFACT_ROOT/monitor-heartbeat.json" 2>/dev/null || printf 0)"
        heartbeat_timestamp="$(jq -r '.timestamp // 0' "$ARTIFACT_ROOT/monitor-heartbeat.json" 2>/dev/null || printf 0)"
        pending_activations="$(jq -r '.pendingActivationCount // -1' \
            "$ARTIFACT_ROOT/monitor-heartbeat.json" 2>/dev/null || printf -- -1)"
        pending_focus="$(read_pending_focus_state \
            "$ARTIFACT_ROOT/monitor-heartbeat.json" 2>/dev/null || printf true)"
        final_sample_timestamp="$(jq -r '.timestamp // 0' "$final_sample_path" 2>/dev/null || printf 0)"
        if [[ "$current_sequence" =~ ^[0-9]+$ && "$current_sequence" -gt "$pre_cleanup_sequence" ]] && \
           [[ "$pending_activations" == 0 && "$pending_focus" == false ]] && \
           awk -v heartbeat="$heartbeat_timestamp" -v final="$final_sample_timestamp" \
               'BEGIN { exit !(heartbeat >= final) }'; then
            settled=true
            break
        fi
        sleep 0.02
    done
    if [[ "$WATCHDOG_PID" =~ ^[1-9][0-9]*$ ]]; then
        : > "$ARTIFACT_ROOT/monitor-watchdog.stop"
        wait "$WATCHDOG_PID" || watchdog_exit=$?
        WATCHDOG_PID=""
    fi
    if kill -0 "$MONITOR_PID" >/dev/null 2>&1; then
        kill "$MONITOR_PID"
        wait "$MONITOR_PID" >/dev/null 2>&1 || true
    fi
    MONITOR_PID=""
    if ! $sample_succeeded; then
        printf '%s\n' 'Could not capture the completed cleanup sample.' >&2
        return 1
    fi
    if [[ $watchdog_exit -ne 0 ]]; then
        printf '%s\n' 'Invariant monitor heartbeat stalled during the certified interval.' >&2
        return 1
    fi
    if ! $settled; then
        printf '%s\n' 'Invariant monitor did not observe the completed cleanup state.' >&2
        return 1
    fi
    return 0
}

cleanup() {
    $CLEANUP_STARTED && return
    CLEANUP_STARTED=true
    trap - EXIT INT TERM
    local controller_pids=("$CLIENT_A_PID" "$CLIENT_B_PID")
    local controller_identities=("$CLIENT_A_IDENTITY" "$CLIENT_B_IDENTITY")
    local pids=("$OVERLAP_WITNESS_PID")
    local pending_launcher_pid="$PENDING_LAUNCHER_PID"
    local pre_cleanup_sequence=0
    if [[ -s "$ARTIFACT_ROOT/monitor-heartbeat.json" ]]; then
        pre_cleanup_sequence="$(jq -r '.sequence // 0' \
            "$ARTIFACT_ROOT/monitor-heartbeat.json" 2>/dev/null || printf 0)"
    fi
    CLIENT_A_PID=""
    CLIENT_B_PID=""
    OVERLAP_WITNESS_PID=""
    PENDING_LAUNCHER_PID=""
    if [[ "$pending_launcher_pid" =~ ^[1-9][0-9]*$ ]]; then
        kill -KILL "$pending_launcher_pid" >/dev/null 2>&1 || true
        wait "$pending_launcher_pid" >/dev/null 2>&1 || true
    fi
    local cleanup_failed=false
    local controller_index controller_state controller_identity
    for controller_index in "${!controller_pids[@]}"; do
        pid="${controller_pids[$controller_index]}"
        controller_identity="${controller_identities[$controller_index]}"
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        if ! [[ "$controller_identity" =~ ^[1-9][0-9]*$ ]]; then
            local controller_parent
            controller_parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
            if [[ "$controller_parent" == "$$" ]]; then
                freeze_and_register_controller_children "$pid"
            else
                cleanup_failed=true
            fi
            continue
        fi
        controller_state=0
        process_generation_state "$pid" "$controller_identity" || controller_state=$?
        if [[ $controller_state -eq 0 ]]; then
            freeze_and_register_controller_children "$pid"
        elif [[ $controller_state -eq 2 ]]; then
            cleanup_failed=true
        fi
    done
    stop_inflight_operations || cleanup_failed=true
    for controller_index in "${!controller_pids[@]}"; do
        pid="${controller_pids[$controller_index]}"
        controller_identity="${controller_identities[$controller_index]}"
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        if ! [[ "$controller_identity" =~ ^[1-9][0-9]*$ ]]; then
            local controller_parent
            controller_parent="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
            if [[ "$controller_parent" == "$$" ]]; then
                kill -KILL "$pid" >/dev/null 2>&1 || true
                wait "$pid" >/dev/null 2>&1 || true
            else
                cleanup_failed=true
            fi
            continue
        fi
        controller_state=0
        process_generation_state "$pid" "$controller_identity" || controller_state=$?
        if [[ $controller_state -eq 0 ]]; then
            kill -KILL "$pid" >/dev/null 2>&1 || true
            wait "$pid" >/dev/null 2>&1 || true
        elif [[ $controller_state -eq 2 ]]; then
            cleanup_failed=true
        fi
    done
    for pid in "${pids[@]}"; do
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
        kill "$pid" >/dev/null 2>&1 || true
        wait "$pid" >/dev/null 2>&1 || true
    done
    stop_inflight_operations || cleanup_failed=true
    if ! $CLEANUP_COMPLETE; then
        quit_owned_target A "$TARGET_A_PID" "$TARGET_A_IDENTITY" || cleanup_failed=true
        quit_owned_target B "$TARGET_B_PID" "$TARGET_B_IDENTITY" || cleanup_failed=true
        quit_recovery_targets || cleanup_failed=true
    fi
    finish_monitoring "$pre_cleanup_sequence" "$ARTIFACT_ROOT/cleanup-final-sample.json" || cleanup_failed=true
    if $cleanup_failed; then
        return 1
    fi
    return 0
}
trap cleanup EXIT
trap 'exit 130' INT TERM

clock_value() {
    "$PROBE_BIN" clock | jq -er '.monotonicSeconds'
}

synchronization_budget_seconds() {
    local maximum_remaining_operations="$1"
    [[ "$maximum_remaining_operations" =~ ^[1-9][0-9]*$ ]] || return 1
    # Two 50 x 5 ms registration/attestation probes plus deadline completion polling fit one handoff second.
    awk -v operations="$maximum_remaining_operations" \
        -v timeout="$OPERATION_TIMEOUT_SECONDS" \
        -v handoff="$CONTROLLED_OPERATION_HANDOFF_SECONDS" '
        BEGIN { printf "%.9f", operations * (timeout + handoff) }
    '
}

synchronization_deadline() {
    local maximum_remaining_operations="$1"
    local started_at="${2:-}"
    local budget
    [[ -n "$started_at" ]] || started_at="$(clock_value)"
    budget="$(synchronization_budget_seconds "$maximum_remaining_operations")" || return 1
    awk -v started="$started_at" -v budget="$budget" '
        BEGIN { printf "%.9f", started + budget }
    '
}

synchronization_deadline_reached() {
    local deadline="$1"
    local now="${2:-}"
    [[ -n "$now" ]] || now="$(clock_value)"
    awk -v now="$now" -v deadline="$deadline" 'BEGIN { exit !(now >= deadline) }'
}

synchronization_marker_ready() {
    local marker="$1"
    local readiness="$2"
    case "$readiness" in
        exists) [[ -e "$marker" ]] ;;
        nonempty) [[ -s "$marker" ]] ;;
        *) return 1 ;;
    esac
}

wait_for_synchronization_until() {
    local marker="$1"
    local peer_pid="$2"
    local peer_identity="$3"
    local deadline="$4"
    local readiness="${5:-exists}"
    while true; do
        synchronization_deadline_reached "$deadline" && return 1
        process_alive "$peer_pid" "$peer_identity" || return 1
        synchronization_deadline_reached "$deadline" && return 1
        synchronization_marker_ready "$marker" "$readiness" && return 0
        sleep 0.01
    done
}

wait_for_controller_marker() {
    local marker="$1"
    local peer_controller="$2"
    local maximum_remaining_operations="$3"
    local readiness="${4:-exists}"
    local receipt="$ARTIFACT_ROOT/controllers/${peer_controller}-client.json"
    local peer_pid peer_identity deadline
    peer_pid="$(jq -er '.pid' "$receipt")" || return 1
    peer_identity="$(jq -er '.startIdentity' "$receipt")" || return 1
    deadline="$(synchronization_deadline "$maximum_remaining_operations")" || return 1
    wait_for_synchronization_until "$marker" "$peer_pid" "$peer_identity" "$deadline" "$readiness"
}

tracked_input_matches_commit() {
    local file="$1"
    local relative="${file#"$ROOT_DIR"/}"
    local working_blob committed_blob
    working_blob="$(git -C "$ROOT_DIR" hash-object "$file")" || return 1
    committed_blob="$(git -C "$ROOT_DIR" rev-parse "$SOURCE_COMMIT:$relative")" || return 1
    [[ "$working_blob" == "$committed_blob" ]]
}

capture_process_identity() {
    local pid="$1"
    local output="$2"
    for _ in $(seq 1 50); do
        if "$PROBE_BIN" process-identity --pid "$pid" --output "$output" 2>/dev/null; then
            return 0
        fi
        sleep 0.005
    done
    return 1
}

capture_process_executable_identity() {
    local pid="$1"
    local output="$2"
    local expected_path="$3"
    for _ in $(seq 1 50); do
        if "$PROBE_BIN" process-executable-identity --pid "$pid" --output "$output.tmp" 2>/dev/null && \
           [[ "$(jq -r '.path // empty' "$output.tmp")" == "$expected_path" ]]; then
            mv "$output.tmp" "$output"
            return 0
        fi
        local state
        state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
        [[ -n "$state" && "$state" != Z* ]] || break
        sleep 0.005
    done
    rm -f "$output.tmp"
    return 1
}

kill_and_reap_stopped_launcher() {
    local pid="$1"
    kill -KILL "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    if [[ "$PENDING_LAUNCHER_PID" == "$pid" ]]; then
        PENDING_LAUNCHER_PID=""
    fi
}

wait_for_spawned_cli() {
    local pid="$1"
    local identity="$2"
    local prefix="$3"
    local resumed_at="$4"
    local timeout_marker="$prefix-timeout.json"
    local deadline term_at
    deadline="$(awk -v resumed="$resumed_at" -v seconds="$OPERATION_TIMEOUT_SECONDS" \
        'BEGIN { printf "%.9f", resumed + seconds }')"
    term_at="$(awk -v resumed="$resumed_at" -v deadline="$deadline" \
        -v seconds="$OPERATION_TIMEOUT_SECONDS" '
        BEGIN {
            grace = seconds * 0.1
            if (grace > 1) grace = 1
            candidate = deadline - grace
            printf "%.9f", (candidate > resumed ? candidate : resumed)
        }
    ')"
    (
        local term_sent=false now
        while true; do
            local generation_state=0
            process_generation_state "$pid" "$identity" || generation_state=$?
            [[ $generation_state -ne 1 ]] || exit 0
            now="$(clock_value 2>/dev/null || true)"
            if ! [[ "$now" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                jq -n --argjson pid "$pid" --arg identity "$identity" \
                    '{pid: $pid, start_identity: $identity, reason: "clock_failed"}' \
                    > "$timeout_marker.tmp"
                mv "$timeout_marker.tmp" "$timeout_marker"
                kill -KILL "$pid" >/dev/null 2>&1 || true
                exit 0
            fi
            if awk -v now="$now" -v deadline="$deadline" 'BEGIN { exit !(now >= deadline) }'; then
                if [[ -s "$timeout_marker" ]]; then
                    jq --argjson killAt "$now" '. + {kill_at: $killAt}' \
                        "$timeout_marker" > "$timeout_marker.tmp"
                else
                    jq -n --argjson pid "$pid" --arg identity "$identity" \
                        --argjson resumedAt "$resumed_at" --argjson deadline "$deadline" \
                        --argjson killAt "$now" --argjson seconds "$OPERATION_TIMEOUT_SECONDS" '
                        {
                            pid: $pid,
                            start_identity: $identity,
                            resumed_at: $resumedAt,
                            deadline: $deadline,
                            kill_at: $killAt,
                            timeout_seconds: $seconds
                        }
                    ' > "$timeout_marker.tmp"
                fi
                mv "$timeout_marker.tmp" "$timeout_marker"
                kill -KILL "$pid" >/dev/null 2>&1 || true
                exit 0
            fi
            if ! $term_sent && \
               awk -v now="$now" -v termAt="$term_at" 'BEGIN { exit !(now >= termAt) }'; then
                jq -n --argjson pid "$pid" --arg identity "$identity" \
                    --argjson resumedAt "$resumed_at" --argjson termAt "$term_at" \
                    --argjson deadline "$deadline" --argjson seconds "$OPERATION_TIMEOUT_SECONDS" '
                    {
                        pid: $pid,
                        start_identity: $identity,
                        resumed_at: $resumedAt,
                        term_at: $termAt,
                        deadline: $deadline,
                        timeout_seconds: $seconds
                    }
                ' > "$timeout_marker.tmp"
                mv "$timeout_marker.tmp" "$timeout_marker"
                kill "$pid" >/dev/null 2>&1 || exit 0
                term_sent=true
            fi
            sleep 0.02
        done
    ) &
    local timeout_pid=$!
    local command_exit=0
    wait "$pid" 2>/dev/null || command_exit=$?
    kill -KILL "$timeout_pid" >/dev/null 2>&1 || true
    wait "$timeout_pid" >/dev/null 2>&1 || true
    [[ ! -s "$timeout_marker" ]] || return 124
    return "$command_exit"
}

spawn_controlled_process() {
    local prefix="$1"
    local expected_path="$2"
    shift 2
    SPAWNED_PID=""
    SPAWNED_IDENTITY=""
    SPAWNED_PATH=""
    SPAWNED_INFLIGHT=""
    SPAWNED_RESUMED_AT=""
    local ready="$prefix-launcher.ready"
    local deferred_signal=""
    trap 'deferred_signal=INT' INT
    trap 'deferred_signal=TERM' TERM
    /bin/sh -c '
        ready=$1
        shift
        printf "%s\n" ready > "$ready"
        kill -STOP "$$"
        exec "$@"
    ' sh "$ready" "$@" > "$prefix.json" 2> "$prefix.stderr" &
    local pid
    pid=$!
    PENDING_LAUNCHER_PID="$pid"
    trap 'exit 130' INT TERM
    if [[ -n "$deferred_signal" ]]; then
        kill_and_reap_stopped_launcher "$pid"
        return 130
    fi
    for _ in $(seq 1 100); do
        if [[ -s "$ready" && "$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')" == T* ]]; then
            break
        fi
        sleep 0.005
    done
    if [[ ! -s "$ready" || "$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]')" != T* ]]; then
        kill_and_reap_stopped_launcher "$pid"
        return 1
    fi
    if ! capture_process_identity "$pid" "$prefix-client-identity.json"; then
        kill_and_reap_stopped_launcher "$pid"
        return 1
    fi
    local identity
    if ! identity="$(jq -er '.startIdentity' "$prefix-client-identity.json")"; then
        kill_and_reap_stopped_launcher "$pid"
        return 1
    fi
    local owner_pid
    owner_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || {
        kill_and_reap_stopped_launcher "$pid"
        return 1
    }
    local inflight="$ARTIFACT_ROOT/controllers/inflight-${pid}-${identity}.json"
    if ! jq -n --argjson pid "$pid" --arg identity "$identity" --arg expectedPath "$expected_path" \
        --argjson ownerPID "$owner_pid" '
        {
            pid: $pid,
            start_identity: $identity,
            expected_executable_path: $expectedPath,
            owner_pid: $ownerPID
        }
    ' > "$inflight.tmp" || \
       ! mv "$inflight.tmp" "$inflight"; then
        rm -f "$inflight.tmp"
        kill_and_reap_stopped_launcher "$pid"
        return 1
    fi
    PENDING_LAUNCHER_PID=""
    SPAWNED_RESUMED_AT="$(clock_value)"
    kill -CONT "$pid"
    if ! capture_process_executable_identity "$pid" "$prefix-client.json" "$expected_path"; then
        local process_state
        process_state="$(ps -o state= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "$process_state" != Z* && -n "$process_state" ]]; then
            return 1
        fi
        jq -n --argjson pid "$pid" --arg identity "$identity" --arg path "$expected_path" '
            {
                pid: $pid,
                startIdentity: $identity,
                path: $path,
                evidence: "exact exec argument; process exited before live path sampling"
            }
        ' > "$prefix-client.json"
    fi
    SPAWNED_PID="$pid"
    SPAWNED_IDENTITY="$identity"
    SPAWNED_PATH="$(jq -er '.path' "$prefix-client.json")"
    SPAWNED_INFLIGHT="$inflight"
}

spawn_controlled_cli() {
    local prefix="$1"
    shift
    spawn_controlled_process "$prefix" "$PEEKABOO_BIN" "$@"
}

monitor_watchdog() {
    local last_sequence last_progress now maximum_stall=0 samples=0
    last_sequence="$(jq -er '.sequence' "$ARTIFACT_ROOT/monitor-heartbeat.json")"
    last_progress=$SECONDS
    while [[ ! -f "$ARTIFACT_ROOT/monitor-watchdog.stop" ]]; do
        local sequence
        sequence="$(jq -r '.sequence // 0' "$ARTIFACT_ROOT/monitor-heartbeat.json" 2>/dev/null || printf '0')"
        now=$SECONDS
        if [[ "$sequence" =~ ^[0-9]+$ && "$sequence" -gt "$last_sequence" ]]; then
            local stall=$((now - last_progress))
            ((stall > maximum_stall)) && maximum_stall=$stall
            last_sequence="$sequence"
            last_progress=$now
            samples=$((samples + 1))
        elif ((now - last_progress >= 2)); then
            jq -n --argjson success false --argjson lastSequence "$last_sequence" \
                --argjson maximumStall "$((now - last_progress))" --argjson samples "$samples" \
                '{success: $success, last_sequence: $lastSequence, maximum_stall_seconds: $maximumStall, samples: $samples}' \
                > "$ARTIFACT_ROOT/monitor-watchdog.json"
            return 1
        fi
        sleep 0.05
    done
    now=$SECONDS
    local final_stall=$((now - last_progress))
    ((final_stall > maximum_stall)) && maximum_stall=$final_stall
    jq -n --argjson success true --argjson lastSequence "$last_sequence" \
        --argjson maximumStall "$maximum_stall" --argjson samples "$samples" \
        '{success: $success, last_sequence: $lastSequence, maximum_stall_seconds: $maximumStall, samples: $samples}' \
        > "$ARTIFACT_ROOT/monitor-watchdog.json"
}

run_client_lifecycle_self_test() {
    local saved_bin="$PEEKABOO_BIN"
    local saved_bridge_socket="$BRIDGE_SOCKET"
    local saved_probe_bin="$PROBE_BIN"
    local saved_timeout="$OPERATION_TIMEOUT_SECONDS"
    local timeout_exit=0 fast_exit=0 bounded_exit=0 mismatch_exit=0 direct_cleanup_exit=0
    local timeout_pid timeout_identity timeout_inflight timeout_started timeout_finished timeout_elapsed
    local timeout_deadline timeout_kill_at timeout_kill_overrun timeout_completion_overrun
    local settled_focus_preserved=false missing_focus_blocks=false null_focus_blocks=false
    local initial_budget overlap_budget workflow_budget restoration_budget max_restoration_budget
    local initial_deadline restoration_deadline
    local slow_phase_budget_accepted=false slow_restoration_budget_accepted=false
    local synchronization_wait_accepted=false synchronization_deadline_refused=false
    local late_marker_refused=false empty_checkpoint_waited_for_nonempty=false
    local synchronization_peer_exit_refused=false synchronization_peer_exit_elapsed=999
    jq -n '{pendingFocusedWindowChange: false}' \
        > "$ARTIFACT_ROOT/results/lifecycle-settled-heartbeat.json"
    if [[ "$(read_pending_focus_state \
        "$ARTIFACT_ROOT/results/lifecycle-settled-heartbeat.json")" == false ]]; then
        settled_focus_preserved=true
    fi
    jq -n '{}' > "$ARTIFACT_ROOT/results/lifecycle-missing-focus-heartbeat.json"
    if [[ "$(read_pending_focus_state \
        "$ARTIFACT_ROOT/results/lifecycle-missing-focus-heartbeat.json")" == true ]]; then
        missing_focus_blocks=true
    fi
    jq -n '{pendingFocusedWindowChange: null}' \
        > "$ARTIFACT_ROOT/results/lifecycle-null-focus-heartbeat.json"
    if [[ "$(read_pending_focus_state \
        "$ARTIFACT_ROOT/results/lifecycle-null-focus-heartbeat.json")" == true ]]; then
        null_focus_blocks=true
    fi
    PEEKABOO_BIN="$PROBE_BIN"
    OPERATION_TIMEOUT_SECONDS=1
    spawn_controlled_cli "$ARTIFACT_ROOT/results/lifecycle-timeout" "$PROBE_BIN" ignore-term
    timeout_pid="$SPAWNED_PID"
    timeout_identity="$SPAWNED_IDENTITY"
    timeout_inflight="$SPAWNED_INFLIGHT"
    timeout_started="$SPAWNED_RESUMED_AT"
    set +e
    wait_for_spawned_cli "$timeout_pid" "$timeout_identity" \
        "$ARTIFACT_ROOT/results/lifecycle-timeout" "$SPAWNED_RESUMED_AT"
    timeout_exit=$?
    set -e
    timeout_finished="$(clock_value)"
    timeout_elapsed="$(awk -v started="$timeout_started" -v finished="$timeout_finished" \
        'BEGIN { printf "%.6f", finished - started }')"
    timeout_deadline="$(jq -er '.deadline' "$ARTIFACT_ROOT/results/lifecycle-timeout-timeout.json")"
    timeout_kill_at="$(jq -er '.kill_at' "$ARTIFACT_ROOT/results/lifecycle-timeout-timeout.json")"
    timeout_kill_overrun="$(awk -v deadline="$timeout_deadline" -v killed="$timeout_kill_at" \
        'BEGIN { printf "%.6f", killed - deadline }')"
    timeout_completion_overrun="$(awk -v deadline="$timeout_deadline" -v finished="$timeout_finished" \
        'BEGIN { printf "%.6f", finished - deadline }')"
    rm -f "$timeout_inflight"

    OPERATION_TIMEOUT_SECONDS=30
    initial_budget="$(synchronization_budget_seconds "$INITIAL_READBACK_REMAINING_OPERATION_COUNT")"
    overlap_budget="$(synchronization_budget_seconds "$OVERLAP_WITNESS_REMAINING_OPERATION_COUNT")"
    workflow_budget="$(synchronization_budget_seconds "$WORKFLOW_REMAINING_OPERATION_COUNT")"
    restoration_budget="$(synchronization_budget_seconds "$RESTORATION_REMAINING_OPERATION_COUNT")"
    initial_deadline="$(synchronization_deadline "$INITIAL_READBACK_REMAINING_OPERATION_COUNT" 1000)"
    restoration_deadline="$(synchronization_deadline "$RESTORATION_REMAINING_OPERATION_COUNT" 1000)"
    if ! synchronization_deadline_reached "$initial_deadline" 1006; then
        slow_phase_budget_accepted=true
    fi
    if ! synchronization_deadline_reached "$restoration_deadline" 1101; then
        slow_restoration_budget_accepted=true
    fi
    OPERATION_TIMEOUT_SECONDS=300
    max_restoration_budget="$(synchronization_budget_seconds "$RESTORATION_REMAINING_OPERATION_COUNT")"

    OPERATION_TIMEOUT_SECONDS=1
    spawn_controlled_process "$ARTIFACT_ROOT/results/synchronization-peer" /bin/sleep /bin/sleep 5
    local synchronization_pid="$SPAWNED_PID"
    local synchronization_identity="$SPAWNED_IDENTITY"
    local synchronization_inflight="$SPAWNED_INFLIGHT"
    local synchronization_marker="$ARTIFACT_ROOT/results/synchronization-peer.ready"
    local synchronization_writer_pid synchronization_wait_exit=0
    (
        sleep 0.05
        : > "$synchronization_marker.tmp"
        mv "$synchronization_marker.tmp" "$synchronization_marker"
    ) &
    synchronization_writer_pid=$!
    local synchronization_wait_deadline
    synchronization_wait_deadline="$(synchronization_deadline 1)"
    set +e
    wait_for_synchronization_until "$synchronization_marker" \
        "$synchronization_pid" "$synchronization_identity" "$synchronization_wait_deadline"
    synchronization_wait_exit=$?
    set -e
    wait "$synchronization_writer_pid"
    [[ $synchronization_wait_exit -eq 0 ]] && synchronization_wait_accepted=true

    rm -f "$synchronization_marker"
    local expired_deadline synchronization_deadline_exit=0
    expired_deadline="$(awk -v now="$(clock_value)" 'BEGIN { printf "%.9f", now - 0.001 }')"
    set +e
    wait_for_synchronization_until "$synchronization_marker" \
        "$synchronization_pid" "$synchronization_identity" "$expired_deadline"
    synchronization_deadline_exit=$?
    set -e
    [[ $synchronization_deadline_exit -ne 0 ]] && synchronization_deadline_refused=true

    local late_marker="$ARTIFACT_ROOT/results/synchronization-late.ready"
    local late_marker_deadline late_marker_exit=0
    late_marker_deadline="$(awk -v now="$(clock_value)" 'BEGIN { printf "%.9f", now - 0.001 }')"
    : > "$late_marker"
    set +e
    wait_for_synchronization_until "$late_marker" \
        "$synchronization_pid" "$synchronization_identity" "$late_marker_deadline"
    late_marker_exit=$?
    set -e
    [[ $late_marker_exit -ne 0 ]] && late_marker_refused=true

    local checkpoint_marker="$ARTIFACT_ROOT/results/synchronization-checkpoint.json"
    local checkpoint_writer_pid checkpoint_wait_exit=0 checkpoint_started checkpoint_finished checkpoint_elapsed
    : > "$checkpoint_marker"
    (
        sleep 0.05
        printf '%s\n' '{"complete":true}' > "$checkpoint_marker.tmp"
        mv "$checkpoint_marker.tmp" "$checkpoint_marker"
    ) &
    checkpoint_writer_pid=$!
    checkpoint_started="$(clock_value)"
    synchronization_wait_deadline="$(synchronization_deadline 1 "$checkpoint_started")"
    set +e
    wait_for_synchronization_until "$checkpoint_marker" \
        "$synchronization_pid" "$synchronization_identity" "$synchronization_wait_deadline" nonempty
    checkpoint_wait_exit=$?
    set -e
    checkpoint_finished="$(clock_value)"
    wait "$checkpoint_writer_pid"
    checkpoint_elapsed="$(awk -v started="$checkpoint_started" -v finished="$checkpoint_finished" \
        'BEGIN { printf "%.6f", finished - started }')"
    if [[ $checkpoint_wait_exit -eq 0 && -s "$checkpoint_marker" ]] && \
       awk -v elapsed="$checkpoint_elapsed" 'BEGIN { exit !(elapsed >= 0.02) }'; then
        empty_checkpoint_waited_for_nonempty=true
    fi
    rm -f "$late_marker" "$checkpoint_marker"

    terminate_owned_generation_directly synchronization-self-test \
        "$synchronization_pid" "$synchronization_identity" forced_self_test
    rm -f "$synchronization_inflight"
    local peer_exit_started peer_exit_finished peer_exit_deadline peer_exit_result=0
    peer_exit_started="$(clock_value)"
    peer_exit_deadline="$(synchronization_deadline 1 "$peer_exit_started")"
    set +e
    wait_for_synchronization_until "$synchronization_marker" \
        "$synchronization_pid" "$synchronization_identity" "$peer_exit_deadline"
    peer_exit_result=$?
    set -e
    peer_exit_finished="$(clock_value)"
    synchronization_peer_exit_elapsed="$(awk -v started="$peer_exit_started" -v finished="$peer_exit_finished" \
        'BEGIN { printf "%.6f", finished - started }')"
    if [[ $peer_exit_result -ne 0 ]] && \
       awk -v elapsed="$synchronization_peer_exit_elapsed" 'BEGIN { exit !(elapsed < 0.5) }'; then
        synchronization_peer_exit_refused=true
    fi

    spawn_controlled_process "$ARTIFACT_ROOT/results/lifecycle-direct-cleanup" /bin/sleep /bin/sleep 60
    local direct_pid="$SPAWNED_PID"
    local direct_identity="$SPAWNED_IDENTITY"
    local direct_inflight="$SPAWNED_INFLIGHT"
    set +e
    terminate_owned_generation_directly lifecycle-self-test "$direct_pid" "$direct_identity" forced_self_test
    direct_cleanup_exit=$?
    set -e
    local direct_generation_gone=false
    owned_generation_gone "$direct_pid" "$direct_identity" && direct_generation_gone=true
    $direct_generation_gone && rm -f "$direct_inflight"

    spawn_controlled_process "$ARTIFACT_ROOT/results/lifecycle-unknown-cleanup" /bin/sleep /bin/sleep 60
    local unknown_pid="$SPAWNED_PID"
    local unknown_identity="$SPAWNED_IDENTITY"
    PROBE_BIN=/usr/bin/false
    local unknown_state=0
    process_generation_state "$unknown_pid" "$unknown_identity" || unknown_state=$?
    stop_inflight_operations
    PROBE_BIN="$saved_probe_bin"
    local unknown_cleanup_gone=false
    owned_generation_gone "$unknown_pid" "$unknown_identity" && unknown_cleanup_gone=true

    PEEKABOO_BIN=/usr/bin/true
    spawn_controlled_cli "$ARTIFACT_ROOT/results/lifecycle-fast" /usr/bin/true
    local fast_pid="$SPAWNED_PID"
    local fast_identity="$SPAWNED_IDENTITY"
    local fast_path="$SPAWNED_PATH"
    local fast_inflight="$SPAWNED_INFLIGHT"
    local fast_zombie_rejected=false fast_state
    for _ in $(seq 1 100); do
        fast_state="$(ps -o state= -p "$fast_pid" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -z "$fast_state" || "$fast_state" == Z* ]]; then
            local fast_generation_state=0
            process_generation_state "$fast_pid" "$fast_identity" || fast_generation_state=$?
            [[ $fast_generation_state -eq 1 ]] && fast_zombie_rejected=true
            break
        fi
        sleep 0.005
    done
    set +e
    wait_for_spawned_cli "$fast_pid" "$fast_identity" \
        "$ARTIFACT_ROOT/results/lifecycle-fast" "$SPAWNED_RESUMED_AT"
    fast_exit=$?
    set -e
    rm -f "$fast_inflight"

    BRIDGE_SOCKET=/tmp/peekaboo-lifecycle-self-test.sock
    set +e
    pb lifecycle-self-test >/dev/null
    bounded_exit=$?
    set -e

    set +e
    spawn_controlled_cli "$ARTIFACT_ROOT/results/lifecycle-mismatch" /bin/sleep 60
    mismatch_exit=$?
    set -e
    local mismatch_receipt mismatch_pid mismatch_identity
    mismatch_receipt="$(find "$ARTIFACT_ROOT/controllers" -maxdepth 1 -type f \
        -name 'inflight-*.json' -print -quit)"
    mismatch_pid="$(jq -er '.pid' "$mismatch_receipt")"
    mismatch_identity="$(jq -er '.start_identity' "$mismatch_receipt")"
    stop_inflight_operations
    local mismatch_gone=false
    owned_generation_gone "$mismatch_pid" "$mismatch_identity" && mismatch_gone=true

    PEEKABOO_BIN="$saved_bin"
    BRIDGE_SOCKET="$saved_bridge_socket"
    OPERATION_TIMEOUT_SECONDS="$saved_timeout"
    jq -n \
        --argjson timeoutExit "$timeout_exit" --argjson fastExit "$fast_exit" \
        --argjson timeoutElapsed "$timeout_elapsed" \
        --argjson timeoutKillOverrun "$timeout_kill_overrun" \
        --argjson timeoutCompletionOverrun "$timeout_completion_overrun" \
        --argjson directCleanupExit "$direct_cleanup_exit" \
        --argjson directGenerationGone "$direct_generation_gone" \
        --argjson unknownState "$unknown_state" --argjson unknownCleanupGone "$unknown_cleanup_gone" \
        --arg fastPath "$fast_path" --argjson boundedExit "$bounded_exit" \
        --argjson fastZombieRejected "$fast_zombie_rejected" \
        --argjson mismatchExit "$mismatch_exit" \
        --argjson mismatchGone "$mismatch_gone" \
        --argjson settledFocusPreserved "$settled_focus_preserved" \
        --argjson missingFocusBlocks "$missing_focus_blocks" \
        --argjson nullFocusBlocks "$null_focus_blocks" \
        --argjson initialBudget "$initial_budget" \
        --argjson overlapBudget "$overlap_budget" \
        --argjson workflowBudget "$workflow_budget" \
        --argjson restorationBudget "$restoration_budget" \
        --argjson maxRestorationBudget "$max_restoration_budget" \
        --argjson slowPhaseBudgetAccepted "$slow_phase_budget_accepted" \
        --argjson slowRestorationBudgetAccepted "$slow_restoration_budget_accepted" \
        --argjson synchronizationWaitAccepted "$synchronization_wait_accepted" \
        --argjson synchronizationDeadlineRefused "$synchronization_deadline_refused" \
        --argjson lateMarkerRefused "$late_marker_refused" \
        --argjson emptyCheckpointWaitedForNonempty "$empty_checkpoint_waited_for_nonempty" \
        --argjson synchronizationPeerExitRefused "$synchronization_peer_exit_refused" \
        --argjson synchronizationPeerExitElapsed "$synchronization_peer_exit_elapsed" \
        --argjson mutationCount "$MUTATION_BOUNDED_OPERATION_COUNT" \
        --argjson observationCount "$OBSERVATION_BOUNDED_OPERATION_COUNT" \
        --argjson overlapCount "$OVERLAP_WITNESS_REMAINING_OPERATION_COUNT" \
        --argjson workflowCount "$WORKFLOW_REMAINING_OPERATION_COUNT" \
        --argjson restorationCount "$RESTORATION_REMAINING_OPERATION_COUNT" '
        {
            success: (
                $timeoutExit == 124 and $timeoutElapsed >= 0.8 and
                $timeoutKillOverrun >= 0 and $timeoutCompletionOverrun >= 0 and
                $timeoutCompletionOverrun <= 0.5 and
                $directCleanupExit == 0 and $directGenerationGone and
                $unknownState == 2 and $unknownCleanupGone and
                $fastExit == 0 and $fastPath == "/usr/bin/true" and
                $fastZombieRejected and $boundedExit == 0 and
                $mismatchExit != 0 and $mismatchGone and
                $settledFocusPreserved and $missingFocusBlocks and $nullFocusBlocks and
                $mutationCount == 3 and $observationCount == 6 and $overlapCount == 8 and
                $workflowCount == 30 and $restorationCount == 15 and
                $initialBudget == 186 and $overlapBudget == 248 and
                $workflowBudget == 930 and $restorationBudget == 465 and
                $maxRestorationBudget == 4515 and
                $slowPhaseBudgetAccepted and $slowRestorationBudgetAccepted and
                $synchronizationWaitAccepted and $synchronizationDeadlineRefused and
                $lateMarkerRefused and $emptyCheckpointWaitedForNonempty and
                $synchronizationPeerExitRefused and $synchronizationPeerExitElapsed < 0.5
            ),
            timeout_exit: $timeoutExit,
            timeout_elapsed_seconds: $timeoutElapsed,
            timeout_kill_overrun_seconds: $timeoutKillOverrun,
            timeout_completion_overrun_seconds: $timeoutCompletionOverrun,
            direct_cleanup_exit: $directCleanupExit,
            direct_generation_gone: $directGenerationGone,
            unknown_state: $unknownState,
            unknown_cleanup_gone: $unknownCleanupGone,
            fast_exit: $fastExit,
            fast_path: $fastPath,
            fast_zombie_rejected: $fastZombieRejected,
            bounded_runner_exit: $boundedExit,
            mismatch_exit: $mismatchExit,
            mismatch_generation_gone: $mismatchGone,
            settled_focus_preserved: $settledFocusPreserved,
            missing_focus_blocks: $missingFocusBlocks,
            null_focus_blocks: $nullFocusBlocks,
            synchronization: {
                mutation_operation_count: $mutationCount,
                observation_operation_count: $observationCount,
                overlap_witness_remaining_operation_count: $overlapCount,
                workflow_remaining_operation_count: $workflowCount,
                restoration_remaining_operation_count: $restorationCount,
                initial_readback_budget_seconds: $initialBudget,
                overlap_witness_budget_seconds: $overlapBudget,
                workflow_budget_seconds: $workflowBudget,
                restoration_budget_seconds: $restorationBudget,
                maximum_timeout_restoration_budget_seconds: $maxRestorationBudget,
                slow_phase_budget_accepted: $slowPhaseBudgetAccepted,
                slow_restoration_budget_accepted: $slowRestorationBudgetAccepted,
                marker_wait_accepted: $synchronizationWaitAccepted,
                exceeded_deadline_refused: $synchronizationDeadlineRefused,
                late_marker_refused: $lateMarkerRefused,
                empty_checkpoint_waited_for_nonempty: $emptyCheckpointWaitedForNonempty,
                peer_exit_refused: $synchronizationPeerExitRefused,
                peer_exit_elapsed_seconds: $synchronizationPeerExitElapsed
            }
        }
    '
}

self_test_cleanup() {
    local pending_launcher_pid="$PENDING_LAUNCHER_PID"
    PENDING_LAUNCHER_PID=""
    if [[ "$pending_launcher_pid" =~ ^[1-9][0-9]*$ ]]; then
        kill -KILL "$pending_launcher_pid" >/dev/null 2>&1 || true
        wait "$pending_launcher_pid" >/dev/null 2>&1 || true
    fi
    stop_inflight_operations || true
}

if $SELF_TEST_ONLY; then
    trap self_test_cleanup EXIT
    node "$REPORTER" --self-test --catalog "$CATALOG" > "$ARTIFACT_ROOT/contract-self-test.json"
    run_launch_ownership_self_test > "$ARTIFACT_ROOT/launch-ownership-self-test.json"
    run_client_lifecycle_self_test > "$ARTIFACT_ROOT/client-lifecycle-self-test.json"
    jq -n \
        --slurpfile probe "$ARTIFACT_ROOT/probe-self-test.json" \
        --slurpfile contract "$ARTIFACT_ROOT/contract-self-test.json" \
        --slurpfile ownership "$ARTIFACT_ROOT/launch-ownership-self-test.json" \
        --slurpfile lifecycle "$ARTIFACT_ROOT/client-lifecycle-self-test.json" \
        '{
            success: (
                $probe[0].success and $contract[0].success and $ownership[0].success and
                $lifecycle[0].success
            ),
            probe: $probe[0],
            contract: $contract[0],
            launch_ownership: $ownership[0],
            client_lifecycle: $lifecycle[0]
        }' \
        > "$ARTIFACT_ROOT/summary.json"
    jq -e '.success == true' "$ARTIFACT_ROOT/summary.json" >/dev/null
    trap - EXIT INT TERM
    printf 'Dual-controller overlap self-test passed: %s\n' "$ARTIFACT_ROOT"
    exit 0
fi

live_overlap_receipt_verifier_available() {
    return 1
}
if ! live_overlap_receipt_verifier_available; then
    printf '%s\n' \
        'Live overlap is reserved until a first-party CLI verifies every exported protocol 1.29 receipt bundle.' >&2
    exit 2
fi

if [[ "${PEEKABOO_RUN_DUAL_CONTROLLER_OVERLAP:-}" != "1" ]]; then
    printf '%s\n' 'Live overlap requires PEEKABOO_RUN_DUAL_CONTROLLER_OVERLAP=1.' >&2
    exit 2
fi
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'Live overlap requires macOS.' >&2
    exit 2
fi
if [[ "$PEEKABOO_BIN" != /* || ! -x "$PEEKABOO_BIN" ]]; then
    printf '%s\n' '--bin must name an absolute executable.' >&2
    exit 2
fi
if [[ "$BRIDGE_SOCKET" != /* || ! -S "$BRIDGE_SOCKET" ]]; then
    printf '%s\n' '--bridge-socket must name one existing absolute Unix socket.' >&2
    exit 2
fi
if [[ "$TEXTEDIT_APP" != /* || ! -d "$TEXTEDIT_APP" ]]; then
    printf '%s\n' '--textedit-app must name an absolute app bundle.' >&2
    exit 2
fi
TEXTEDIT_APP="$(cd "$TEXTEDIT_APP" && pwd -P)"
TEXTEDIT_EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw -o - "$TEXTEDIT_APP/Contents/Info.plist")"
TEXTEDIT_EXECUTABLE="$TEXTEDIT_APP/Contents/MacOS/$TEXTEDIT_EXECUTABLE_NAME"
if [[ "$TEXTEDIT_EXECUTABLE_NAME" == */* || ! -x "$TEXTEDIT_EXECUTABLE" ]]; then
    printf '%s\n' '--textedit-app does not contain one valid main executable.' >&2
    exit 2
fi
if ! [[ "$SENTINEL_PID" =~ ^[1-9][0-9]*$ && "$SENTINEL_WINDOW_ID" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' '--sentinel-pid and --sentinel-window-id must be positive integers.' >&2
    exit 2
fi
for command_name in codesign git; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'Missing required command: %s\n' "$command_name" >&2
        exit 2
    }
done

source_status="$ARTIFACT_ROOT/source-status.txt"
git -C "$ROOT_DIR" status --porcelain --untracked-files=all > "$source_status"
if [[ -s "$source_status" ]]; then
    printf '%s\n' 'Live overlap requires one exact clean source tree.' >&2
    exit 2
fi
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || exit 2
SOURCE_INPUTS=(
    "$ROOT_DIR/scripts/dual-controller-overlap-catalog.json"
    "$ROOT_DIR/scripts/validate-dual-controller-overlap-report.mjs"
    "$ROOT_DIR/scripts/support/background-computer-use-probe.swift"
    "$ROOT_DIR/scripts/test-dual-controller-overlap.sh"
)
for source_input in "${SOURCE_INPUTS[@]}"; do
    tracked_input_matches_commit "$source_input" || {
        printf 'Certification input does not match %s: %s\n' "$SOURCE_COMMIT" "$source_input" >&2
        exit 2
    }
done

codesign --verify --strict "$PEEKABOO_BIN"
codesign --verify --strict "$TEXTEDIT_APP"
codesign -dv --verbose=4 "$PEEKABOO_BIN" > "$ARTIFACT_ROOT/cli-signature.txt" 2>&1
if ! rg -q '^TeamIdentifier=[A-Z0-9]+$' "$ARTIFACT_ROOT/cli-signature.txt" || \
   rg -q '^TeamIdentifier=not set$' "$ARTIFACT_ROOT/cli-signature.txt"; then
    printf '%s\n' 'Live overlap requires a team-signed CLI.' >&2
    exit 2
fi
CLI_CDHASH="$(sed -n 's/^CDHash=//p' "$ARTIFACT_ROOT/cli-signature.txt" | head -1)"
CLI_SHA256="$(shasum -a 256 "$PEEKABOO_BIN" | awk '{print $1}')"
[[ "$CLI_CDHASH" =~ ^[0-9a-f]{40}$ && "$CLI_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
    printf '%s\n' 'CLI signature does not expose a canonical code or file hash.' >&2
    exit 2
}
CERTIFIED_PEEKABOO_BIN="$ARTIFACT_ROOT/bin/peekaboo-certified"
cp -p "$PEEKABOO_BIN" "$CERTIFIED_PEEKABOO_BIN"
chmod 500 "$CERTIFIED_PEEKABOO_BIN"
codesign --verify --strict "$CERTIFIED_PEEKABOO_BIN"
[[ "$(shasum -a 256 "$CERTIFIED_PEEKABOO_BIN" | awk '{print $1}')" == "$CLI_SHA256" ]] || {
    printf '%s\n' 'Private CLI copy differs from the verified executable.' >&2
    exit 2
}
PEEKABOO_BIN="$CERTIFIED_PEEKABOO_BIN"
pb --version --json > "$ARTIFACT_ROOT/cli-version.json"
CLI_SOURCE_COMMIT="$(jq -er '.data.sourceCommit | select(test("^[0-9a-f]{40}$"))' \
    "$ARTIFACT_ROOT/cli-version.json")"
if [[ "$CLI_SOURCE_COMMIT" != "$SOURCE_COMMIT" ]]; then
    printf '%s\n' 'CLI source receipt does not match the clean checkout.' >&2
    exit 2
fi
SOURCE_CATALOG="$CATALOG"
SOURCE_REPORTER="$REPORTER"
SOURCE_PROBE_SOURCE="$PROBE_SOURCE"
CATALOG_SHA256_INITIAL="$(shasum -a 256 "$SOURCE_CATALOG" | awk '{print $1}')"
REPORTER_SHA256_INITIAL="$(shasum -a 256 "$SOURCE_REPORTER" | awk '{print $1}')"
PROBE_SOURCE_SHA256_INITIAL="$(shasum -a 256 "$SOURCE_PROBE_SOURCE" | awk '{print $1}')"
CATALOG="$ARTIFACT_ROOT/bin/dual-controller-overlap-catalog.json"
REPORTER="$ARTIFACT_ROOT/bin/validate-dual-controller-overlap-report.mjs"
CERTIFIED_PROBE_SOURCE="$ARTIFACT_ROOT/bin/background-computer-use-probe.swift"
cp -p "$SOURCE_CATALOG" "$CATALOG"
cp -p "$SOURCE_REPORTER" "$REPORTER"
cp -p "$SOURCE_PROBE_SOURCE" "$CERTIFIED_PROBE_SOURCE"
chmod 400 "$CATALOG" "$REPORTER" "$CERTIFIED_PROBE_SOURCE"
swiftc "$CERTIFIED_PROBE_SOURCE" -o "$PROBE_BIN" \
    -framework AppKit -framework ApplicationServices -framework CoreGraphics -framework CryptoKit
"$PROBE_BIN" self-test > "$ARTIFACT_ROOT/probe-live-self-test.json"

pb bridge status --verbose --json > "$ARTIFACT_ROOT/bridge-before.json"
jq -e --arg socket "$BRIDGE_SOCKET" --arg source "$SOURCE_COMMIT" '
    .success == true and .data.selected.source == "remote" and
    .data.selected.socketPath == $socket and
    .data.selected.handshake.hostIdentity.sourceCommit == $source and
    (.data.selected.handshake.hostIdentity.processIdentifier | type) == "number" and
    ((.data.selected.handshake.hostIdentity.processStartIdentityDecimal // "") | test("^[1-9][0-9]*$")) and
    ((.data.selected.handshake.hostIdentity.codeSignatureHash // "") | test("^[0-9a-f]{40}$"))
' "$ARTIFACT_ROOT/bridge-before.json" >/dev/null || {
    printf '%s\n' 'Bridge did not expose one signed current exact host generation.' >&2
    exit 2
}
HOST_PID="$(jq -er '.data.selected.handshake.hostIdentity.processIdentifier' \
    "$ARTIFACT_ROOT/bridge-before.json")"
HOST_IDENTITY="$(jq -er '.data.selected.handshake.hostIdentity.processStartIdentityDecimal' \
    "$ARTIFACT_ROOT/bridge-before.json")"
HOST_CDHASH="$(jq -er '.data.selected.handshake.hostIdentity.codeSignatureHash' \
    "$ARTIFACT_ROOT/bridge-before.json")"
HOST_PROTOCOL_MAJOR="$(jq -er '.data.selected.handshake.negotiatedVersion.major' \
    "$ARTIFACT_ROOT/bridge-before.json")"
HOST_PROTOCOL_MINOR="$(jq -er '.data.selected.handshake.negotiatedVersion.minor' \
    "$ARTIFACT_ROOT/bridge-before.json")"
"$PROBE_BIN" process-executable --pid "$HOST_PID" --output "$ARTIFACT_ROOT/host-executable-before.json"
HOST_SHA256="$(jq -er --arg identity "$HOST_IDENTITY" '
    select((.startIdentity | tostring) == $identity) | .sha256 | select(test("^[0-9a-f]{64}$"))
' "$ARTIFACT_ROOT/host-executable-before.json")"

capture_host_receipt() {
    local output="$1"
    pb bridge status --verbose --json > "$output"
    jq -e --argjson pid "$HOST_PID" --arg identity "$HOST_IDENTITY" \
        --arg source "$SOURCE_COMMIT" --arg cdhash "$HOST_CDHASH" --arg socket "$BRIDGE_SOCKET" '
        .data.selected.source == "remote" and .data.selected.socketPath == $socket and
        .data.selected.handshake.hostIdentity.processIdentifier == $pid and
        .data.selected.handshake.hostIdentity.processStartIdentityDecimal == $identity and
        .data.selected.handshake.hostIdentity.sourceCommit == $source and
        .data.selected.handshake.hostIdentity.codeSignatureHash == $cdhash
    ' "$output" >/dev/null
}

capture_observation_route() {
    local prefix="$1"
    local target_pid="$2"
    local target_window="$3"
    local command_pid command_exit command_identity command_path target_identity_after reported_target_pid inflight
    capture_host_receipt "$prefix-route-host-before.json"
    spawn_controlled_cli "$prefix-route" \
        "$PEEKABOO_BIN" window list --pid "$target_pid" --json --bridge-socket "$BRIDGE_SOCKET"
    command_pid="$SPAWNED_PID"
    command_identity="$SPAWNED_IDENTITY"
    command_path="$SPAWNED_PATH"
    inflight="$SPAWNED_INFLIGHT"
    set +e
    wait_for_spawned_cli "$command_pid" "$command_identity" "$prefix-route" "$SPAWNED_RESUMED_AT"
    command_exit=$?
    set -e
    rm -f "$inflight"
    [[ $command_exit -eq 0 ]]
    capture_host_receipt "$prefix-route-host-after.json"
    reported_target_pid="$(jq -er --argjson window "$target_window" '
        select(.success == true and any(.data.windows[]; .window_id == $window)) |
        .data.target_application_info.pid
    ' "$prefix-route.json")"
    "$PROBE_BIN" process-identity --pid "$target_pid" --output "$prefix-route-target-after.json"
    target_identity_after="$(jq -er '.startIdentity' "$prefix-route-target-after.json")"
    jq -n --argjson clientPID "$command_pid" --arg clientIdentity "$command_identity" \
        --arg clientPath "$command_path" --argjson hostPID "$HOST_PID" \
        --arg hostIdentity "$HOST_IDENTITY" --arg hostCDHash "$HOST_CDHASH" \
        --argjson reportedTargetPID "$reported_target_pid" --argjson reportedWindow "$target_window" \
        --arg targetIdentityAfter "$target_identity_after" '
        {
            client_pid: $clientPID,
            client_start_identity: $clientIdentity,
            client_executable_path: $clientPath,
            host_pid: $hostPID,
            host_start_identity: $hostIdentity,
            host_code_signature_hash: $hostCDHash,
            reported_target_pid: $reportedTargetPID,
            reported_window_id: $reportedWindow,
            target_start_identity_after: $targetIdentityAfter,
            result_success: true
        }
    ' > "$prefix-route-receipt.json"
}

SENTINEL_IDENTITY="$("$PROBE_BIN" process-identity --pid "$SENTINEL_PID" | \
    jq -er '.startIdentity | tostring')"
pb window focus --pid "$SENTINEL_PID" --window-id "$SENTINEL_WINDOW_ID" --verify --json \
    > "$ARTIFACT_ROOT/sentinel-focus.json"

launch_textedit() {
    local id="$1"
    local prefix="$ARTIFACT_ROOT/results/launch-${id}-process"
    local ownership_result="$ARTIFACT_ROOT/controllers/owned-target-${id}-direct.json"
    local window_result="$ARTIFACT_ROOT/results/launch-${id}-window.json"
    spawn_controlled_process "$prefix" "$TEXTEDIT_EXECUTABLE" \
        "$TEXTEDIT_EXECUTABLE" -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO
    local pid="$SPAWNED_PID"
    local identity="$SPAWNED_IDENTITY"
    local inflight="$SPAWNED_INFLIGHT"
    [[ "$SPAWNED_PATH" == "$TEXTEDIT_EXECUTABLE" ]] || return 1
    persist_owned_generation "$id" "$pid" "$identity" "$ownership_result"
    rm -f "$inflight"
    process_alive "$pid" "$identity" || return 1
    pb app launch "PID:$pid" --wait-for-window --json > "$window_result"
    LAUNCHED_WINDOW_ID="$(jq -er --argjson pid "$pid" --arg identity "$identity" '
        .data as $data |
        $data.process_start_identity_decimal as $returnedIdentity |
        select(.success == true and $data.pid == $pid and $returnedIdentity == $identity and
            $data.window_ready == true and $data.window_identity == "exact" and
            ($data.window_ids | type) == "array" and ($data.window_ids | length) == 1 and
            ($data.window_ids[0] | type) == "number" and $data.window_ids[0] > 0) |
        $data.window_ids[0]
    ' "$window_result")"
}

launch_textedit A
TARGET_A_WINDOW_ID="$LAUNCHED_WINDOW_ID"
launch_textedit B
TARGET_B_WINDOW_ID="$LAUNCHED_WINDOW_ID"
if [[ "$TARGET_A_PID" == "$TARGET_B_PID" || "$TARGET_A_WINDOW_ID" == "$TARGET_B_WINDOW_ID" ]]; then
    printf '%s\n' 'TextEdit launch receipts are not distinct.' >&2
    exit 1
fi

RUN_ID="overlap-$(uuidgen | tr '[:upper:]' '[:lower:]')"
TOKEN_A_INITIAL="${RUN_ID}-a-initial"
TOKEN_A_FIRST_APPEND="${RUN_ID}-a-first"
TOKEN_A_AFTER_FIRST="${TOKEN_A_INITIAL}${TOKEN_A_FIRST_APPEND}"
TOKEN_A_SECOND="${RUN_ID}-a-final"
TOKEN_A_FINAL="${TOKEN_A_AFTER_FIRST}"$'\n'"${TOKEN_A_SECOND}"
TOKEN_B_INITIAL="${RUN_ID}-b-initial"
TOKEN_B_FINAL="${TOKEN_B_INITIAL}${RUN_ID}-b-1${RUN_ID}-b-2${RUN_ID}-b-3${RUN_ID}-b-4"

pb type "$TOKEN_A_INITIAL" --pid "$TARGET_A_PID" --window-id "$TARGET_A_WINDOW_ID" --clear --json \
    > "$ARTIFACT_ROOT/results/setup-a.json"
pb type "$TOKEN_B_INITIAL" --pid "$TARGET_B_PID" --window-id "$TARGET_B_WINDOW_ID" --clear --json \
    > "$ARTIFACT_ROOT/results/setup-b.json"
pb window focus --pid "$SENTINEL_PID" --window-id "$SENTINEL_WINDOW_ID" --verify --json \
    > "$ARTIFACT_ROOT/sentinel-refocus.json"
"$PROBE_BIN" sample --no-clipboard-digest --output "$ARTIFACT_ROOT/baseline.json"
jq -e --argjson pid "$SENTINEL_PID" --argjson window "$SENTINEL_WINDOW_ID" '
    .frontmostPID == $pid and .frontmostWindowID == $window and .clipboardDigest == ""
' "$ARTIFACT_ROOT/baseline.json" >/dev/null || {
    printf '%s\n' 'Sentinel was not exact before monitoring.' >&2
    exit 1
}

INVARIANT_NAMES='["sentinel_frontmost_pid","sentinel_top_window","physical_cursor","no_peekaboo_global_input","clipboard_change_count","peekaboo_alpha_overlay"]'
printf '%s\n' running > "$ARTIFACT_ROOT/monitor-phase.txt"
jq -n --argjson pid "$HOST_PID" --arg identity "$HOST_IDENTITY" \
    '{revision: 1, producers: [{pid: $pid, startIdentity: $identity}]}' \
    > "$ARTIFACT_ROOT/allowed-producers.json"
"$PROBE_BIN" watch \
    --baseline "$ARTIFACT_ROOT/baseline.json" \
    --output "$ARTIFACT_ROOT/monitor-violations.jsonl" \
    --contamination-output "$ARTIFACT_ROOT/monitor-contamination.jsonl" \
    --ready "$ARTIFACT_ROOT/monitor.ready" \
    --heartbeat "$ARTIFACT_ROOT/monitor-heartbeat.json" \
    --phase "$ARTIFACT_ROOT/monitor-phase.txt" \
    --allowed-producers "$ARTIFACT_ROOT/allowed-producers.json" \
    --invariant-names "$INVARIANT_NAMES" \
    --cursor-observational \
    --physical-input-observational \
    --interval-ms 20 &
MONITOR_PID=$!
for _ in $(seq 1 200); do
    [[ -s "$ARTIFACT_ROOT/monitor.ready" && -s "$ARTIFACT_ROOT/monitor-heartbeat.json" ]] && break
    sleep 0.01
done
if [[ ! -s "$ARTIFACT_ROOT/monitor.ready" || ! -s "$ARTIFACT_ROOT/monitor-heartbeat.json" ]]; then
    printf '%s\n' 'Native invariant monitor did not become ready.' >&2
    exit 1
fi
(monitor_watchdog) &
WATCHDOG_PID=$!
record_mutation() {
    local controller="$1"
    local index="$2"
    local command_name="$3"
    local mutation_phase="$4"
    local target_pid="$5"
    local target_window="$6"
    shift 6
    local prefix="$ARTIFACT_ROOT/results/${controller}-mutation-${index}"
    local started finished command_exit=0 command_pid command_identity command_path target_identity_after inflight
    capture_host_receipt "$prefix-host-before.json"
    spawn_controlled_cli "$prefix" "$PEEKABOO_BIN" "$@" --json --bridge-socket "$BRIDGE_SOCKET"
    command_pid="$SPAWNED_PID"
    command_identity="$SPAWNED_IDENTITY"
    command_path="$SPAWNED_PATH"
    inflight="$SPAWNED_INFLIGHT"
    started="$(clock_value)"
    jq -n --arg controller "$controller" --argjson index "$index" \
        --arg phase "$mutation_phase" --argjson pid "$command_pid" --arg identity "$command_identity" \
        '{controller: $controller, index: $index, phase: $phase, pid: $pid, start_identity: $identity}' \
        > "$ARTIFACT_ROOT/controllers/${controller}-active.tmp"
    mv "$ARTIFACT_ROOT/controllers/${controller}-active.tmp" \
        "$ARTIFACT_ROOT/controllers/${controller}-active.json"
    set +e
    wait_for_spawned_cli "$command_pid" "$command_identity" "$prefix" "$SPAWNED_RESUMED_AT"
    command_exit=$?
    set -e
    finished="$(clock_value)"
    rm -f "$inflight"
    capture_host_receipt "$prefix-host-after.json"
    "$PROBE_BIN" process-identity --pid "$target_pid" --output "$prefix-target-after.json"
    target_identity_after="$(jq -er '.startIdentity | tostring' "$prefix-target-after.json")"
    jq -n \
        --argjson index "$index" --arg command "$command_name" --arg phase "$mutation_phase" \
        --argjson started "$started" --argjson finished "$finished" \
        --argjson targetPID "$target_pid" --argjson targetWindow "$target_window" \
        --argjson clientPID "$command_pid" --arg clientIdentity "$command_identity" \
        --arg clientPath "$command_path" --argjson hostPID "$HOST_PID" \
        --arg hostIdentity "$HOST_IDENTITY" --arg hostCDHash "$HOST_CDHASH" \
        --arg targetIdentityAfter "$target_identity_after" \
        --argjson commandExit "$command_exit" --slurpfile result "$prefix.json" '
        ($result[0] // {}) as $result |
        {
            index: $index,
            command: $command,
            phase: $phase,
            started_at: $started,
            finished_at: $finished,
            target_pid: $targetPID,
            target_window_id: $targetWindow,
            client_pid: $clientPID,
            client_start_identity: $clientIdentity,
            client_executable_path: $clientPath,
            host_pid: $hostPID,
            host_start_identity: $hostIdentity,
            host_code_signature_hash: $hostCDHash,
            reported_target_pid: ($result.data.targetPID // $result.data.target_pid // null),
            reported_target_window_id: ($result.data.targetWindowID // $result.data.target_window_id // null),
            target_start_identity_after: $targetIdentityAfter,
            delivery_mode: ($result.data.deliveryMode // $result.data.delivery_mode // null),
            success: ($commandExit == 0 and $result.success == true),
            effect: ($result.outcome.effect // $result.effect // null),
            mutation_dispatched: (
                if (($result.outcome | type) == "object" and ($result.outcome | has("mutation_dispatched")))
                then $result.outcome.mutation_dispatched
                elif (($result.error | type) == "object" and ($result.error | has("mutation_dispatched")))
                then $result.error.mutation_dispatched else null end
            ),
            retry_safe: (
                if (($result.outcome | type) == "object" and ($result.outcome | has("retry_safe")))
                then $result.outcome.retry_safe
                elif (($result.error | type) == "object" and ($result.error | has("retry_safe")))
                then $result.error.retry_safe else null end
            ),
            foreground: false
        }
    ' >> "$ARTIFACT_ROOT/controllers/${controller}-mutations.jsonl"
    [[ $command_exit -eq 0 ]]
}

capture_observation_receipt() {
    local prefix="$1"
    local receipt="$2"
    local index="$3"
    local target_pid="$4"
    local target_window="$5"
    local expected_token="$6"
    local started finished command_pid command_exit command_identity command_path target_identity_after inflight
    capture_host_receipt "$prefix-host-before.json"
    spawn_controlled_cli "$prefix" \
        "$PEEKABOO_BIN" see --tree --no-screenshot --pid "$target_pid" --window-id "$target_window" \
        --json --bridge-socket "$BRIDGE_SOCKET"
    command_pid="$SPAWNED_PID"
    command_identity="$SPAWNED_IDENTITY"
    command_path="$SPAWNED_PATH"
    inflight="$SPAWNED_INFLIGHT"
    started="$(clock_value)"
    set +e
    wait_for_spawned_cli "$command_pid" "$command_identity" "$prefix" "$SPAWNED_RESUMED_AT"
    command_exit=$?
    set -e
    rm -f "$inflight"
    capture_host_receipt "$prefix-host-after.json"
    [[ $command_exit -eq 0 ]]
    "$PROBE_BIN" process-identity --pid "$target_pid" --output "$prefix-target-after.json"
    target_identity_after="$(jq -er '.startIdentity' "$prefix-target-after.json")"
    capture_observation_route "$prefix" "$target_pid" "$target_window"
    finished="$(clock_value)"
    jq -n \
        --argjson index "$index" --argjson started "$started" --argjson finished "$finished" \
        --argjson targetPID "$target_pid" --argjson targetWindow "$target_window" \
        --argjson clientPID "$command_pid" --arg clientIdentity "$command_identity" \
        --arg clientPath "$command_path" --argjson hostPID "$HOST_PID" \
        --arg hostIdentity "$HOST_IDENTITY" --arg hostCDHash "$HOST_CDHASH" \
        --arg targetIdentityAfter "$target_identity_after" \
        --arg expected "$expected_token" --arg runID "$RUN_ID" \
        --slurpfile result "$prefix.json" --slurpfile route "$prefix-route-receipt.json" '
        [$result[0].data.ui_elements[]? | .value? | select(type == "string")] as $values |
        ($values | any(. == $expected)) as $present |
        ($values | all((contains($runID) | not) or . == $expected)) as $otherAbsent |
        {
            index: $index,
            started_at: $started,
            finished_at: $finished,
            target_pid: $targetPID,
            target_window_id: $targetWindow,
            client_pid: $clientPID,
            client_start_identity: $clientIdentity,
            client_executable_path: $clientPath,
            host_pid: $hostPID,
            host_start_identity: $hostIdentity,
            host_code_signature_hash: $hostCDHash,
            result_success: ($result[0].success == true),
            reported_window_id: ($result[0].data.observation.target.window_id // null),
            target_start_identity_after: $targetIdentityAfter,
            route_receipt: $route[0],
            expected_token: $expected,
            token_present: $present,
            other_token_absent: $otherAbsent
        }
    ' > "$receipt"
    jq -e --arg expected "$expected_token" --arg runID "$RUN_ID" '
        select(.success == true) |
        [.data.ui_elements[]? | .value? | select(type == "string")] as $values |
        ($values | any(. == $expected)) and
        ($values | all((contains($runID) | not) or . == $expected))
    ' "$prefix.json" >/dev/null
}

record_observation() {
    local controller="$1"
    local index="$2"
    local target_pid="$3"
    local target_window="$4"
    local expected_token="$5"
    local prefix="$ARTIFACT_ROOT/results/${controller}-observation-${index}"
    local receipt="$prefix-receipt.json"
    capture_observation_receipt \
        "$prefix" "$receipt" "$index" "$target_pid" "$target_window" "$expected_token"
    cat "$receipt" >> "$ARTIFACT_ROOT/controllers/${controller}-observations.jsonl"
}

record_restoration_checkpoint() {
    local controller="$1"
    local expected_a="$2"
    local expected_b="$3"
    local prefix_a="$ARTIFACT_ROOT/results/restoration-${controller}-target-A"
    local prefix_b="$ARTIFACT_ROOT/results/restoration-${controller}-target-B"
    local receipt_a="$prefix_a-receipt.json"
    local receipt_b="$prefix_b-receipt.json"
    local checkpoint="$ARTIFACT_ROOT/controllers/${controller}-restoration-checkpoint.json"
    capture_observation_receipt \
        "$prefix_a" "$receipt_a" 1 "$TARGET_A_PID" "$TARGET_A_WINDOW_ID" "$expected_a"
    capture_observation_receipt \
        "$prefix_b" "$receipt_b" 2 "$TARGET_B_PID" "$TARGET_B_WINDOW_ID" "$expected_b"
    jq -n --arg controller "$controller" \
        --slurpfile observationA "$receipt_a" --slurpfile observationB "$receipt_b" '
        {
            after_controller: $controller,
            observations: [$observationA[0], $observationB[0]]
        }
    ' > "$checkpoint.tmp"
    mv "$checkpoint.tmp" "$checkpoint"
}

first_mutation_barrier() {
    local controller="$1"
    local peer_controller=A
    [[ "$controller" == A ]] && peer_controller=B
    : > "$ARTIFACT_ROOT/controllers/${controller}-first-mutation.ready"
    wait_for_controller_marker \
        "$ARTIFACT_ROOT/controllers/${peer_controller}-first-mutation.ready" \
        "$peer_controller" "$INITIAL_READBACK_REMAINING_OPERATION_COUNT"
}

phase_barrier() {
    local phase="$1"
    local controller="$2"
    local peer_controller=A maximum_remaining_operations
    [[ "$controller" == A ]] && peer_controller=B
    case "$phase" in
        workflow-complete)
            maximum_remaining_operations="$WORKFLOW_REMAINING_OPERATION_COUNT"
            ;;
        workflow-readback-complete)
            maximum_remaining_operations="$FINAL_READBACK_REMAINING_OPERATION_COUNT"
            ;;
        restoration-complete)
            maximum_remaining_operations="$RESTORATION_REMAINING_OPERATION_COUNT"
            ;;
        *) return 1 ;;
    esac
    : > "$ARTIFACT_ROOT/controllers/${controller}-${phase}.ready"
    wait_for_controller_marker \
        "$ARTIFACT_ROOT/controllers/${peer_controller}-${phase}.ready" \
        "$peer_controller" "$maximum_remaining_operations"
}

wait_for_restoration_checkpoint() {
    local controller="$1"
    local checkpoint="$ARTIFACT_ROOT/controllers/${controller}-restoration-checkpoint.json"
    wait_for_controller_marker \
        "$checkpoint" "$controller" "$RESTORATION_REMAINING_OPERATION_COUNT" nonempty
}

overlap_witness() {
    local a_marker="$ARTIFACT_ROOT/controllers/A-active.json"
    local b_marker="$ARTIFACT_ROOT/controllers/B-active.json"
    local a_snapshot="$ARTIFACT_ROOT/controllers/witness-A-active.json"
    local b_snapshot="$ARTIFACT_ROOT/controllers/witness-B-active.json"
    local a_controller_pid a_controller_identity b_controller_pid b_controller_identity deadline
    a_controller_pid="$(jq -er '.pid' "$ARTIFACT_ROOT/controllers/A-client.json")"
    a_controller_identity="$(jq -er '.startIdentity' "$ARTIFACT_ROOT/controllers/A-client.json")"
    b_controller_pid="$(jq -er '.pid' "$ARTIFACT_ROOT/controllers/B-client.json")"
    b_controller_identity="$(jq -er '.startIdentity' "$ARTIFACT_ROOT/controllers/B-client.json")"
    deadline="$(synchronization_deadline "$OVERLAP_WITNESS_REMAINING_OPERATION_COUNT")"
    while true; do
        synchronization_deadline_reached "$deadline" && return 1
        process_alive "$a_controller_pid" "$a_controller_identity" || return 1
        process_alive "$b_controller_pid" "$b_controller_identity" || return 1
        if [[ -s "$a_marker" && -s "$b_marker" ]]; then
            local a_pid a_identity b_pid b_identity
            local a_checked_before_at b_checked_at a_checked_after_at
            cp "$a_marker" "$a_snapshot.tmp" || continue
            cp "$b_marker" "$b_snapshot.tmp" || continue
            mv "$a_snapshot.tmp" "$a_snapshot"
            mv "$b_snapshot.tmp" "$b_snapshot"
            if ! jq -e '
                keys == ["controller", "index", "phase", "pid", "start_identity"] and
                .controller == "A" and (.index | type) == "number" and .index > 0 and
                .phase == "workflow" and (.pid | type) == "number" and .pid > 0 and
                ((.start_identity // "") | test("^[1-9][0-9]*$"))
            ' "$a_snapshot" >/dev/null || \
               ! jq -e '
                keys == ["controller", "index", "phase", "pid", "start_identity"] and
                .controller == "B" and (.index | type) == "number" and .index > 0 and
                .phase == "workflow" and (.pid | type) == "number" and .pid > 0 and
                ((.start_identity // "") | test("^[1-9][0-9]*$"))
            ' "$b_snapshot" >/dev/null; then
                sleep 0.01
                continue
            fi
            a_pid="$(jq -er '.pid' "$a_snapshot")"
            a_identity="$(jq -er '.start_identity' "$a_snapshot")"
            b_pid="$(jq -er '.pid' "$b_snapshot")"
            b_identity="$(jq -er '.start_identity' "$b_snapshot")"
            if process_alive "$a_pid" "$a_identity"; then
                a_checked_before_at="$(clock_value)"
                if ! process_alive "$b_pid" "$b_identity"; then
                    sleep 0.01
                    continue
                fi
                b_checked_at="$(clock_value)"
                if ! process_alive "$a_pid" "$a_identity"; then
                    sleep 0.01
                    continue
                fi
                a_checked_after_at="$(clock_value)"
                if ! cmp -s "$a_snapshot" "$a_marker" || ! cmp -s "$b_snapshot" "$b_marker"; then
                    sleep 0.01
                    continue
                fi
                synchronization_deadline_reached "$deadline" && return 1
                jq -n --argjson aPID "$a_pid" --arg aIdentity "$a_identity" \
                    --argjson bPID "$b_pid" --arg bIdentity "$b_identity" \
                    --argjson aCheckedBeforeAt "$a_checked_before_at" \
                    --argjson bCheckedAt "$b_checked_at" \
                    --argjson aCheckedAfterAt "$a_checked_after_at" \
                    --slurpfile aMarker "$a_snapshot" --slurpfile bMarker "$b_snapshot" '
                    {
                        a_pid: $aPID, a_start_identity: $aIdentity,
                        b_pid: $bPID, b_start_identity: $bIdentity,
                        a_checked_before_at: $aCheckedBeforeAt,
                        b_checked_at: $bCheckedAt,
                        a_checked_after_at: $aCheckedAfterAt,
                        observed_at: $bCheckedAt,
                        a_active_marker: $aMarker[0],
                        b_active_marker: $bMarker[0],
                        markers_unchanged: true
                    }
                ' > "$ARTIFACT_ROOT/controllers/simultaneous-liveness.json"
                return 0
            fi
        fi
        sleep 0.01
    done
}

controller_a() {
    while [[ ! -f "$ARTIFACT_ROOT/controllers/start.barrier" ]]; do sleep 0.01; done
    local started finished
    started="$(clock_value)"
    record_observation A 1 "$TARGET_A_PID" "$TARGET_A_WINDOW_ID" "$TOKEN_A_INITIAL"
    first_mutation_barrier A
    record_mutation A 1 type workflow "$TARGET_A_PID" "$TARGET_A_WINDOW_ID" \
        type "$TOKEN_A_FIRST_APPEND" --pid "$TARGET_A_PID" --window-id "$TARGET_A_WINDOW_ID" --delay 15ms
    record_observation A 2 "$TARGET_A_PID" "$TARGET_A_WINDOW_ID" "$TOKEN_A_AFTER_FIRST"
    sleep 0.05
    record_mutation A 2 press workflow "$TARGET_A_PID" "$TARGET_A_WINDOW_ID" \
        press Return --pid "$TARGET_A_PID" --window-id "$TARGET_A_WINDOW_ID"
    record_mutation A 3 type workflow "$TARGET_A_PID" "$TARGET_A_WINDOW_ID" \
        type "$TOKEN_A_SECOND" --pid "$TARGET_A_PID" --window-id "$TARGET_A_WINDOW_ID"
    phase_barrier workflow-complete A
    record_observation A 3 "$TARGET_A_PID" "$TARGET_A_WINDOW_ID" "$TOKEN_A_FINAL"
    phase_barrier workflow-readback-complete A
    record_mutation A 4 type restoration "$TARGET_A_PID" "$TARGET_A_WINDOW_ID" \
        type "$TOKEN_A_INITIAL" --pid "$TARGET_A_PID" --window-id "$TARGET_A_WINDOW_ID" --clear
    record_restoration_checkpoint A "$TOKEN_A_INITIAL" "$TOKEN_B_FINAL"
    phase_barrier restoration-complete A
    record_observation A 4 "$TARGET_A_PID" "$TARGET_A_WINDOW_ID" "$TOKEN_A_INITIAL"
    finished="$(clock_value)"
    jq -s '.' "$ARTIFACT_ROOT/controllers/A-mutations.jsonl" > "$ARTIFACT_ROOT/controllers/A-mutations.json"
    jq -s '.' "$ARTIFACT_ROOT/controllers/A-observations.jsonl" > "$ARTIFACT_ROOT/controllers/A-observations.json"
    jq -n --argjson started "$started" --argjson finished "$finished" \
        --arg initial "$TOKEN_A_INITIAL" --arg final "$TOKEN_A_FINAL" \
        '{started_at: $started, finished_at: $finished, initial_token: $initial, final_token: $final}' \
        > "$ARTIFACT_ROOT/controllers/A-meta.json"
}

controller_b() {
    while [[ ! -f "$ARTIFACT_ROOT/controllers/start.barrier" ]]; do sleep 0.01; done
    local started finished token state
    started="$(clock_value)"
    state="$TOKEN_B_INITIAL"
    record_observation B 1 "$TARGET_B_PID" "$TARGET_B_WINDOW_ID" "$state"
    first_mutation_barrier B
    for index in 1 2 3 4; do
        token="${RUN_ID}-b-${index}"
        if [[ $index -eq 1 ]]; then
            record_mutation B "$index" type workflow "$TARGET_B_PID" "$TARGET_B_WINDOW_ID" \
                type "$token" --pid "$TARGET_B_PID" --window-id "$TARGET_B_WINDOW_ID" --delay 15ms
        else
            record_mutation B "$index" type workflow "$TARGET_B_PID" "$TARGET_B_WINDOW_ID" \
                type "$token" --pid "$TARGET_B_PID" --window-id "$TARGET_B_WINDOW_ID"
        fi
        state="${state}${token}"
        if [[ $index -lt 4 ]]; then
            record_observation B "$((index + 1))" "$TARGET_B_PID" "$TARGET_B_WINDOW_ID" "$state"
        fi
        sleep 0.08
    done
    phase_barrier workflow-complete B
    record_observation B 5 "$TARGET_B_PID" "$TARGET_B_WINDOW_ID" "$state"
    phase_barrier workflow-readback-complete B
    wait_for_restoration_checkpoint A
    record_mutation B 5 type restoration "$TARGET_B_PID" "$TARGET_B_WINDOW_ID" \
        type "$TOKEN_B_INITIAL" --pid "$TARGET_B_PID" --window-id "$TARGET_B_WINDOW_ID" --clear
    record_restoration_checkpoint B "$TOKEN_A_INITIAL" "$TOKEN_B_INITIAL"
    phase_barrier restoration-complete B
    record_observation B 6 "$TARGET_B_PID" "$TARGET_B_WINDOW_ID" "$TOKEN_B_INITIAL"
    finished="$(clock_value)"
    jq -s '.' "$ARTIFACT_ROOT/controllers/B-mutations.jsonl" > "$ARTIFACT_ROOT/controllers/B-mutations.json"
    jq -s '.' "$ARTIFACT_ROOT/controllers/B-observations.jsonl" > "$ARTIFACT_ROOT/controllers/B-observations.json"
    jq -n --argjson started "$started" --argjson finished "$finished" \
        --arg initial "$TOKEN_B_INITIAL" --arg final "$TOKEN_B_FINAL" \
        '{started_at: $started, finished_at: $finished, initial_token: $initial, final_token: $final}' \
        > "$ARTIFACT_ROOT/controllers/B-meta.json"
}

(controller_a) &
CLIENT_A_PID=$!
CLIENT_A_RECEIPT_PID="$CLIENT_A_PID"
"$PROBE_BIN" process-identity --pid "$CLIENT_A_PID" --output "$ARTIFACT_ROOT/controllers/A-client.json"
CLIENT_A_IDENTITY="$(jq -er '.startIdentity | tostring' "$ARTIFACT_ROOT/controllers/A-client.json")"
(controller_b) &
CLIENT_B_PID=$!
CLIENT_B_RECEIPT_PID="$CLIENT_B_PID"
"$PROBE_BIN" process-identity --pid "$CLIENT_B_PID" --output "$ARTIFACT_ROOT/controllers/B-client.json"
CLIENT_B_IDENTITY="$(jq -er '.startIdentity | tostring' "$ARTIFACT_ROOT/controllers/B-client.json")"
(overlap_witness) &
OVERLAP_WITNESS_PID=$!
: > "$ARTIFACT_ROOT/controllers/start.barrier"

set +e
wait "$CLIENT_A_PID"; CLIENT_A_EXIT=$?
CLIENT_A_PID=""
wait "$CLIENT_B_PID"; CLIENT_B_EXIT=$?
CLIENT_B_PID=""
wait "$OVERLAP_WITNESS_PID"; OVERLAP_WITNESS_EXIT=$?
OVERLAP_WITNESS_PID=""
set -e
if [[ $CLIENT_A_EXIT -ne 0 || $CLIENT_B_EXIT -ne 0 || $OVERLAP_WITNESS_EXIT -ne 0 ]]; then
    printf 'Overlap clients failed: A=%s B=%s witness=%s\n' \
        "$CLIENT_A_EXIT" "$CLIENT_B_EXIT" "$OVERLAP_WITNESS_EXIT" >&2
    exit 1
fi

PRE_CLEANUP_SEQUENCE="$(jq -er '.sequence' "$ARTIFACT_ROOT/monitor-heartbeat.json")"
quit_owned_target A "$TARGET_A_PID" "$TARGET_A_IDENTITY"
quit_owned_target B "$TARGET_B_PID" "$TARGET_B_IDENTITY"
A_GONE=true
B_GONE=true
CLEANUP_COMPLETE=true
finish_monitoring "$PRE_CLEANUP_SEQUENCE" "$ARTIFACT_ROOT/final-sample.json"

pb bridge status --verbose --json > "$ARTIFACT_ROOT/bridge-after.json"
"$PROBE_BIN" process-executable --pid "$HOST_PID" --output "$ARTIFACT_ROOT/host-executable-after.json"
HOST_STABLE=false
if jq -e --argjson pid "$HOST_PID" --arg identity "$HOST_IDENTITY" --arg source "$SOURCE_COMMIT" \
    --arg cdhash "$HOST_CDHASH" --arg socket "$BRIDGE_SOCKET" '
    .data.selected.source == "remote" and .data.selected.socketPath == $socket and
    .data.selected.handshake.hostIdentity.processIdentifier == $pid and
    .data.selected.handshake.hostIdentity.processStartIdentityDecimal == $identity and
    .data.selected.handshake.hostIdentity.sourceCommit == $source and
    .data.selected.handshake.hostIdentity.codeSignatureHash == $cdhash
' "$ARTIFACT_ROOT/bridge-after.json" >/dev/null && \
   jq -e --arg identity "$HOST_IDENTITY" --arg sha "$HOST_SHA256" '
    (.startIdentity | tostring) == $identity and .sha256 == $sha
' "$ARTIFACT_ROOT/host-executable-after.json" >/dev/null; then
    HOST_STABLE=true
fi

MONITOR_CLEAN=false
if [[ ! -s "$ARTIFACT_ROOT/monitor-violations.jsonl" && \
      ! -s "$ARTIFACT_ROOT/monitor-contamination.jsonl" ]] && \
   jq -e '.success == true and .samples > 0 and .maximum_stall_seconds < 2' \
      "$ARTIFACT_ROOT/monitor-watchdog.json" >/dev/null && \
   jq -e --argjson sequence "$PRE_CLEANUP_SEQUENCE" --slurpfile final "$ARTIFACT_ROOT/final-sample.json" '
      .inputAttributionAvailable == true and .contaminationBlocked == false and
      .allowedProducerRevision == 1 and .sequence > $sequence and .timestamp >= $final[0].timestamp and
      .pendingActivationCount == 0 and .pendingFocusedWindowChange == false
   ' \
      "$ARTIFACT_ROOT/monitor-heartbeat.json" >/dev/null; then
    MONITOR_CLEAN=true
fi
git -C "$ROOT_DIR" status --porcelain --untracked-files=all > "$ARTIFACT_ROOT/source-status-final.txt"
for source_input in "${SOURCE_INPUTS[@]}"; do
    tracked_input_matches_commit "$source_input" || {
        printf 'Certification input changed from %s: %s\n' "$SOURCE_COMMIT" "$source_input" >&2
        exit 1
    }
done
if [[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" != "$SOURCE_COMMIT" || \
      -s "$ARTIFACT_ROOT/source-status-final.txt" || \
      "$(shasum -a 256 "$SOURCE_CATALOG" | awk '{print $1}')" != "$CATALOG_SHA256_INITIAL" || \
      "$(shasum -a 256 "$SOURCE_REPORTER" | awk '{print $1}')" != "$REPORTER_SHA256_INITIAL" || \
      "$(shasum -a 256 "$SOURCE_PROBE_SOURCE" | awk '{print $1}')" != "$PROBE_SOURCE_SHA256_INITIAL" ]]; then
    printf '%s\n' 'Source head or certification contract changed during the live run.' >&2
    exit 1
fi
CATALOG_SHA256="$CATALOG_SHA256_INITIAL"

jq -n \
    --arg id A --argjson clientPID "$CLIENT_A_RECEIPT_PID" \
    --arg clientIdentity "$CLIENT_A_IDENTITY" \
    --argjson targetPID "$TARGET_A_PID" --arg targetIdentity "$TARGET_A_IDENTITY" \
    --argjson targetWindow "$TARGET_A_WINDOW_ID" \
    --slurpfile meta "$ARTIFACT_ROOT/controllers/A-meta.json" \
    --slurpfile mutations "$ARTIFACT_ROOT/controllers/A-mutations.json" \
    --slurpfile observations "$ARTIFACT_ROOT/controllers/A-observations.json" '
    {
        id: $id,
        controller_process: {pid: $clientPID, start_identity: $clientIdentity},
        target: {pid: $targetPID, start_identity: $targetIdentity, window_id: $targetWindow},
        started_at: $meta[0].started_at,
        finished_at: $meta[0].finished_at,
        mutations: $mutations[0],
        observations: $observations[0],
        initial_token: $meta[0].initial_token,
        final_token: $meta[0].final_token,
        readback_token: $meta[0].final_token,
        restored_token: $meta[0].initial_token,
        restoration_readback: $meta[0].initial_token,
        cross_target_clear: (all($observations[0][]; .other_token_absent == true))
    }
' > "$ARTIFACT_ROOT/controllers/A-report.json"

jq -n \
    --arg id B --argjson clientPID "$CLIENT_B_RECEIPT_PID" \
    --arg clientIdentity "$CLIENT_B_IDENTITY" \
    --argjson targetPID "$TARGET_B_PID" --arg targetIdentity "$TARGET_B_IDENTITY" \
    --argjson targetWindow "$TARGET_B_WINDOW_ID" \
    --slurpfile meta "$ARTIFACT_ROOT/controllers/B-meta.json" \
    --slurpfile mutations "$ARTIFACT_ROOT/controllers/B-mutations.json" \
    --slurpfile observations "$ARTIFACT_ROOT/controllers/B-observations.json" '
    {
        id: $id,
        controller_process: {pid: $clientPID, start_identity: $clientIdentity},
        target: {pid: $targetPID, start_identity: $targetIdentity, window_id: $targetWindow},
        started_at: $meta[0].started_at,
        finished_at: $meta[0].finished_at,
        mutations: $mutations[0],
        observations: $observations[0],
        initial_token: $meta[0].initial_token,
        final_token: $meta[0].final_token,
        readback_token: $meta[0].final_token,
        restored_token: $meta[0].initial_token,
        restoration_readback: $meta[0].initial_token,
        cross_target_clear: (all($observations[0][]; .other_token_absent == true))
    }
' > "$ARTIFACT_ROOT/controllers/B-report.json"

jq -s '.' \
    "$ARTIFACT_ROOT/controllers/A-restoration-checkpoint.json" \
    "$ARTIFACT_ROOT/controllers/B-restoration-checkpoint.json" \
    > "$ARTIFACT_ROOT/restoration-checkpoints.json"

jq -n \
    --argjson a "$(cat "$ARTIFACT_ROOT/controllers/A-report.json")" \
    --argjson b "$(cat "$ARTIFACT_ROOT/controllers/B-report.json")" \
    --slurpfile witness "$ARTIFACT_ROOT/controllers/simultaneous-liveness.json" '
    [
        ($a.mutations[] | select(.phase == "workflow")) as $am |
        ($b.mutations[] | select(.phase == "workflow")) as $bm |
        ([$am.started_at, $bm.started_at] | max) as $pairStart |
        ([$am.finished_at, $bm.finished_at] | min) as $pairFinish |
        select($pairFinish > $pairStart) |
        {
            a_index: $am.index,
            b_index: $bm.index,
            a_client_pid: $am.client_pid,
            a_client_start_identity: $am.client_start_identity,
            b_client_pid: $bm.client_pid,
            b_client_start_identity: $bm.client_start_identity,
            started_at: $pairStart,
            finished_at: $pairFinish,
            seconds: ($pairFinish - $pairStart)
        }
    ] as $pairs |
    ($pairs | map(.started_at) | min) as $start |
    ($pairs | map(.finished_at) | max) as $finish |
    {
        started_at: $start,
        finished_at: $finish,
        seconds: ($pairs | map(.seconds) | add // 0),
        a_mutations_during_b: ([$pairs[].a_index] | unique | length),
        b_mutations_during_a: ([$pairs[].b_index] | unique | length),
        concurrent_mutation_pairs: $pairs,
        simultaneous_liveness_witness: $witness[0]
    }
' > "$ARTIFACT_ROOT/overlap.json"

jq -n \
    --argjson version 1 --arg catalogSHA "$CATALOG_SHA256" --arg runID "$RUN_ID" \
    --arg source "$SOURCE_COMMIT" --arg cliCDHash "$CLI_CDHASH" --arg cliSHA "$CLI_SHA256" \
    --arg cliPath "$PEEKABOO_BIN" \
    --argjson hostPID "$HOST_PID" --arg hostIdentity "$HOST_IDENTITY" \
    --arg socket "$BRIDGE_SOCKET" --arg cdhash "$HOST_CDHASH" --arg hostSHA "$HOST_SHA256" \
    --argjson protocolMajor "$HOST_PROTOCOL_MAJOR" --argjson protocolMinor "$HOST_PROTOCOL_MINOR" \
    --argjson hostStable "$HOST_STABLE" \
    --argjson sentinelPID "$SENTINEL_PID" --arg sentinelIdentity "$SENTINEL_IDENTITY" \
    --argjson sentinelWindow "$SENTINEL_WINDOW_ID" \
    --slurpfile baseline "$ARTIFACT_ROOT/baseline.json" --slurpfile final "$ARTIFACT_ROOT/final-sample.json" \
    --slurpfile heartbeat "$ARTIFACT_ROOT/monitor-heartbeat.json" \
    --slurpfile a "$ARTIFACT_ROOT/controllers/A-report.json" \
    --slurpfile b "$ARTIFACT_ROOT/controllers/B-report.json" \
    --slurpfile overlap "$ARTIFACT_ROOT/overlap.json" \
    --slurpfile restorationCheckpoints "$ARTIFACT_ROOT/restoration-checkpoints.json" \
    --argjson monitorClean "$MONITOR_CLEAN" --argjson aGone "$A_GONE" --argjson bGone "$B_GONE" '
    {
        version: $version,
        catalog_sha256: $catalogSHA,
        run_id: $runID,
        source_commit: $source,
        cli: {
            source_commit: $source,
            code_signature_hash: $cliCDHash,
            executable_sha256: $cliSHA,
            executable_path: $cliPath
        },
        host: {
            pid: $hostPID, start_identity: $hostIdentity, socket_path: $socket,
            source_commit: $source, code_signature_hash: $cdhash,
            protocol_major: $protocolMajor, protocol_minor: $protocolMinor,
            executable_sha256: $hostSHA, stable: $hostStable
        },
        sentinel: {
            pid: $sentinelPID, start_identity: $sentinelIdentity, window_id: $sentinelWindow,
            initial_frontmost_pid: $baseline[0].frontmostPID,
            initial_top_window_id: $baseline[0].frontmostWindowID,
            final_frontmost_pid: $final[0].frontmostPID,
            final_top_window_id: $final[0].frontmostWindowID
        },
        controllers: [$a[0], $b[0]],
        overlap: $overlap[0],
        invariants: [
            {name: "signed_host_generation", passed: $hostStable, evidence: "bridge-before.json+bridge-after.json"},
            {name: "sentinel_frontmost_pid", passed: ($monitorClean and $final[0].frontmostPID == $sentinelPID), evidence: "monitor-violations.jsonl+final-sample.json"},
            {name: "sentinel_top_window", passed: ($monitorClean and $final[0].frontmostWindowID == $sentinelWindow), evidence: "monitor-violations.jsonl+final-sample.json"},
            {name: "no_cross_target_dispatch", passed: (
                $a[0].cross_target_clear and $b[0].cross_target_clear and
                all($restorationCheckpoints[0][]?.observations[]?;
                    .token_present == true and .other_token_absent == true)
            ), evidence: "controllers/*-observations.json+restoration-checkpoints.json"},
            {name: "no_peekaboo_global_input", passed: $monitorClean, evidence: "monitor-violations.jsonl"},
            {name: "clipboard_change_count", passed: ($baseline[0].clipboardChangeCount == $final[0].clipboardChangeCount), evidence: "baseline.json+final-sample.json"},
            {name: "peekaboo_alpha_overlay", passed: $monitorClean, evidence: "monitor-violations.jsonl"},
            {name: "monitor_liveness", passed: $monitorClean, evidence: "monitor-heartbeat.json"}
        ],
        cursor_observation: {
            policy: "observational",
            start_x: $baseline[0].cursor.x, start_y: $baseline[0].cursor.y,
            end_x: $final[0].cursor.x, end_y: $final[0].cursor.y,
            moved: ($heartbeat[0].cursorMovementObserved == true)
        },
        restoration: {
            controller_a: ($a[0].restoration_readback == $a[0].initial_token),
            controller_b: ($b[0].restoration_readback == $b[0].initial_token),
            sentinel: ($final[0].frontmostPID == $sentinelPID and $final[0].frontmostWindowID == $sentinelWindow)
        },
        restoration_checkpoints: $restorationCheckpoints[0],
        cleanup: [
            {id: "A", pid: $a[0].target.pid, start_identity: $a[0].target.start_identity, gone: $aGone},
            {id: "B", pid: $b[0].target.pid, start_identity: $b[0].target.start_identity, gone: $bGone}
        ],
        evidence: {
            exact_target_receipts: true,
            independent_readback: true,
            overlapping_intervals: ($overlap[0].seconds > 0),
            restoration: true,
            generation_pinned_cleanup: ($aGone and $bGone)
        }
    }
' > "$ARTIFACT_ROOT/observed.json"

node "$REPORTER" --catalog "$CATALOG" --report "$ARTIFACT_ROOT/observed.json" \
    --output "$ARTIFACT_ROOT/certification.json"
jq -n \
    --slurpfile certification "$ARTIFACT_ROOT/certification.json" \
    --slurpfile overlap "$ARTIFACT_ROOT/overlap.json" \
    '{success: $certification[0].success, overlap: $overlap[0], certification: $certification[0]}' \
    > "$ARTIFACT_ROOT/summary.json"
printf 'Dual-controller overlap certification passed: %s\n' "$ARTIFACT_ROOT"
