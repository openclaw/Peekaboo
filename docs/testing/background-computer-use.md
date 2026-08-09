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
`see`, `inspect-ui`, `image`, `capture live`, click by ID and query, `type`, `press`, `hotkey`, `paste`, `set-value`,
`perform-action`, and Accessibility-only targeted scroll. Stale snapshots and unsupported actions—including a target
without an AX scroll action—must fail nonzero instead of falling back to foreground synthesis.
Background keyboard requests with a window selector are also rejected because macOS process-targeted key events cannot
guarantee isolation between multiple windows in one process; the successful keyboard cases intentionally use exact PID.
The harness invokes the current CLI directly; it does not use AppleScript or a command runner.

Every background case is continuously sampled at 10 ms and fails if the sentinel PID or top window changes, the
physical cursor moves, the clipboard leaks, or a new visible Peekaboo window appears. Clipboard contents are hashed,
never printed. App-owned state is verified from fresh UI inspection plus controlled Playground logs; unrelated app
windows and content are not collected. Results go under `.artifacts/background-computer-use/<UTC>/`.

Background is the omission contract. `--foreground` is the only consent for activation, global keyboard input,
physical cursor movement, or synthetic pointer/wheel events. The optional physical phase is deliberately separate:

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

Use `--bin`, `--artifacts`, `--sentinel-bundle-id`, or `--playground-app ... --skip-playground-build` to select an exact
binary, controlled foreground app, or prebuilt signed fixture. Add `--no-remote` when the exact CLI is team-signed and
has local TCC grants; this prevents an installed bridge host from masking working-tree behavior. A prebuilt app must
have a team signature; ad-hoc fixtures are rejected.
