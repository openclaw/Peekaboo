---
summary: 'Execute .peekaboo.json scripts via peekaboo run'
read_when:
  - 'batching multiple CLI steps into a reusable automation script'
  - 'capturing structured execution results for regression tests'
---

# `peekaboo run`

`peekaboo run` loads a `.peekaboo.json` (PeekabooScript) file, executes every step via `ProcessService`, and reports the aggregated result. It’s the same engine the agent runtime uses for scripted flows, which makes it ideal for regression suites or reproducing agent traces.

## Key options
| Flag | Description |
| --- | --- |
| `<scriptPath>` | Positional argument pointing at a `.peekaboo.json` file. |
| `--output <file>` | Write the JSON execution report to disk. With `--json`, the report is also emitted to stdout. |
| `--no-fail-fast` | Continue executing the remaining steps even if one fails (default behavior is fail-fast). |
| `--json` | Emit machine-readable JSON to stdout (wrapper + `ScriptExecutionResult`). (Alias: `--json-output` / `-j`) |

## Implementation notes
- Scripts are parsed on the main actor via `services.process.loadScript`, so relative paths (`~/`, `./`) resolve exactly as they do when agents run scripts.
- Execution delegates to `services.process.executeScript`, which returns a `[StepResult]` containing individual timings, success flags, and error strings; the command wraps those in a summary with total durations and counts.
- `--output` writes via `JSONEncoder().encode` + atomic file replacement; if the write succeeds but the script fails, you still get the partial data for debugging. Pairing it with `--json` also emits the structured response to stdout.
- `<scriptPath>` and `--output` accept `~/...`.
- Script-level `see` screenshot paths and clipboard file/output paths also accept `~/...`.
- In JSON mode (`--json` / `--json-output` / `-j`), stdout is a single `CodableJSONResponse<ScriptExecutionResult>` payload (top-level `success` tracks overall script success).
- The command exits non-zero if any step fails (even when `--no-fail-fast` continues execution) so CI can register the run as failed.

## Script format

`params` is a normal flat JSON object. Values may be strings, booleans, numbers, or string arrays; do not use the old synthesized Swift enum shape (`generic._0`). Existing files with that legacy wrapper still decode, but newly encoded scripts and all examples use the stable flat form.

```json
{
  "description": "Background TextEdit shortcut",
  "steps": [
    {
      "stepId": "select-all",
      "command": "hotkey",
      "params": {
        "app": "TextEdit",
        "key": "a",
        "modifiers": ["command"]
      }
    }
  ]
}
```

Interaction steps use background delivery by default. `see`, `click`, `type`, `hotkey`, and `scroll` accept `app`,
`pid`, and `windowId` targets; process targets and exact window identities must agree when combined. An explicit
`windowId` never reuses a snapshot from a sibling window, even when both windows belong to the same process. An
interaction without `snapshot` carries the snapshot produced by the preceding `see` when its element or exact-window
context is required, and validates any explicit target against that snapshot. Set `"foreground": true` only when the
action intentionally focuses or drives the current desktop.

`pid` is a positive signed 32-bit integer and `windowId` is a positive unsigned 32-bit integer. A present malformed,
zero, negative, or out-of-range identifier fails before Peekaboo resolves or captures any fallback target.

Within one script, `snapshot` accepts a generated snapshot ID, `"latest"`, or the `stepId` of any preceding step that
produced a snapshot. Each `see` creates a fresh snapshot, so a later observation does not overwrite an earlier named
one. `latest` fails clearly if no preceding step has produced a snapshot.

Hotkeys use `key` plus `modifiers` as the canonical schema. For parity with the standalone command, the additive
`keys` chord form is also accepted, for example `"keys": ["cmd", "a"]` or `"keys": "cmd+a"`.

Safety is strict:

- Background `click`, `type`, and `hotkey` must resolve a process from `app`, `pid`, `windowId`, or a process-scoped snapshot. They fail instead of silently sending global input.
- Background clicks use the process-targeted click API. PID/window-targeted coordinates are resolved through background-safe Accessibility hit testing; a coordinate without a process target fails closed. Set `"foreground": true` only when you intentionally want a physical pointer click.
- Background typing and hotkeys use process-targeted keyboard delivery. For a window-scoped snapshot, `type` must name
  a `field` that Peekaboo can focus and verify inside that window, or immediately follow a successful exact-window
  click whose focused element remains inside it. The same immediate click proof can authorize a window-scoped
  `hotkey`; otherwise target the app/PID or use foreground delivery. Exact-window keyboard validation and dispatch are
  one host-side operation, and paced typing rechecks the owning window before every dispatched character.
- Background scroll requires both an element `target` and a process-scoped `snapshot`, normally produced by `see`. Targetless scroll, `swipe`, and `drag` affect the physical pointer and require `"foreground": true`.
- When foreground delivery has an app, PID, window, or snapshot target, `run` focuses that target before dispatching input.

## Examples
```bash
# Run a script and view the JSON summary inline
peekaboo run scripts/safari-login.peekaboo.json --json

# Capture results for later inspection but keep executing even if a step flakes
peekaboo run ./flows/regression.peekaboo.json --no-fail-fast --output /tmp/regression-results.json
```

```json
{
  "description": "Observe Safari, then interact without stealing focus",
  "steps": [
    {
      "stepId": "observe",
      "command": "see",
      "params": {"pid": 4242, "windowId": 9001, "path": "/tmp/safari.png"}
    },
    {
      "stepId": "click-address",
      "command": "click",
      "params": {"query": "Smart Search Field", "snapshot": "observe"}
    },
    {
      "stepId": "enter-url",
      "command": "type",
      "params": {"field": "Smart Search Field", "text": "https://example.com", "pressEnter": true}
    }
  ]
}
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- If an input step reports that `foreground: true` is required, either add a process/window/snapshot target for background delivery or opt into foreground delivery intentionally.
- Re-run with `--json` or `--verbose` to surface detailed errors.
