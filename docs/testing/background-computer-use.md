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
and keeps Calculator as a controlled foreground sentinel. It then exercises fresh, exact PID/window snapshots through
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
harness terminates it, or if the sentinel PID/top window changes, the physical cursor moves, the clipboard leaks, or a
new visible Peekaboo window appears. Clipboard contents are hashed, never printed. Selected mutations use fresh UI
readback or PID-scoped Playground log checks and deltas; result contracts cover the remaining cases. Unrelated app
windows and content are not collected. Artifact directories must be new or empty so a rerun cannot reuse old summaries,
images, or logs. Results go under `.artifacts/background-computer-use/<UTC>/`.

The 34 required CLI cases are source-controlled in `scripts/background-computer-use-catalog.json`. Each row declares
its exit contract and, where applicable, its effect, delivery, refusal code, allowed outcome tuples, and named checks.
The catalog documents the monitored invariant families. The harness writes its observed facts per case and
`scripts/validate-background-computer-use-report.mjs` rejects missing, duplicate, or unknown rows; surface, command, or
phase drift; wrong refusal codes; disallowed conditional outcomes; effect or delivery drift; absent declared
readback/log/artifact evidence; monitor failure; and every recorded invariant violation. Command and phase identity are
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

That phase restores the cursor, relaunches Playground to reset fixture state, and returns to the Calculator sentinel.
Do not move Dock items, switch Spaces, or open file dialogs in this harness; those belong in explicitly destructive or
interactive test plans.

For a fast helper check with no GUI automation:

```bash
scripts/test-background-computer-use.sh --self-test
```

That self-test also validates a complete synthetic certification report. The reporter's fail-closed corruptions run in
the normal safe gate or directly with `pnpm run test:background-certification`; they cover deleted, duplicate, unknown,
wrong-refusal, missing-evidence, disallowed conditional-outcome, effect/delivery-drift, and invariant-canary reports.

Use `--bin`, `--artifacts`, `--sentinel-bundle-id`, or `--playground-app ... --skip-playground-build` to select an exact
binary, controlled foreground app, or prebuilt signed fixture. Add `--no-remote` when the exact CLI is team-signed and
has local TCC grants; this prevents an installed bridge host from masking working-tree behavior. A prebuilt app must
have a team signature; ad-hoc fixtures are rejected.
