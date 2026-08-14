---
summary: 'Scroll targets in the background or explicitly synthesize foreground wheel input'
read_when:
  - 'panning long views or tables without dragging the scrollbar'
  - 'needing scroll result details (direction, ticks) for automation logs'
---

# `peekaboo scroll`

`scroll` invokes an element's Accessibility scroll action by default, keeping the target app in the background and leaving the shared cursor untouched. When a visible WKWebView/Tauri surface exposes only an opaque container, Peekaboo can instead route line-wheel events to the fresh snapshot's exact PID/window. Add `--foreground` for targetless, smooth, or delayed global wheel input.

## Key options
| Flag | Description |
| --- | --- |
| `--direction up|down|left|right` | Required. Case-insensitive and validated before execution. |
| `--amount <ticks>` | Number of scroll “ticks” (default `3`). Smooth mode multiplies this internally. |
| `--on <element-id>` | Scroll relative to a Peekaboo element from the current/most recent snapshot. |
| `--snapshot <id>` | Override the snapshot used to resolve `--on`. |
| `--foreground` | Focus the target and allow synthetic wheel events at the physical pointer. Required without `--on`. |
| `--delay <duration>` | Time between synthetic ticks (default `0`; bare values are milliseconds; nonzero requires `--foreground`). |
| `--smooth` | Use smaller synthetic increments; requires `--foreground`. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>`. Background mode uses these only to resolve/refresh the target; foreground mode focuses it first. |
| Foreground focus flags | `--space-switch`, `--bring-to-current-space`, timeout, and retry controls require `--foreground`. |

## Implementation notes
- If you pass `--on` without a snapshot, the command automatically looks up `services.snapshots.getMostRecentSnapshot()` so you rarely need to wire IDs manually.
- If a canonical scroll result requires fresh observation, or no canonical outcome is available, the used snapshot remains readable but cannot drive another mutation. Re-run `peekaboo see`; replaying the old ID returns `SNAPSHOT_STALE` before dispatch.
- Background scrolling first invokes a directional Accessibility action, then tries a settable descendant `AXScrollBar` used by standard AppKit scroll areas. If an opaque group still cannot scroll, a pixel-backed exact-window snapshot may use native PID-routed wheel events only for a visible, WebKit-linked, non-Electron app. Peekaboo revalidates the captured process generation, window ID, bounds, and point around every tick; it never activates the app, moves the cursor, or falls back to a desktop-global event.
- macOS does not acknowledge receiver consumption for PID-routed wheel events. A successful routed dispatch therefore reports `effect: "unverifiable"`, `retry_safe: false`, and requires a fresh observation before another scroll. Hidden apps, AX-only snapshots, Electron/Chromium/Catalyst apps, stale receipts, and changed bounds keep the existing pre-dispatch refusal.
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
- Background element scroll needs Accessibility. The exact-window WebKit wheel route and foreground wheel input also need Event Synthesizing on the selected execution host (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
