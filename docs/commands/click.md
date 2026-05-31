---
summary: 'Target UI elements via peekaboo click'
read_when:
  - 'building deterministic element interactions after running `see`'
  - 'debugging focus/snapshot issues for click automation'
---

# `peekaboo click`

`click` is the primary interaction command. It accepts element IDs, fuzzy text queries, or literal coordinates and then drives `AutomationServiceBridge.click`. Background delivery is the default so target apps do not need to become frontmost; pass `--foreground` for old foreground mouse behavior.

## Key options
| Flag | Description |
| --- | --- |
| `[query]` | Optional positional text query (case-insensitive substring match). |
| `--on <id>` / `--id <id>` | Target a specific Peekaboo element ID (e.g., `B1`, `T2`). |
| `--coords x,y` | Click coordinates. With target flags, coordinates are relative to the resolved target window; without target flags, they are global screen coordinates. |
| `--global-coords` | Treat `--coords` as global screen coordinates even when target flags are supplied. |
| `--snapshot <id>` | Reuse a prior snapshot; defaults to `services.snapshots.getMostRecentSnapshot()` when omitted. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before clicking. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| `--wait-for <ms>` | Millisecond timeout while waiting for the element to appear (default 5000). |
| `--double` / `--right` | Perform double-click or secondary-click instead of the default single click. |
| `--foreground` | Focus target and send a foreground mouse click. Focus flags also imply foreground delivery. |
| Focus flags | `--no-auto-focus`, `--focus-timeout-seconds`, `--focus-retry-count`, `--space-switch`, `--bring-to-current-space` (foreground mode only; see `FocusCommandOptions`). |
| `--focus-background` | Legacy alias for the default background delivery. Use `--app`, `--pid`, `--window-id`, or a snapshot with process metadata. |

## Implementation notes
- Validation makes sure you only provide one targeting strategy (ID/query vs. `--coords`) and that coordinate strings parse cleanly into doubles. Target-relative coordinate clicks fail if the point is outside the resolved window.
- When no `--snapshot` is provided, the command grabs the most recent snapshot ID (if any) before waiting for elements. Coordinate clicks skip snapshot usage entirely to avoid stale caches, but targeted coordinate clicks resolve the target window before synthesizing the final screen point.
- Background element/query clicks use cached snapshot geometry and skip foreground focus. Run `peekaboo see` first when you need fresh element IDs or target process metadata.
- Foreground element-based clicks call `AutomationServiceBridge.waitForElement` with the supplied timeout so you don’t have to insert manual sleeps. Helpful hints are printed when timeouts expire.
- `--foreground` enforces focus just before the click by `ensureFocused`; it will hop Spaces if necessary unless you pass `--no-auto-focus`.
- Background delivery uses process-targeted CoreGraphics mouse events and skips foreground focus. It requires Event Synthesizing access and a resolvable target process. Coordinate clicks need explicit `--app`, `--pid`, `--window-id`, or `--foreground`; element clicks can reuse snapshot process metadata.
- JSON output reports `clickedElement`, input coordinates, resolved screen coordinates, coordinate space, target window metadata, wait time, execution time, and `targetPoint` diagnostics. Element/query `targetPoint` includes the original snapshot midpoint, the final resolved point, the snapshot ID, and whether a moved-window adjustment was applied.

## Examples
```bash
# Click the "Send" button (ID from a previous `see` run)
peekaboo click --on B12

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
