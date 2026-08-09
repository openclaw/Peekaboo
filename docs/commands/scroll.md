---
summary: 'Scroll targets in the background or explicitly synthesize foreground wheel input'
read_when:
  - 'panning long views or tables without dragging the scrollbar'
  - 'needing scroll result details (direction, ticks) for automation logs'
---

# `peekaboo scroll`

`scroll` invokes an element's Accessibility scroll action by default, keeping the target app in the background and leaving the shared cursor untouched. Add `--foreground` for targetless, smooth, or delayed synthetic wheel input.

## Key options
| Flag | Description |
| --- | --- |
| `--direction up|down|left|right` | Required. Case-insensitive and validated before execution. |
| `--amount <ticks>` | Number of scroll “ticks” (default `3`). Smooth mode multiplies this internally. |
| `--on <element-id>` | Scroll relative to a Peekaboo element from the current/most recent snapshot. |
| `--snapshot <id>` | Override the snapshot used to resolve `--on`. |
| `--foreground` | Focus the target and allow synthetic wheel events at the physical pointer. Required without `--on`. |
| `--delay <ms>` | Milliseconds between synthetic ticks (default `0`; nonzero requires `--foreground`). |
| `--smooth` | Use smaller synthetic increments; requires `--foreground`. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>`. Background mode uses these only to resolve/refresh the target; foreground mode focuses it first. |
| Foreground focus flags | `--space-switch`, `--bring-to-current-space`, timeout, and retry controls require `--foreground`. |

## Implementation notes
- If you pass `--on` without a snapshot, the command automatically looks up `services.snapshots.getMostRecentSnapshot()` so you rarely need to wire IDs manually.
- Background scrolling is action-only. If the target has no usable Accessibility scroll action, Peekaboo fails with guidance to retry in foreground rather than silently moving the cursor or scrolling another app.
- Foreground mode verifies focus when a target exists, then uses synthetic wheel events. Focus failure aborts before pointer dispatch.
- JSON output reports target diagnostics for element scrolls and the current pointer position for explicit foreground targetless scrolls.
- `ScrollRequest` is handed directly to `AutomationServiceBridge.scroll`, so the CLI benefits from the same smooth/step semantics the agent runtime sees.

## Examples
```bash
# Scroll down five ticks wherever the pointer currently sits
peekaboo scroll --direction down --amount 5 --foreground

# Scroll the element labeled "table_orders" using the latest snapshot
peekaboo scroll --direction up --amount 2 --on table_orders

# Smooth horizontal pan after intentionally focusing Keynote
peekaboo scroll --direction right --smooth --app Keynote --foreground --space-switch
```

## Troubleshooting
- Background element scroll needs Accessibility; foreground wheel input needs Event Synthesizing (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
