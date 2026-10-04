---
summary: 'Review Peekaboo Playground Testing Methodology guidance'
read_when:
  - 'planning work related to peekaboo playground testing methodology'
  - 'debugging or extending features described here'
---

# Peekaboo Playground Testing Methodology

Playground provides controlled UI elements and native action logs for testing Peekaboo. Test the default background
workflow first; a successful command dispatch is not proof that the intended receiver changed.

## Prepare a signed, owned test

Use the signed installed CLI for routine tests, or build and sign a source candidate using
[the building guide](building.md). Pin the exact binary and intended Bridge host. The
[background computer-use qualification guide](testing/background-computer-use.md) covers signed Playground artifacts,
source identities, independent observers, and the repository-owned native matrix.

```bash
PEEKABOO_BIN="${PEEKABOO_BIN:-$(command -v peekaboo)}"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/peekaboo-playground.XXXXXX")"
"$PEEKABOO_BIN" --version
"$PEEKABOO_BIN" bridge status --verbose --json
"$PEEKABOO_BIN" permissions status --all-sources --json
"$PEEKABOO_BIN" app list --include-hidden --include-background --json
```

Record the task-owned Playground PID and process generation, then select its window from `window list`.
Do not adopt or quit an existing user instance. Retain old artifacts and use a fresh run directory. Sign a locally built
Playground with the appropriate identity before launching it; unsigned compilation is not a qualified fixture.

Keep visualizer and deliberate foreground tests separate from background noninterference tests. Do not activate an app
or grant new permissions merely to turn a background refusal into success. A background launch request alone does not
prove that an app stayed behind the user's work.

Use `pnpm run test:automation:local` for the repository-owned local runner. A filtered Swift suite needs both
`PEEKABOO_INCLUDE_AUTOMATION_TESTS=true` and `RUN_LOCAL_TESTS=true`. Read-only/action CI lanes use
`RUN_AUTOMATION_READ` / `RUN_AUTOMATION_ACTIONS`; do not add per-test environment switches.

## Observe, act once, and verify

These examples are individual steps, not a batch to run with stale IDs. Assign each placeholder from the indicated
fresh result. An opaque element ID belongs to its snapshot; a snapshot is not a resumable Agent session.

### Element interaction

```bash
# PLAYGROUND_PID is the admitted task-owned process.
"$PEEKABOO_BIN" window list --pid "$PLAYGROUND_PID" --json
# Copy WINDOW_ID from that inventory.
"$PEEKABOO_BIN" see --pid "$PLAYGROUND_PID" --window-id "$WINDOW_ID" \
  --path "$RUN_DIR/before.png" --json

# Copy BUTTON_ID and SNAPSHOT_ID from this observation.
"$PEEKABOO_BIN" click --on "$BUTTON_ID" --snapshot "$SNAPSHOT_ID" --json
"$PEEKABOO_BIN" see --pid "$PLAYGROUND_PID" --window-id "$WINDOW_ID" \
  --path "$RUN_DIR/after-click.png" --json
```

For typing, click the intended text field from a fresh observation, observe it again, then use the new focused-field
snapshot with `type "Hello World" --snapshot "$FOCUSED_SNAPSHOT_ID" --json`. Never reuse the button's consumed snapshot
or silently add `--foreground` after a refusal. See the [click](commands/click.md) and [type](commands/type.md) contracts
for coordinate and keyboard routes.

Inspect `outcome` and `requires_fresh_observation` in JSON results. An accepted, indeterminate, or
`dispatched_unverified` action may already have changed the receiver, even if the command exits nonzero.
Do not repeat the input to make the status green: get fresh exact-target readback. Distinguish a no-dispatch refusal
from an unconfirmed mutation. Pixels and Accessibility data are not acquired atomically; retain a mixed-state
observation and verify the later state without replay.

### Window state

```bash
"$PEEKABOO_BIN" window list --pid "$PLAYGROUND_PID" --json
"$PEEKABOO_BIN" window minimize --pid "$PLAYGROUND_PID" --window-id "$WINDOW_ID" --json
"$PEEKABOO_BIN" window list --pid "$PLAYGROUND_PID" --json
```

After confirming the minimized state and unchanged identity, use
`window restore --pid "$PLAYGROUND_PID" --window-id "$WINDOW_ID" --json` and verify again.
`window focus` deliberately makes an app foreground; reserve it for a separately authorized foreground test.
The removed v3 command `peekaboo list windows` is not an alias for `peekaboo window list`.

### Menu selection

```bash
"$PEEKABOO_BIN" menu list --pid "$PLAYGROUND_PID" --json
# Use the path only if that fresh inventory reports it.
"$PEEKABOO_BIN" menu click --pid "$PLAYGROUND_PID" --path "Test Menu > Test Action 1" --json
```

Corroborate the callback through the owned PID's log and fresh UI/native state. Unverified menu delivery is not
permission to click again.

## Command and capability coverage

Start with `"$PEEKABOO_BIN" <command> --help` or `"$PEEKABOO_BIN" help <command>`, then read the command's documentation
and owning implementation. Both help forms are supported. App/process selectors and element selectors have different
roles: `--app` does not replace `--on`. Do not invent aliases to make an outdated example work.

For each relevant capability, record:

| Check | Required evidence |
| --- | --- |
| Basic behavior | Intended native effect and fresh exact-target readback, not just a successful response. |
| Parameters | Required/optional forms, conflicting selectors, missing or invalid values, and documented time units. |
| Text | Empty input, spaces/quotes, Unicode/emoji, newlines, literal text and expected selection ranges. |
| Refusals | Missing/ambiguous/stale targets; whether input was dispatched and whether retry is safe. |
| Isolation | Sampled foreground, pointer/buttons/modifiers, untouched guards, and the observer's gaps. |
| Performance | Actual operation latency and test conditions; separate startup, dispatch, and receiver completion. |
| Comparison | The same intended effect through the comparison tool, including its failures and limits. |

Playground's Click, Text, Controls, Scroll, Window, Drag, Keyboard and Dialog fixtures exercise different behavior.
An AX value replacement is not keyboard-event proof; an AXPress is not right/middle/double-click proof.
Help-only checks do not establish native capability coverage. Test combinations incrementally and preserve failed
attempts rather than silently replacing them with a successful replay.

## Logs and evidence

The log helper is useful for exploration:

```bash
./Apps/Playground/scripts/playground-log.sh --help
./Apps/Playground/scripts/playground-log.sh -c Click -n 20
```

It filters by subsystem/category, not an exact process. For qualification, scope native logs to the owned PID and the
run's time range; do not count another instance's events. The background qualification guide defines the current
pointer/keyboard witness contracts and their limitations. Keep captures local until inspected for unrelated/private
content, and record exact artifact/source identities alongside commands and results.

Document a reproduced issue in `Apps/Playground/PLAYGROUND_TEST.md` with the command, expected and actual behavior,
receiver/readback evidence, root cause, fix, and retest. Correct misleading help/examples at their owner rather than
adding a compatibility shim without a real public contract. Add a regression test where appropriate.

## Finish without disturbing other work

Stop new mutations after an uncertain result. Once pending input is terminal and fresh native evidence establishes a
safe state, normally quit only the exact generation admitted for this test:

```bash
"$PEEKABOO_BIN" app quit --pid "$PLAYGROUND_PID" \
  --expected-process-start-identity "$PLAYGROUND_START_ID" --json
```

Verify its absence and preserve other processes/windows. Do not force-quit an uncertain receiver, delete earlier test
evidence, or restore stale user focus/cursor/clipboard state. Report each case as passed, failed, blocked, or untested,
with any finite-sampling or missing-evidence limit.
