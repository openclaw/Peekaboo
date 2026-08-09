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

Interaction steps use background delivery by default. `click`, `type`, `hotkey`, and `scroll` accept the common target fields `app`, `pid`, `windowId`, and `snapshot`; an explicit field overrides the snapshot carried from the preceding `see` step. Process target fields must agree when combined. Set `"foreground": true` only when the action intentionally focuses or drives the current desktop.

Safety is strict:

- Background `click`, `type`, and `hotkey` must resolve a process from `app`, `pid`, `windowId`, or a process-scoped snapshot. They fail instead of silently sending global input.
- Background clicks use the process-targeted click API. PID/window-targeted coordinates are resolved through background-safe Accessibility hit testing; a coordinate without a process target fails closed. Set `"foreground": true` only when you intentionally want a physical pointer click.
- Background typing and hotkeys use process-targeted keyboard delivery. A `field` on `type` is clicked through the same delivery route before the typing actions are sent.
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
      "params": {"app": "Safari", "path": "/tmp/safari.png"}
    },
    {
      "stepId": "click-address",
      "command": "click",
      "params": {"query": "Smart Search Field"}
    },
    {
      "stepId": "enter-url",
      "command": "type",
      "params": {"text": "https://example.com", "pressEnter": true}
    }
  ]
}
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- If an input step reports that `foreground: true` is required, either add a process/window/snapshot target for background delivery or opt into foreground delivery intentionally.
- Re-run with `--json` or `--verbose` to surface detailed errors.
