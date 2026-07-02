---
summary: 'Target UI elements via peekaboo click'
read_when:
  - 'building deterministic element interactions after running `see`'
  - 'debugging focus/snapshot issues for click automation'
---

# `peekaboo click`

`click` is the primary interaction command. It accepts element IDs, fuzzy text queries, or literal coordinates and then drives `AutomationServiceBridge.click`. Background delivery is the default so target apps do not need to become frontmost; pass `--foreground` for focused foreground mouse behavior.

## Key options
| Flag | Description |
| --- | --- |
| `[query]` | Optional positional text query (case-insensitive substring match). |
| `--on <id>` / `--id <id>` | Target an opaque Peekaboo element ID copied exactly from current `see` or `inspect-ui` output. |
| `--coords x,y` | Click coordinates. With target flags, coordinates are relative to the resolved target window; without target flags, they are global screen coordinates. |
| `--global-coords` | Treat `--coords` as global screen coordinates even when target flags are supplied. |
| `--snapshot <id>` | Reuse a prior snapshot; defaults to `services.snapshots.getMostRecentSnapshot()` when omitted. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — resolve the app/window that should receive the click. In background mode this does not focus the app; with `--foreground` it focuses before clicking. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| `--wait-for <ms>` | Millisecond timeout while waiting for the element to appear (default 5000). |
| `--double` / `--right` | Perform double-click or secondary-click instead of the default single click. |
| `--foreground` | Focus target and send a foreground mouse click. Focus flags also imply foreground delivery. |
| Focus flags | `--no-auto-focus`, `--focus-timeout-seconds`, `--focus-retry-count`, `--space-switch`, `--bring-to-current-space` (foreground mode only; see `FocusCommandOptions`). |
| `--focus-background` | Legacy alias for the default background delivery. Use `--app`, `--pid`, `--window-id`, or a snapshot with process metadata. |

## Delivery modes
- **Background** is the default when Peekaboo can resolve a target process from target flags or snapshot metadata. Element/query clicks invoke the matching AX action first, then fall back to a process-targeted event when needed; coordinate clicks use process-targeted events. Neither path activates or focuses the app.
- **Foreground** (`--foreground`) focuses the target first and sends the click through the normal focused path. Use it for apps that require a key window, clicks that must move focus, or Space-switching flows.
- Background coordinate clicks need `--app`, `--pid`, or `--window-id` so Peekaboo knows which process/window owns the coordinate. Without a target, use global coordinates with foreground delivery.

## Implementation notes
- Validation makes sure you only provide one targeting strategy (ID/query vs. `--coords`) and that coordinate strings parse cleanly into doubles. Target-relative coordinate clicks fail if the point is outside the resolved window.
- When no `--snapshot` is provided, the command grabs the most recent snapshot ID (if any) before waiting for elements. Coordinate clicks skip snapshot usage entirely to avoid stale caches, but targeted coordinate clicks resolve the target window before synthesizing the final screen point.
- Background element/query clicks re-resolve cached elements in the target process and exact snapshot window, then invoke their AX action before falling back to snapshot geometry. Mismatched process/window selectors and unverifiable window snapshots are rejected. Run `peekaboo see` first when you need fresh element IDs or target metadata.
- Foreground element-based clicks call `AutomationServiceBridge.waitForElement` with the supplied timeout so you don’t have to insert manual sleeps. Helpful hints are printed when timeouts expire.
- `--foreground` enforces focus just before the click by `ensureFocused`; it will hop Spaces if necessary unless you pass `--no-auto-focus`.
- Synthetic background fallback stamps CoreGraphics events with the resolved process and exact window ID, rejects vanished/reused windows or points outside current bounds, and requires Event Synthesizing access. macOS still does not report whether the target accepted a posted event; AX-action success is directly reported by Accessibility.
- JSON output reports `clickedElement`, input coordinates, resolved screen coordinates, coordinate space, target window metadata, wait time, execution time, and `targetPoint` diagnostics. Element/query `targetPoint` includes the original snapshot midpoint, the final resolved point, the snapshot ID, and whether a moved-window adjustment was applied.

## Examples
```bash
# Click the "Send" button using an ID copied from current `see` output
peekaboo click --on "$ELEMENT_ID"

# Fuzzy search + extra wait for a slow dialog using foreground delivery
peekaboo click "Allow" --foreground --wait-for 8000 --space-switch

# Issue a right-click at global screen coordinates
peekaboo click --coords 1024,88 --right --foreground --no-auto-focus

# Click 20,40 inside a resolved app window
peekaboo click --app Safari --coords 20,40

# Force global screen coordinates while still focusing a target first
peekaboo click --window-id 59620 --coords 1024,88 --global-coords --foreground

# Click Safari coordinates without activating Safari
peekaboo click --coords 420,180 --app Safari --global-coords
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see` (or omit `--snapshot` to use the most recent one). Cleaned/expired snapshots cannot be reused.
- Re-run with `--json` or `--verbose` to surface detailed errors.
