#!/bin/bash

set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CERTIFICATION_CATALOG="$ROOT_DIR/scripts/background-computer-use-catalog.json"
CERTIFICATION_REPORTER="$ROOT_DIR/scripts/validate-background-computer-use-report.mjs"
CERTIFICATION_TEST="$ROOT_DIR/tests/background-computer-use-report.test.mjs"
PLAYGROUND_BUNDLE_ID="boo.peekaboo.playground.debug"
TEXTEDIT_BUNDLE_ID="com.apple.TextEdit"
TEXTEDIT_APP="/System/Applications/TextEdit.app"
SENTINEL_BUNDLE_ID=""
PEEKABOO_BIN="${PEEKABOO_BIN:-}"
ARTIFACT_ROOT=""
PLAYGROUND_APP=""
SKIP_PLAYGROUND_BUILD=false
RUN_FOREGROUND_PHASE=false
SELF_TEST_ONLY=false
NO_REMOTE=false
QUALIFICATION_CYCLE=""
BRIDGE_SOCKET="${PEEKABOO_CERTIFICATION_BRIDGE_SOCKET:-${PEEKABOO_BRIDGE_SOCKET:-}}"

usage() {
    cat <<'EOF'
Usage: scripts/test-background-computer-use.sh [options]

Deterministically validates that targeted Peekaboo computer-use operations stay
in the background. Human mouse movement is observational; the optional foreground
phase is the only phase allowed to move the cursor on Peekaboo's behalf or
synthesize pointer/wheel events.

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
  --qualification-cycle N   Add the signed Playground alert lifecycle for final cycle 1...5
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
        --qualification-cycle)
            QUALIFICATION_CYCLE="$2"
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

if [[ -n "$QUALIFICATION_CYCLE" ]] &&
   [[ ! "$QUALIFICATION_CYCLE" =~ ^[1-5]$ ]]; then
    echo "--qualification-cycle must be an integer from 1 through 5." >&2
    exit 2
fi

if ! $NO_REMOTE && [[ -z "$BRIDGE_SOCKET" ]]; then
    BRIDGE_SOCKET="$HOME/Library/Application Support/Peekaboo/bridge.sock"
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This harness requires macOS." >&2
    exit 2
fi

for command_name in file git jq node plutil realpath rg swiftc xcodebuild codesign security open uuidgen shasum; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Missing required command: $command_name" >&2
        exit 2
    fi
done

read_code_signature_hash() {
    local details
    details="$(codesign -dvvv "$1" 2>&1)" || return 1
    awk -F= '
        /^CDHash=/ {
            count += 1
            value = $2
        }
        END {
            if (count != 1 || value !~ /^[0-9a-f]{40}$/) {
                exit 1
            }
            print value
        }
    ' <<<"$details"
}

openclaw_codesign_identity() {
    local identities
    identities="$(security find-identity -p codesigning -v 2>/dev/null)" || true
    awk -F'"' '
        /Developer ID Application: OpenClaw Foundation/ && identity == "" {
            identity = $2
        }
        END { print identity }
    ' <<<"$identities"
}

sign_playground_app() {
    local app="$1"
    local identity="$2"
    local executable_name main_executable candidate description
    executable_name="$(plutil -extract CFBundleExecutable raw "$app/Contents/Info.plist")"
    main_executable="$app/Contents/MacOS/$executable_name"

    while IFS= read -r -d '' candidate; do
        [[ "$candidate" != "$main_executable" ]] || continue
        description="$(file -b "$candidate" 2>/dev/null || true)"
        [[ "$description" == *Mach-O* ]] || continue
        case "$candidate" in
            "$app/Contents/MacOS/$executable_name.debug.dylib" | \
            "$app/Contents/MacOS/__preview.dylib" | \
            "$app/Contents/Frameworks/libswiftCompatibilitySpan.dylib") ;;
            *)
                echo "Unexpected nested Playground Mach-O payload: $candidate" >&2
                return 1
                ;;
        esac
        "$ROOT_DIR/scripts/codesign-with-retry.sh" \
            --force --options runtime --timestamp --sign "$identity" "$candidate"
    done < <(find -P "$app/Contents" -type f -print0)

    "$ROOT_DIR/scripts/codesign-with-retry.sh" \
        --force --options runtime --timestamp --sign "$identity" "$app"
}

CERTIFICATION_INVARIANTS_JSON="$(jq -cer '
    .invariants |
    select(type == "array" and length > 0) |
    select(all(.[]; type == "string" and length > 0)) |
    select((unique | length) == length)
' "$CERTIFICATION_CATALOG")" || {
    echo "Certification catalog must declare unique nonempty invariant names." >&2
    exit 2
}
CERTIFICATION_PHYSICAL_APPS_JSON="$(jq -cer '
    .physical_apps |
    select(type == "array" and length == 8) |
    select(all(.[]; type == "string" and length > 0)) |
    select((unique | length) == length)
' "$CERTIFICATION_CATALOG")" || {
    echo "Certification catalog must declare eight unique physical app names." >&2
    exit 2
}
CERTIFICATION_PHYSICAL_APP_WINDOW_TITLES_JSON="$(jq -cer '
    def normalized_title: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    .physical_app_window_titles |
    select(type == "object" and keys == ["activity-monitor"]) |
    select(all(to_entries[];
        (.key | type) == "string" and
        (.value | type) == "string" and
        .value != "" and
        (.value | normalized_title) == .value))
' "$CERTIFICATION_CATALOG")" || {
    echo "Certification catalog must declare one normalized Activity Monitor title selector." >&2
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
    "$ARTIFACT_ROOT/bin" \
    "$ARTIFACT_ROOT/setup" \
    "$ARTIFACT_ROOT/physical-targets"
chmod 700 "$ARTIFACT_ROOT"

SOURCE_CATALOG="$CERTIFICATION_CATALOG"
SOURCE_REPORTER="$CERTIFICATION_REPORTER"
SOURCE_PROBE="$ROOT_DIR/scripts/support/background-computer-use-probe.swift"
SOURCE_HARNESS="$ROOT_DIR/scripts/test-background-computer-use.sh"
SOURCE_INPUT_ROOT="$ARTIFACT_ROOT/source-inputs"
mkdir -m 700 "$SOURCE_INPUT_ROOT"
cp -p "$SOURCE_CATALOG" "$SOURCE_INPUT_ROOT/catalog.json"
cp -p "$SOURCE_REPORTER" "$SOURCE_INPUT_ROOT/reporter.mjs"
cp -p "$SOURCE_PROBE" "$SOURCE_INPUT_ROOT/probe.swift"
cp -p "$SOURCE_HARNESS" "$SOURCE_INPUT_ROOT/harness.sh"
chmod 400 "$SOURCE_INPUT_ROOT"/*
CATALOG_SHA256_INITIAL="$(shasum -a 256 "$SOURCE_INPUT_ROOT/catalog.json" | awk '{print $1}')"
REPORTER_SHA256_INITIAL="$(shasum -a 256 "$SOURCE_INPUT_ROOT/reporter.mjs" | awk '{print $1}')"
PROBE_SOURCE_SHA256_INITIAL="$(shasum -a 256 "$SOURCE_INPUT_ROOT/probe.swift" | awk '{print $1}')"
HARNESS_SHA256_INITIAL="$(shasum -a 256 "$SOURCE_INPUT_ROOT/harness.sh" | awk '{print $1}')"
CERTIFICATION_CATALOG="$SOURCE_INPUT_ROOT/catalog.json"
CERTIFICATION_REPORTER="$SOURCE_INPUT_ROOT/reporter.mjs"
CERTIFICATION_INVARIANTS_JSON="$(jq -cer '
    .invariants |
    select(type == "array" and length > 0) |
    select(all(.[]; type == "string" and length > 0)) |
    select((unique | length) == length)
' "$CERTIFICATION_CATALOG")"
CERTIFICATION_PHYSICAL_APPS_JSON="$(jq -cer '
    .physical_apps |
    select(type == "array" and length == 8) |
    select(all(.[]; type == "string" and length > 0)) |
    select((unique | length) == length)
' "$CERTIFICATION_CATALOG")"
CERTIFICATION_PHYSICAL_APP_WINDOW_TITLES_JSON="$(jq -cer '
    def normalized_title: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    .physical_app_window_titles |
    select(type == "object" and keys == ["activity-monitor"]) |
    select(all(to_entries[];
        (.key | type) == "string" and
        (.value | type) == "string" and
        .value != "" and
        (.value | normalized_title) == .value))
' "$CERTIFICATION_CATALOG")"

PROBE_BIN="$ARTIFACT_ROOT/bin/background-computer-use-probe"
swiftc "$SOURCE_INPUT_ROOT/probe.swift" \
    -o "$PROBE_BIN" \
    -framework AppKit \
    -framework ApplicationServices \
    -framework CoreGraphics \
    -framework CryptoKit \
    -framework Security
PROBE_EXECUTABLE_SHA256_INITIAL="$(shasum -a 256 "$PROBE_BIN" | awk '{print $1}')"
PROBE_EXECUTABLE_DEVICE_INITIAL="$(stat -f '%d' "$PROBE_BIN")"
PROBE_EXECUTABLE_INODE_INITIAL="$(stat -f '%i' "$PROBE_BIN")"
"$PROBE_BIN" self-test > "$ARTIFACT_ROOT/probe-self-test.json"

MONITOR_DIGEST_FIXTURE="$ARTIFACT_ROOT/monitor-digest-fixture.json"
MONITOR_DIGEST_EXPECTED="$ARTIFACT_ROOT/monitor-digest-expected.txt"
node - "$MONITOR_DIGEST_FIXTURE" "$MONITOR_DIGEST_EXPECTED" <<'NODE'
const fs = require('node:fs');
const { createHash } = require('node:crypto');
const [fixturePath, expectedPath] = process.argv.slice(2);
const nonce = 'a'.repeat(64);
const monitorID = '00000000-0000-4000-8000-000000000001';
const heartbeat = (sequence, name) => ({
  sequence,
  monotonicMicroseconds: 7786870761000 + sequence * 10000,
  wallClockMilliseconds: 1786870761000 + sequence * 10,
  lastCleanSequence: sequence,
  contaminationRetries: 0,
  contaminationBlocked: false,
  inputAttributionAvailable: true,
  allowedProducerRevision: sequence < 2 ? 1 : sequence < 5 ? 2 : 3,
  phase: name,
  cursorMovementObserved: false,
  pendingActivationCount: 0,
  pendingFocusedWindowChange: false,
  authorizationEpoch: sequence,
  transitionAcknowledged: false,
  foregroundActive: false,
  foregroundTargetPID: null,
  foregroundTargetWindowID: null,
  attributedForegroundEventCount: 0,
  attributedForegroundSourcePIDs: [],
  foregroundActivityObserved: false,
  executionNonce: nonce,
  monitorInstanceID: monitorID,
  historyCommitmentSHA256: 'b'.repeat(64),
});
const fenceNames = [
  'baseline-stable', 'grant-stable', 'operations-start',
  'operations-complete', 'revoke-stable', 'final-stable',
];
const evidence = {
  version: 1,
  execution_nonce: nonce,
  monitor_instance_id: monitorID,
  monitor_source_sha256: '1'.repeat(64),
  coordinator_source_sha256: '2'.repeat(64),
  monitor_process: {
    pid: 4242,
    start_identity: '1786870761472',
    executable_path: '/tmp/Peekaboo Monitor',
    executable_sha256: '3'.repeat(64),
    code_signature_hash: '4'.repeat(40),
    team_id: 'UNICODEÉ',
    source_commit: '5'.repeat(40),
    heartbeat_path: '/tmp/heartbeat.json',
  },
  monitor_attestation_socket_path: '/tmp/attestation.sock',
  sentinel: { pid: 99, start_identity: '9007199254740991', window_id: 101 },
  foreground_controller: { pid: 88, start_identity: '8800', code_signature_hash: '6'.repeat(40) },
  foreground_target: { pid: 77, start_identity: '7700', window_id: 202 },
  producer_sets: { baseline: { revision: 1 }, grant: { revision: 2 }, revoke: { revision: 3 } },
  fences: fenceNames.map((name, index) => ({ name, heartbeat: heartbeat(index + 1, name) })),
  baseline_sample: { frontmost_pid: 99, frontmost_window_id: 101, clipboard_change_count: 7, clipboard_digest: '7'.repeat(64) },
  final_sample: { frontmost_pid: 99, frontmost_window_id: 101, clipboard_change_count: 7, clipboard_digest: '7'.repeat(64) },
  foreground_plan: {
    request_marker: 'foreground:"quoted"\\path🦞\u2028line\u2029paragraph',
    semantic_element: { role: 'AXTextField', identifier: null, title: 'Résumé 😀' },
    unicode_order_probe: { '\u{1F600}': 'non-bmp', '\uE000': 'bmp-private-use' },
  },
  violation_records: [],
  contamination_records: [],
  baseline_commitment_sha256: '8'.repeat(64),
  history_commitment_sha256: '9'.repeat(64),
  crash_evidence: { version: 1, baseline: [], final: [], new_reports: [] },
  restoration: { background_final_bounds_slot_ids: ['a', 'b'], foreground_postcondition_sha256: 'c'.repeat(64), sentinel_sample_sha256: 'd'.repeat(64) },
};
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, canonical(value[key])]));
  }
  return value;
}
const bytes = Buffer.concat([
  Buffer.from('peekaboo.multi-target-certification.monitor-evidence.v2\0', 'utf8'),
  Buffer.from(JSON.stringify(canonical(evidence)), 'utf8'),
]);
fs.writeFileSync(fixturePath, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
fs.writeFileSync(expectedPath, `${createHash('sha256').update(bytes).digest('hex')}\n`, { mode: 0o600 });
NODE
"$PROBE_BIN" monitor-evidence-v2-digest --input "$MONITOR_DIGEST_FIXTURE" \
    --output "$ARTIFACT_ROOT/monitor-digest-observed.json"
[[ "$(jq -er '.monitor_evidence_sha256' "$ARTIFACT_ROOT/monitor-digest-observed.json")" == \
    "$(tr -d '[:space:]' < "$MONITOR_DIGEST_EXPECTED")" ]] || {
    echo "Monitor evidence digest differs from the Node/finalizer canonical contract." >&2
    exit 1
}
printf '%s\n' '{"value":-0}' > "$ARTIFACT_ROOT/monitor-digest-negative-zero.json"
if "$PROBE_BIN" monitor-evidence-v2-digest \
    --input "$ARTIFACT_ROOT/monitor-digest-negative-zero.json" >/dev/null 2>&1; then
    echo "Monitor evidence digest accepted negative zero." >&2
    exit 1
fi
printf '%s\n' '{"value":-9223372036854775808}' > "$ARTIFACT_ROOT/monitor-digest-int64-min.json"
if "$PROBE_BIN" monitor-evidence-v2-digest \
    --input "$ARTIFACT_ROOT/monitor-digest-int64-min.json" >/dev/null 2>&1; then
    echo "Monitor evidence digest accepted an unsafe Int64 minimum." >&2
    exit 1
fi
printf '%s\n' '{"value":1.5}' > "$ARTIFACT_ROOT/monitor-digest-fractional.json"
if "$PROBE_BIN" monitor-evidence-v2-digest \
    --input "$ARTIFACT_ROOT/monitor-digest-fractional.json" >/dev/null 2>&1; then
    echo "Monitor evidence digest accepted a fractional committed number." >&2
    exit 1
fi

RUN_EXECUTION_NONCE="$(printf '%s' "$(uuidgen):$$:$(date +%s%N):$RANDOM" | shasum -a 256 | awk '{print $1}')"

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

resolve_delivery_mode() {
    local result_file="$1"
    jq -c '
        (.outcome? // null) as $outcome |
        (.data? // null) as $data |
        (($outcome | type) == "object" and ($outcome | has("delivery_mode"))) as $canonicalPresent |
        (if $canonicalPresent then $outcome.delivery_mode else null end) as $canonical |
        ([
            if (($data | type) == "object" and ($data | has("deliveryMode"))) then
                $data.deliveryMode
            else empty end,
            if (($data | type) == "object" and ($data | has("delivery_mode"))) then
                $data.delivery_mode
            else empty end
        ]) as $legacy |
        if (
            ($outcome == null or ($outcome | type) == "object") and
            (if $canonicalPresent then
                ($canonical == "background" or $canonical == "foreground")
            else true end) and
            all($legacy[]; . == "background" or . == "foreground") and
            (($legacy | unique | length) <= 1) and
            (($legacy | length) == 0 or
                ($canonicalPresent and all($legacy[]; . == $canonical)))
        ) then
            $canonical
        else
            error("conflicting or invalid canonical and legacy delivery modes")
        end
    ' "$result_file"
}

monitor_sequence() {
    jq -er '
        .sequence |
        select(type == "number" and . >= 1 and (. | floor) == .)
    ' "$1"
}

heartbeat_matches_current_run() {
    local heartbeat_path="$1"
    [[ -z "${monitor_instance_id:-}" ]] && return 0
    jq -e \
        --arg executionNonce "$RUN_EXECUTION_NONCE" \
        --arg monitorInstanceID "$monitor_instance_id" \
        --arg historyCommitmentSHA256 "$(tr -d '[:space:]' < "$history_commitment")" '
        .executionNonce == $executionNonce and
        .monitorInstanceID == $monitorInstanceID and
        .historyCommitmentSHA256 == $historyCommitmentSHA256 and
        (.monotonicMicroseconds | type) == "number" and .monotonicMicroseconds > 0 and
        (.wallClockMilliseconds | type) == "number" and .wallClockMilliseconds > 0 and
        (.authorizationEpoch | type) == "number" and .authorizationEpoch > 0
    ' "$heartbeat_path" >/dev/null 2>&1
}

wait_for_monitor_advance() {
    local heartbeat_path="$1"
    local previous_sequence="$2"
    local attempts="${3:-100}"
    local current_sequence=""
    for _ in $(seq 1 "$attempts"); do
        heartbeat_matches_current_run "$heartbeat_path" || return 1
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
        heartbeat_matches_current_run "$heartbeat_path" || return 1
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
        heartbeat_matches_current_run "$heartbeat_path" || return 1
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
        heartbeat_matches_current_run "$heartbeat_path" || return 1
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
            sourceCommit: $identity.sourceCommit,
            codeSignatureHash: $identity.codeSignatureHash
        } |
        select(
            (.pid | type) == "number" and .pid > 0 and
            (.startIdentity | type) == "string" and
            (.startIdentity | test("^[0-9]+$")) and
            (.sourceCommit | type) == "string" and
            (.sourceCommit | test("^[0-9a-f]{40}$")) and
            (.codeSignatureHash | type) == "string" and
            (.codeSignatureHash | test("^[0-9a-f]{40}$"))
        )
    ' "$status_file"
}

application_receipt_from_inventory() {
    local inventory_file="${1:?Application inventory required}"
    local bundle_id="${2:?Bundle identifier required}"
    jq -cer --arg bundleID "$bundle_id" '
        [.data.apps[]? |
            select(.bundle_id == $bundleID) |
            {
                application_name: .name,
                bundle_id: .bundle_id,
                pid: .pid,
                process_start_identity: (
                    .process_start_identity_decimal // (.process_start_identity | tostring)
                )
            } |
            select(
                (.application_name | type) == "string" and .application_name != "" and
                (.pid | type) == "number" and .pid > 0 and (.pid | floor) == .pid and
                (.process_start_identity | type) == "string" and
                (.process_start_identity | test("^[1-9][0-9]*$"))
            )] as $matches |
        select(($matches | length) == 1) |
        $matches[0]
    ' "$inventory_file"
}

new_application_receipt_from_inventories() {
    local before_file="${1:?Before inventory required}"
    local after_file="${2:?After inventory required}"
    local bundle_id="${3:?Bundle identifier required}"
    jq -cer --arg bundleID "$bundle_id" --slurpfile before "$before_file" '
        [$before[0].data.apps[]? | select(.bundle_id == $bundleID) | .pid] as $priorPIDs |
        [.data.apps[]? |
            select(.bundle_id == $bundleID) |
            select((.pid as $pid | $priorPIDs | index($pid)) == null) |
            {
                application_name: .name,
                bundle_id: .bundle_id,
                pid: .pid,
                process_start_identity: (
                    .process_start_identity_decimal // (.process_start_identity | tostring)
                )
            } |
            select(
                (.application_name | type) == "string" and .application_name != "" and
                (.pid | type) == "number" and .pid > 0 and (.pid | floor) == .pid and
                (.process_start_identity | type) == "string" and
                (.process_start_identity | test("^[1-9][0-9]*$"))
            )] as $matches |
        select(($matches | length) == 1) |
        $matches[0]
    ' "$after_file"
}

exact_window_receipt_from_inventory() {
    local inventory_file="${1:?Window inventory required}"
    jq -cer '
        [.data.windows[]? |
            select((.layer // 0) == 0 and .is_on_screen == true) |
            {
                window_id: .window_id,
                window_title: (.window_title // .title // ""),
                bounds: .bounds,
                is_key: (.is_key == true)
            } |
            select(
                (.window_id | type) == "number" and .window_id > 0 and
                (.window_id | floor) == .window_id and
                (.window_title | type) == "string" and
                (.bounds | type) == "object" and
                ([.bounds.x, .bounds.y, .bounds.width, .bounds.height] |
                    all(type == "number")) and
                .bounds.width > 0 and .bounds.height > 0
            )] as $eligible |
        [$eligible[] | select(.is_key)] as $keyWindows |
        if ($keyWindows | length) == 1 then $keyWindows[0]
        elif ($eligible | length) == 1 then $eligible[0]
        else empty
        end |
        del(.is_key)
    ' "$inventory_file"
}

physical_expected_window_title() {
    local slug="${1:?Physical app slug required}"
    jq -er --arg slug "$slug" '.[$slug] // empty' \
        <<< "$CERTIFICATION_PHYSICAL_APP_WINDOW_TITLES_JSON"
}

exact_named_window_receipt_from_inventory() {
    local inventory_file="${1:?Window inventory required}"
    local expected_title="${2:?Expected window title required}"
    local expected_pid="${3:?Expected PID required}"
    local expected_bundle_id="${4:?Expected bundle identifier required}"
    local expected_application_name="${5:?Expected application name required}"
    jq -cer \
        --arg expectedTitle "$expected_title" \
        --argjson expectedPID "$expected_pid" \
        --arg expectedBundleID "$expected_bundle_id" \
        --arg expectedApplicationName "$expected_application_name" '
        def normalized_title: gsub("^[[:space:]]+|[[:space:]]+$"; "");
        def exact_filter_warning:
            type == "string" and
            (test("^Window list omitted 1 non-renderable or duplicate inventory row\\.$") or
                test("^Window list omitted (?:[2-9]|[1-9][0-9]+) non-renderable or duplicate inventory rows\\.$"));
        def valid_window:
            type == "object" and
            (.window_id | type) == "number" and
            .window_id > 0 and .window_id <= 4294967295 and
            (.window_id | floor) == .window_id and
            (.window_title | type) == "string" and
            (.bounds | type) == "object" and
            ([.bounds.x, .bounds.y, .bounds.width, .bounds.height] | all(type == "number")) and
            .bounds.width > 0 and .bounds.height > 0 and
            (.layer | type) == "number" and (.layer | floor) == .layer and
            (.is_on_screen | type) == "boolean";
        select(.success == true) |
        .data as $data |
        select(($expectedTitle | normalized_title) == $expectedTitle) |
        select(($expectedApplicationName | normalized_title) == $expectedTitle) |
        select(
            $data.target_application_info.pid == $expectedPID and
            $data.target_application_info.bundle_id == $expectedBundleID and
            $data.target_application_info.app_name == $expectedApplicationName
        ) |
        $data.inventory_completeness as $completeness |
        $data.inventory_warnings as $warnings |
        select(
            ($completeness == "complete" and ($warnings | type) == "array" and
                ($warnings | length) == 0) or
            ($completeness == "partial" and ($warnings | type) == "array" and
                ($warnings | length) == 1 and ($warnings[0] | exact_filter_warning))
        ) |
        $data.windows as $windows |
        select(($windows | type) == "array" and all($windows[]; valid_window)) |
        [$windows[] |
            select(.layer == 0 and .is_on_screen == true) |
            select((.window_title | normalized_title) == $expectedTitle) |
            {
                window_id: .window_id,
                window_title: .window_title,
                bounds: .bounds
            }] as $matches |
        select(($matches | length) == 1) |
        $matches[0]
    ' "$inventory_file"
}

exact_window_receipts_match() {
    local expected_file="${1:?Expected window receipt required}"
    local observed_file="${2:?Observed window receipt required}"
    jq -ne \
        --slurpfile expected "$expected_file" \
        --slurpfile observed "$observed_file" '
        ($expected | length) == 1 and ($observed | length) == 1 and
        $observed[0].window_id == $expected[0].window_id and
        $observed[0].window_title == $expected[0].window_title and
        $observed[0].bounds == $expected[0].bounds
    ' >/dev/null
}

physical_target_receipt() {
    local slug="${1:?Physical app slug required}"
    local application_receipt_file="${2:?Application receipt required}"
    local window_receipt_file="${3:?Window receipt required}"
    jq -cn \
        --arg slug "$slug" \
        --slurpfile application "$application_receipt_file" \
        --slurpfile window "$window_receipt_file" '
        select(($application | length) == 1 and ($window | length) == 1) |
        $application[0] + $window[0] + {physical_app: $slug}
    '
}

if $SELF_TEST_ONLY; then
    CODE_SIGNATURE_HASH_SELF_TEST="0123456789abcdef0123456789abcdef01234567"
    codesign() {
        printf 'CDHash=%s\n' "$CODE_SIGNATURE_HASH_SELF_TEST"
        local index
        for ((index = 0; index < 4096; index += 1)); do
            printf 'Metadata-%d=value\n' "$index"
        done
    }
    if [[ "$(read_code_signature_hash /self-test)" != "$CODE_SIGNATURE_HASH_SELF_TEST" ]]; then
        echo "Code-signature hash extraction self-test failed." >&2
        exit 1
    fi
    codesign() {
        printf 'CDHash=%s\nCDHash=%s\n' \
            "$CODE_SIGNATURE_HASH_SELF_TEST" "$CODE_SIGNATURE_HASH_SELF_TEST"
    }
    if read_code_signature_hash /self-test >/dev/null 2>&1; then
        echo "Code-signature hash extraction accepted duplicate fields." >&2
        exit 1
    fi
    unset -f codesign

    security() {
        printf '%s\n' \
            '1) 1111111111111111111111111111111111111111 "Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)"' \
            '2) 2222222222222222222222222222222222222222 "Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)"'
    }
    if [[ "$(openclaw_codesign_identity)" != \
          "Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)" ]]; then
        echo "Code-signing identity extraction self-test failed." >&2
        exit 1
    fi
    unset -f security

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
                    sourceCommit: "0123456789abcdef0123456789abcdef01234567",
                    codeSignatureHash: "0123456789abcdef0123456789abcdef01234567"
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
    DELIVERY_CANONICAL_SELF_TEST="$ARTIFACT_ROOT/delivery-canonical-self-test.json"
    DELIVERY_MATCHING_SELF_TEST="$ARTIFACT_ROOT/delivery-matching-self-test.json"
    DELIVERY_CONFLICT_SELF_TEST="$ARTIFACT_ROOT/delivery-conflict-self-test.json"
    DELIVERY_NULL_CONFLICT_SELF_TEST="$ARTIFACT_ROOT/delivery-null-conflict-self-test.json"
    DELIVERY_LEGACY_ONLY_SELF_TEST="$ARTIFACT_ROOT/delivery-legacy-only-self-test.json"
    DELIVERY_LEGACY_CONFLICT_SELF_TEST="$ARTIFACT_ROOT/delivery-legacy-conflict-self-test.json"
    printf '%s\n' '{"outcome":{"delivery_mode":"background"},"data":{}}' \
        > "$DELIVERY_CANONICAL_SELF_TEST"
    printf '%s\n' \
        '{"outcome":{"delivery_mode":"background"},"data":{"deliveryMode":"background","delivery_mode":"background"}}' \
        > "$DELIVERY_MATCHING_SELF_TEST"
    printf '%s\n' \
        '{"outcome":{"delivery_mode":"background"},"data":{"deliveryMode":"foreground"}}' \
        > "$DELIVERY_CONFLICT_SELF_TEST"
    printf '%s\n' \
        '{"outcome":{"delivery_mode":"background"},"data":{"deliveryMode":null}}' \
        > "$DELIVERY_NULL_CONFLICT_SELF_TEST"
    printf '%s\n' '{"data":{"deliveryMode":"background"}}' > "$DELIVERY_LEGACY_ONLY_SELF_TEST"
    printf '%s\n' \
        '{"data":{"deliveryMode":"background","delivery_mode":"foreground"}}' \
        > "$DELIVERY_LEGACY_CONFLICT_SELF_TEST"
    if [[ "$(resolve_delivery_mode "$DELIVERY_CANONICAL_SELF_TEST")" != '"background"' ]] || \
       [[ "$(resolve_delivery_mode "$DELIVERY_MATCHING_SELF_TEST")" != '"background"' ]] || \
       resolve_delivery_mode "$DELIVERY_CONFLICT_SELF_TEST" >/dev/null 2>&1 || \
       resolve_delivery_mode "$DELIVERY_NULL_CONFLICT_SELF_TEST" >/dev/null 2>&1 || \
       resolve_delivery_mode "$DELIVERY_LEGACY_ONLY_SELF_TEST" >/dev/null 2>&1 || \
       resolve_delivery_mode "$DELIVERY_LEGACY_CONFLICT_SELF_TEST" >/dev/null 2>&1; then
        echo "Canonical delivery-mode resolution self-test failed." >&2
        exit 1
    fi
    APPLICATIONS_BEFORE_SELF_TEST="$ARTIFACT_ROOT/applications-before-self-test.json"
    APPLICATIONS_AFTER_SELF_TEST="$ARTIFACT_ROOT/applications-after-self-test.json"
    APPLICATIONS_AMBIGUOUS_SELF_TEST="$ARTIFACT_ROOT/applications-ambiguous-self-test.json"
    WINDOWS_SELF_TEST="$ARTIFACT_ROOT/windows-self-test.json"
    WINDOWS_AMBIGUOUS_SELF_TEST="$ARTIFACT_ROOT/windows-ambiguous-self-test.json"
    printf '%s\n' \
        '{"data":{"apps":[{"name":"TextEdit","bundle_id":"com.apple.TextEdit","pid":101,"process_start_identity_decimal":"7001"}]}}' \
        > "$APPLICATIONS_BEFORE_SELF_TEST"
    printf '%s\n' \
        '{"data":{"apps":[{"name":"TextEdit","bundle_id":"com.apple.TextEdit","pid":101,"process_start_identity_decimal":"7001"},{"name":"TextEdit","bundle_id":"com.apple.TextEdit","pid":102,"process_start_identity_decimal":"7002"}]}}' \
        > "$APPLICATIONS_AFTER_SELF_TEST"
    cp "$APPLICATIONS_AFTER_SELF_TEST" "$APPLICATIONS_AMBIGUOUS_SELF_TEST"
    printf '%s\n' \
        '{"data":{"windows":[{"window_id":41,"window_title":"First","bounds":{"x":1,"y":2,"width":640,"height":480},"layer":0,"is_on_screen":true,"is_key":false},{"window_id":42,"window_title":"Owned","bounds":{"x":3,"y":4,"width":800,"height":600},"layer":0,"is_on_screen":true,"is_key":true}]}}' \
        > "$WINDOWS_SELF_TEST"
    jq '.data.windows[0].is_key = true' "$WINDOWS_SELF_TEST" > "$WINDOWS_AMBIGUOUS_SELF_TEST"
    NEW_APPLICATION_SELF_TEST="$ARTIFACT_ROOT/new-application-self-test.json"
    NEW_WINDOW_SELF_TEST="$ARTIFACT_ROOT/new-window-self-test.json"
    new_application_receipt_from_inventories \
        "$APPLICATIONS_BEFORE_SELF_TEST" "$APPLICATIONS_AFTER_SELF_TEST" \
        "$TEXTEDIT_BUNDLE_ID" > "$NEW_APPLICATION_SELF_TEST"
    exact_window_receipt_from_inventory "$WINDOWS_SELF_TEST" > "$NEW_WINDOW_SELF_TEST"
    if ! jq -e '.pid == 102 and .process_start_identity == "7002"' \
        "$NEW_APPLICATION_SELF_TEST" >/dev/null || \
       ! jq -e '.window_id == 42 and .window_title == "Owned"' \
        "$NEW_WINDOW_SELF_TEST" >/dev/null || \
       application_receipt_from_inventory \
        "$APPLICATIONS_AMBIGUOUS_SELF_TEST" "$TEXTEDIT_BUNDLE_ID" >/dev/null 2>&1 || \
       exact_window_receipt_from_inventory "$WINDOWS_AMBIGUOUS_SELF_TEST" >/dev/null 2>&1; then
        echo "Owned application/window receipt self-test failed." >&2
        exit 1
    fi
    NAMED_WINDOWS_SELF_TEST="$ARTIFACT_ROOT/named-windows-self-test.json"
    NAMED_WINDOWS_COMPLETE_SELF_TEST="$ARTIFACT_ROOT/named-windows-complete-self-test.json"
    NAMED_WINDOWS_DUPLICATE_SELF_TEST="$ARTIFACT_ROOT/named-windows-duplicate-self-test.json"
    NAMED_WINDOWS_TITLE_DRIFT_SELF_TEST="$ARTIFACT_ROOT/named-windows-title-drift-self-test.json"
    NAMED_WINDOWS_BOUNDS_DRIFT_SELF_TEST="$ARTIFACT_ROOT/named-windows-bounds-drift-self-test.json"
    NAMED_WINDOWS_UNSAFE_PARTIAL_SELF_TEST="$ARTIFACT_ROOT/named-windows-unsafe-partial-self-test.json"
    NAMED_WINDOWS_MIXED_PARTIAL_SELF_TEST="$ARTIFACT_ROOT/named-windows-mixed-partial-self-test.json"
    NAMED_WINDOWS_BAD_SINGULAR_SELF_TEST="$ARTIFACT_ROOT/named-windows-bad-singular-self-test.json"
    NAMED_WINDOWS_BAD_PLURAL_SELF_TEST="$ARTIFACT_ROOT/named-windows-bad-plural-self-test.json"
    NAMED_WINDOWS_OWNER_MISMATCH_SELF_TEST="$ARTIFACT_ROOT/named-windows-owner-mismatch-self-test.json"
    NAMED_WINDOWS_NAME_MISMATCH_SELF_TEST="$ARTIFACT_ROOT/named-windows-name-mismatch-self-test.json"
    NAMED_WINDOWS_OFFSCREEN_SELF_TEST="$ARTIFACT_ROOT/named-windows-offscreen-self-test.json"
    NAMED_WINDOWS_LAYER_SELF_TEST="$ARTIFACT_ROOT/named-windows-layer-self-test.json"
    NAMED_WINDOWS_BOUNDS_SELF_TEST="$ARTIFACT_ROOT/named-windows-bounds-self-test.json"
    NAMED_WINDOW_RECEIPT_SELF_TEST="$ARTIFACT_ROOT/named-window-receipt-self-test.json"
    NAMED_WINDOW_COMPLETE_RECEIPT_SELF_TEST="$ARTIFACT_ROOT/named-window-complete-receipt-self-test.json"
    NAMED_WINDOW_DRIFT_RECEIPT_SELF_TEST="$ARTIFACT_ROOT/named-window-drift-receipt-self-test.json"
    printf '%s\n' \
        '{"success":true,"data":{"inventory_completeness":"partial","inventory_warnings":["Window list omitted 5 non-renderable or duplicate inventory rows."],"target_application_info":{"pid":11393,"bundle_id":"com.apple.ActivityMonitor","app_name":"Activity Monitor"},"windows":[{"window_id":770,"window_title":"Activity Monitor","bounds":{"x":1250,"y":138,"width":960,"height":858},"layer":0,"is_on_screen":true},{"window_id":769,"window_title":"Dock Icon Host Window","bounds":{"x":416,"y":376,"width":361,"height":361},"layer":0,"is_on_screen":true}]}}' \
        > "$NAMED_WINDOWS_SELF_TEST"
    jq '.data.inventory_completeness = "complete" | .data.inventory_warnings = []' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_COMPLETE_SELF_TEST"
    jq '.data.windows += [(.data.windows[0] | .window_id = 771 | .window_title = " Activity Monitor ")]' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_DUPLICATE_SELF_TEST"
    jq '.data.windows[0].window_title = "CPU"' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_TITLE_DRIFT_SELF_TEST"
    jq '.data.inventory_warnings = ["Accessibility window enrichment was incomplete"]' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_UNSAFE_PARTIAL_SELF_TEST"
    jq '.data.inventory_warnings += ["Accessibility window enrichment was incomplete"]' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_MIXED_PARTIAL_SELF_TEST"
    jq '.data.inventory_warnings = ["Window list omitted 2 non-renderable or duplicate inventory row."]' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_BAD_SINGULAR_SELF_TEST"
    jq '.data.inventory_warnings = ["Window list omitted 1 non-renderable or duplicate inventory rows."]' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_BAD_PLURAL_SELF_TEST"
    jq '.data.target_application_info.pid = 11394' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_OWNER_MISMATCH_SELF_TEST"
    jq '.data.target_application_info.app_name = "Dock Icon Host Window"' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_NAME_MISMATCH_SELF_TEST"
    jq '.data.windows[0].is_on_screen = false' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_OFFSCREEN_SELF_TEST"
    jq '.data.windows[0].layer = 1' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_LAYER_SELF_TEST"
    jq '.data.windows[0].bounds.width = 0' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_BOUNDS_SELF_TEST"
    exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_SELF_TEST" "Activity Monitor" 11393 com.apple.ActivityMonitor "Activity Monitor" \
        > "$NAMED_WINDOW_RECEIPT_SELF_TEST"
    exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_COMPLETE_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        > "$NAMED_WINDOW_COMPLETE_RECEIPT_SELF_TEST"
    jq '.data.windows[0].bounds.x += 1' \
        "$NAMED_WINDOWS_SELF_TEST" > "$NAMED_WINDOWS_BOUNDS_DRIFT_SELF_TEST"
    exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_BOUNDS_DRIFT_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        > "$NAMED_WINDOW_DRIFT_RECEIPT_SELF_TEST"
    if [[ "$(physical_expected_window_title activity-monitor)" != "Activity Monitor" ]] || \
       physical_expected_window_title finder >/dev/null 2>&1 || \
       ! jq -e '.window_id == 770 and .window_title == "Activity Monitor"' \
        "$NAMED_WINDOW_RECEIPT_SELF_TEST" >/dev/null || \
       ! exact_window_receipts_match \
        "$NAMED_WINDOW_RECEIPT_SELF_TEST" "$NAMED_WINDOW_COMPLETE_RECEIPT_SELF_TEST" || \
       ! exact_window_receipts_match \
        "$NAMED_WINDOW_RECEIPT_SELF_TEST" "$NAMED_WINDOW_RECEIPT_SELF_TEST" || \
       exact_window_receipts_match \
        "$NAMED_WINDOW_RECEIPT_SELF_TEST" "$NAMED_WINDOW_DRIFT_RECEIPT_SELF_TEST" || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_DUPLICATE_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_TITLE_DRIFT_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_UNSAFE_PARTIAL_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_MIXED_PARTIAL_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_BAD_SINGULAR_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_BAD_PLURAL_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_OWNER_MISMATCH_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_NAME_MISMATCH_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_OFFSCREEN_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_LAYER_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1 || \
       exact_named_window_receipt_from_inventory \
        "$NAMED_WINDOWS_BOUNDS_SELF_TEST" "Activity Monitor" 11393 \
        com.apple.ActivityMonitor "Activity Monitor" \
        >/dev/null 2>&1; then
        echo "Exact physical title receipt self-test failed." >&2
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
    printf '%s\n' \
        '{"kind":"producer_pointer_event","expected":"none","actual":"pid=123; type=5"}' \
        > "$INVARIANT_SELF_TEST"
    INVARIANT_RESULTS_SELF_TEST="$(invariant_results "$INVARIANT_SELF_TEST")"
    if ! jq -e \
        --argjson catalog "$CERTIFICATION_INVARIANTS_JSON" '
        ([.[] | select(.name == "producer_pointer_event" and .passed == false)] | length) == 1 and
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
    PLAYGROUND_PID=100
    PLAYGROUND_PROCESS_START_IDENTITY=7
    refresh_playground_process_receipt 101 8
    if [[ "$PLAYGROUND_PID" != 101 || "$PLAYGROUND_PROCESS_START_IDENTITY" != 8 ]] || \
       same_process_generation 7 "$PLAYGROUND_PROCESS_START_IDENTITY" || \
       ! same_process_generation 8 "$PLAYGROUND_PROCESS_START_IDENTITY"; then
        echo "Playground owned-process receipt refresh self-test failed." >&2
        exit 1
    fi
    if refresh_playground_process_receipt 102 ""; then
        echo "Playground ownership accepted a missing process generation." >&2
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
PEEKABOO_BIN="$(realpath "$PEEKABOO_BIN")"
PEEKABOO_EXECUTABLE_SHA256="$(shasum -a 256 "$PEEKABOO_BIN" | awk '{print $1}')"
PEEKABOO_EXECUTABLE_DEVICE="$(stat -f '%d' "$PEEKABOO_BIN")"
PEEKABOO_EXECUTABLE_INODE="$(stat -f '%i' "$PEEKABOO_BIN")"
PEEKABOO_CODE_SIGNATURE_HASH="$(read_code_signature_hash "$PEEKABOO_BIN")"
if [[ ! "$PEEKABOO_EXECUTABLE_SHA256" =~ ^[0-9a-f]{64}$ || \
      ! "$PEEKABOO_CODE_SIGNATURE_HASH" =~ ^[0-9a-f]{40}$ ]]; then
    echo "Peekaboo CLI lacks an exact executable SHA-256 or code-signature hash." >&2
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
BRIDGE_EXECUTABLE_SHA256_JSON=null
BRIDGE_CODE_SIGNATURE_HASH_JSON=null
BRIDGE_EXECUTABLE_DEVICE_JSON=null
BRIDGE_EXECUTABLE_INODE_JSON=null
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
    BRIDGE_PID="$(jq -er '.pid' <<<"$REMOTE_EVENT_PRODUCER_JSON")"
    BRIDGE_START_IDENTITY="$(jq -er '.startIdentity' <<<"$REMOTE_EVENT_PRODUCER_JSON")"
    "$PROBE_BIN" process-executable --pid "$BRIDGE_PID" \
        --output "$ARTIFACT_ROOT/bridge-executable-before.json"
    if ! jq -e --argjson pid "$BRIDGE_PID" --arg startIdentity "$BRIDGE_START_IDENTITY" '
        .pid == $pid and .startIdentity == $startIdentity and
        (.sha256 | test("^[0-9a-f]{64}$"))
    ' "$ARTIFACT_ROOT/bridge-executable-before.json" >/dev/null; then
        echo "Pinned Bridge executable receipt differs from its handshake generation." >&2
        exit 2
    fi
    BRIDGE_EXECUTABLE_SHA256_JSON="$(jq -c '.sha256' "$ARTIFACT_ROOT/bridge-executable-before.json")"
    BRIDGE_CODE_SIGNATURE_HASH_JSON="$(jq -c '.codeSignatureHash' <<<"$REMOTE_EVENT_PRODUCER_JSON")"
    BRIDGE_EXECUTABLE_PATH="$(jq -er '.path' "$ARTIFACT_ROOT/bridge-executable-before.json")"
    BRIDGE_EXECUTABLE_DEVICE_JSON="$(stat -f '%d' "$BRIDGE_EXECUTABLE_PATH" | jq -Rsc 'rtrimstr("\n")')"
    BRIDGE_EXECUTABLE_INODE_JSON="$(stat -f '%i' "$BRIDGE_EXECUTABLE_PATH" | jq -Rsc 'rtrimstr("\n")')"
fi

PLAYGROUND_SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
PLAYGROUND_SOURCE_TREE="$(git -C "$ROOT_DIR" rev-parse HEAD:Apps/Playground)"

build_playground() {
    local derived_data="$ARTIFACT_ROOT/DerivedData"
    local build_log="$ARTIFACT_ROOT/playground-build.log"
    if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=all -- Apps/Playground)" ]]; then
        echo "Playground sources differ from the committed source tree; refusing a false provenance stamp." >&2
        return 1
    fi
    xcodebuild \
        -project "$ROOT_DIR/Apps/Playground/Playground.xcodeproj" \
        -scheme Playground \
        -configuration Debug \
        -derivedDataPath "$derived_data" \
        build CODE_SIGNING_ALLOWED=NO > "$build_log" 2>&1

    PLAYGROUND_APP="$derived_data/Build/Products/Debug/Playground.app"
    local identity="${PEEKABOO_PLAYGROUND_SIGN_IDENTITY:-}"
    if [[ -z "$identity" ]]; then
        identity="$(openclaw_codesign_identity)"
    fi
    if [[ -z "$identity" ]]; then
        echo "No OpenClaw Foundation Developer ID Application identity is available." >&2
        return 1
    fi

    mkdir -p "$PLAYGROUND_APP/Contents/Resources"
    jq -n \
        --arg sourceCommit "$PLAYGROUND_SOURCE_COMMIT" \
        --arg sourceTree "$PLAYGROUND_SOURCE_TREE" '
        {version: 1, source_commit: $sourceCommit, source_tree: $sourceTree}
    ' > "$PLAYGROUND_APP/Contents/Resources/PeekabooPlaygroundSource.json"
    chmod 444 "$PLAYGROUND_APP/Contents/Resources/PeekabooPlaygroundSource.json"

    sign_playground_app "$PLAYGROUND_APP" "$identity"
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
PLAYGROUND_SOURCE_MANIFEST="$PLAYGROUND_APP/Contents/Resources/PeekabooPlaygroundSource.json"
if ! jq -e \
    --arg sourceCommit "$PLAYGROUND_SOURCE_COMMIT" \
    --arg sourceTree "$PLAYGROUND_SOURCE_TREE" '
    type == "object" and keys == ["source_commit", "source_tree", "version"] and
    .version == 1 and .source_commit == $sourceCommit and .source_tree == $sourceTree
' "$PLAYGROUND_SOURCE_MANIFEST" >/dev/null; then
    echo "Playground app lacks an exact current-source manifest; rebuild it from this checkout." >&2
    exit 2
fi
codesign --verify --deep --strict "$PLAYGROUND_APP"
codesign -dv --verbose=2 "$PLAYGROUND_APP" > "$ARTIFACT_ROOT/playground-signature.txt" 2>&1
if ! rg -q '^TeamIdentifier=' "$ARTIFACT_ROOT/playground-signature.txt" || \
   rg -q '^TeamIdentifier=not set$' "$ARTIFACT_ROOT/playground-signature.txt"; then
    echo "Playground must have a team-signed identity, not an ad-hoc signature." >&2
    exit 2
fi
PLAYGROUND_EXECUTABLE_NAME="$(plutil -extract CFBundleExecutable raw \
    "$PLAYGROUND_APP/Contents/Info.plist")"
PLAYGROUND_EXECUTABLE="$PLAYGROUND_APP/Contents/MacOS/$PLAYGROUND_EXECUTABLE_NAME"

MONITOR_PID=""
PLAYGROUND_PID=""
PLAYGROUND_PROCESS_START_IDENTITY=""
LIFECYCLE_PIDS=()
LIFECYCLE_PROCESS_START_IDENTITIES=()
MAXIMIZE_TEXTEDIT_PID=""
MAXIMIZE_TEXTEDIT_WINDOW_ID=""
QUIT_TEXTEDIT_PID=""
QUIT_TEXTEDIT_PROCESS_START_IDENTITY=""
OWNED_PID=""
OWNED_PROCESS_START_IDENTITY=""
OWNED_WINDOW_ID=""

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

write_application_inventory() {
    local output="${1:?Application inventory output required}"
    pb app list --include-hidden --include-background --json > "$output"
}

process_generation_matches() {
    local pid="${1:?PID required}"
    local expected_start_identity="${2:?Process start identity required}"
    local output="${3:?Process identity output required}"
    "$PROBE_BIN" process-identity --pid "$pid" --output "$output" 2>/dev/null &&
        jq -e --argjson pid "$pid" --arg expected "$expected_start_identity" '
            .pid == $pid and .startIdentity == $expected
        ' "$output" >/dev/null
}

sentinel_still_exact() {
    local output="${1:?Sentinel sample output required}"
    "$PROBE_BIN" sample --output "$output"
    jq -e --argjson pid "$SENTINEL_PID" --argjson windowID "$SENTINEL_WINDOW_ID" '
        .frontmostPID == $pid and .frontmostWindowID == $windowID
    ' "$output" >/dev/null
}

launch_owned_background_app() {
    local label="${1:?Owned app label required}"
    local bundle_id="${2:?Owned app bundle identifier required}"
    local application_path="${3:?Owned app path required}"
    local track_lifecycle="${4:-false}"
    local setup_dir="$ARTIFACT_ROOT/setup/$label"
    local before="$setup_dir/applications-before.json"
    local after="$setup_dir/applications-after.json"
    local application_receipt="$setup_dir/application-receipt.json"
    local window_inventory="$setup_dir/windows.json"
    local window_receipt="$setup_dir/window-receipt.json"
    local target_receipt="$setup_dir/target-receipt.json"
    mkdir -p "$setup_dir"

    write_application_inventory "$before"
    open -g -n "$application_path" > "$setup_dir/open.stdout" 2> "$setup_dir/open.stderr"

    local attempt
    for attempt in $(seq 1 80); do
        write_application_inventory "$after"
        if new_application_receipt_from_inventories \
            "$before" "$after" "$bundle_id" > "$application_receipt" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done
    if [[ ! -s "$application_receipt" ]]; then
        echo "Background setup did not produce one exact new $label process." >&2
        return 1
    fi

    OWNED_PID="$(jq -er '.pid' "$application_receipt")"
    OWNED_PROCESS_START_IDENTITY="$(jq -er '.process_start_identity' "$application_receipt")"
    if [[ "$label" == playground ]]; then
        refresh_playground_process_receipt \
            "$OWNED_PID" "$OWNED_PROCESS_START_IDENTITY" || return 1
    elif [[ "$track_lifecycle" == true ]]; then
        LIFECYCLE_PIDS+=("$OWNED_PID")
        LIFECYCLE_PROCESS_START_IDENTITIES+=("$OWNED_PROCESS_START_IDENTITY")
    fi
    if ! process_generation_matches \
        "$OWNED_PID" "$OWNED_PROCESS_START_IDENTITY" "$setup_dir/process-identity.json"; then
        echo "Background setup could not pin the $label process generation." >&2
        return 1
    fi

    for attempt in $(seq 1 80); do
        if pb window list --pid "$OWNED_PID" --json > "$window_inventory" 2> "$setup_dir/windows.stderr" &&
           exact_window_receipt_from_inventory "$window_inventory" > "$window_receipt" 2>/dev/null; then
            break
        fi
        sleep 0.05
    done
    if [[ ! -s "$window_receipt" ]]; then
        echo "Background setup did not produce one exact visible $label window." >&2
        return 1
    fi
    OWNED_WINDOW_ID="$(jq -er '.window_id' "$window_receipt")"
    physical_target_receipt \
        "$label" "$application_receipt" "$window_receipt" > "$target_receipt"

    if ! sentinel_still_exact "$setup_dir/sentinel-after.json"; then
        echo "Background setup changed the exact foreground sentinel while launching $label." >&2
        return 1
    fi
}

resolve_existing_physical_target() {
    local slug="${1:?Physical app slug required}"
    local bundle_id="${2:?Physical app bundle identifier required}"
    local target_dir="$ARTIFACT_ROOT/physical-targets/$slug"
    local application_inventory="$target_dir/applications.json"
    local application_receipt="$target_dir/application-receipt.json"
    local window_inventory="$target_dir/windows.json"
    local window_receipt="$target_dir/window-receipt.json"
    mkdir -p "$target_dir"

    write_application_inventory "$application_inventory"
    if ! application_receipt_from_inventory \
        "$application_inventory" "$bundle_id" > "$application_receipt"; then
        echo "Physical app $slug requires exactly one already-running $bundle_id process." >&2
        return 1
    fi
    local pid process_start_identity application_name expected_window_title
    pid="$(jq -er '.pid' "$application_receipt")"
    process_start_identity="$(jq -er '.process_start_identity' "$application_receipt")"
    application_name="$(jq -er '.application_name' "$application_receipt")"
    expected_window_title="$(physical_expected_window_title "$slug" 2>/dev/null || true)"
    if ! process_generation_matches \
        "$pid" "$process_start_identity" "$target_dir/process-identity.json"; then
        echo "Physical app $slug changed process generation during setup." >&2
        return 1
    fi
    if ! pb window list --pid "$pid" --json > "$window_inventory"; then
        echo "Physical app $slug window inventory failed." >&2
        return 1
    fi
    if [[ -n "$expected_window_title" ]]; then
        if ! exact_named_window_receipt_from_inventory \
            "$window_inventory" "$expected_window_title" "$pid" "$bundle_id" "$application_name" \
            > "$window_receipt"; then
            echo "Physical app $slug requires one exact visible '$expected_window_title' window." >&2
            return 1
        fi
    elif ! exact_window_receipt_from_inventory "$window_inventory" > "$window_receipt"; then
        echo "Physical app $slug requires one exact visible key or sole window." >&2
        return 1
    fi
    if ! process_generation_matches \
        "$pid" "$process_start_identity" "$target_dir/process-identity-after-window.json"; then
        echo "Physical app $slug changed process generation during window selection." >&2
        return 1
    fi
    physical_target_receipt \
        "$slug" "$application_receipt" "$window_receipt" > "$target_dir/target-receipt.json"
}

"$PROBE_BIN" sample --output "$ARTIFACT_ROOT/sentinel.json"
SENTINEL_PID="$(jq -r '.frontmostPID // empty' "$ARTIFACT_ROOT/sentinel.json")"
SENTINEL_WINDOW_ID="$(jq -r '.frontmostWindowID // empty' "$ARTIFACT_ROOT/sentinel.json")"
SENTINEL_OBSERVED_BUNDLE_ID="$(jq -r '.frontmostBundleIdentifier // empty' \
    "$ARTIFACT_ROOT/sentinel.json")"
if [[ -z "$SENTINEL_PID" || -z "$SENTINEL_WINDOW_ID" ]]; then
    echo "A foreground sentinel window is required for background certification." >&2
    exit 1
fi
case "$SENTINEL_OBSERVED_BUNDLE_ID" in
    "$PLAYGROUND_BUNDLE_ID"|"$TEXTEDIT_BUNDLE_ID"|com.apple.Safari|com.apple.iCal|\
        com.apple.systempreferences|com.apple.calculator|com.apple.ActivityMonitor|com.apple.finder)
        echo "The foreground sentinel must not be one of the eight physical matrix targets." >&2
        exit 1
        ;;
esac
if [[ -n "$SENTINEL_BUNDLE_ID" && "$SENTINEL_OBSERVED_BUNDLE_ID" != "$SENTINEL_BUNDLE_ID" ]]; then
    echo "Required sentinel $SENTINEL_BUNDLE_ID is not already frontmost; refusing to activate it." >&2
    exit 1
fi

launch_owned_background_app playground "$PLAYGROUND_BUNDLE_ID" "$PLAYGROUND_APP" false
cp "$ARTIFACT_ROOT/setup/playground/target-receipt.json" \
    "$ARTIFACT_ROOT/physical-targets/playground.json"

if [[ ! -d "$TEXTEDIT_APP" ]]; then
    echo "TextEdit app not found at $TEXTEDIT_APP." >&2
    exit 2
fi
launch_owned_background_app textedit-maximize "$TEXTEDIT_BUNDLE_ID" "$TEXTEDIT_APP" true
MAXIMIZE_TEXTEDIT_PID="$OWNED_PID"
MAXIMIZE_TEXTEDIT_WINDOW_ID="$OWNED_WINDOW_ID"
jq '.physical_app = "textedit"' \
    "$ARTIFACT_ROOT/setup/textedit-maximize/target-receipt.json" \
    > "$ARTIFACT_ROOT/physical-targets/textedit.json"

launch_owned_background_app textedit-quit "$TEXTEDIT_BUNDLE_ID" "$TEXTEDIT_APP" true
QUIT_TEXTEDIT_PID="$OWNED_PID"
QUIT_TEXTEDIT_PROCESS_START_IDENTITY="$OWNED_PROCESS_START_IDENTITY"

resolve_existing_physical_target safari com.apple.Safari
resolve_existing_physical_target calendar com.apple.iCal
resolve_existing_physical_target settings com.apple.systempreferences
resolve_existing_physical_target calculator com.apple.calculator
resolve_existing_physical_target activity-monitor com.apple.ActivityMonitor
resolve_existing_physical_target finder com.apple.finder

jq -s \
    --argjson expected "$CERTIFICATION_PHYSICAL_APPS_JSON" '
    map({key: .physical_app, value: .}) | from_entries as $targets |
    select(($targets | keys | sort) == ($expected | sort)) |
    {version: 1, targets: $targets}
' \
    "$ARTIFACT_ROOT/physical-targets/playground.json" \
    "$ARTIFACT_ROOT/physical-targets/textedit.json" \
    "$ARTIFACT_ROOT/physical-targets/safari/target-receipt.json" \
    "$ARTIFACT_ROOT/physical-targets/calendar/target-receipt.json" \
    "$ARTIFACT_ROOT/physical-targets/settings/target-receipt.json" \
    "$ARTIFACT_ROOT/physical-targets/calculator/target-receipt.json" \
    "$ARTIFACT_ROOT/physical-targets/activity-monitor/target-receipt.json" \
    "$ARTIFACT_ROOT/physical-targets/finder/target-receipt.json" \
    > "$ARTIFACT_ROOT/physical-targets.json"
if [[ ! -s "$ARTIFACT_ROOT/physical-targets.json" ]]; then
    echo "Physical target setup did not resolve the closed eight-app matrix." >&2
    exit 1
fi

attest_physical_target_binary() {
    local slug="$1"
    local pid executable_receipt executable_path code_signature_hash expected_playground_executable
    pid="$(jq -er --arg slug "$slug" '.targets[$slug].pid' "$ARTIFACT_ROOT/physical-targets.json")"
    executable_receipt="$ARTIFACT_ROOT/physical-targets/$slug-executable.json"
    "$PROBE_BIN" process-executable --pid "$pid" --output "$executable_receipt"
    executable_path="$(jq -er '.path' "$executable_receipt")"
    if [[ "$slug" == playground ]]; then
        expected_playground_executable="$(realpath "$PLAYGROUND_EXECUTABLE")"
        [[ "$(realpath "$executable_path")" == "$expected_playground_executable" ]] || {
            echo "Playground process executable differs from the signed fixture." >&2
            return 1
        }
        codesign --verify --strict "$executable_path"
    else
        codesign --verify --strict -R '=anchor apple' "$executable_path"
    fi
    code_signature_hash="$(read_code_signature_hash "$executable_path")"
    [[ "$code_signature_hash" =~ ^[0-9a-f]{40}$ ]] || return 1
    jq \
        --arg slug "$slug" \
        --arg codeSignatureHash "$code_signature_hash" \
        --slurpfile executable "$executable_receipt" '
        .targets[$slug].executable = {
            path: $executable[0].path,
            sha256: $executable[0].sha256,
            code_signature_hash: $codeSignatureHash
        }
    ' "$ARTIFACT_ROOT/physical-targets.json" > "$ARTIFACT_ROOT/physical-targets.json.tmp"
    mv "$ARTIFACT_ROOT/physical-targets.json.tmp" "$ARTIFACT_ROOT/physical-targets.json"
}

for physical_slug in playground textedit safari calendar settings calculator activity-monitor finder; do
    attest_physical_target_binary "$physical_slug"
done

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
    local stale_window_id=""
    local stale_pid=""
    local physical_app=""
    local physical_target_receipt=null
    local background_target_pid="$PLAYGROUND_PID"
    while true; do
        case "${1:-}" in
            --setup-nonmaximized-window)
                setup_window_id="$2"
                setup_pid="$3"
                shift 3
                ;;
            --setup-stale-window)
                stale_window_id="$2"
                stale_pid="$3"
                shift 3
                ;;
            --physical-app)
                physical_app="$2"
                physical_target_receipt="$(jq -c --arg slug "$2" \
                    '.targets[$slug]' "$ARTIFACT_ROOT/physical-targets.json")"
                background_target_pid="$(jq -er --arg slug "$2" \
                    '.targets[$slug].pid' "$ARTIFACT_ROOT/physical-targets.json")"
                shift 2
                ;;
            --background-target-pid)
                background_target_pid="$2"
                shift 2
                ;;
            *)
                break
                ;;
        esac
    done

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
    local history_commitment="$case_dir/history-commitment.txt"
    local monitor_instance_id
    monitor_instance_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
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
    "$PROBE_BIN" sample --output "$before"
    jq -cn \
        --arg executionNonce "$RUN_EXECUTION_NONCE" \
        --arg monitorInstanceID "$monitor_instance_id" '
        {
            revision: 1,
            executionNonce: $executionNonce,
            monitorInstanceID: $monitorInstanceID,
            producers: [],
            foreground: {active: false, target: null}
        }
    ' > "$allowed_producers"
    jq -cS \
        --arg domain 'peekaboo.background-computer-use.monitor-baseline.v2' \
        --arg executionNonce "$RUN_EXECUTION_NONCE" \
        --arg monitorInstanceID "$monitor_instance_id" \
        --arg caseID "$name" \
        --slurpfile baseline "$before" \
        '{domain: $domain, execution_nonce: $executionNonce,
          monitor_instance_id: $monitorInstanceID, case_id: $caseID,
          baseline: $baseline[0]}' | shasum -a 256 | awk '{print $1}' \
        > "$history_commitment"
    if [[ -z "$(jq -r '.frontmostPID // empty' "$before")" || \
          -z "$(jq -r '.frontmostWindowID // empty' "$before")" || \
          "$(jq -r '.frontmostPID // empty' "$before")" == "$background_target_pid" ]]; then
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
        --execution-nonce "$RUN_EXECUTION_NONCE"
        --monitor-instance-id "$monitor_instance_id"
        --history-commitment "$history_commitment"
        --physical-input-observational
        --cursor-observational
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
    if ! jq -e \
        --arg executionNonce "$RUN_EXECUTION_NONCE" \
        --arg monitorInstanceID "$monitor_instance_id" \
        --arg historyCommitmentSHA256 "$(tr -d '[:space:]' < "$history_commitment")" '
        .executionNonce == $executionNonce and
        .monitorInstanceID == $monitorInstanceID and
        .historyCommitmentSHA256 == $historyCommitmentSHA256 and
        (.authorizationEpoch | type) == "number" and .authorizationEpoch > 0
    ' "$heartbeat" >/dev/null; then
        abort_current_monitor
        record_failure "$name monitor heartbeat was not bound to its execution nonce, instance, and baseline"
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
    cp "$heartbeat" "$case_dir/monitor-start-heartbeat.json"

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
        --arg executionNonce "$RUN_EXECUTION_NONCE" \
        --arg monitorInstanceID "$monitor_instance_id" \
        --argjson remote "$case_remote_receipt" '
        {
            revision: $revision,
            executionNonce: $executionNonce,
            monitorInstanceID: $monitorInstanceID,
            producers: (
                [{pid: $pid, startIdentity: $startIdentity, role: "bridge"}] +
                (if $remote == null then [] else [
                    {pid: $remote.pid, startIdentity: $remote.startIdentity, role: "bridge"}
                ] end)
            ),
            foreground: {active: false, target: null}
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
    local command_started_at_milliseconds
    local command_completed_at_milliseconds
    command_started_at_milliseconds="$(node -e 'process.stdout.write(String(Date.now()))')"
    : > "$command_gate"
    set +e
    wait "$command_pid"
    local command_exit=$?
    set -e
    command_completed_at_milliseconds="$(node -e 'process.stdout.write(String(Date.now()))')"
    jq -n \
        --argjson started "$command_started_at_milliseconds" \
        --argjson completed "$command_completed_at_milliseconds" '
        {
            version: 1,
            started_at_milliseconds: $started,
            completed_at_milliseconds: $completed,
            wall_time_milliseconds: ($completed - $started)
        }
    ' > "$case_dir/command-timing.json"
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
    cp "$heartbeat" "$case_dir/monitor-final-heartbeat.json"
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
    local cursor_movement_observed=false
    if jq -e '.cursorMovementObserved == true' "$heartbeat" >/dev/null 2>&1; then
        cursor_movement_observed=true
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
        if ! delivery_mode="$(resolve_delivery_mode "$result" 2>/dev/null)"; then
            result_contract=false
            delivery_mode=null
            record_failure "$name result carried conflicting canonical and legacy delivery modes"
            failed=true
        fi
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
        --arg physicalApp "$physical_app" \
        --argjson physicalTarget "$physical_target_receipt" \
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
        --argjson cursorMovementObserved "$cursor_movement_observed" \
        --argjson nonmaximizedPrecondition "$nonmaximized_precondition" \
        --argjson snapshotWindowDrift "$snapshot_window_drift" \
        --argjson targetWindowRestored "$target_window_restored" \
        --argjson eventProducer "$case_remote_receipt" \
        --argjson eventProducerStable "$event_producer_stable" \
        --arg executionNonce "$RUN_EXECUTION_NONCE" \
        --arg monitorInstanceID "$monitor_instance_id" \
        --arg historyCommitmentSHA256 "$(tr -d '[:space:]' < "$history_commitment")" \
        --argjson producerRevision "$command_pid" \
        --slurpfile monitorStart "$case_dir/monitor-start-heartbeat.json" \
        --slurpfile monitorFinal "$case_dir/monitor-final-heartbeat.json" \
        '{
            id: $id,
            surface: $surface,
            command: $command,
            phase: $phase,
            physical_app: (if $physicalApp == "" then null else $physicalApp end),
            physical_target: $physicalTarget,
            expected_exit: $expectedExit,
            exit_code: $exitCode,
            result_success: $resultSuccess,
            effect: $effect,
            delivery_mode: $deliveryMode,
            error_code: $errorCode,
            event_producer: $eventProducer,
            event_producer_stable: $eventProducerStable,
            monitor_receipt: {
                execution_nonce: $executionNonce,
                monitor_instance_id: $monitorInstanceID,
                history_commitment_sha256: $historyCommitmentSHA256,
                producer_revision: $producerRevision,
                start: {
                    sequence: $monitorStart[0].sequence,
                    authorization_epoch: $monitorStart[0].authorizationEpoch,
                    producer_revision: $monitorStart[0].allowedProducerRevision,
                    monotonic_microseconds: $monitorStart[0].monotonicMicroseconds,
                    wall_clock_milliseconds: $monitorStart[0].wallClockMilliseconds
                },
                final: {
                    sequence: $monitorFinal[0].sequence,
                    authorization_epoch: $monitorFinal[0].authorizationEpoch,
                    producer_revision: $monitorFinal[0].allowedProducerRevision,
                    monotonic_microseconds: $monitorFinal[0].monotonicMicroseconds,
                    wall_clock_milliseconds: $monitorFinal[0].wallClockMilliseconds
                }
            },
            invariants: $invariants,
            evidence: {
                result_contract: $resultContract,
                monitor_liveness: $monitorLiveness,
                contamination_clear: $contaminationClear,
                desktop_restored: $desktopRestored,
                clipboard_policy: $clipboardPolicy,
                cursor_observational: true,
                cursor_movement_observed: $cursorMovementObserved
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

semantic_witness_value_from_result() {
    local result_file="$1"
    local identifier="$2"
    jq -er --arg identifier "$identifier" '
        [(.data.ui_elements? // .ui_elements? // [])[] |
            select(.identifier == $identifier) |
            select(.ax_role == "AXStaticText") |
            select(.bounds.width > 5 and .bounds.height > 5) |
            .value |
            select(type == "string")] |
        select(length == 1) |
        .[0]
    ' "$result_file"
}

assert_semantic_witness() {
    local case_name="$1"
    local oracle="$2"
    local result_file="$3"
    local identifier="$4"
    local expected="$5"
    local observed
    observed="$(semantic_witness_value_from_result "$result_file" "$identifier" 2>/dev/null || true)"
    if [[ "$observed" != "$expected" ]]; then
        record_case_oracle "$case_name" "$oracle" false || true
        record_failure "$case_name did not expose exact $identifier semantic witness value"
        return 1
    fi
    record_case_oracle "$case_name" "$oracle" true
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

assert_predispatch_foreground_refusal() {
    local case_name="$1"
    local result_file="$2"
    if ! jq -e '
        .success == false and
        .effect == "refused" and
        .error.code == "VALIDATION_ERROR" and
        .outcome.state == "refused" and
        .outcome.effect == "refused" and
        .outcome.dispatch_state == "none" and
        .outcome.refusal_reason == "foreground_consent_required" and
        (.outcome.delivery_mode // null) == null
    ' "$result_file" >/dev/null; then
        record_case_oracle "$case_name" predispatch_refusal false || true
        record_failure "$case_name did not expose a canonical zero-dispatch foreground-consent refusal"
        return 1
    fi
    record_case_oracle "$case_name" predispatch_refusal true
}

assert_background_delivery() {
    local name="$1"
    local result_file="$2"
    local delivery_mode
    if ! delivery_mode="$(resolve_delivery_mode "$result_file" 2>/dev/null)" || \
       [[ "$delivery_mode" != '"background"' ]]; then
        record_case_oracle "$name" background_delivery false || true
        record_failure "$name did not report background delivery"
        return 1
    fi
    record_case_oracle "$name" background_delivery true
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

run_physical_observation() {
    local slug="${1:?Physical app slug required}"
    local case_name="physical-$slug"
    local target
    target="$(jq -cer --arg slug "$slug" '.targets[$slug]' \
        "$ARTIFACT_ROOT/physical-targets.json")"
    local pid process_start_identity window_id artifact case_dir expected_window_title
    pid="$(jq -er '.pid' <<< "$target")"
    process_start_identity="$(jq -er '.process_start_identity' <<< "$target")"
    window_id="$(jq -er '.window_id' <<< "$target")"
    expected_window_title="$(physical_expected_window_title "$slug" 2>/dev/null || true)"
    case_dir="$(case_dir_path "$case_name")"
    artifact="$case_dir/window.png"

    run_checked_case "$case_name" unchanged success \
        --physical-app "$slug" \
        see --no-elements --pid "$pid" --window-id "$window_id" --path "$artifact" || true
    assert_case_artifacts "$case_name" "$artifact" || true

    local generation_file="$case_dir/target-process-identity.json"
    local executable_file="$case_dir/target-process-executable.json"
    local window_readback="$case_dir/target-window-readback.json"
    local selector_readback="$case_dir/target-window-selector-readback.json"
    local target_verified=true
    if ! process_generation_matches \
        "$pid" "$process_start_identity" "$generation_file"; then
        target_verified=false
    fi
    if ! "$PROBE_BIN" process-executable --pid "$pid" --output "$executable_file" || \
       ! jq -e --argjson target "$target" '
            .pid == $target.pid and
            .startIdentity == $target.process_start_identity and
            .path == $target.executable.path and
            .sha256 == $target.executable.sha256
       ' "$executable_file" >/dev/null; then
        target_verified=false
    elif [[ "$(read_code_signature_hash "$(jq -er '.path' "$executable_file")")" != \
        "$(jq -er '.executable.code_signature_hash' <<< "$target")" ]]; then
        target_verified=false
    fi
    if ! pb window list --pid "$pid" --json > "$window_readback"; then
        target_verified=false
    elif [[ -n "$expected_window_title" ]]; then
        if ! exact_named_window_receipt_from_inventory \
            "$window_readback" \
            "$expected_window_title" \
            "$pid" \
            "$(jq -er '.bundle_id' <<< "$target")" \
            "$(jq -er '.application_name' <<< "$target")" \
            > "$selector_readback" ||
           ! exact_window_receipts_match \
            "$ARTIFACT_ROOT/physical-targets/$slug/target-receipt.json" \
            "$selector_readback"; then
            target_verified=false
        fi
    elif ! jq -e --argjson target "$target" '
        any(.data.windows[]?;
            .window_id == $target.window_id and
            .window_title == $target.window_title and
            .bounds == $target.bounds)
    ' "$window_readback" >/dev/null; then
        target_verified=false
    fi
    if ! process_generation_matches \
        "$pid" "$process_start_identity" "$case_dir/target-process-identity-after-window-readback.json"; then
        target_verified=false
    fi
    if ! jq -e --argjson target "$target" --arg artifact "$artifact" '
        ($target.bounds |
            [[.x, .y], [.width, .height]]) as $expectedBounds |
        .success == true and
        (.data.files | length) == 1 and
        .data.files[0].window_id == $target.window_id and
        .data.files[0].path == $artifact and
        .data.files[0].mime_type == "image/png" and
        (.data.observations | length) == 1 and
        .data.observations[0].target.window_id == $target.window_id and
        .data.observations[0].target.resolved_kind == "window-id" and
        .data.observations[0].target.bounds == $expectedBounds and
        .data.observations[0].coordinates.logical_bounds == $expectedBounds
    ' "$LAST_RESULT" >/dev/null; then
        target_verified=false
    fi
    if [[ "$target_verified" != true ]]; then
        record_case_oracle "$case_name" physical_target false || true
        record_failure "$case_name did not preserve its exact process/window receipt"
    else
        record_case_oracle "$case_name" physical_target true
    fi
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

assert_playground_log_unchanged() {
    local case_name="$1"
    local before="$2"
    local after="$3"
    local expected="$4"
    local before_count
    local after_count
    before_count="$(playground_log_count "$before" "$expected")"
    after_count="$(playground_log_count "$after" "$expected")"
    if [[ "$after_count" -ne "$before_count" ]]; then
        record_case_oracle "$case_name" playground_log_unchanged false || true
        record_failure "$case_name changed the PID-scoped Playground log despite pre-dispatch refusal"
        return 1
    fi
    record_case_oracle "$case_name" playground_log_unchanged true
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

for physical_app in playground textedit safari calendar settings calculator activity-monitor finder; do
    run_physical_observation "$physical_app"
done

run_checked_case lifecycle-maximize unchanged success \
    --background-target-pid "$MAXIMIZE_TEXTEDIT_PID" \
    --setup-nonmaximized-window "$MAXIMIZE_TEXTEDIT_WINDOW_ID" "$MAXIMIZE_TEXTEDIT_PID" \
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
    --background-target-pid "$MAXIMIZE_TEXTEDIT_PID" \
    window close --window-id "$MAXIMIZE_TEXTEDIT_WINDOW_ID" || true

run_checked_case lifecycle-quit unchanged either \
    --background-target-pid "$QUIT_TEXTEDIT_PID" \
    app quit --pid "$QUIT_TEXTEDIT_PID" \
    --expected-process-start-identity "$QUIT_TEXTEDIT_PROCESS_START_IDENTITY" || true
assert_lifecycle_quit_outcome lifecycle-quit "$LAST_RESULT" "$QUIT_TEXTEDIT_PID" \
    "$QUIT_TEXTEDIT_PROCESS_START_IDENTITY" || true

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

validate_alert_receipt_directory() {
    local phase="$1"
    local expected_operation="$2"
    local receipt_directory="$3"
    local validator_directory="$4"
    local bundle_files=()
    local bundle
    local matching_operations=0
    mkdir -m 700 "$validator_directory"
    while IFS= read -r -d '' bundle; do
        bundle_files+=("$bundle")
    done < <(find "$receipt_directory" -mindepth 1 -maxdepth 1 -type f -name '*.json' -print0)
    if [[ ${#bundle_files[@]} -eq 0 ]]; then
        record_failure "$phase exported no signed Bridge receipt bundle"
        return 1
    fi
    for bundle in "${bundle_files[@]}"; do
        local validator
        validator="$validator_directory/$(basename "$bundle")"
        if ! pb bridge receipt validate --bundle "$bundle" --json > "$validator" ||
           ! jq -e '.success == true and .data.valid == true' "$validator" >/dev/null; then
            record_failure "$phase retained a bundle that failed live listener validation"
            return 1
        fi
        if [[ "$(jq -r '.data.operation // empty' "$validator")" == "$expected_operation" ]]; then
            matching_operations=$((matching_operations + 1))
        fi
    done
    if [[ $matching_operations -ne 1 ]]; then
        record_failure "$phase did not export exactly one $expected_operation receipt"
        return 1
    fi
}

run_alert_lifecycle_case() {
    local phase="$1"
    local expected_operation="$2"
    shift 2
    local case_name="playground-alert-$phase"
    local receipt_directory="$PLAYGROUND_ALERT_ROOT/receipts/$phase"
    local validator_directory="$PLAYGROUND_ALERT_ROOT/validators/$phase"
    mkdir -m 700 "$receipt_directory"
    if ! PEEKABOO_OPERATION_RECEIPT_DIRECTORY="$receipt_directory" \
        run_checked_case "$case_name" unchanged success "$@"; then
        record_failure "$phase did not complete its monitored CLI command"
        return 1
    fi
    if ! validate_alert_receipt_directory \
        "$phase" "$expected_operation" "$receipt_directory" "$validator_directory"; then
        return 1
    fi
    local archived_case="$PLAYGROUND_ALERT_ROOT/phases/$phase"
    mv "$(case_dir_path "$case_name")" "$archived_case"
    LAST_RESULT="$archived_case/result.json"
    LAST_CASE="$case_name"
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

run_checked_case type-ambiguous-pid-refused unchanged failure \
    type "must-not-route-$RUN_TOKEN" --pid "$PLAYGROUND_PID" || true
assert_result_contains refusal_guidance "$LAST_RESULT" "multiple eligible windows" || true

run_checked_case type-exact-window unchanged success \
    type "$TYPE_TOKEN" --clear --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" || true
assert_background_delivery type-exact-window "$LAST_RESULT" || true
run_checked_case press-exact-window unchanged success \
    press return --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" || true
assert_background_delivery press-exact-window "$LAST_RESULT" || true
run_checked_case press-pid-refused unchanged failure \
    press return --pid "$PLAYGROUND_PID" || true
assert_result_contains refusal_guidance "$LAST_RESULT" "require explicit foreground consent" || true
run_checked_case press-app-refused unchanged failure \
    press return --app "$PLAYGROUND_BUNDLE_ID" || true
assert_result_contains refusal_guidance "$LAST_RESULT" "require explicit foreground consent" || true
run_checked_case paste-text allow-temporary success \
    paste "$PASTE_TOKEN" --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" || true
assert_background_delivery paste-text "$LAST_RESULT" || true

run_checked_case see-text-after-paste unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$TEXT_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/text-after-paste.png" || true
assert_case_artifacts see-text-after-paste "$ARTIFACT_ROOT/text-after-paste.png" || true
assert_result_contains paste_readback "$LAST_RESULT" "$PASTE_TOKEN" || true
assert_semantic_witness \
    press-exact-window submitted_text_witness "$LAST_RESULT" basic-text-last-submitted "$TYPE_TOKEN" || true
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
assert_semantic_witness click-id single_click_witness "$LAST_RESULT" single-click-count "1" || true
CLICK_LOG_AFTER_ID="$ARTIFACT_ROOT/playground-click-after-id.json"
capture_playground_log "$CLICK_LOG_AFTER_ID"
assert_playground_log_delta click-id "$CLICK_LOG_BASELINE" "$CLICK_LOG_AFTER_ID" \
    "Single click on 'Single Click' button" || true
CLICK_QUERY_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"

run_checked_case click-query unchanged success \
    click "Secondary Button" --snapshot "$CLICK_QUERY_SNAPSHOT" \
    --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" || true
assert_background_delivery click-query "$LAST_RESULT" || true
run_checked_case see-click-after-query unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$CLICK_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/click-after-query.png" || true
assert_case_artifacts see-click-after-query "$ARTIFACT_ROOT/click-after-query.png" || true
assert_semantic_witness \
    click-query secondary_click_witness "$LAST_RESULT" secondary-click-count "1" || true
CLICK_LOG_AFTER_QUERY="$ARTIFACT_ROOT/playground-click-after-query.json"
capture_playground_log "$CLICK_LOG_AFTER_QUERY"
assert_playground_log_delta click-query "$CLICK_LOG_AFTER_ID" "$CLICK_LOG_AFTER_QUERY" \
    "Clicked 'Secondary Button'" || true

run_checked_case see-scroll unchanged success \
    see --pid "$PLAYGROUND_PID" --window-id "$SCROLL_WINDOW_ID" \
    --path "$ARTIFACT_ROOT/scroll-see.png" || true
SCROLL_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
VERTICAL_SCROLL_ID="$(element_id_from_result "$LAST_RESULT" vertical-scroll)"
ACTION_STEPPER_ID="$(element_id_from_result "$LAST_RESULT" action-stepper)"
SCROLL_PRESS_ID="$(element_id_from_result "$LAST_RESULT" scroll-to-top)"
SCROLL_WITNESS_BEFORE="$(
    semantic_witness_value_from_result "$LAST_RESULT" vertical-scroll-offset 2>/dev/null || true
)"
ACTION_VALUE_BEFORE="$(
    semantic_witness_value_from_result "$LAST_RESULT" action-stepper-value 2>/dev/null || true
)"
assert_case_artifacts see-scroll "$ARTIFACT_ROOT/scroll-see.png" || true
assert_snapshot_identifiers \
    see-scroll "$SCROLL_SNAPSHOT" "$VERTICAL_SCROLL_ID" "$ACTION_STEPPER_ID" "$SCROLL_PRESS_ID" || true
if [[ -z "$SCROLL_SNAPSHOT" || -z "$VERTICAL_SCROLL_ID" || \
      -z "$ACTION_STEPPER_ID" || -z "$SCROLL_PRESS_ID" ]]; then
    record_failure "scroll fixture snapshot was missing its scroll, stepper, or AXPress target"
else
    SCROLL_LOG_BEFORE="$ARTIFACT_ROOT/playground-scroll-before.json"
    capture_playground_log "$SCROLL_LOG_BEFORE"

    run_checked_case action-press-refused unchanged failure \
        action AXPress --on "$SCROLL_PRESS_ID" --snapshot "$SCROLL_SNAPSHOT" || true
    assert_predispatch_foreground_refusal action-press-refused "$LAST_RESULT" || true
    assert_result_contains refusal_guidance "$LAST_RESULT" "requires --foreground" || true
    record_case_oracle action-press-refused snapshot_only_targeting true

    ACTION_VALUE_EXPECTED=""
    ACTION_VALUE_PRECONDITION=false
    if [[ "$ACTION_VALUE_BEFORE" =~ ^-?[0-9]+$ ]] && ((ACTION_VALUE_BEFORE < 10)); then
        ACTION_VALUE_EXPECTED="$((ACTION_VALUE_BEFORE + 1))"
        ACTION_VALUE_PRECONDITION=true
    else
        record_failure "action stepper did not expose an incrementable exact initial value"
    fi
    ACTION_SNAPSHOT="$SCROLL_SNAPSHOT"
    run_checked_case action unchanged success \
        action AXIncrement --on "$ACTION_STEPPER_ID" --snapshot "$ACTION_SNAPSHOT" || true
    ACTION_RESULT="$LAST_RESULT"
    assert_background_delivery action "$ACTION_RESULT" || true
    record_case_oracle action snapshot_only_targeting true
    if $ACTION_VALUE_PRECONDITION; then
        record_case_oracle action action_value_precondition true
    else
        record_case_oracle action action_value_precondition false || true
    fi
    if [[ "$ACTION_SNAPSHOT" == "$SCROLL_SNAPSHOT" ]] && \
       jq -e '.success == true' "$ACTION_RESULT" >/dev/null 2>&1; then
        record_case_oracle action-press-refused same_snapshot_reuse true
        record_case_oracle action same_snapshot_reuse true
    else
        record_case_oracle action-press-refused same_snapshot_reuse false || true
        record_case_oracle action same_snapshot_reuse false || true
        record_failure "foreground-consent refusal did not preserve the exact snapshot for AXIncrement"
    fi

    run_checked_case see-scroll-after-action unchanged success \
        see --pid "$PLAYGROUND_PID" --window-id "$SCROLL_WINDOW_ID" \
        --path "$ARTIFACT_ROOT/scroll-after-action.png" || true
    assert_case_artifacts see-scroll-after-action "$ARTIFACT_ROOT/scroll-after-action.png" || true
    assert_semantic_witness \
        action-press-refused action_no_effect_readback \
        "$LAST_RESULT" vertical-scroll-offset "$SCROLL_WITNESS_BEFORE" || true
    assert_semantic_witness \
        action action_readback "$LAST_RESULT" action-stepper-value "$ACTION_VALUE_EXPECTED" || true
    SCROLL_LOG_AFTER_ACTION="$ARTIFACT_ROOT/playground-scroll-after-action.json"
    capture_playground_log "$SCROLL_LOG_AFTER_ACTION"
    assert_playground_log_unchanged \
        action-press-refused "$SCROLL_LOG_BEFORE" "$SCROLL_LOG_AFTER_ACTION" "Scrolled to top" || true
    assert_playground_log_delta \
        action "$SCROLL_LOG_BEFORE" "$SCROLL_LOG_AFTER_ACTION" "Action stepper incremented" || true

    SCROLL_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
    VERTICAL_SCROLL_ID="$(element_id_from_result "$LAST_RESULT" vertical-scroll)"
    SCROLL_WITNESS_BEFORE="$(
        semantic_witness_value_from_result "$LAST_RESULT" vertical-scroll-offset 2>/dev/null || true
    )"
    if [[ -z "$SCROLL_SNAPSHOT" || -z "$VERTICAL_SCROLL_ID" ]]; then
        record_failure "post-action scroll snapshot was missing its exact scroll target"
    else
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
        SCROLL_WITNESS_READBACK="$ARTIFACT_ROOT/scroll-semantic-readback.json"
        if ! pb see --tree --no-screenshot --pid "$PLAYGROUND_PID" --window-id "$SCROLL_WINDOW_ID" \
            --json > "$SCROLL_WITNESS_READBACK"; then
            record_last_case_oracle scroll_witness_changed false || true
            record_failure "scroll-action-background could not read the vertical-scroll-offset witness"
        else
            SCROLL_WITNESS_AFTER="$(
                semantic_witness_value_from_result \
                    "$SCROLL_WITNESS_READBACK" vertical-scroll-offset 2>/dev/null || true
            )"
            if [[ ! "$SCROLL_WITNESS_BEFORE" =~ ^-?[0-9]+([.][0-9]{2})?$ ]] ||
               [[ ! "$SCROLL_WITNESS_AFTER" =~ ^-?[0-9]+([.][0-9]{2})?$ ]] ||
               [[ "$SCROLL_WITNESS_AFTER" == "$SCROLL_WITNESS_BEFORE" ]]; then
                record_last_case_oracle scroll_witness_changed false || true
                record_failure "scroll-action-background did not change its exact AX semantic witness"
            else
                record_last_case_oracle scroll_witness_changed true
            fi
        fi
        SCROLL_LOG_AFTER="$ARTIFACT_ROOT/playground-scroll-after.json"
        capture_playground_log "$SCROLL_LOG_AFTER"
        assert_playground_scroll_changed \
            scroll-action-background "$SCROLL_LOG_BEFORE" "$SCROLL_LOG_AFTER" || true
    fi
fi

if [[ -n "$QUALIFICATION_CYCLE" ]]; then
    if $NO_REMOTE; then
        record_failure "final Playground alert qualification requires one signed remote Bridge host"
    else
        PLAYGROUND_ALERT_ROOT="$ARTIFACT_ROOT/playground-alert-lifecycle"
        mkdir -m 700 "$PLAYGROUND_ALERT_ROOT"
        mkdir -m 700 \
            "$PLAYGROUND_ALERT_ROOT/phases" \
            "$PLAYGROUND_ALERT_ROOT/receipts" \
            "$PLAYGROUND_ALERT_ROOT/validators"
        PLAYGROUND_ALERT_BUTTON="OK"
        if ((QUALIFICATION_CYCLE % 2 == 0)); then
            PLAYGROUND_ALERT_BUTTON="Cancel"
        fi
        PLAYGROUND_ALERT_CRASH_DIRECTORY="$HOME/Library/Logs/DiagnosticReports"
        "$PROBE_BIN" process-executable --pid "$PLAYGROUND_PID" \
            --output "$PLAYGROUND_ALERT_ROOT/target-before.json"
        node "$ROOT_DIR/scripts/final-qualification/crash-inventory.mjs" capture \
            --catalog "$ROOT_DIR/scripts/multi-target-certification-catalog.json" \
            --directory "$PLAYGROUND_ALERT_CRASH_DIRECTORY" \
            --output "$PLAYGROUND_ALERT_ROOT/crash-before.json"

        run_alert_lifecycle_case open-fixture-menu clickMenuItem \
            menu click --pid "$PLAYGROUND_PID" --path "Fixtures > Open Dialog Fixture" || true
        run_alert_lifecycle_case open-fixture-window listWindows \
            window list --pid "$PLAYGROUND_PID" || true
        PLAYGROUND_ALERT_WINDOW_ID="$(
            window_id_from_result "$LAST_RESULT" "Dialog Fixture"
        )"
        if [[ -z "$PLAYGROUND_ALERT_WINDOW_ID" ]]; then
            record_failure "Playground alert lifecycle did not resolve one Dialog Fixture window"
        else
            run_alert_lifecycle_case initial-see desktopObservation \
                see --pid "$PLAYGROUND_PID" --window-id "$PLAYGROUND_ALERT_WINDOW_ID" \
                --path "$PLAYGROUND_ALERT_ROOT/initial-see.png" || true
            PLAYGROUND_ALERT_INITIAL_SNAPSHOT="$(snapshot_id_from_result "$LAST_RESULT")"
            PLAYGROUND_ALERT_SHOW_ID="$(
                element_id_from_result "$LAST_RESULT" dialog-fixture-show-alert
            )"
            if [[ -z "$PLAYGROUND_ALERT_INITIAL_SNAPSHOT" || -z "$PLAYGROUND_ALERT_SHOW_ID" ]]; then
                record_failure "Playground alert lifecycle initial See lacked its exact Show Alert snapshot"
            else
                run_alert_lifecycle_case show-alert exactWindowTargetedClick \
                    click --on "$PLAYGROUND_ALERT_SHOW_ID" \
                    --snapshot "$PLAYGROUND_ALERT_INITIAL_SNAPSHOT" \
                    --pid "$PLAYGROUND_PID" --window-id "$PLAYGROUND_ALERT_WINDOW_ID" || true
                run_alert_lifecycle_case dialog-observe targetedDialogListElements \
                    dialog list --pid "$PLAYGROUND_PID" \
                    --window-id "$PLAYGROUND_ALERT_WINDOW_ID" || true
                run_alert_lifecycle_case dismiss exactDialogClickButton \
                    dialog click --button "$PLAYGROUND_ALERT_BUTTON" \
                    --pid "$PLAYGROUND_PID" --window-id "$PLAYGROUND_ALERT_WINDOW_ID" || true
                run_alert_lifecycle_case post-dismiss-ax inspectAccessibilityTree \
                    see --tree --no-screenshot --max-elements 500 \
                    --pid "$PLAYGROUND_PID" --window-id "$PLAYGROUND_ALERT_WINDOW_ID" || true
            fi
        fi

        node "$ROOT_DIR/scripts/final-qualification/crash-inventory.mjs" capture \
            --catalog "$ROOT_DIR/scripts/multi-target-certification-catalog.json" \
            --directory "$PLAYGROUND_ALERT_CRASH_DIRECTORY" \
            --output "$PLAYGROUND_ALERT_ROOT/crash-after.json"
        "$PROBE_BIN" process-executable --pid "$PLAYGROUND_PID" \
            --output "$PLAYGROUND_ALERT_ROOT/target-after.json"
        if ! node "$ROOT_DIR/scripts/final-qualification/crash-inventory.mjs" compare \
            --baseline "$PLAYGROUND_ALERT_ROOT/crash-before.json" \
            --final "$PLAYGROUND_ALERT_ROOT/crash-after.json" \
            --output "$PLAYGROUND_ALERT_ROOT/crash-comparison.json"; then
            record_failure "Playground alert lifecycle produced a new or changed crash report"
        fi
        if ! node "$ROOT_DIR/scripts/final-qualification/playground-alert-lifecycle.mjs" construct \
            --root "$PLAYGROUND_ALERT_ROOT" \
            --physical-targets "$ARTIFACT_ROOT/physical-targets.json" \
            --cycle "$QUALIFICATION_CYCLE" \
            --execution-nonce "$RUN_EXECUTION_NONCE" \
            --peekaboo-source "$PEEKABOO_SOURCE_COMMIT" \
            --bridge-source "$BRIDGE_SOURCE_COMMIT" \
            --button "$PLAYGROUND_ALERT_BUTTON" \
            --output "$PLAYGROUND_ALERT_ROOT/report.json"; then
            record_failure "Playground alert lifecycle evidence could not be closed"
        fi
    fi
fi

sleep 0.3
capture_playground_log "$ARTIFACT_ROOT/playground.json"
assert_playground_log_line type-exact-window playground_log_line \
    "$ARTIFACT_ROOT/playground.json" "Basic text changed" "To: '$TYPE_TOKEN'" || true
assert_playground_log_line press-exact-window playground_log_line \
    "$ARTIFACT_ROOT/playground.json" "Submitted basic text field" "Value: '$TYPE_TOKEN'" || true
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
    "$PROBE_BIN" sample --output "$FOREGROUND_DIR/before-cursor-restore.json"
    if jq -e --slurpfile move "$FOREGROUND_DIR/move.json" '
        ((.cursor.x - $move[0].data.targetLocation.x) | fabs) <= 0.5 and
        ((.cursor.y - $move[0].data.targetLocation.y) | fabs) <= 0.5
    ' "$FOREGROUND_DIR/before-cursor-restore.json" >/dev/null; then
        pb move --at "$ORIGINAL_CURSOR" --foreground --json \
            > "$FOREGROUND_DIR/restore-cursor.json"
    else
        printf '%s\n' \
            '{"restored":false,"reason":"cursor changed after Peekaboo move; refusing to overwrite newer user state"}' \
            > "$FOREGROUND_DIR/restore-cursor-skipped.json"
    fi

    "$PROBE_BIN" sample --output "$FOREGROUND_DIR/before-sentinel-restore.json"
    if jq -e --argjson pid "$PLAYGROUND_PID" '.frontmostPID == $pid' \
        "$FOREGROUND_DIR/before-sentinel-restore.json" >/dev/null; then
        pb window focus --pid "$SENTINEL_PID" --window-id "$SENTINEL_WINDOW_ID" --verify --json \
            > "$FOREGROUND_DIR/restore-sentinel.json"
    else
        printf '%s\n' \
            '{"restored":false,"reason":"frontmost app changed after Peekaboo switch; refusing to overwrite newer user state"}' \
            > "$FOREGROUND_DIR/restore-sentinel-skipped.json"
    fi
fi

OBSERVED_CERTIFICATION="$ARTIFACT_ROOT/certification-observed.json"
CERTIFICATION_RESULT="$ARTIFACT_ROOT/certification.json"
case_summaries=("$ARTIFACT_ROOT"/cases/*/summary.json)
PROVENANCE_STABLE=true
for source_and_digest in \
    "$SOURCE_CATALOG:$CATALOG_SHA256_INITIAL" \
    "$SOURCE_REPORTER:$REPORTER_SHA256_INITIAL" \
    "$SOURCE_PROBE:$PROBE_SOURCE_SHA256_INITIAL" \
    "$SOURCE_HARNESS:$HARNESS_SHA256_INITIAL"; do
    source_path="${source_and_digest%:*}"
    expected_digest="${source_and_digest##*:}"
    if [[ "$(shasum -a 256 "$source_path" | awk '{print $1}')" != "$expected_digest" ]]; then
        record_failure "certification source input changed after its private snapshot: $source_path"
        PROVENANCE_STABLE=false
    fi
done
if [[ "$(shasum -a 256 "$PROBE_BIN" | awk '{print $1}')" != \
        "$PROBE_EXECUTABLE_SHA256_INITIAL" || \
      "$(stat -f '%d' "$PROBE_BIN")" != "$PROBE_EXECUTABLE_DEVICE_INITIAL" || \
      "$(stat -f '%i' "$PROBE_BIN")" != "$PROBE_EXECUTABLE_INODE_INITIAL" ]]; then
    record_failure "Native certification probe executable changed during the matrix"
    PROVENANCE_STABLE=false
fi
if [[ "$(shasum -a 256 "$PEEKABOO_BIN" | awk '{print $1}')" != "$PEEKABOO_EXECUTABLE_SHA256" || \
      "$(read_code_signature_hash "$PEEKABOO_BIN")" != \
        "$PEEKABOO_CODE_SIGNATURE_HASH" || \
      "$(stat -f '%d' "$PEEKABOO_BIN")" != "$PEEKABOO_EXECUTABLE_DEVICE" || \
      "$(stat -f '%i' "$PEEKABOO_BIN")" != "$PEEKABOO_EXECUTABLE_INODE" ]]; then
    record_failure "Peekaboo CLI executable or code signature changed during the matrix"
    PROVENANCE_STABLE=false
fi
if ! $NO_REMOTE; then
    "$PROBE_BIN" process-executable --pid "$BRIDGE_PID" \
        --output "$ARTIFACT_ROOT/bridge-executable-after.json" || true
    if ! jq -e \
        --argjson pid "$BRIDGE_PID" \
        --arg startIdentity "$BRIDGE_START_IDENTITY" \
        --argjson expectedSHA256 "$BRIDGE_EXECUTABLE_SHA256_JSON" '
        .pid == $pid and .startIdentity == $startIdentity and .sha256 == $expectedSHA256
    ' "$ARTIFACT_ROOT/bridge-executable-after.json" >/dev/null 2>&1; then
        record_failure "Pinned Bridge executable or process generation changed during the matrix"
        PROVENANCE_STABLE=false
    fi
    if [[ "$(stat -f '%d' "$BRIDGE_EXECUTABLE_PATH")" != \
          "$(jq -r . <<<"$BRIDGE_EXECUTABLE_DEVICE_JSON")" || \
          "$(stat -f '%i' "$BRIDGE_EXECUTABLE_PATH")" != \
          "$(jq -r . <<<"$BRIDGE_EXECUTABLE_INODE_JSON")" ]]; then
        record_failure "Pinned Bridge executable inode changed during the matrix"
        PROVENANCE_STABLE=false
    fi
fi
PLAYGROUND_CODE_SIGNATURE_HASH="$(read_code_signature_hash "$PLAYGROUND_APP")"
SOURCE_ARTIFACTS_JSON="$(jq -cn \
    --arg catalogSHA256 "$CATALOG_SHA256_INITIAL" \
    --arg reporterSHA256 "$REPORTER_SHA256_INITIAL" \
    --arg probeSourceSHA256 "$PROBE_SOURCE_SHA256_INITIAL" \
    --arg probeExecutableSHA256 "$PROBE_EXECUTABLE_SHA256_INITIAL" \
    --arg harnessSHA256 "$HARNESS_SHA256_INITIAL" \
    --arg cliExecutableSHA256 "$PEEKABOO_EXECUTABLE_SHA256" \
    --arg cliCodeSignatureHash "$PEEKABOO_CODE_SIGNATURE_HASH" \
    --arg cliExecutableDevice "$PEEKABOO_EXECUTABLE_DEVICE" \
    --arg cliExecutableInode "$PEEKABOO_EXECUTABLE_INODE" \
    --argjson bridgeExecutableSHA256 "$BRIDGE_EXECUTABLE_SHA256_JSON" \
    --argjson bridgeCodeSignatureHash "$BRIDGE_CODE_SIGNATURE_HASH_JSON" \
    --argjson bridgeExecutableDevice "$BRIDGE_EXECUTABLE_DEVICE_JSON" \
    --argjson bridgeExecutableInode "$BRIDGE_EXECUTABLE_INODE_JSON" \
    --arg playgroundSourceTree "$PLAYGROUND_SOURCE_TREE" \
    --arg playgroundExecutableSHA256 "$(shasum -a 256 "$PLAYGROUND_EXECUTABLE" | awk '{print $1}')" \
    --arg playgroundCodeSignatureHash "$PLAYGROUND_CODE_SIGNATURE_HASH" '
    {
        catalog_sha256: $catalogSHA256,
        reporter_sha256: $reporterSHA256,
        probe_source_sha256: $probeSourceSHA256,
        probe_executable_sha256: $probeExecutableSHA256,
        harness_sha256: $harnessSHA256,
        cli_executable_sha256: $cliExecutableSHA256,
        cli_code_signature_hash: $cliCodeSignatureHash,
        cli_executable_device: $cliExecutableDevice,
        cli_executable_inode: $cliExecutableInode,
        bridge_executable_sha256: $bridgeExecutableSHA256,
        bridge_code_signature_hash: $bridgeCodeSignatureHash,
        bridge_executable_device: $bridgeExecutableDevice,
        bridge_executable_inode: $bridgeExecutableInode,
        playground_source_tree: $playgroundSourceTree,
        playground_executable_sha256: $playgroundExecutableSHA256,
        playground_code_signature_hash: $playgroundCodeSignatureHash
    }
')"
jq -s \
    --slurpfile probe "$ARTIFACT_ROOT/probe-self-test.json" \
    --arg cliSourceCommit "$PEEKABOO_SOURCE_COMMIT" \
    --arg eventProducerSource "$EVENT_PRODUCER_SOURCE" \
    --arg eventProducerSourceCommit "$EVENT_PRODUCER_SOURCE_COMMIT" \
    --arg requestedBridgeSocket "$BRIDGE_SOCKET" \
    --argjson remoteHost "$REMOTE_EVENT_PRODUCER_JSON" \
    --argjson sourceArtifacts "$SOURCE_ARTIFACTS_JSON" \
    --argjson provenanceStable "$PROVENANCE_STABLE" \
    '{
        probe_canary: ($probe[0].success == true),
        provenance_stable: $provenanceStable,
        provenance: {
            cli_source_commit: $cliSourceCommit,
            event_producer_source: $eventProducerSource,
            event_producer_source_commit: $eventProducerSourceCommit,
            requested_bridge_socket: (
                if $eventProducerSource == "remote" then $requestedBridgeSocket else null end
            ),
            remote_host: $remoteHost,
            source_artifacts: $sourceArtifacts
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
CURSOR_MOVEMENT_OBSERVED="$(jq -s \
    'any(.[]; .evidence.cursor_movement_observed == true)' \
    "${case_summaries[@]}")"
jq -n \
    --arg peekaboo "$(head -n 1 "$ARTIFACT_ROOT/peekaboo-version.txt")" \
    --arg sourceCommit "$PEEKABOO_SOURCE_COMMIT" \
    --arg playgroundBundle "$PLAYGROUND_BUNDLE_ID" \
    --argjson playgroundPID "$PLAYGROUND_PID" \
    --argjson sentinelPID "$SENTINEL_PID" \
    --argjson sentinelWindowID "$SENTINEL_WINDOW_ID" \
    --argjson cases "$CASE_COUNT" \
    --argjson failures "$FAILURES" \
    --argjson cursorMovementObserved "$CURSOR_MOVEMENT_OBSERVED" \
    --argjson foregroundPhase "$RUN_FOREGROUND_PHASE" \
    --slurpfile certification "$CERTIFICATION_RESULT" \
    --slurpfile physicalTargets "$ARTIFACT_ROOT/physical-targets.json" \
    '{
        success: ($failures == 0),
        peekaboo: $peekaboo,
        source_commit: $sourceCommit,
        playground: {bundle_id: $playgroundBundle, pid: $playgroundPID},
        sentinel: {pid: $sentinelPID, window_id: $sentinelWindowID},
        cases: $cases,
        failures: $failures,
        cursor_observational: true,
        cursor_movement_observed: $cursorMovementObserved,
        physical_targets: $physicalTargets[0],
        foreground_phase: $foregroundPhase,
        certification: $certification[0]
    }' > "$ARTIFACT_ROOT/summary.json"

if [[ $FAILURES -ne 0 ]]; then
    echo "$FAILURES background computer-use checks failed; see $ARTIFACT_ROOT" >&2
    exit 1
fi

echo "Background computer-use validation passed ($CASE_COUNT cases): $ARTIFACT_ROOT"
