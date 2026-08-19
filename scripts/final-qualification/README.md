# Peekaboo final qualification tools

These source-owned tools close the final physical qualification handshakes. They do not install, sign, launch a GUI app, change TCC, synthesize input, stop an unrelated process, or publish anything. The managed-launch guardian can terminate and reap only the exact child it created. The only tool that observes live input is the explicitly invoked native emitter calibrator; its event tap is passive (`listenOnly`) and excludes mouse-move and button/key-up events. The process-tree collector only reads native process ancestry and signed identities for caller-supplied task roots. Its native kqueue guard continuously observes and fails on fork, exec, or exit lifecycle activity from those exact roots and their initially observed descendants while coverage is active; it never scans, stops, or adopts unrelated ambient services.

All JSON inputs and outputs must be absolute, canonical, current-user-owned regular files under mode-0700 directories. Raw/private inputs must be mode 0600 (0400 is also accepted), non-symlink, non-hardlinked, bounded, and stable across the read. Outputs must not exist. Executables may be readable by others but may not be group/other-writable.

## Freeze and test the tools

```bash
TOOLS="$(git rev-parse --show-toplevel)/scripts/final-qualification"
node --check "$TOOLS/project-live-bindings.mjs"
node --check "$TOOLS/construct-live-plan.mjs"
node --check "$TOOLS/crash-inventory.mjs"
node --check "$TOOLS/playground-alert-lifecycle.mjs"
node --check "$TOOLS/publish-coordinator-marker.mjs"
node --check "$TOOLS/publish-agent-execution-acknowledgement.mjs"
node --check "$TOOLS/managed-launcher.mjs"
node --check "$TOOLS/validate-concurrent-run.mjs"
node --check "$TOOLS/qualification-manifest.mjs"
node --check "$TOOLS/process-tree-collector.mjs"
node --check "$TOOLS/executable-policy-scanner.mjs"
node "$TOOLS/process-tree-collector.mjs" --self-test
LIFECYCLE_SELFTEST_ROOT="$(mktemp -d /private/tmp/peekaboo-lifecycle-self-test.XXXXXX)"
chmod 700 "$LIFECYCLE_SELFTEST_ROOT"
trap 'rm -rf -- "$LIFECYCLE_SELFTEST_ROOT"' EXIT
xcrun cc -std=c11 -Wall -Wextra -Werror \
  "$TOOLS/process-lifecycle-guard.c" \
  -o "$LIFECYCLE_SELFTEST_ROOT/process-lifecycle-guard"
"$LIFECYCLE_SELFTEST_ROOT/process-lifecycle-guard" --self-test
node --test "$TOOLS/test/qualification-tools.test.mjs"
shasum -a 256 "$TOOLS"/*.{c,mjs,swift} "$TOOLS/test/qualification-tools.test.mjs"
rm -rf -- "$LIFECYCLE_SELFTEST_ROOT"
trap - EXIT
```

The test suite compiles the native calibrator and runs only its `--self-test`; it never creates an event tap or touches UI. The lifecycle guard self-test watches its own controlled fork and reaps only that task-owned child.

## 1. Calibrate the actual integrated Computer Use emitter

Build both architectures from the retained source, combine them once, then sign the immutable result. Replace the signing placeholders only with the already-approved Developer ID values used for the qualification helpers.

```bash
TOOLS="$(git rev-parse --show-toplevel)/scripts/final-qualification"
CAL_ROOT="$EVIDENCE_ROOT/emitter-calibrator"
mkdir -m 700 "$CAL_ROOT"

xcrun swiftc -O -whole-module-optimization -target arm64-apple-macos14.0 \
  "$TOOLS/integrated-cu-emitter-calibrator.swift" \
  -o "$CAL_ROOT/calibrator-arm64" \
  -framework AppKit -framework CoreGraphics -framework CryptoKit -framework Security
xcrun swiftc -O -whole-module-optimization -target x86_64-apple-macos14.0 \
  "$TOOLS/integrated-cu-emitter-calibrator.swift" \
  -o "$CAL_ROOT/calibrator-x86_64" \
  -framework AppKit -framework CoreGraphics -framework CryptoKit -framework Security
lipo -create "$CAL_ROOT/calibrator-arm64" "$CAL_ROOT/calibrator-x86_64" \
  -output "$CAL_ROOT/integrated-cu-emitter-calibrator"

"$CAL_ROOT/integrated-cu-emitter-calibrator" --self-test
MAC_RELEASE_CODESIGN_IDENTITY="$PEEKABOO_CERT_SIGN_IDENTITY" \
  /Users/steipete/Projects/peekaboo/scripts/codesign-with-retry.sh \
    --force --options runtime --timestamp="$CODESIGN_TIMESTAMP_URL" \
    --sign "$PEEKABOO_CERT_SIGN_IDENTITY" \
    --identifier boo.peekaboo.integrated-cu-emitter-calibrator \
    "$CAL_ROOT/integrated-cu-emitter-calibrator"
codesign --verify --strict -R="anchor apple generic and certificate leaf[subject.OU] = \\
\"$PEEKABOO_CERT_TEAM_ID\"" "$CAL_ROOT/integrated-cu-emitter-calibrator"
chmod -R a-w "$CAL_ROOT"
```

Run it in a managed foreground terminal session only after the disposable semantic target is already the exact frontmost PID/window. Then perform exactly one simple integrated Computer Use action on that controlled target. A single click-down, key-down, flags-change, or scroll event is eligible; mouse move and up events are ignored. More than one eligible event during the settle window fails.

```bash
EMITTER_RECEIPT="$EVIDENCE_ROOT/integrated-cu-emitter-calibration.json"
"$CAL_ROOT/integrated-cu-emitter-calibrator" \
  --target-pid "$FOREGROUND_TARGET_PID" \
  --target-start-identity "$FOREGROUND_TARGET_START" \
  --target-window-id "$FOREGROUND_TARGET_WINDOW" \
  --timeout-seconds 30 \
  --settle-milliseconds 500 \
  --output "$EMITTER_RECEIPT"
```

The helper never accepts an emitter PID. It obtains the actual `CGEvent` source PID, samples its native process-start identity in the callback, and authenticates the same live/on-disk executable before and after the settle window using an Apple-anchored Security.framework requirement, Team ID, CDHash, signing identifier, canonical executable path, and SHA-256. It refuses its own PID and the target PID.

macOS exposes the source PID only when the event is delivered, so there is no truthful pre-event identity sample for a previously unknown emitter. `source_start_identity_at_callback`, `before`, and `after` are the strongest native bracket. The final live coordinator independently revalidates the calibrated PID/generation/Team/CDHash immediately before launch. If a passive event tap is denied, calibration hard-stops with an Input Monitoring diagnostic; do not infer the Codex app, wrapper, cursor owner, or another PID.

## 2. Project raw receipts into `LIVE_BINDINGS`

The projector accepts no identity literals in its input. `receipts.integrated_cu_emitter` is the calibrator output above. Each target uses the native monitor's exact `{pid,startIdentity}` output plus a `peekaboo window list --pid ... --json` result with `inventory_completeness:"complete"`, an empty `inventory_warnings` list, and exactly one window whose `target_application_info.pid` matches. A partial catalog or any omitted-row warning is rejected before the projector considers the row count. The semantic receipt is a closed owner projection of a fresh exact-target AX readback:

```json
{
  "version": 1,
  "target": {"pid": 203, "start_identity": "203001", "window_id": 303},
  "focused_element": {
    "role": "AXTextArea",
    "identifier": "stable-identifier",
    "title": null,
    "frame": {"x": 10, "y": 20, "width": 300, "height": 100}
  },
  "baseline_value": "fresh nonempty value"
}
```

`projection-input.json` has this exact shape; every string value shown as a path is an absolute receipt/artifact path, not an identity value:

```json
{
  "version": 1,
  "paths": {
    "catalog": "/absolute/peekaboo/scripts/multi-target-certification-catalog.json",
    "runs_directory": "/private/.../live-v4-runs",
    "peekaboo_executable": "/private/.../peekaboo",
    "controller_executable": "/private/.../peekaboo-certification-controller",
    "monitor_executable": "/private/.../background-computer-use-probe",
    "crash_directory": "/Users/OWNER/Library/Logs/DiagnosticReports"
  },
  "receipts": {
    "bridge_status": "/private/.../bridge-status.json",
    "controller_a": {"process_identity": "/private/.../a-process.json", "window_inventory": "/private/.../a-windows.json"},
    "controller_b": {"process_identity": "/private/.../b-process.json", "window_inventory": "/private/.../b-windows.json"},
    "observer": {"process_identity": "/private/.../observer-process.json", "window_inventory": "/private/.../observer-windows.json"},
    "sentinel": {"process_identity": "/private/.../sentinel-process.json", "window_inventory": "/private/.../sentinel-windows.json"},
    "observer_semantic": "/private/.../observer-semantic.json",
    "integrated_cu_emitter": "/private/.../integrated-cu-emitter-calibration.json",
    "monitor_codesign": "/private/.../monitor-codesign.txt"
  },
  "timeouts": {
    "external_foreground_timeout_seconds": 90,
    "operation_timeout_seconds": 360,
    "monitor_interval_milliseconds": 10
  }
}
```

Generate the bindings, then pass them through the already-reviewed plan constructor:

```bash
node "$TOOLS/project-live-bindings.mjs" \
  --input "$EVIDENCE_ROOT/projection-input.json" \
  --output "$EVIDENCE_ROOT/live-v4-bindings.json"
node "$TOOLS/construct-live-plan.mjs" construct \
  --bindings "$EVIDENCE_ROOT/live-v4-bindings.json" \
  --output "$EVIDENCE_ROOT/live-v4-plan.json"
```

The projector derives controller click points from exact window centers, obtains Bridge Team trust from the source catalog, and takes the monitor CDHash from raw `codesign -dvvv` output with an Apple Root CA chain. It rejects a second eligible window, target/emitter reuse, semantic-frame mismatch, unsafe paths, noncanonical DiagnosticReports, a status handshake other than protocol 1.31, or any identity drift. The live-v4 controller still deliberately opens its separate exact protocol-1.30 session for the cataloged click and held-pointer contracts.

## 3. Publish coordinator markers after readback

For `perform`, the readback evidence has the exact common fields below plus `expected_value_sha256` and `observed_value_sha256`, both SHA-256 of the owner window's `request_marker`. For `restore`, replace `expected_value_sha256` with `baseline_value_sha256`, set `observed_value_sha256` to the same digest, and add the exact `sentinel` target plus `observed_sentinel:{pid,start_identity,window_id}`. `emitter` is copied from the calibrated receipt; it is not typed or inferred.

```json
{
  "version": 1,
  "execution_nonce": "64-lower-hex",
  "monitor_instance_id": "uuid",
  "phase": "perform",
  "window_path": "/private/.../external-foreground-window.json",
  "emitter": {"pid": 205, "start_identity": "205001", "team_id": "TENCHARID1", "code_signature_hash": "40-lower-hex"},
  "target": {"scope": "window", "pid": 203, "start_identity": "203001", "window_id": 303, "bounds": {"x": 0, "y": 0, "width": 400, "height": 300}, "is_minimized": false},
  "observed_at_milliseconds": 1900000000000,
  "passed": true,
  "expected_value_sha256": "64-lower-hex",
  "observed_value_sha256": "64-lower-hex"
}
```

Only after fresh integrated Computer Use readback writes that file:

```bash
node "$TOOLS/publish-coordinator-marker.mjs" \
  --window "$LIVE_RUN_ROOT/external-foreground-window.json" \
  --readback "$EVIDENCE_ROOT/integrated-cu-perform-readback.json"

node "$TOOLS/publish-coordinator-marker.mjs" \
  --window "$LIVE_RUN_ROOT/external-foreground-window.json" \
  --readback "$EVIDENCE_ROOT/integrated-cu-restore-readback.json"
```

The tool accepts only the coordinator's exact phase-dependent window schema, canonical sibling marker path, matching nonce/monitor/target/sentinel, a passing before-deadline readback, and an absent output. It publishes complete bytes through the retained `atomic-publish-no-replace.swift` helper using Darwin `renameatx_np(RENAME_EXCL)`; a pre-existing marker cannot be overwritten.

## 4. Launch the coordinator and authorize one Bridge-owned Agent terminal request

`managed-launcher.mjs` is coordinator-only. It never invokes a shell or detaches, and it rejects `kind:"agent"`. It compiles the retained `managed-launch-suspended.c` guardian in a fresh private directory, stages owner-read-only copies of the coordinator source and plan, authenticates the exact signed monitor while the child is suspended, and releases only the measured PID/generation and invocation digest. The guardian owns that coordinator through bounded wait/TERM/KILL. Its closed spec uses `kind:"coordinator"`, the exact current Node executable, exactly `arguments:[COORDINATOR_SOURCE,"--plan",LIVE_PLAN]`, and `context:{"coordinator_source_path":COORDINATOR_SOURCE}`. The invocation receipt binds the executed source and plan digests with `execution_staged:true`; the exit receipt supplies zero-exit authority; and `stdout_path` is the authoritative `live-v4-events.jsonl`:

```bash
node "$TOOLS/managed-launcher.mjs" --spec "$EVIDENCE_ROOT/coordinator-launch-spec.json"
```

The Agent has no separate launcher, invocation receipt, process receipt, or exit receipt. Protocol 1.31 makes the entire Agent lifetime one authenticated Bridge request. The task is not prose: retain one closed version-1 JSON contract as canonical compact UTF-8 plus exactly one terminal newline. Its two ordered targets must be copied from the plan's `controller-a`/`controller-b` controlled-fixture bindings, while each expected value comes from the fresh baseline and intended postcondition for that exact target. The five evidence-checkpoint slots and all fixed constraints/postconditions below are mandatory; do not paraphrase or add keys. The expanded object is shown only for readability: serialize it with `canonicalBytes` from `lib.mjs`, then append one LF. The expanded representation itself is not a valid retained task.

```json
{
  "version": 1,
  "kind": "peekaboo-concurrent-agent-qualification",
  "goal": "two-target-background-mutate-verify-restore-with-concurrent-cu",
  "constraints": {
    "delivery_mode": "background",
    "foreground": "forbidden",
    "progress_interleaving": "before-and-after-integrated-cu",
    "shell": "forbidden",
    "skips_and_failures": "forbidden"
  },
  "targets": [
    {
      "label": "target-a",
      "target": {"pid": 301, "start_identity": "301001", "window_id": 401},
      "steps": [
        {"phase": "baseline", "expected_value": "alpha"},
        {"phase": "mutate", "family": "set_value", "expected_value": "alpha!"},
        {"phase": "verify-mutated", "expected_value": "alpha!"},
        {"phase": "restore", "family": "set_value", "expected_value": "alpha"},
        {"phase": "verify-restored", "expected_value": "alpha"}
      ]
    },
    {
      "label": "target-b",
      "target": {"pid": 302, "start_identity": "302001", "window_id": 402},
      "steps": [
        {"phase": "baseline", "expected_value": "beta"},
        {"phase": "mutate", "family": "paste", "expected_value": "beta!"},
        {"phase": "verify-mutated", "expected_value": "beta!"},
        {"phase": "restore", "family": "type", "expected_value": "beta"},
        {"phase": "verify-restored", "expected_value": "beta"}
      ]
    }
  ],
  "postconditions": {
    "all_targets_restored": true,
    "cleanup": "restore-exact-baselines",
    "exact_dispatched_mutation_count": 4,
    "exact_target_count": 2,
    "minimum_primary_mutation_family_count": 2,
    "novel_restoration_family_required": true,
    "target_b_distinct_restoration_family": true
  }
}
```

The example identities and values are illustrative; the retained contract must use the current run's plan and readbacks. `mutate` and `restore` are the four Agent dispatches. `baseline`, `verify-mutated`, and `verify-restored` precommit the owner semantic-readback checkpoints that bracket those dispatches; they are not represented as separate Agent trace calls. Create a canonical owner-owned mode-0700 run root, load the task file without its terminal newline into `AGENT_TASK_TEXT`, and start the hidden qualification adapter in a second attached PTY. Its stdout is the canonical signed terminal bundle:

```bash
umask 077
AGENT_RUN_ROOT="$EVIDENCE_ROOT/agent-execution"
mkdir -m 700 "$AGENT_RUN_ROOT"
AGENT_TASK_TEXT="$(/bin/cat "$EVIDENCE_ROOT/agent-task.txt")"

"$PEEKABOO_BIN" bridge _agent-execution-trace \
  --task "$AGENT_TASK_TEXT" \
  --run-root "$AGENT_RUN_ROOT" \
  --bridge-socket "$BRIDGE_SOCKET" \
  --max-steps 40 \
  --start-timeout-seconds 30 \
  --run-timeout-seconds 900 \
  > "$EVIDENCE_ROOT/agent-terminal-bundle.json"
```

The host derives the executable from the authenticated CLI requester and accepts no executable path, arbitrary argv, caller-selected environment, Shell, AppleScript, JXA, or foreground authority. It starts the exact fixed `agent run TASK --no-cache --max-steps 40 --bridge-socket SOCKET --json` child in a fresh session, enters the earliest CLI gate, irreversibly sets both `RLIMIT_NPROC` limits to zero, and publishes `agent-execution-coordination.json`. The child remains blocked on the anonymous release pipe; `SIGCONT` alone cannot route the command.

After coordination appears, construct the local/during process-tree spec from its exact signed requester and child identities plus the coordinator, Bridge, elevation helper, both controlled fixtures, and integrated-CU emitter. Set `ready_path` to an absent private path and `acknowledgement_path` to the coordination receipt's canonical `agent-execution-ack.json`. Start the collector in a third attached PTY:

```bash
node "$TOOLS/process-tree-collector.mjs" \
  --spec "$EVIDENCE_ROOT/local-during-process-spec.json" \
  --monitor "$MONITOR_BIN" \
  --output "$EVIDENCE_ROOT/local-during-process-tree.json"
```

The collector starts the native lifecycle guard before its first authenticated sample and atomically publishes readiness only after requester, Agent, and every other declared root are continuously covered. Authorize release through the source-owned helper; it validates the coordination bytes, live signed identities, canonical control paths, collector/guard/monitor sources, and the initial process inventory. It stages the acknowledgement, but the still-active lifecycle guard alone may publish it after draining pending events:

```bash
node "$TOOLS/publish-agent-execution-acknowledgement.mjs" \
  --coordination "$AGENT_RUN_ROOT/agent-execution-coordination.json" \
  --readiness "$EVIDENCE_ROOT/local-during-process-ready.json" \
  --output "$AGENT_RUN_ROOT/agent-execution-ack.json"
```

A fork, exec, or exit observed before authorization, stale readiness, a pre-existing control path, or stop-before-authorization prevents acknowledgement. After guard publication, the host atomically installs the fresh nested receipt directory and releases the Agent. Keep the collector active across the complete concurrent operation interval: any later lifecycle event, root drift, or executable drift fails the final process-tree receipt even though release has already occurred. A successful Bridge terminal response follows `waitid(..., WNOWAIT)` with exact `waitpid`; on wait-anchor failure, signed failure may return while exact-generation reaper custody continues asynchronously. Cancellation, timeout, and overflow remain attached to the same leader. Once the command completes, validate its bundle against the same live listener and retain the minimized report:

```bash
"$PEEKABOO_BIN" bridge receipt validate \
  --bundle "$EVIDENCE_ROOT/agent-terminal-bundle.json" \
  --bridge-socket "$BRIDGE_SOCKET" \
  --json > "$EVIDENCE_ROOT/agent-terminal-validator.json"
```

## 5. Validate the completed concurrent run

`concurrent-validation-input.json` is closed:

```json
{
  "version": 1,
  "plan": "/private/.../live-v4-plan.json",
  "coordinator_invocation": "/private/.../coordinator-invocation.json",
  "coordinator_events": "/private/.../live-v4-events.jsonl",
  "coordinator_exit": "/private/.../coordinator-exit.json",
  "agent_task": "/private/.../agent-task.txt",
  "agent_run_root": "/private/.../agent-execution",
  "agent_execution_bundle": "/private/.../agent-terminal-bundle.json",
  "agent_execution_validator_report": "/private/.../agent-terminal-validator.json",
  "agent_bundles": [
    {"bundle_path": "/private/.../agent-execution/agent-operation-receipts/REQUEST.json", "validator_report_path": "/private/.../agent-validators/REQUEST.json"}
  ],
  "agent_readbacks": "/private/.../agent-readbacks.json",
  "integrated_cu": {
    "emitter": "/private/.../integrated-cu-emitter-calibration.json",
    "perform_readback": "/private/.../integrated-cu-perform-readback.json",
    "restore_readback": "/private/.../integrated-cu-restore-readback.json"
  }
}
```

The coordinator launcher still writes the only standalone invocation and exit receipts. Successful qualification requires its exit code 0 with no signal. The Agent's outer protocol-1.31 terminal bundle replaces every legacy Agent launcher artifact. Live authentication must prove the connected listener, requester, child PID/generation/CDHash, fixed nine-argument background-only invocation, task/run-root/socket commitments, closed environment policy, `processCreationLimit:0`, exact coordination and acknowledgement bytes, and complete bounded stdout/stderr. A successful terminal response must be `processDisposition:"exited"`, exit code 0, no signal, `outputDisposition:"validated_execution_trace"`, and carry an untruncated execution trace identical to the trace decoded from stdout. Any cleanup, wait-anchor, output, or protocol failure is terminal and cannot be resealed by caller-authored JSON. Manifest validation later proves that the lifecycle guard published those exact signed acknowledgement bytes.

`agent-readbacks.json` contains exactly two ordered targets (`target-a`, `target-b`). Each identity must equal both the same-ID task-contract target and the controlled target already projected into the live-v4 plan for `controller-a` or `controller-b`; an unrelated, swapped, recycled-generation, or different-window claim fails even when every Agent trace, bundle, validator, task, and readback is consistently resealed. The source-owned final certification summary must independently carry the matching same-ID `target_sha256` over the full exact-window target, and the local/during process tree must contain both PID generations as candidate Playground fixture roots. Each readback entry has exact `{pid,start_identity,window_id}`, `baseline_readback_path`, and `mutation`/`restoration` objects with `{trace_call_id,family,readback_path,bundle_path,validator_report_path}`. Each referenced semantic readback is closed `{version,target,phase,value,observed_at_milliseconds,passed}` with phases `baseline`, `mutated`, or `restored`; hashes are derived from those actual bytes and values, never accepted as caller claims. Those values and operation families must equal the signed task's explicit baseline/mutate/verify/restore/verify expectations. Qualification actions are restricted to `set_value`, `type`, and `paste`: `set_value` and `type` must carry explicit nonempty snapshot selectors, while `paste` must carry the exact PID/window. The validator decodes each authenticated bundle's signed canonical Bridge request and binds those sanitized trace selectors to the signed request; every resulting trace/request binding must be unique. A caller-authored call-ID-to-bundle map therefore cannot substitute a valid target receipt for a trace call aimed elsewhere. The baseline observation must strictly precede mutation dispatch, mutation observation must strictly follow mutation completion and precede restoration dispatch, and the restoration observation must strictly follow restoration completion; zero-duration dispatch receipts fail. Every bundle is revalidated by the exact source-bound Peekaboo executable against the exact authenticated live Bridge socket and host policy; the retained validator JSON must equal that fresh result but is never itself a trust anchor. Each signed bundle must carry the Agent PID/start generation as its client, match the trace/readback PID/window and operation family, prove a definite background dispatch, and fall wholly inside `operations-start..operations-complete`. Bundle SHA-256 values, authenticated listener/request identities, and authenticated listener/session/sequence claims are corpus-unique, so copied or hard-linked files cannot provide a second receipt or remap one receipt to another trace call. The receipt-directory inventory and `agent_bundles` list must be identical, including observation bundles; any unlisted or unmapped dispatched bundle fails.

Exactly four—and only four—trace call IDs may report `mutationDispatch:"dispatched"`: mutate and restore for target A, then mutate and restore for target B, in the signed task order. The two controlled fixtures must be distinct process generations/windows and disjoint from the Bridge host, observer/foreground target, integrated-CU emitter, and sentinel infrastructure. Both primary mutations must use different families; at least one restoration family must be outside the primary-family set, and target B's restoration must differ from its primary mutation. The validation report records the task file SHA-256, signed task SHA-256, canonical semantic-contract SHA-256, fixed constraints/postconditions, plan-derived targets, family choices, and hashes of all expected values. Manifest generation and read-only verification do not trust that projection: both reparse the retained canonical task against the bound plan, independently regenerate the complete projection, compare it to the report, bind it back to the terminal response, and then regenerate the remaining semantic validation from the retained trace, bundles, and readbacks.

```bash
node "$TOOLS/validate-concurrent-run.mjs" \
  --input "$EVIDENCE_ROOT/concurrent-validation-input.json" \
  --output "$EVIDENCE_ROOT/agent-cu-validation-report.json"
```

Success requires the exact four-event coordinator lifecycle ending in eligible `completed` with the summary's exact size and SHA-256, a closed version-2 certification summary whose structural, foreground-postcondition, slot, first-party, and offline sub-gates all passed with no failures, coordinator zero exit, one authenticated protocol-1.31 Agent terminal success, exactly four mapped and signed background mutations with no extra dispatch, six in-window semantic readbacks on the two authenticated, physically disjoint controlled fixtures, an untruncated trace with no Shell/foreground/skipped/failed/possibly-dispatched call, the calibrated emitter, both integrated-CU readbacks, and a signed Agent lifetime covering the entire authoritative `operations-start` through `operations-complete` monitor interval. The terminal bundle's inner coordination and acknowledgement child/requester identities must equal the outer receipt. At least one signed Agent mutation must complete strictly before the integrated-CU perform readback and at least one must start strictly afterward; shared process lifetime or equal boundary timestamps are not accepted as concurrent progress. The integrated-CU perform timestamp must be within two seconds of the retained readback file mtime, and both values form the authenticated interleaving pivot. Manifest generation and verification independently rederive that pivot, bind the terminal identities and acknowledgement to the local/during readiness roots and guard authorization, and recheck the Agent action intervals, closed summary success and event commitment, controlled-fixture ownership, readback/dispatch order, and fresh live bundle authentication instead of trusting the concurrent report or caller-authored validator JSON.

## 6. Generate and verify the final qualification manifest

First create the immutable, self-verifying source manifest for the frozen qualification tools. The file order is part of the aggregate:

```bash
node "$TOOLS/qualification-manifest.mjs" tooling \
  --directory "$(git rev-parse --show-toplevel)" \
  --source-commit "$PEEKABOO_FINAL_SHA" \
  --output "$EVIDENCE_ROOT/qualification-tools-source.json"

chmod 400 "$EVIDENCE_ROOT/qualification-tools-source.json"
```

The source manifest accepts only the repository's exact clean `HEAD`. Every listed byte is compared with its tracked Git blob before creation and on every verification; a 40-hex label, dirty or untracked file, skip-worktree substitution, stale commit, or later `HEAD` change fails closed. The canonical list includes the final-qualification tools, deterministic policy scanner, monitor source, and monitor catalog.

The manifest input is version 2 and has exact top-level keys `version`, `artifact_manifest`, `deployment`, `tooling`, `live_v4`, `matrix_cycles`, `agent_cu`, `adjuncts`, and `restoration_cleanup`. `artifact_manifest` names a version-2 cross-artifact binding that carries the deployment envelope, both source commits, qualification-tools aggregate, and exact `{path,sha256}` references to the immutable Peekaboo artifact manifest and authenticated OpenClaw elevation-artifact receipt. Qualification requires the candidate CLI SHA-256 and CDHash to equal the protocol-1.31 terminal bundle's exact Agent child and local/during process sample; the requester must carry the same authenticated CDHash, and the candidate SHA-256 must be installed on both hosts. Its candidate monitor source/hash/CDHash must likewise equal the reviewed Git blob, live plan and coordinator invocation, every process-tree collection, and the executable retained in final evidence. The candidate app CDHash equals every persistent Bridge root, and the candidate Playground CDHash equals each controlled fixture root. `tooling` contains the canonical Git-owned `qualification_tools_manifest`, `construct-live-plan.mjs`, and `crash-inventory.mjs`; copied or substituted helpers fail. The input also requires the live plan plus coordinator identity handshake/invocation/exit/summary/monitor evidence; five ordered matrix objects (`certificate`, `crash_inventory`, `playground_alert_lifecycle`); the Agent task, run root, terminal bundle, live terminal-validator report, readback map, every nested signed bundle/live-validator report, and exactly six semantic readback files; integrated-CU evidence; one middle-click bundle/report/readback/restoration; one held-key bundle/report/readback/restoration; and the held-pointer controller result, six bundles/reports, two exact target-generation receipts, PID-scoped readback, restoration, and crash comparison. The generated manifest adds the two canonical Agent `controlled_fixture_targets` as a derived value, then verification recomputes them from the retained plan, authenticated final summary, process roots, bundles, and readbacks. Every referenced path is globally unique.

`deployment` is closed and ordered:

```json
{
  "installed_inventories": ["/private/.../local-installed.json", "/private/.../studio-installed.json"],
  "elevation_receipts": ["/private/.../local-elevation.json", "/private/.../studio-elevation.json"],
  "process_tree_collector": "/absolute/source/scripts/final-qualification/process-tree-collector.mjs",
  "process_tree_monitor": "/private/.../background-computer-use-probe",
  "process_trees": [
    "/private/.../local-before.json", "/private/.../local-during.json", "/private/.../local-after.json",
    "/private/.../studio-before.json", "/private/.../studio-during.json", "/private/.../studio-after.json"
  ],
  "executable_policy_scanner": "/absolute/source/scripts/final-qualification/executable-policy-scanner.mjs",
  "executable_policy_reports": ["/private/.../local-policy.json", "/private/.../studio-policy.json"]
}
```

Each installed inventory binds role, distinct hardware UUID, hostname, deployment-envelope SHA-256, exact Peekaboo/OpenClaw source commits, the reviewed qualification-tools aggregate, the corresponding elevation-receipt SHA-256, capture time, and one canonically ordered normalized entry list. File entries have `{artifact,relative_path,type:"file",mode,size,sha256}`; symlinks have `{artifact,relative_path,type:"symlink",mode,target}`. The `openclaw_app`, `peekaboo_app`, and `peekaboo_cli` classes must all be present. Only the host-specific role/UUID/hostname/elevation receipt/capture time may differ; the normalized installed projection must be byte-identical across the two hosts. Each elevation receipt is the closed schema-3 installed transaction and must bind the same source commits, artifact-receipt/archive/installer digests, and per-architecture CDHashes as the authenticated OpenClaw artifact. Its paired/approved cryptographic node identity, transaction ID, and receipt bytes must be host-distinct; each host's persistent elevation root must use one of that receipt's CDHashes. The upstream receipt has no hardware UUID, so node profile is validated as `primary|node` but is not guessed from the local/Studio role.

Create each process snapshot with the source-owned collector and the exact signed monitor already frozen for qualification:

```bash
node "$TOOLS/process-tree-collector.mjs" \
  --spec "$EVIDENCE_ROOT/local-during-spec.json" \
  --monitor "$MONITOR_BIN" \
  --output "$EVIDENCE_ROOT/local-during.json"
```

Collector specs add bounded `observation_milliseconds`, `sample_interval_milliseconds`, `maximum_sample_gap_milliseconds`, an absent `ready_path`, and `acknowledgement_path` (non-null only for local/during) to closed task roots with `{root_id,root_class,pid,start_identity,code_signature_hash}`. Before coverage begins, the collector authenticates and hashes the exact signed monitor, compiles the reviewed lifecycle source from retained bytes under a closed toolchain environment, verifies the exact executable before and after use, and registers that native kqueue guard for every exact root and initially observed descendant. The source path/hash must be the exact entry in the reviewed qualification-tools manifest; any fork, exec, or exit event fails qualification even when the child would start and exit between table samples. The collector also polls throughout the interval, independently re-hashes the canonical executable selected by the monitor, retains descendants observed by any sample, and revalidates PID generation, parent, executable bytes/path, signing identity, Team ID, and CDHash on every sample; PID reuse, reparenting, monitor replacement, and in-place executable replacement fail. Coverage completes at the actual final process-table sample at or after the requested deadline, never at the later end of serial identity enrichment, and any observed table-sampling gap above the declared bound fails.

Version-4 snapshots carry `complete:true`, continuous-lifecycle success/source/binary/timing, coverage start/end, sample count, declared/observed maximum gap, collector SHA-256, exact monitor path/SHA-256/CDHash, host/envelope identity, exact epoch, the hash-bound readiness path/publication time, and every root/descendant with PID/start/CDHash, executable hash/signing identity, and parent PID/start. Local/during additionally binds the guard-published acknowledgement plus exact authorization request/result hashes and time; all other epochs require null acknowledgement authority. Required roots are local `bridge,elevation,integrated_cu` before/after plus `agent_requester,agent,bridge,coordinator,elevation,fixture,integrated_cu` during; Studio requires `bridge,elevation` before/after plus its controlled `fixture` during representative cells. The requester and Agent roots must equal both the outer terminal receipt and its signed coordination/acknowledgement contents. Persistent root generations/CDHashes and non-overlapping epoch coverage must remain stable and ordered. The local during coverage must begin before Agent release and its final process-table sample must follow the authoritative concurrent operation interval while its Agent/coordinator/Bridge/integrated-CU roots match the bound concurrent report and plan; its candidate Playground fixture roots must contain both controlled Agent PID generations. Missing edges, lifecycle events, cycles, PID reuse, ambiguous roots, stale readiness, unauthorized acknowledgement, or incomplete capture fail.

The process policy is deliberately scoped to those task-owned trees. It rejects forbidden roots or descendants including `cua-driver`, `osascript`, AppleScript/JXA/OSA interpreters, Lume, Parallels, VMware, VirtualBox, UTM, Tart, `vfkit`, QEMU, VNC, Screen Sharing, and remote-desktop helpers. It never uses ambient process presence as failure evidence and never kills a service. Because a process tree cannot prove that a native executable contains no in-process AppleScript/JXA/OSA path, both host-specific executable/script policy reports are separately mandatory. Generate them with the reviewed `executable-policy-scanner.mjs` and a mode-0600 spec containing `version:1`, the exact installed-inventory path, and canonical `artifact_roots` for `openclaw_app`, `peekaboo_app`, and `peekaboo_cli`. The scanner re-hashes every installed file and symlink, derives every classification and rule result itself, and treats all thin or fat Mach-O byte orders as executable/loadable native code even when a dylib or framework binary has no execute bit. It rejects forbidden markers and writes a closed version-2 report. Manifest generation and final verification execute that exact Git-bound scanner again on the bound inventory/roots and require byte-equivalent classifications, counts, coverage, and zero findings; a forged clean report or benign subset is rejected.

Each matrix certificate is version 2 and binds its ordinal cycle, unique execution nonce, local hardware UUID, exact Peekaboo/Bridge source commit, deployment-envelope SHA-256, installed-inventory aggregate, immutable Peekaboo artifact-manifest SHA-256, start/end interval, and passing 42/42 catalog result. Its version-2 zero-delta crash comparison carries the same cycle/nonce/host/source/candidate identity and brackets that interval. Run each final physical matrix with `--qualification-cycle 1` through `5`; that adds the alert lifecycle after the fixed 42 catalog rows without changing their count. The harness retains every raw CLI result, continuous background-invariant summary, exact process/executable receipt, command wall-time record, exported signed Bridge bundle, authenticated live-validator report, and the source-owned crash comparison. It then constructs one hash-bound `playground-alert-lifecycle/report.json`; manifest generation and verification re-read those raw bytes, inventory every receipt directory, and authenticate every bundle against the exact live 1.31 listener. Caller-authored delivery, target, timing, or success claims are not accepted.

The exact signed Playground PID/generation/window must remain stable while `dialog-fixture-show-alert` is background-pressed, an `AXSheet` with `Cancel` and `OK` is observed, the cycle's alternating `OK`/`Cancel` button is background-pressed, and a new complete `see --tree --no-screenshot` snapshot reads the matching `dialog-fixture-last-alert-result` with no dialog remaining. The initial screenshot-plus-elements See retains the overall/sparse regression budget and must finish below 2500 ms of retained command wall time; its signed response must bind the nonempty PNG path and SHA-256. The final native AX-only See must finish below 1500 ms of retained command wall time, while its signed response must bind the fresh snapshot, empty screenshot path, complete non-dialog metadata, and exact result element/value. CLI `execution_time` remains diagnostic and is not presented as signed timing authority. The lifecycle interval must sit inside both the cycle certificate and its zero-delta crash comparison. All five nonces must be distinct and the cycle intervals strictly ordered without overlap. The concurrent report must itself be passed with eligible completed/zero exits, four mapped calls, six semantic readbacks, matching bundle count, and true Agent/CU progress interleaving. Every overlapping plan/event/summary/monitor/coordinator-invocation/exit/Agent-terminal-bundle/terminal-validator/readback/emitter hash is compared back to that same concurrent report, preventing run-A/run-B evidence mixing.

Adjunct semantic files are executable contracts, not opaque attachments. Every adjunct validator must name the candidate source commit and the live-v4 plan's exact Bridge PID, generation, and CDHash; every adjunct target must be one of the plan's two exact controlled fixture targets. The held-pointer controller additionally repeats the plan's host kind and exact candidate source in both its build and handshake. Generation and read-only verification independently rederive these bindings from the retained live-v4 plan and deployment evidence:

- Middle-click readback records exactly two consecutive source-owned Playground events, `{button:"middle",phase:"down"}` then `{button:"middle",phase:"up"}`, on the exact window; restoration carries equal literal baseline/restored values.
- Held-key readback fixes key `a`, hold 500 ms, and requires `observed_value == baseline_value + "a"`; restoration returns the exact literal baseline.
- Held-pointer readback records exactly two consecutive source-owned Playground events, left-button `down` then `up`, on the exact controller target. The source-bound certification controller result must report protocol 1.30, a nonce-derived UUIDv8 client, the exact build/controller/host identities, cleanup `owner_disconnected`, six ordered receipts, begin/release/lifecycle units 2/1/3, and terminal reason `released`. Two native process receipts must retain the target PID/generation, the crash comparison must be clean, and restoration returns the exact literal baseline. Its six live-validated operations are exactly two window lists plus create/begin/release/disconnect.

```bash
node "$TOOLS/qualification-manifest.mjs" generate \
  --input "$EVIDENCE_ROOT/qualification-manifest-input.json" \
  --output "$EVIDENCE_ROOT/qualification-manifest.json"
node "$TOOLS/qualification-manifest.mjs" verify \
  --manifest "$EVIDENCE_ROOT/qualification-manifest.json" \
  | tee "$EVIDENCE_ROOT/qualification-manifest-verification.json"

chmod 400 \
  "$EVIDENCE_ROOT/qualification-manifest.json" \
  "$EVIDENCE_ROOT/qualification-manifest-verification.json"
chmod -R a-w "$EVIDENCE_ROOT"

# Read-only re-verification must still pass; write the transient result outside the sealed root.
node "$TOOLS/qualification-manifest.mjs" verify \
  --manifest "$EVIDENCE_ROOT/qualification-manifest.json" \
  > /private/tmp/peekaboo-qualification-sealed-verification.json
```

The generated version-2 manifest hashes every file, including both authenticated artifact manifests and their cross-binding, the qualification-tools file manifest, both installed inventories and elevation receipts, six process snapshots, collector, executable-policy reports/scanner, plan constructor, and crash scanner. It also carries the two derived same-ID Agent-to-controller controlled-fixture bindings. It binds a version-2 domain-separated aggregate and states both `qualification_claim:"release-qualification"` and `adjuncts_are_live_v4_slots:false`. Verification rehashes the tool source tree and re-runs installed-parity, artifact/source/tool/elevation binding, task-root/process-policy/coverage binding, cycle uniqueness, crash, concurrent/interleaving, signed-bundle, authenticated controlled-target summary, controller, process-generation, cross-run, readback, and restoration checks in addition to closed shape, unique paths, bytes, sizes, hashes, and aggregate.

## Current product-output gaps that remain explicit hard boundaries

- Coordinator stdout has the lifecycle and eligible completion but not process identity, invocation, exit status, or operation-fence timestamps. The managed launcher supplies identity/invocation/exit authority; the validator reads fence times from coordinator-owned `monitor/monitor-evidence.json`.
- Agent stdout has the authoritative execution trace but not value content or linkage from a trace call to a nested signed receipt/readback file. The outer protocol-1.31 terminal bundle supplies exact requester/child identity, fixed argv/policy, coordination, acknowledgement bytes, complete stdout/stderr, lifetime, and terminal exit authority; the local/during version-4 process receipt separately proves lifecycle-guard publication. The closed Agent readback map remains mandatory for semantic values and trace-to-receipt linkage. Those owner-private readbacks are source-shaped, stable-file and mtime corroborated, but not listener-signed producer receipts; qualification treats their controlled owner as an explicit remaining trust boundary rather than claiming the Agent itself emitted the three observation checkpoints.
- Integrated Computer Use has no machine-readable emitter PID/generation/Team/CDHash or closed semantic readback receipt. The passive native calibrator and the two owner readback files supply those facts. If event-tap permission is unavailable or source identity is ambiguous, qualification stops.
- A `window list` plus process receipt does not itself emit the observer's exact focused semantic element and baseline in the coordinator schema. The fresh semantic readback must be projected once into the closed `observer_semantic` receipt; a missing/ambiguous identifier/title or frame outside the exact window is rejected.
