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
app/window as the sentinel. Before any certifying monitor starts, native background LaunchServices requests
(`open -g -n`) create one task-owned Playground generation and two task-owned TextEdit generations. Exact before/after
application-inventory deltas, native process-start identities, and exact visible windows establish ownership. Every
setup launch must leave the sentinel unchanged; the harness never foregrounds a fixture and never "restores" a stale
foreground app after setup.

The live matrix also requires one already-running process with one exact key or sole visible window for Safari,
Calendar, System Settings, Calculator, Activity Monitor, and Finder. Those six processes are read-only prerequisites:
the harness never launches, quits, closes, or otherwise mutates them. Together with the owned Playground and TextEdit
targets, eight monitored screenshot-only exact-window cells prove cross-app routing without focus or cursor control.
Missing processes, duplicate instances, ambiguous windows, process-generation drift, or changed window receipts fail
closed rather than selecting a first match.

The remaining cases exercise fresh, exact PID/window snapshots through `see` (including AX-only and screenshot-only
modes), `capture live`, click by ID and query, exact-window `type`, `press`, and `paste`, app/PID-only raw-press refusal,
`set-value`, `action`, and targeted background scroll. Stale snapshots and unsupported named AX actions must
fail nonzero instead of falling back to foreground synthesis. Standard targeted scroll must report Accessibility
delivery and produce an independent, PID-scoped Playground offset change; controlled WebKit fixtures may instead
report exact-window routed, unverifiable delivery and must prove the offset independently before any retry.
The monitored lifecycle phase uses the already-owned TextEdit receipts, establishes a non-maximized exact frame, then
maximizes and closes one window. Quit accepts exactly two tuples: confirmed success with the target process gone, or
`suspected_noop`/`INTERACTION_FAILED` with that target still alive. The harness does not infer the state of an unrelated
sibling process from the quit result. Cleanup passes every task-owned PID and process-start identity in one
generation-pinned `app quit` request; it never mints ownership from a bare post-launch PID or issues an unpinned quit
that could hit a recycled process.

PID-only typing is deliberately refused once Playground has multiple eligible windows. Exact-window typing succeeds
only after one background semantic click establishes the fixture focus. Exact-window raw Return then exercises the
receipt-pinned background press route and requires an independent PID-scoped submit log. The same raw press with only
an app or PID must refuse before dispatch with foreground-consent guidance. Fixture windows open through background
semantic menu actions rather than uncertified shortcuts. The harness invokes the current CLI directly and uses no
AppleScript or JXA.
Certification requires a stamped CLI whose `--version --json` output contains one canonical 40-hex `sourceCommit`.
Remote certification pins every command to one exact Bridge socket and requires its additive host-identity receipt to
expose the same source commit. Raw SwiftPM and manual unstamped Xcode builds report `unknown` and are intentionally
refused for certification. The validated certification report records both stamps and rejects missing or mismatched
provenance when artifacts are replayed. Every monitored case brackets its command with exact socket, PID, and
process-generation attestations; a restarted or rebound Bridge host invalidates that case. The report also commits
pre/post CLI and Bridge executable SHA-256, CDHash, device, and inode receipts. Catalog, reporter, probe, and harness
inputs are copied into the owner-private run root before execution and verified unchanged afterward. Playground carries
an embedded current-commit/source-tree manifest beneath the app signature, so a prebuilt fixture cannot claim the
checkout's source merely because its bundle identifier matches.

Every background case starts only after the 10 ms monitor completes its first sample and publishes a sequence
heartbeat. After the command and its restoration checks finish, the case waits for that sequence to advance again; an
alive but wedged watcher cannot certify a pass. The case also fails if the monitor does not remain alive until the
harness terminates it, or if Peekaboo changes the sentinel PID/top window, the clipboard leaks, or a new visible
Peekaboo window appears. Physical cursor coordinates are observational because the user may move the mouse while the
matrix runs. The probe records `cursorMovementObserved`; hardware-origin `mouseMoved` events from PID 0 neither fail nor
contaminate a row. User clicks, keys, wheel input, attribution loss, and focus changes remain contamination. A passive
native event tap correlates product input with exact command/Bridge-host PID and
process-generation receipts. An acknowledged producer event that reaches the session-global tap violates the catalog's
`global_input_event` invariant; legitimate background PID-targeted delivery does not traverse that tap. All other input
makes the attempt sticky-indeterminate. An activation or focused-window notification accompanied by that external input
is part of the same contamination; without external input it violates the matching focus invariant. The tap requests
the complete non-null event mask and verifies that macOS retained the required mouse, keyboard, scroll, and tablet bits;
missing listen access, a reduced tap, disablement, or event overflow blocks certification. The original focus baseline
is never rebased into a pass; no cursor-position equality is required. The catalog's
`producer_pointer_event` slot means Peekaboo emitted no attributable shared-pointer route, not that the user
kept the mouse still. When observational cursor policy is disabled, coordinate drift is reported separately as the
out-of-catalog `cursor_position` violation, which still fails the harness without blaming Peekaboo for the user's input.
A pre-command attempt can be discarded and restarted from a fresh baseline, with
three total attempts. After dispatch, only catalog rows with a named replay-safe reset contract may rerun the whole row; mutation rows
such as click, type, paste, close, and quit block instead. Disabled attribution, event overflow, or retry exhaustion also
blocks the row instead of silently passing or blaming unrelated motion on Peekaboo. Clipboard and overlay invariants
remain active even on a contaminated interactive sample. The harness does not save and unconditionally restore a
run-start clipboard snapshot, so a newer user clipboard is never overwritten during cleanup; the paste command's own
transaction must restore its temporary payload. Clipboard
contents are hashed, never printed. Selected mutations use fresh UI readback or PID-scoped Playground log checks and
deltas; result contracts cover the remaining cases. Only exact declared or controlled target windows are collected;
their screenshot artifacts can contain visible local app content and must remain private. Unrelated windows are not
captured. Artifact directories must be new or empty so a rerun cannot reuse old summaries, images, or logs. Results go under
the owner-only `.artifacts/background-computer-use/<UTC>/` root.

The native monitor has one authorization-epoch state machine for producer publication and all input, activation, and
focused-window callbacks. Each callback is admitted on one atomic cutoff and retains that epoch plus the PID,
process-start identity, and focused window sampled during the callback. Admission reserves a cheap immutable token,
releases the publication lock while sampling native process/focus evidence, and completes that exact token afterward;
sealed epochs cannot reach a heartbeat while any reservation remains incomplete. Input and activation callbacks use
exact Accessibility focus lookup rather than a broad WindowServer inventory. Each window lookup is bracketed by matching
process-generation reads; generation drift discards the combined evidence instead of synthesizing a PID/window pair.
Publishing a higher producer revision closes the old epoch before the new epoch can admit evidence; heartbeat closure
uses the same cutoff, so there is no separate drain-to-heartbeat interval. Each heartbeat samples system state, drains
callbacks that became ready during sampling, and only then closes/evaluates that epoch. Every higher revision is a
transition barrier, including a producer-only update or
an unchanged foreground target. A separate full callback run-loop turn and `beforeWaiting` idle barrier must finish before
that revision becomes eligible for acknowledgement. A missed bounded idle barrier defers the transition while stable
monitoring continues; persistent backlog eventually times out the harness acknowledgement wait rather than relabeling
queued callbacks. Admission remains on the previously acknowledged policy through that barrier. A grant therefore cannot
credit its new controller early, while a queued event from the prior grant is neither relabeled nor treated as outside
input during
revoke. The monitor will not publish an acknowledgement while its pre-ack bucket has a pending reservation or unevaluated
event. Once that bucket is empty, observer reconciliation, the atomic heartbeat write, and the admission switch to the
new authorization share one cutoff. Heartbeat bytes and the same-directory temporary file are prepared outside the
cutoff, then a final adjacent terminal-order idle barrier requires two `beforeWaiting` passes so work queued by another
observer receives one more drain turn; any resulting evidence defers acknowledgement again. Current and prior controller
generations and targets are revalidated inside the cutoff before observer retirement
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

Every heartbeat is bound to one 64-hex execution nonce, one UUIDv4 monitor instance, and one SHA-256 history
commitment. Closed heartbeats use safe-integer `monotonicMicroseconds` for strict ordering and
`wallClockMilliseconds` for signed-receipt interval comparison; adjacent fence deltas may differ by at most two seconds,
so a wall-clock jump fails closed. Fractional timestamps remain diagnostic-only and never enter sealed evidence.
Producer documents carry the same run identity and use a closed schema. The source-owned live coordinator
can additionally start an owner-private Unix attestation socket. After the monitor matches six ordered certification
fences against heartbeats it actually published, it seals the exact coordinator corpus, rewrites the final heartbeat
to the sealed history commitment, and serves a newline-delimited challenge response containing its PID generation,
code-signature hash, and domain-separated `monitor-evidence` digest. The controller verifies the kernel Unix peer PID;
writing heartbeat, evidence, or receipt files cannot mint monitor authority.

The standalone probe's `monitor-evidence-v2-digest` helper is deliberately scoped to this closed integer-only monitor
schema. It sorts decoded object keys by ECMAScript UTF-16 order, retains source-owned Node integer tokens, and rejects
fractions, exponents, negative zero, duplicate keys, and integers outside JavaScript's safe range. The general digest
specification remains implemented by the Node finalizer; this native helper does not claim to canonicalize arbitrary
JSON numbers.

The 42-case matrix does not grant a foreground controller; its default remains background-only. Concurrent certification
is a separate source-owned coordinator workflow and requires the run-bound seal, PID attestation, signed receipts, and
foreground semantic witness together. The matrix therefore does not pass the five live-seal paths or claim a v4 live
certificate. The probe's deterministic tests exercise the seal and peer-PID endpoint; the dependent live coordinator
owns the six-fence execution. Epoch heartbeats alone are not a concurrent certification.

The 42 required CLI cases are source-controlled in the version 2
`scripts/background-computer-use-catalog.json`. Each row declares
its exit contract and, where applicable, its effect, delivery, refusal code, allowed outcome tuples, and named checks.
The catalog is the canonical list of monitored invariant families and projects their names into the native probe,
harness summaries, synthetic fixtures, and reporter. The harness writes one exact array of closed `{name, passed}`
results per case, preserving duplicate names so the reporter can reject them after ordinary JSON parsing. The reporter
`scripts/validate-background-computer-use-report.mjs` rejects missing, duplicate, or unknown rows; surface, command, or
phase drift; wrong refusal codes; disallowed conditional outcomes; effect or delivery drift; absent declared
readback/log/artifact evidence; physical-app identity or coverage drift; monitor failure; and every missing, unknown, or
violated catalog invariant. A legacy aggregate violation count cannot certify a row. Command and phase identity are
derived from the actual harness arguments rather than copied from the catalog, so adding `--foreground` invalidates a
background row. The stale-snapshot row resizes the exact captured window under the same monitor, requires
`SNAPSHOT_STALE` when reusing that real snapshot ID, and restores the original bounds before the case can pass. A run is
not certified merely because the cases that happened to execute passed. The machine-readable verdict is
`certification.json` beside the normal summary.

Completeness is relative to this source-controlled 42-case single-controller matrix; it is not a claim that every
Peekaboo CLI combination is represented. `scripts/test-dual-controller-overlap.sh` is the complementary workflow-level
cell; its internal steps deliberately stay outside the 42-row command catalog.

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

That opt-in phase intentionally controls the shared cursor. It restores the prior cursor and sentinel only when their
current values still match Peekaboo's last write; a concurrent user change is newer state and is never overwritten. The
phase is not part of the default background certification and should run only on an otherwise idle desktop.
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
requested sentinel that is not already frontmost; the sentinel must not be any of the eight physical targets. Before a
live run, leave exactly one visible key or sole window open for Safari, Calendar, System Settings, Calculator, Activity
Monitor, and Finder. Add `--no-remote` when the exact CLI is team-signed and
has local TCC grants; this prevents an installed bridge host from masking working-tree behavior. A prebuilt app must
have a team signature and the exact current-source `PeekabooPlaygroundSource.json` manifest; ad-hoc or unstamped
fixtures are rejected.
