---
summary: 'Deterministic end-to-end validation for non-interrupting background computer use'
read_when:
  - 'changing interaction delivery, focus behavior, snapshots, or overlays'
  - 'comparing Peekaboo with another computer-use implementation'
---

# Background computer-use validation

Run the source-controlled harness from the repository root:

```bash
scripts/test-background-computer-use.sh
```

It builds the Playground fixture, signs it with the OpenClaw Foundation Developer ID, and samples the already-frontmost
app/window as the sentinel. It explicitly foreground-launches the controlled fixture before monitoring, then restores
and verifies that exact sentinel window. The monitored phase never activates Calculator or restores a stale foreground
app after the run. It then exercises fresh, exact PID/window snapshots through
`see` (including AX-only and screenshot-only modes), `capture live`, click by ID and query, `type`, raw-press refusal, `paste`,
`set-value`, `action`, and targeted background scroll. Stale snapshots and unsupported named AX actions must
fail nonzero instead of falling back to foreground synthesis. Standard targeted scroll must report Accessibility
delivery and produce an independent, PID-scoped Playground offset change; controlled WebKit fixtures may instead
report exact-window routed, unverifiable delivery and must prove the offset independently before any retry.
The monitored lifecycle phase also launches distinct TextEdit processes with exact window receipts, establishes a
non-maximized exact frame, then maximizes and closes that background window. Quit accepts exactly two tuples: confirmed
success with the target process gone, or `suspected_noop`/`INTERACTION_FAILED` with that target still alive. The harness
does not infer the state of an unrelated sibling process from the quit result.
Harness cleanup consumes each controlled PID and process-start identity directly from the launch/relaunch result and
passes both values in one generation-pinned `app quit` request. A missing receipt for the essential Playground fixture
aborts immediately; a missing lifecycle receipt records a failed/omitted catalog case. Cleanup never probes a bare
post-launch PID to mint ownership or issues a separate unpinned quit that could hit a recycled process. Background raw
`press` and keyboard requests with a window selector are refused. Process-only typed cases use the exact PID to isolate
the target process and intentionally do not claim sibling-window isolation. Fixture windows open through background
semantic menu actions rather than uncertified raw shortcuts.
The harness invokes the current CLI directly; it does not use AppleScript or a command runner.
Certification requires a stamped CLI whose `--version --json` output contains one canonical 40-hex `sourceCommit`.
Remote certification pins every command to one exact Bridge socket and requires its additive host-identity receipt to
expose the same source commit. Raw SwiftPM and manual unstamped Xcode builds report `unknown` and are intentionally
refused for certification. The validated certification report records both stamps and rejects missing or mismatched
provenance when artifacts are replayed. Every monitored case brackets its command with exact socket, PID, and
process-generation attestations; a restarted or rebound Bridge host invalidates that case.

Every background case starts only after the 10 ms monitor completes its first sample and publishes a sequence
heartbeat. After the command and its restoration checks finish, the case waits for that sequence to advance again; an
alive but wedged watcher cannot certify a pass. The case also fails if the monitor does not remain alive until the
harness terminates it, or if Peekaboo changes the sentinel PID/top window or physical cursor, the clipboard leaks, or a
new visible Peekaboo window appears. A passive native event tap correlates input with exact command/Bridge-host PID and
process-generation receipts. An acknowledged producer event that reaches the session-global tap violates the catalog's
`global_input_event` invariant; legitimate background PID-targeted delivery does not traverse that tap. All other input
makes the attempt sticky-indeterminate. An activation or focused-window notification accompanied by that external input
is part of the same contamination; without external input it violates the matching focus invariant. The tap requests
the complete non-null event mask and verifies that macOS retained the required mouse, keyboard, scroll, and tablet bits;
missing listen access, a reduced tap, disablement, or event overflow blocks certification. The original focus/cursor
baseline is never rebased into a pass. A pre-command attempt can be discarded and restarted from a fresh baseline, with
three total attempts. After dispatch, only catalog rows with a named replay-safe reset contract may rerun the whole row; mutation rows
such as click, type, paste, close, and quit block instead. Disabled attribution, event overflow, or retry exhaustion also
blocks the row instead of silently passing or blaming unrelated motion on Peekaboo. Clipboard and overlay invariants
remain active even on a contaminated interactive sample. The harness does not save and unconditionally restore a
run-start clipboard snapshot, so a newer user clipboard is never overwritten during cleanup; the paste command's own
transaction must restore its temporary payload. Clipboard
contents are hashed, never printed. Selected mutations use fresh UI readback or PID-scoped Playground log checks and
deltas; result contracts cover the remaining cases. Unrelated app windows and content are not collected. Artifact
directories must be new or empty so a rerun cannot reuse old summaries, images, or logs. Results go under
`.artifacts/background-computer-use/<UTC>/`.

The native monitor has one authorization-epoch state machine for producer publication and all input, activation, and
focused-window callbacks. Each callback is admitted on one atomic cutoff and retains that epoch plus the PID,
process-start identity, and focused window sampled during the callback. Admission reserves a cheap immutable token,
releases the publication lock while sampling native process/focus evidence, and completes that exact token afterward;
sealed epochs cannot reach a heartbeat while any reservation remains incomplete. Input and activation callbacks use
exact Accessibility focus lookup rather than a broad WindowServer inventory. Each window lookup is bracketed by matching
process-generation reads; generation drift discards the combined evidence instead of synthesizing a PID/window pair.
Publishing a higher producer revision closes the old epoch before the new epoch can admit evidence; heartbeat closure
uses the same cutoff, so there is no
separate drain-to-heartbeat interval. Every higher revision is a transition barrier, including a producer-only update or
an unchanged foreground target. A separate full callback run-loop turn and `beforeWaiting` idle barrier must finish before
that revision becomes eligible for acknowledgement. A missed bounded idle barrier defers the transition while stable
monitoring continues; persistent backlog eventually times out the harness acknowledgement wait rather than relabeling
queued callbacks. Admission remains on the previously acknowledged policy through that barrier. A grant therefore cannot
credit its new controller early, while a queued event from the prior grant is neither relabeled nor treated as outside
input during
revoke. The monitor will not publish an acknowledgement while its pre-ack bucket has a pending reservation or unevaluated
event. Once that bucket is empty, observer reconciliation, the atomic heartbeat write, and the admission switch to the
new authorization share one cutoff. Heartbeat bytes and the same-directory temporary file are prepared outside the
cutoff, then a final adjacent idle barrier drains newly queued callbacks; any resulting evidence defers acknowledgement
again. Current and prior controller generations and targets are revalidated inside the cutoff before observer retirement
and atomic rename, so liveness cannot drift during the final barrier. Every evaluated transition summary is still published
with `transitionAcknowledged: false` while waiting, so activation/focus counts are never discarded. The eventual
acknowledgement advertises the new revision and target but cannot advance `lastCleanSequence`; the next fully closed stable
epoch may do so. Repeating the current revision is idempotent only when the exact producer set (ignoring array order) and
optional foreground payload are unchanged.

The producer document may label one exact process generation with role `foreground-controller` and pair it with
`foreground: {active: true, target: {pid, startIdentity, windowID}}`. A foreground grant requires exactly one such
controller and at least one ordinary Bridge producer; inactive policy permits neither a controller nor a target. The
baseline focus observer remains installed, a new granted-target observer is installed before publication, and observers
for prior targets remain alive while transition evidence is evaluated. They retire inside the acknowledgement cutoff;
removal or final liveness failure prevents the acknowledgement, publishes a non-acknowledging heartbeat, and records a
sticky attribution failure without terminating the watcher. Every heartbeat revalidates all effective and pending
foreground-controller generations even when no input arrived; ordinary Bridge generations remain publication-validated
and event-time validated because short-lived CLI producers may exit before the post-command heartbeat. Foreground-activity
counters are scoped to the advertised revision so an earlier grant cannot satisfy a later grant. Controller recycling or
current/deferred target generation or window drift disables attribution. Hardware-origin mouse movement may be recorded as
observational when the harness opts in; other user input still makes the attempt indeterminate.

This state machine is deterministic infrastructure only in the current slice. The dual-controller command continues to
refuse before UI setup: no physical foreground grant/revoke coordinator is enabled, and these epoch contracts alone are
not concurrent certification.

The 34 required CLI cases are source-controlled in `scripts/background-computer-use-catalog.json`. Each row declares
its exit contract and, where applicable, its effect, delivery, refusal code, allowed outcome tuples, and named checks.
The catalog is the canonical list of monitored invariant families and projects their names into the native probe,
harness summaries, synthetic fixtures, and reporter. The harness writes one exact array of closed `{name, passed}`
results per case, preserving duplicate names so the reporter can reject them after ordinary JSON parsing. The reporter
`scripts/validate-background-computer-use-report.mjs` rejects missing, duplicate, or unknown rows; surface, command, or
phase drift; wrong refusal codes; disallowed conditional outcomes; effect or delivery drift; absent declared
readback/log/artifact evidence; monitor failure; and every missing, unknown, or violated catalog invariant. A legacy
aggregate violation count cannot certify a row. Command and phase identity are
derived from the actual harness arguments rather than copied from the catalog, so adding `--foreground` invalidates a
background row. The stale-snapshot row resizes the exact captured window under the same monitor, requires
`SNAPSHOT_STALE` when reusing that real snapshot ID, and restores the original bounds before the case can pass. A run is
not certified merely because the cases that happened to execute passed. The machine-readable verdict is
`certification.json` beside the normal summary.

Completeness is relative to this source-controlled 34-case single-controller matrix; it is not a claim that every
Peekaboo CLI combination is represented. `scripts/test-dual-controller-overlap.sh` is the complementary workflow-level
cell; its internal steps deliberately stay outside the 34-row command catalog.

The overlap cell starts two owned TextEdit executable generations during setup, pins their exact process/window
receipts, and then restores an independently selected sentinel window. Two separate controller processes launch
independently generation- and executable-attested CLI clients through one explicit signed current Bridge socket:
controller A completes an observe/type/press/type/readback workflow while controller B continuously observes and updates
its different exact window. Restoration is serialized: after A restores, both targets are read before B may restore,
then both targets are read again, so a cross-target mutation cannot be overwritten by the peer restoration. Cleanup uses
the launch receipts, and the validator requires real bidirectional interval overlap plus independent readback with no
cross-target token. The native monitor keeps focus, top-window, session-global Peekaboo input, clipboard change count,
visible Peekaboo alpha windows, host generation, and heartbeat liveness fail-closed through cleanup.
Physical cursor motion is recorded as observational evidence and never fails the cell because the user may be working
concurrently. Every CLI generation is registered before it can run and has a 30-second deadline (bounded to 1–300
seconds with
`PEEKABOO_OVERLAP_OPERATION_TIMEOUT_SECONDS`); timeout and abort cleanup escalate from TERM to KILL while the invariant
monitor remains active. Peer synchronization uses one monotonic deadline derived from that timeout plus the bounded
registration/attestation handoff for each maximum remaining operation: 6 for initial/final readback, 8 to establish the
overlap witness, 30 for the longer controller workflow, and 15 for restoration plus its two-target checkpoint. A peer
generation exit still refuses immediately. Each target starts as a stopped direct child: its intended executable path
and process generation are recorded durably before resume, then the live executable path is verified after `exec`;
cleanup never infers ownership from an ambient application-inventory delta or a response that can be interrupted.

Protocol 1.29 now validates a stable listener identity, a peer-bound logical operation session, and a signed terminal
receipt on the same authenticated request connection. Bounded sessions roll over without restarting the listener:
each request uses a decimal-string session sequence and deterministic request UUID, while the only automatic retry is
one request backed by a fully verified signed refusal proving `mutation_dispatched=false` and `retry_safe=true` and
carrying the successor session. Protocol 1.28 remains receiptless.

`peekaboo bridge receipt validate` now authenticates one exact live listener and validates one exported protocol 1.29
bundle against that independently obtained trust anchor. Live overlap execution remains deliberately reserved: the
shell harness does not yet have the separately audited multi-target coordinator and certification contract needed to
bind every expected request, session rollover, target, and terminal bundle without widening the single-target receipt
policy. `bridge status`, structural `jq` checks, and a bundle's self-signature are not substitutes. The current command
therefore still refuses before UI setup; its deterministic self-test remains non-live infrastructure.

```bash
PEEKABOO_RUN_DUAL_CONTROLLER_OVERLAP=1 \
scripts/test-dual-controller-overlap.sh \
  --bin /absolute/path/to/peekaboo \
  --bridge-socket /absolute/path/to/bridge.sock \
  --sentinel-pid 1234 \
  --sentinel-window-id 5678 \
  --artifacts /absolute/new/artifact-directory
```

The safe source/contract gate never touches UI:

```bash
scripts/test-dual-controller-overlap.sh --self-test \
  --artifacts /absolute/new/self-test-directory
```

For the interaction commands exercised here, background is the omission contract: `--foreground` is the only consent
for focus/activation, global keyboard input, physical cursor movement, or synthetic pointer/wheel events. Explicit app
switching and other inherently foreground commands are outside that statement. The optional physical phase is separate:

```bash
scripts/test-background-computer-use.sh --foreground-phase
```

That phase restores the cursor, relaunches Playground to reset fixture state, and returns to the captured sentinel.
Do not move Dock items, switch Spaces, or open file dialogs in this harness; those belong in explicitly destructive or
interactive test plans.

For a fast helper check with no GUI automation:

```bash
scripts/test-background-computer-use.sh --self-test
```

That self-test also validates a complete synthetic certification report. The reporter's fail-closed corruptions run in
the normal safe gate or directly with `pnpm run test:background-certification`; they cover deleted, duplicate, unknown,
wrong-refusal, missing-evidence, disallowed conditional-outcome, effect/delivery-drift, catalog invariant corruption,
duplicate/missing/unknown/violated invariant results, legacy object/aggregate shapes, and invariant-canary reports.

Use `--bin`, `--artifacts`, `--sentinel-bundle-id`, or `--playground-app ... --skip-playground-build` to select an exact
binary, require an already-frontmost app, or use a prebuilt signed fixture. The harness refuses rather than activating a
requested sentinel that is not already frontmost. Add `--no-remote` when the exact CLI is team-signed and
has local TCC grants; this prevents an installed bridge host from masking working-tree behavior. A prebuilt app must
have a team signature; ad-hoc fixtures are rejected.
