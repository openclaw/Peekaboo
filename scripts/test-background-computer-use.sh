#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAYGROUND_BUNDLE_ID="boo.peekaboo.playground.debug"
SENTINEL_BUNDLE_ID="com.apple.calculator"
PEEKABOO_BIN="${PEEKABOO_BIN:-}"
ARTIFACT_ROOT=""
PLAYGROUND_APP=""
SKIP_PLAYGROUND_BUILD=false
RUN_FOREGROUND_PHASE=false
SELF_TEST_ONLY=false
NO_REMOTE=false

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
  --sentinel-bundle-id ID   Controlled foreground sentinel (default: Calculator)
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

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This harness requires macOS." >&2
    exit 2
fi

for command_name in jq rg swiftc xcodebuild codesign security; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 2
    fi
done

if [[ -z "$ARTIFACT_ROOT" ]]; then
    ARTIFACT_ROOT="$ROOT_DIR/.artifacts/background-computer-use/$(date -u +%Y%m%dT%H%M%SZ)"
elif [[ "$ARTIFACT_ROOT" != /* ]]; then
    ARTIFACT_ROOT="$ROOT_DIR/$ARTIFACT_ROOT"
fi
mkdir -p "$ARTIFACT_ROOT" "$ARTIFACT_ROOT/cases" "$ARTIFACT_ROOT/bin"

PROBE_BIN="$ARTIFACT_ROOT/bin/background-computer-use-probe"
swiftc "$ROOT_DIR/scripts/support/background-computer-use-probe.swift" \
    -o "$PROBE_BIN" \
    -framework AppKit \
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
    jq -e '
        .success == true and
        .effect == "confirmed" and
        .data.action == "maximize" and
        .data.new_bounds.width > 0 and
        .data.new_bounds.height > 0
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

if $SELF_TEST_ONLY; then
    "$PROBE_BIN" process-identity --pid "$$" \
        --output "$ARTIFACT_ROOT/probe-process-identity.json"
    jq -e --argjson pid "$$" \
        '.pid == $pid and (.startIdentity | type) == "number" and .startIdentity > 0' \
        "$ARTIFACT_ROOT/probe-process-identity.json" >/dev/null
    same_process_generation 7 7
    if same_process_generation 7 8 || same_process_generation "" 7; then
        echo "Process-generation cleanup guard self-test failed." >&2
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
    VALID_SCROLL_RESULT="$ARTIFACT_ROOT/valid-scroll-result.json"
    STALE_SCROLL_RESULT="$ARTIFACT_ROOT/stale-scroll-result.json"
    printf '%s\n' \
        '{"success":true,"effect":"confirmed","data":{"action":"maximize","new_bounds":{"width":800,"height":600}}}' \
        > "$VALID_MAXIMIZE_RESULT"
    printf '%s\n' \
        '{"success":true,"data":{"success":true,"new_bounds":{"width":800,"height":600}}}' \
        > "$STALE_MAXIMIZE_RESULT"
    printf '%s\n' \
        '{"success":true,"effect":"confirmed","data":{"targetPoint":{"source":"element"},"totalTicks":1}}' \
        > "$VALID_SCROLL_RESULT"
    printf '%s\n' \
        '{"success":false,"effect":"refused","data":null}' > "$STALE_SCROLL_RESULT"
    if ! verified_maximize_result "$VALID_MAXIMIZE_RESULT" || \
       verified_maximize_result "$STALE_MAXIMIZE_RESULT" || \
       ! confirmed_element_scroll_result "$VALID_SCROLL_RESULT" || \
       confirmed_element_scroll_result "$STALE_SCROLL_RESULT"; then
        echo "Current maximize/scroll result contract self-test failed." >&2
        exit 1
    fi
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
        "$PEEKABOO_BIN" "$@"
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
pb permissions status --json > "$ARTIFACT_ROOT/permissions.json"
if ! jq -e '
    .success == true and
    ([.data.permissions[] | select(.isRequired == true and .isGranted != true)] | length == 0)
' "$ARTIFACT_ROOT/permissions.json" >/dev/null; then
    echo "Peekaboo is missing a required macOS permission; see $ARTIFACT_ROOT/permissions.json" >&2
    exit 2
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

ORIGINAL_FRONTMOST_PID="$("$PROBE_BIN" sample | jq -r '.frontmostPID // empty')"
CLIPBOARD_SLOT="background-computer-use-$$"
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
    pb clipboard restore --slot "$CLIPBOARD_SLOT" --json >/dev/null 2>&1 || true
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
    if [[ -n "$ORIGINAL_FRONTMOST_PID" ]] && kill -0 "$ORIGINAL_FRONTMOST_PID" 2>/dev/null; then
        pb app switch --to "PID:$ORIGINAL_FRONTMOST_PID" --json >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

pb clipboard save --slot "$CLIPBOARD_SLOT" --json > "$ARTIFACT_ROOT/clipboard-save.json"

if "$PROBE_BIN" find-app --bundle-id "$PLAYGROUND_BUNDLE_ID" >/dev/null 2>&1; then
    pb app quit --app "$PLAYGROUND_BUNDLE_ID" --json \
        > "$ARTIFACT_ROOT/playground-quit-existing.json" || true
fi

pb app launch "$PLAYGROUND_APP" --wait-ready --json \
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

pb app launch --bundle-id "$SENTINEL_BUNDLE_ID" --wait-ready --foreground --json \
    > "$ARTIFACT_ROOT/sentinel-launch.json"
sleep 0.2
"$PROBE_BIN" sample --output "$ARTIFACT_ROOT/sentinel.json"
SENTINEL_PID="$(jq -r '.frontmostPID // empty' "$ARTIFACT_ROOT/sentinel.json")"
SENTINEL_WINDOW_ID="$(jq -r '.frontmostWindowID // empty' "$ARTIFACT_ROOT/sentinel.json")"
if [[ -z "$SENTINEL_PID" || -z "$SENTINEL_WINDOW_ID" ]] || \
   [[ "$(jq -r '.frontmostBundleIdentifier' "$ARTIFACT_ROOT/sentinel.json")" != "$SENTINEL_BUNDLE_ID" ]]; then
    echo "Calculator did not become a stable foreground sentinel." >&2
    exit 1
fi

FAILURES=0
LAST_RESULT=""

record_failure() {
    echo "FAIL: $1" >&2
    FAILURES=$((FAILURES + 1))
}

run_case() {
    local name="$1"
    local clipboard_policy="$2"
    local expected_exit="$3"
    shift 3

    local case_dir="$ARTIFACT_ROOT/cases/$name"
    mkdir -p "$case_dir"
    local before="$case_dir/before.json"
    local after="$case_dir/after.json"
    local monitor="$case_dir/monitor.jsonl"
    local ready="$case_dir/monitor.ready"
    local result="$case_dir/result.json"
    local stderr_file="$case_dir/stderr.txt"
    local exit_file="$case_dir/exit-code.txt"

    "$PROBE_BIN" sample --output "$before"
    if [[ "$(jq -r '.frontmostPID // empty' "$before")" != "$SENTINEL_PID" || \
          "$(jq -r '.frontmostWindowID // empty' "$before")" != "$SENTINEL_WINDOW_ID" ]]; then
        pb app switch --to "PID:$SENTINEL_PID" --verify --json > "$case_dir/restore-sentinel.json"
        sleep 0.1
        "$PROBE_BIN" sample --output "$before"
    fi
    if [[ "$(jq -r '.frontmostPID // empty' "$before")" != "$SENTINEL_PID" || \
          "$(jq -r '.frontmostWindowID // empty' "$before")" != "$SENTINEL_WINDOW_ID" ]]; then
        record_failure "$name could not establish the foreground sentinel"
        return 1
    fi
    local monitor_args=(watch --baseline "$before" --output "$monitor" --ready "$ready" --interval-ms 10)
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
        kill "$MONITOR_PID" >/dev/null 2>&1 || true
        wait "$MONITOR_PID" 2>/dev/null || true
        MONITOR_PID=""
        record_failure "$name invariant monitor did not start"
        return 1
    fi

    set +e
    pb "$@" --json > "$result" 2> "$stderr_file"
    local command_exit=$?
    set -e
    printf '%s\n' "$command_exit" > "$exit_file"

    sleep 0.15
    "$PROBE_BIN" sample --output "$after"
    kill "$MONITOR_PID" >/dev/null 2>&1 || true
    wait "$MONITOR_PID" 2>/dev/null || true
    MONITOR_PID=""
    LAST_RESULT="$result"

    local failed=false
    if [[ "$expected_exit" == "success" ]]; then
        if [[ $command_exit -ne 0 ]] || ! jq -e '(.success // true) == true' "$result" >/dev/null 2>&1; then
            record_failure "$name command failed (exit $command_exit)"
            failed=true
        fi
    elif [[ "$expected_exit" == "failure" && $command_exit -eq 0 ]]; then
        record_failure "$name was expected to fail but exited zero"
        failed=true
    fi

    if [[ -s "$monitor" ]]; then
        record_failure "$name leaked focus, cursor, clipboard, or a Peekaboo overlay"
        failed=true
    fi

    if ! jq -e --slurpfile after "$after" '
        .frontmostPID == $after[0].frontmostPID and
        .frontmostWindowID == $after[0].frontmostWindowID and
        ((.cursor.x - $after[0].cursor.x) | fabs) <= 0.5 and
        ((.cursor.y - $after[0].cursor.y) | fabs) <= 0.5 and
        .clipboardDigest == $after[0].clipboardDigest and
        ((.peekabooWindowIDs - $after[0].peekabooWindowIDs) | length) == 0 and
        (($after[0].peekabooWindowIDs - .peekabooWindowIDs) | length) == 0
    ' "$before" >/dev/null; then
        record_failure "$name did not restore the stable desktop state"
        failed=true
    fi
    if [[ "$clipboard_policy" == "unchanged" ]] && \
       ! jq -e --slurpfile after "$after" '.clipboardChangeCount == $after[0].clipboardChangeCount' \
            "$before" >/dev/null; then
        record_failure "$name changed the clipboard"
        failed=true
    fi

    jq -n \
        --arg name "$name" \
        --arg expectation "$expected_exit" \
        --argjson exitCode "$command_exit" \
        --argjson invariantViolations "$(wc -l < "$monitor" | tr -d ' ')" \
        '{name: $name, expectation: $expectation, exit_code: $exitCode, invariant_violations: $invariantViolations}' \
        > "$case_dir/summary.json"

    [[ "$failed" == false ]]
}

run_checked_case() {
    if ! run_case "$@"; then
        return 1
    fi
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
    local name="$1"
    local result_file="$2"
    local expected="$3"
    if ! jq -e --arg expected "$expected" '[.. | strings] | any(contains($expected))' \
        "$result_file" >/dev/null; then
        record_failure "$name did not expose expected app-owned state"
        return 1
    fi
}

assert_background_delivery() {
    local name="$1"
    local result_file="$2"
    if ! jq -e '.data.deliveryMode == "background"' "$result_file" >/dev/null; then
        record_failure "$name did not report background delivery"
        return 1
    fi
}

read_lifecycle_launch_receipt() {
    local name="$1"
    local result_file="$2"
    if [[ -z "$result_file" || ! -s "$result_file" ]]; then
        record_failure "$name did not produce a launch receipt"
        LIFECYCLE_PID=""
        LIFECYCLE_WINDOW_ID=""
        LIFECYCLE_PROCESS_START_IDENTITY=""
        return 1
    fi
    if ! read_launch_process_receipt "$result_file"; then
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
        record_failure "$name did not return a refreshed exact window receipt"
        LIFECYCLE_PID=""
        LIFECYCLE_WINDOW_ID=""
        LIFECYCLE_PROCESS_START_IDENTITY=""
        return 1
    fi
    LIFECYCLE_PIDS+=("$LIFECYCLE_PID")
    LIFECYCLE_PROCESS_START_IDENTITIES+=("$LIFECYCLE_PROCESS_START_IDENTITY")
}

LIFECYCLE_PID=""
LIFECYCLE_WINDOW_ID=""
LIFECYCLE_PROCESS_START_IDENTITY=""
run_checked_case lifecycle-launch-maximize-close unchanged success \
    app launch TextEdit --new-instance --wait-for-window || true
if read_lifecycle_launch_receipt lifecycle-launch-maximize-close "$LAST_RESULT"; then
    MAXIMIZE_TEXTEDIT_WINDOW_ID="$LIFECYCLE_WINDOW_ID"
    run_checked_case lifecycle-maximize unchanged success \
        window maximize --window-id "$MAXIMIZE_TEXTEDIT_WINDOW_ID" || true
    if ! verified_maximize_result "$LAST_RESULT"; then
        record_failure "lifecycle-maximize did not return verified settled bounds"
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
    if jq -e '.success == true' "$LAST_RESULT" >/dev/null && kill -0 "$QUIT_TEXTEDIT_PID" 2>/dev/null; then
        record_failure "lifecycle-quit reported success while PID $QUIT_TEXTEDIT_PID remained alive"
    fi
fi

open_fixture() {
    local key="$1"
    local title="$2"
    local slug="$3"
    run_checked_case "press-open-$slug" unchanged success \
        press "cmd+ctrl+$key" --pid "$PLAYGROUND_PID" || true
    assert_background_delivery "press-open-$slug" "$LAST_RESULT" || true
    run_checked_case "list-window-$slug" unchanged success \
        window list --pid "$PLAYGROUND_PID" || true
    OPENED_WINDOW_ID="$(window_id_from_result "$LAST_RESULT" "$title")"
    if [[ -z "$OPENED_WINDOW_ID" ]]; then
        record_failure "$slug fixture did not open in the background"
    fi
}

OPENED_WINDOW_ID=""
open_fixture 2 "Text Fixture" text
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
if [[ -z "$TEXT_SNAPSHOT" || -z "$BASIC_FIELD_ID" || -z "$FOCUS_BUTTON_ID" ]]; then
    record_failure "text fixture snapshot was missing deterministic identifiers"
    echo "Cannot continue safely without an exact text snapshot." >&2
    exit 1
fi

run_checked_case inspect-text unchanged success \
    see --tree --no-screenshot --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --max-elements 300 || true
assert_result_contains inspect-text "$LAST_RESULT" "Basic Text Field" || true

run_checked_case screenshot-text unchanged success \
    see --no-elements --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/text-screenshot.png" || true

run_checked_case capture-text unchanged success \
    capture live --pid "$PLAYGROUND_PID" --window-title "Text Fixture" --mode window \
    --duration 1s --idle-fps 2 --active-fps 2 --path "$ARTIFACT_ROOT/text-capture" || true

run_checked_case focus-basic-field unchanged success \
    click --on "$FOCUS_BUTTON_ID" --snapshot "$TEXT_SNAPSHOT" \
    --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" || true
assert_background_delivery focus-basic-field "$LAST_RESULT" || true

run_checked_case stale-snapshot unchanged failure \
    click --on "$FOCUS_BUTTON_ID" --snapshot "missing-snapshot-$$" \
    --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" || true

RUN_TOKEN="background-$RANDOM-$$"
TYPE_TOKEN="type-$RUN_TOKEN"
PASTE_TOKEN="paste-$RUN_TOKEN"
SET_TOKEN="set-$RUN_TOKEN"

run_checked_case type-window-selector-rejected unchanged failure \
    type "must-not-route-$RUN_TOKEN" --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" || true
assert_result_contains type-window-selector-rejected "$LAST_RESULT" "cannot safely target a specific window" || true

run_checked_case type-text unchanged success \
    type "$TYPE_TOKEN" --pid "$PLAYGROUND_PID" || true
assert_background_delivery type-text "$LAST_RESULT" || true
run_checked_case press-return unchanged success \
    press return --pid "$PLAYGROUND_PID" || true
assert_background_delivery press-return "$LAST_RESULT" || true
run_checked_case paste-text allow-temporary success \
    paste "$PASTE_TOKEN" --pid "$PLAYGROUND_PID" || true
assert_background_delivery paste-text "$LAST_RESULT" || true

run_checked_case see-text-after-paste unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/text-after-paste.png" || true
assert_result_contains see-text-after-paste "$LAST_RESULT" "$PASTE_TOKEN" || true
TEXT_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
BASIC_FIELD_ID="$(element_id_from_result "$LAST_RESULT" basic-text-field)"

run_checked_case set-value unchanged success \
    set-value "$SET_TOKEN" --on "$BASIC_FIELD_ID" --snapshot "$TEXT_SNAPSHOT" || true
run_checked_case see-text-after-set-value unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/text-after-set-value.png" || true
assert_result_contains see-text-after-set-value "$LAST_RESULT" "$SET_TOKEN" || true

open_fixture 1 "Click Fixture" click
CLICK_WINDOW_ID="$OPENED_WINDOW_ID"
open_fixture 4 "Scroll Fixture" scroll
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
if [[ -z "$CLICK_SNAPSHOT" || -z "$SINGLE_CLICK_ID" ]]; then
    record_failure "click fixture snapshot was missing deterministic identifiers"
    echo "Cannot continue safely without an exact click snapshot." >&2
    exit 1
fi

run_checked_case click-id unchanged success \
    click --on "$SINGLE_CLICK_ID" --snapshot "$CLICK_SNAPSHOT" \
    --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" || true
assert_background_delivery click-id "$LAST_RESULT" || true
run_checked_case see-click-after-id unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/click-after-id.png" || true
assert_result_contains click-id-state "$LAST_RESULT" "1 total clicks" || true
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

run_checked_case action unchanged success \
    action AXPress --on "$SINGLE_CLICK_ID" --snapshot "$CLICK_SNAPSHOT" || true
run_checked_case see-click-after-action unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/click-after-action.png" || true
assert_result_contains action-state "$LAST_RESULT" "2 total clicks" || true

CLICK_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
SINGLE_CLICK_ID="$(element_id_from_result "$LAST_RESULT" single-click-button)"
run_checked_case unsupported-action unchanged failure \
    action AXDefinitelyUnsupported --on "$SINGLE_CLICK_ID" --snapshot "$CLICK_SNAPSHOT" || true

run_checked_case see-scroll unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$SCROLL_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/scroll-see.png" || true
SCROLL_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
VERTICAL_SCROLL_ID="$(element_id_from_result "$LAST_RESULT" vertical-scroll)"
if [[ -z "$SCROLL_SNAPSHOT" || -z "$VERTICAL_SCROLL_ID" ]]; then
    record_failure "scroll fixture snapshot was missing the vertical scroll target"
else
    run_checked_case scroll-action-background unchanged success \
        scroll --direction down --amount 1 --delay 0ms --on "$VERTICAL_SCROLL_ID" \
        --snapshot "$SCROLL_SNAPSHOT" --pid "$PLAYGROUND_PID" --window-id "$SCROLL_WINDOW_ID" || true
    if ! confirmed_element_scroll_result "$LAST_RESULT"; then
        record_failure "scroll-action-background did not confirm exact element scrolling"
    fi
fi

sleep 0.3
"$ROOT_DIR/Apps/Playground/scripts/playground-log.sh" --last 10m --all \
    --output "$ARTIFACT_ROOT/playground.log" >/dev/null
for expected_log in "$TYPE_TOKEN" "$PASTE_TOKEN" "$SET_TOKEN" "Single click on 'Single Click' button"; do
    if ! rg -Fq "$expected_log" "$ARTIFACT_ROOT/playground.log"; then
        record_failure "Playground log did not contain controlled state evidence: $expected_log"
    fi
done

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

    # Relaunching the controlled fixture resets any visual/scroll state from this explicit phase.
    pb app relaunch --pid "$PLAYGROUND_PID" --wait-until-ready --json \
        > "$FOREGROUND_DIR/reset-playground.json"
    if ! read_launch_process_receipt "$FOREGROUND_DIR/reset-playground.json" || \
       ! refresh_playground_process_receipt \
           "$LAUNCH_RECEIPT_PID" "$LAUNCH_RECEIPT_PROCESS_START_IDENTITY"; then
        echo "Playground relaunch did not return a process-generation receipt." >&2
        exit 1
    fi
    if ! kill -0 "$PLAYGROUND_PID" 2>/dev/null; then
        echo "Playground relaunch receipt names a process that is no longer running." >&2
        exit 1
    fi
    pb app switch --to "PID:$SENTINEL_PID" --verify --json \
        > "$FOREGROUND_DIR/restore-sentinel.json"
fi

CASE_COUNT="$(find "$ARTIFACT_ROOT/cases" -name summary.json -type f | wc -l | tr -d ' ')"
jq -n \
    --arg peekaboo "$(head -n 1 "$ARTIFACT_ROOT/peekaboo-version.txt")" \
    --arg playgroundBundle "$PLAYGROUND_BUNDLE_ID" \
    --argjson playgroundPID "$PLAYGROUND_PID" \
    --argjson sentinelPID "$SENTINEL_PID" \
    --argjson sentinelWindowID "$SENTINEL_WINDOW_ID" \
    --argjson cases "$CASE_COUNT" \
    --argjson failures "$FAILURES" \
    --argjson foregroundPhase "$RUN_FOREGROUND_PHASE" \
    '{
        success: ($failures == 0),
        peekaboo: $peekaboo,
        playground: {bundle_id: $playgroundBundle, pid: $playgroundPID},
        sentinel: {pid: $sentinelPID, window_id: $sentinelWindowID},
        cases: $cases,
        failures: $failures,
        foreground_phase: $foregroundPhase
    }' > "$ARTIFACT_ROOT/summary.json"

if [[ $FAILURES -ne 0 ]]; then
    echo "$FAILURES background computer-use checks failed; see $ARTIFACT_ROOT" >&2
    exit 1
fi

echo "Background computer-use validation passed ($CASE_COUNT cases): $ARTIFACT_ROOT"
