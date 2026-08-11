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

It builds the Playground fixture, signs it with the OpenClaw Foundation Developer ID, launches it without activation,
and samples the app that is already frontmost as the per-row sentinel. It never activates Calculator or restores a
stale foreground app after the run. It then exercises fresh, exact PID/window snapshots through
`see` (including AX-only and screenshot-only modes), `capture live`, click by ID and query, `type`, `press`, `paste`,
`set-value`, `action`, and Accessibility-only targeted scroll. Stale snapshots and unsupported named AX actions must
fail nonzero instead of falling back to foreground synthesis. Targeted scroll must report confirmed Accessibility
delivery and produce an independent, PID-scoped Playground offset change.
The monitored lifecycle phase also launches distinct TextEdit processes with exact window receipts, establishes a
non-maximized exact frame, then maximizes and closes that background window. Quit accepts exactly two tuples: confirmed
success with the target process gone, or `suspected_noop`/`INTERACTION_FAILED` with that target still alive. The harness
does not infer the state of an unrelated sibling process from the quit result.
Harness cleanup consumes each controlled PID and process-start identity directly from the launch/relaunch result and
passes both values in one generation-pinned `app quit` request. A missing receipt for the essential Playground fixture
aborts immediately; a missing lifecycle receipt records a failed/omitted catalog case. Cleanup never probes a bare
post-launch PID to mint ownership or issues a separate unpinned quit that could hit a recycled process. Background
keyboard requests with a window selector are refused. Process-only cases use the exact PID to isolate the target
process and intentionally do not claim sibling-window isolation.
The harness invokes the current CLI directly; it does not use AppleScript or a command runner.

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
Peekaboo CLI combination is represented. Dual-controller overlap is intentionally outside these rows and is not yet an
in-tree certification cell. Once source-controlled, it should remain one complementary workflow-level cell rather than
duplicating its internal steps in this catalog.

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
