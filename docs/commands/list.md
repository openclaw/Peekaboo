---
summary: 'Enumerate apps, windows, screens, and permissions via peekaboo list'
read_when:
  - 'inspecting what Peekaboo can currently target'
  - 'scripting toolchains that need structured app/window inventory'
---

# `peekaboo list`

`peekaboo list` is a container command that fans out into focused inventory subcommands. Each subcommand returns human-readable tables by default and emits the same structure in JSON when `--json` is set, so agents can choose whichever format fits their control loop.

## Subcommands
| Subcommand | What it does | Notable options |
| --- | --- | --- |
| `apps` (default) | Enumerates every running GUI app with bundle ID, PID, and focus status. | None. |
| `windows` | Lists the windows owned by a specific process with optional bounds/ID metadata. | `--app <name|bundle|PID:1234>` (required), `--pid`, `--include-details bounds,ids,off_screen`. |
| `menubar` | Dumps every status-item title/index so you can target them via `menubar click`. | Supports `--json` for scripts piping into `jq`. |
| `screens` | Shows connected displays, resolution, scaling, and whether they are main/secondary. | None. |
| `permissions` | Mirrors `peekaboo permissions status` for quick entitlement checks. | None.

## Implementation notes
- The root command does nothing; Commander dispatches straight to the subcommand so `peekaboo list` defaults to `list apps`.
- Application inventory prefers the GUI bridge host so sandboxed CLI callers see the GUI session’s complete process list. Other read-only inventory stays local by default unless its command needs host state or you pass `--bridge-socket <path>`.
- `windows` calls `requireScreenRecordingPermission` before crawling AX so macOS doesn’t silently strip metadata; `apps` does not require Screen Recording.
- `windows` accepts either user-friendly names or `PID:####` tokens and normalizes `--include-details` values by lowercasing + replacing `-` with `_`, so both `--include-details offscreen,bounds` and `off_screen` work.
- `windows` deduplicates entries by `window_id` and assigns contiguous `index` values afterwards, so `--window-index` targeting lines up with what is printed. It intentionally shows the full enumeration (including tiny/utility windows on non-zero layers); `peekaboo window list` filters those out but keeps the same IDs and indexes.
- Menu bar listing is powered by the same `MenuServiceBridge` used by `peekaboo menubar`, so indices reported here line up with what `menubar click --index` expects.
- App/window/screen inventory uses `UnifiedToolOutput` payloads, which include `data`, `summary`, and `metadata`. `list permissions --json` mirrors `permissions status --json` with the standard `{ success, data }` envelope.

## Examples
```bash
# Default invocation: list every app currently visible to AX
peekaboo list

# Inspect all Chrome windows including their bounds + element IDs
peekaboo list windows --app "Google Chrome" --include-details bounds,ids

# Pipe the current display layout into jq for scripting
peekaboo list screens --json | jq '.data.screens[] | {name, size: .frame}'
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
