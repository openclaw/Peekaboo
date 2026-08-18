# Peekaboo final qualification tools

These source-owned tools close the final physical qualification handshakes. They do not install, sign, launch a GUI app, change TCC, synthesize input, stop a process, or publish anything. The only tool that observes live input is the explicitly invoked native emitter calibrator; its event tap is passive (`listenOnly`) and excludes mouse-move and button/key-up events. The process-tree collector only reads native process ancestry and signed identities for caller-supplied task roots. It never scans, stops, or adopts unrelated ambient services.

All JSON inputs and outputs must be absolute, canonical, current-user-owned regular files under mode-0700 directories. Raw/private inputs must be mode 0600 (0400 is also accepted), non-symlink, non-hardlinked, bounded, and stable across the read. Outputs must not exist. Executables may be readable by others but may not be group/other-writable.

## Freeze and test the tools

```bash
TOOLS="$(git rev-parse --show-toplevel)/scripts/final-qualification"
node --check "$TOOLS/project-live-bindings.mjs"
node --check "$TOOLS/publish-coordinator-marker.mjs"
node --check "$TOOLS/managed-launcher.mjs"
node --check "$TOOLS/validate-concurrent-run.mjs"
node --check "$TOOLS/qualification-manifest.mjs"
node --check "$TOOLS/process-tree-collector.mjs"
node "$TOOLS/process-tree-collector.mjs" --self-test
node --test "$TOOLS/test/qualification-tools.test.mjs"
shasum -a 256 "$TOOLS"/*.{c,mjs,swift} "$TOOLS/test/qualification-tools.test.mjs"
```

The test suite compiles the native calibrator and runs only its `--self-test`; it never creates an event tap or touches UI.

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

The projector accepts no identity literals in its input. `receipts.integrated_cu_emitter` is the calibrator output above. Each target uses the native monitor's exact `{pid,startIdentity}` output plus a `peekaboo window list --pid ... --json` result containing exactly one window whose `target_application_info.pid` matches. The semantic receipt is a closed owner projection of a fresh exact-target AX readback:

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
node "$EVIDENCE_ROOT/peekaboo-live-v4-plan-constructor.mjs" \
  --bindings "$EVIDENCE_ROOT/live-v4-bindings.json" \
  --output "$EVIDENCE_ROOT/live-v4-plan.json"
```

The projector derives controller click points from exact window centers, obtains Bridge Team trust from the source catalog, and takes the monitor CDHash from raw `codesign -dvvv` output with an Apple Root CA chain. It rejects a second eligible window, target/emitter reuse, semantic-frame mismatch, unsafe paths, noncanonical DiagnosticReports, protocol other than 1.30, or any identity drift.

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

## 4. Launch Agent and coordinator with exact process/exit authority

`managed-launcher.mjs` never invokes a shell and never detaches. It compiles the retained `managed-launch-suspended.c` guardian into a fresh private temporary directory, uses `posix_spawn(POSIX_SPAWN_START_SUSPENDED)` for the exact executable/argv, and streams the child's already-private stdout/stderr files to the launcher's corresponding streams. Before release it runs the plan's exact signed monitor as `process-identity --pid ... --output ...`, requires the monitor's live CDHash to match the plan, atomically publishes the invocation receipt and start acknowledgement, and only then sends `SIGCONT`. The guardian remains the child's owner through bounded wait/TERM/KILL and reports the real exit code or terminating signal.

The Agent launch spec is closed:

```json
{
  "version": 1,
  "kind": "agent",
  "plan_path": "/private/.../live-v4-plan.json",
  "executable": "/private/.../peekaboo",
  "arguments": ["agent", "run", "EXACT TASK TEXT", "--no-cache", "--max-steps", "40", "--bridge-socket", "/Users/.../bridge.sock", "--json"],
  "identity_handshake_path": "/private/.../agent-launch-process.json",
  "pid_path": "/private/.../agent-pid.json",
  "start_ack_path": "/private/.../agent-start.json",
  "invocation_receipt_path": "/private/.../agent-invocation.json",
  "exit_receipt_path": "/private/.../agent-exit.json",
  "stdout_path": "/private/.../agent-result.json",
  "stderr_path": "/private/.../agent-stderr.log",
  "start_timeout_seconds": 30,
  "run_timeout_seconds": 900,
  "context": {
    "task_path": "/private/.../agent-task.txt",
    "receipt_directory": "/private/.../agent-receipts",
    "bridge_socket": "/Users/.../bridge.sock"
  }
}
```

The task argument must byte-match the retained task file after its one terminal newline is removed. The nine arguments and their order are exact; audio, resume/cache, foreground, model, quiet, or any other additional flag is rejected. The receipt directory must be a new empty mode-0700 directory. Launch in managed PTY session A:

```bash
node "$TOOLS/managed-launcher.mjs" --spec "$EVIDENCE_ROOT/agent-launch-spec.json"
```

The coordinator spec has the same top-level keys, changes `kind` to `coordinator`, uses the exact current Node executable, and has exactly `arguments:[COORDINATOR_SOURCE,"--plan",LIVE_PLAN]` plus `context:{"coordinator_source_path":COORDINATOR_SOURCE}`. Its `stdout_path` is the authoritative `live-v4-events.jsonl` consumed by the operator while the launcher remains attached:

```bash
node "$TOOLS/managed-launcher.mjs" --spec "$EVIDENCE_ROOT/coordinator-launch-spec.json"
```

Both runs create closed invocation and exit receipts atomically. An absent, malformed, wrong-PID, or stale monitor identity handshake prevents `SIGCONT`; the still-suspended child is killed and no invocation/exit authority is minted.

The Agent launch spec's `identity_handshake_path` is the signed-monitor launch receipt. At the coordinator's `perform` and `restore` external windows, capture two more receipts from the same exact monitor before handling each phase:

```bash
MONITOR="$(jq -er '.monitor_executable' "$LIVE_PLAN")"
AGENT_PID="$(jq -er '.pid' "$EVIDENCE_ROOT/agent-pid.json")"

# Launch receipt is written automatically while the Agent is still suspended:
jq -e --argjson pid "$AGENT_PID" '.pid == $pid and (.startIdentity | type) == "string"' \
  "$EVIDENCE_ROOT/agent-launch-process.json"

# Run on receipt of external-foreground-window phase=perform:
"$MONITOR" process-identity --pid "$AGENT_PID" \
  --output "$EVIDENCE_ROOT/agent-perform-process.json"

# Run on receipt of external-foreground-window phase=restore, before its marker:
"$MONITOR" process-identity --pid "$AGENT_PID" \
  --output "$EVIDENCE_ROOT/agent-restore-process.json"
```

All three must report the same decimal process generation. The concurrent input orders them exactly as launch, perform, restore.

## 5. Validate the completed concurrent run

`concurrent-validation-input.json` is closed:

```json
{
  "version": 1,
  "plan": "/private/.../live-v4-plan.json",
  "coordinator_invocation": "/private/.../coordinator-invocation.json",
  "coordinator_events": "/private/.../live-v4-events.jsonl",
  "coordinator_exit": "/private/.../coordinator-exit.json",
  "agent_result": "/private/.../agent-result.json",
  "agent_exit": "/private/.../agent-exit.json",
  "agent_invocation": "/private/.../agent-invocation.json",
  "agent_identity": {
    "launch": "/private/.../agent-launch-process.json",
    "perform": "/private/.../agent-perform-process.json",
    "restore": "/private/.../agent-restore-process.json"
  },
  "agent_bundles": [
    {"bundle_path": "/private/.../agent-receipts/REQUEST.json", "validator_report_path": "/private/.../agent-validators/REQUEST.json"}
  ],
  "agent_readbacks": "/private/.../agent-readbacks.json",
  "integrated_cu": {
    "emitter": "/private/.../integrated-cu-emitter-calibration.json",
    "perform_readback": "/private/.../integrated-cu-perform-readback.json",
    "restore_readback": "/private/.../integrated-cu-restore-readback.json"
  }
}
```

Each exit receipt is written by the managed launcher after `wait` and has exactly:

```json
{"version":1,"process":"agent","pid":901,"start_identity":"901001","started_at_milliseconds":1,"completed_at_milliseconds":2,"exit_code":0,"signal":null}
```

Use `process:"coordinator"` for the coordinator. The launcher records `exit_code:null` plus the numeric signal for signal termination; successful qualification requires code 0 and a null signal.

The managed launcher also writes `agent-invocation.json`, binding the exact executable/argv, plan, signed monitor bytes, native identity handshake, task, receipt directory, Bridge socket, stdout/stderr, and immutable background-only/no-foreground/no-Shell policy. The validator requires the complete ordered argv to equal the nine-item array in the spec exactly. The analogous coordinator receipt binds the exact Node executable, source file, plan, monitor handshake, and event-stream stdout.

`agent-readbacks.json` contains exactly two ordered targets (`target-a`, `target-b`). Each has exact `{pid,start_identity,window_id}`, `baseline_readback_path`, and `mutation`/`restoration` objects with `{trace_call_id,family,readback_path,bundle_path,validator_report_path}`. Each referenced semantic readback is closed `{version,target,phase,value,observed_at_milliseconds,passed}` with phases `baseline`, `mutated`, or `restored`; hashes are derived from those actual bytes and values, never accepted as caller claims. Every bundle must pass the live Bridge validator, carry the Agent PID/start generation as its signed client, match the trace/readback PID/window and operation family, prove a definite background dispatch, and fall wholly inside `operations-start..operations-complete`. The receipt-directory inventory and `agent_bundles` list must be identical, including observation bundles; any unlisted or unmapped dispatched bundle fails.

Exactly four—and only four—trace call IDs may report `mutationDispatch:"dispatched"`: mutate and restore for target A, then mutate and restore for target B. Both targets must be distinct process generations/windows and disjoint from controller A/B, Bridge host, observer/foreground target, integrated-CU emitter, and sentinel. Both primary mutations must use different families; target B's restoration uses a different family from its primary mutation.

```bash
node "$TOOLS/validate-concurrent-run.mjs" \
  --input "$EVIDENCE_ROOT/concurrent-validation-input.json" \
  --output "$EVIDENCE_ROOT/agent-cu-validation-report.json"
```

Success requires the exact four-event coordinator lifecycle ending in eligible `completed`, explicit zero exits, one unchanged Agent PID/generation at launch/perform/restore, exactly four mapped and signed background mutations with no extra dispatch, six in-window semantic readbacks, disjoint physical targets, an untruncated trace with no Shell/foreground/skipped/failed/possibly-dispatched call, the calibrated emitter, both integrated-CU readbacks, and an Agent lifetime covering the entire authoritative `operations-start` through `operations-complete` monitor interval.

## 6. Generate and verify the final qualification manifest

First create the immutable, self-verifying source manifest for the frozen qualification tools. The file order is part of the aggregate:

```bash
node "$TOOLS/qualification-manifest.mjs" tooling \
  --directory "$TOOLS" \
  --source-commit "$PEEKABOO_FINAL_SHA" \
  --output "$EVIDENCE_ROOT/qualification-tools-source.json"

chmod 400 "$EVIDENCE_ROOT/qualification-tools-source.json"
```

The manifest input is version 2 and has exact top-level keys `version`, `artifact_manifest`, `deployment`, `tooling`, `live_v4`, `matrix_cycles`, `agent_cu`, `adjuncts`, and `restoration_cleanup`. `tooling` contains exact paths for `qualification_tools_manifest`, `plan_constructor`, and `crash_scanner`. It also requires the live plan plus coordinator identity handshake/invocation/exit/summary/monitor evidence; five ordered matrix objects (`certificate`, `crash_inventory`); the Agent task/result/invocation/exit/process/readback map, every signed bundle and live-validator report, and exactly six semantic readback files; integrated-CU evidence; one middle-click bundle/report/readback/restoration; one held-key bundle/report/readback/restoration; and the held-pointer controller result, six bundles/reports, two exact target-generation receipts, PID-scoped readback, restoration, and crash comparison. Every referenced path is globally unique.

`deployment` is closed and ordered:

```json
{
  "installed_inventories": ["/private/.../local-installed.json", "/private/.../studio-installed.json"],
  "elevation_receipts": ["/private/.../local-elevation.json", "/private/.../studio-elevation.json"],
  "process_tree_collector": "/absolute/source/scripts/final-qualification/process-tree-collector.mjs",
  "process_trees": [
    "/private/.../local-before.json", "/private/.../local-during.json", "/private/.../local-after.json",
    "/private/.../studio-before.json", "/private/.../studio-during.json", "/private/.../studio-after.json"
  ],
  "executable_policy_scanner": "/private/.../bound-native-policy-scanner",
  "executable_policy_reports": ["/private/.../local-policy.json", "/private/.../studio-policy.json"]
}
```

Each installed inventory binds role, distinct hardware UUID, hostname, deployment-envelope SHA-256, exact Peekaboo/OpenClaw source commits, the reviewed qualification-tools aggregate, the corresponding elevation-receipt SHA-256, capture time, and one canonically ordered normalized entry list. File entries have `{artifact,relative_path,type:"file",mode,size,sha256}`; symlinks have `{artifact,relative_path,type:"symlink",mode,target}`. The `openclaw_app`, `peekaboo_app`, and `peekaboo_cli` classes must all be present. Only the host-specific role/UUID/hostname/elevation receipt/capture time may differ; the normalized installed projection must be byte-identical across the two hosts.

Create each process snapshot with the source-owned collector and the exact signed monitor already frozen for qualification:

```bash
node "$TOOLS/process-tree-collector.mjs" \
  --spec "$EVIDENCE_ROOT/local-during-spec.json" \
  --monitor "$MONITOR_BIN" \
  --output "$EVIDENCE_ROOT/local-during.json"
```

Collector specs name closed task roots with `{root_id,root_class,pid,start_identity,code_signature_hash}`. Snapshots carry `complete:true`, the collector SHA-256, host/envelope identity, exact epoch, and every root/descendant with PID/start/CDHash, executable hash/signing identity, and parent PID/start. Required roots are local `bridge,elevation,integrated_cu` before/after plus `agent,coordinator,fixture` during; Studio requires `bridge,elevation` before/after plus its controlled `fixture` during representative cells. Persistent root generations/CDHashes must remain stable; timestamps must satisfy `before < during < after`; missing edges, cycles, PID reuse, ambiguous roots, or incomplete capture fail.

The process policy is deliberately scoped to those task-owned trees. It rejects forbidden roots or descendants including `cua-driver`, `osascript`, AppleScript/JXA/OSA interpreters, Lume, Parallels, VMware, VirtualBox, UTM, Tart, `vfkit`, QEMU, VNC, Screen Sharing, and remote-desktop helpers. It never uses ambient process presence as failure evidence and never kills a service. Because a process tree cannot prove that a native executable contains no in-process AppleScript/JXA/OSA path, both host-specific executable/script policy reports are separately mandatory, must bind one reviewed scanner, must be complete, and must contain zero findings.

Each matrix certificate must be exactly `{success:true,catalog_version:2,expected_cases:42,observed_cases:42,failures:[]}` and each crash comparison exactly version 1, `passed:true`, with empty added/changed/removed arrays. The concurrent report must itself be passed with eligible completed/zero exits, four mapped calls, six semantic readbacks, and matching bundle count. Every overlapping plan/event/summary/monitor/invocation/exit/result/readback/emitter hash is compared back to that same concurrent report, preventing run-A/run-B evidence mixing.

Adjunct semantic files are executable contracts, not opaque attachments:

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

The generated version-2 manifest hashes every file, including the qualification-tools file manifest, both installed inventories and elevation receipts, six process snapshots, collector, executable-policy reports/scanner, plan constructor, and crash scanner. It binds a version-2 domain-separated aggregate and states both `qualification_claim:"release-qualification"` and `adjuncts_are_live_v4_slots:false`. Verification rehashes the tool source tree and re-runs installed-parity, source/tool/elevation binding, task-root/process-policy, certificate, crash, concurrent, signed-bundle, controller, process-generation, cross-run, readback, and restoration checks in addition to closed shape, unique paths, bytes, sizes, hashes, and aggregate.

## Current product-output gaps that remain explicit hard boundaries

- Coordinator stdout has the lifecycle and eligible completion but not process identity, invocation, exit status, or operation-fence timestamps. The managed launcher supplies identity/invocation/exit authority; the validator reads fence times from coordinator-owned `monitor/monitor-evidence.json`.
- Agent JSON has the authoritative execution trace but not its PID/start identity, wall-clock lifetime, exit status, launch argv/policy, value content, or linkage from a trace call to a signed receipt/readback file. The managed-launcher invocation/exit receipts, three native process receipts, and the closed Agent readback map are therefore mandatory.
- Integrated Computer Use has no machine-readable emitter PID/generation/Team/CDHash or closed semantic readback receipt. The passive native calibrator and the two owner readback files supply those facts. If event-tap permission is unavailable or source identity is ambiguous, qualification stops.
- A `window list` plus process receipt does not itself emit the observer's exact focused semantic element and baseline in the coordinator schema. The fresh semantic readback must be projected once into the closed `observer_semantic` receipt; a missing/ambiguous identifier/title or frame outside the exact window is rejected.
