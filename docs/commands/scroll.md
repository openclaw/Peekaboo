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
- A concrete `--snapshot <id>` is authoritative and never triggers an observation refresh or a new capture. Omitted, blank, `latest`, `most-recent`, and `most_recent` references may refresh missing elements and therefore can require a capture-capable host.
- If a canonical scroll result requires fresh observation, or no canonical outcome is available, the used snapshot remains readable but cannot drive another mutation. Re-run `peekaboo see`; replaying the old ID returns `SNAPSHOT_STALE` before dispatch.
- Background scrolling first invokes a directional Accessibility action, then tries a settable descendant `AXScrollBar` used by standard AppKit scroll areas. If an opaque group still cannot scroll, a pixel-backed exact-window snapshot may use native PID-routed wheel events only for a visible, WebKit-linked, non-Electron app. Peekaboo revalidates the captured process generation, window ID, bounds, and point around every tick; it never activates the app, moves the cursor, or falls back to a desktop-global event.
- Fallback is available only before the first native scroll unit is accepted. If a multi-page Accessibility, scroll-bar, value, or exact-window route stops after a definite prefix, Peekaboo reports retry-unsafe `partial` with the exact accepted-unit count and side-effect recovery guidance; an ambiguous in-flight unit reports retry-unsafe `indeterminate` and requires fresh observation. Another route never replays the full requested amount.
- macOS does not acknowledge receiver consumption for PID-routed wheel events. A successful routed dispatch therefore reports `effect: "unverifiable"`, `retry_safe: false`, and requires a fresh observation before another scroll. Hidden apps, AX-only snapshots, Electron/Chromium/Catalyst apps, stale receipts, and changed bounds keep the existing pre-dispatch refusal.
- Foreground mode verifies focus when a target exists, then uses synthetic wheel events. Focus failure aborts before pointer dispatch.
- JSON output reports target diagnostics for element scrolls and the current pointer position for explicit foreground targetless scrolls. When a snapshot carries a complete exact receipt, `targetReceipt` repeats its snapshot ID, PID, decimal process-generation identity, window ID, and bounds so callers can audit the dispatched destination.
- `ScrollRequest` is handed directly to `AutomationServiceBridge.scroll`, so the CLI benefits from the same smooth/step semantics the agent runtime sees.

## Examples
```bash
# Scroll down five ticks wherever the pointer currently sits
peekaboo scroll --direction down --amount 5 --foreground

# Scroll the element labeled "table_orders" using the latest snapshot
peekaboo scroll --direction up --amount 2 --on table_orders

# Under capture-owner contention, create an exact classic receipt once and scroll without another capture
SNAPSHOT_ID=$(peekaboo see --pid 123 --window-id 456 --capture-engine classic --json | jq -r '.data.snapshot_id')
peekaboo scroll --direction down --on table_orders --snapshot "$SNAPSHOT_ID"

# Smooth horizontal pan after intentionally focusing Keynote
peekaboo scroll --direction right --smooth --app Keynote --foreground --space-switch
```

## Troubleshooting
- Background element scroll needs Accessibility. The exact-window WebKit wheel route and foreground wheel input also need Event Synthesizing on the selected execution host (`peekaboo permissions status`).
- If an omitted/latest snapshot needs refresh while another process owns ScreenCaptureKit, run an exact `peekaboo see --capture-engine classic`, then retry `scroll` with the returned concrete `--snapshot` ID. `scroll` itself does not accept `--capture-engine` because an explicit receipt performs no capture.
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
