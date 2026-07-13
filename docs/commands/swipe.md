---
summary: 'Perform gesture-style drags via peekaboo swipe'
read_when:
  - 'animating trackpad-like swipes between coordinates or elements'
  - 'needing smooth, timed drags for carousels/cover flow UI'
---

# `peekaboo swipe`

`swipe` drives `AutomationServiceBridge.swipe` to move from one point to another over a fixed duration. You can describe the endpoints via element IDs (from `see`) or raw coordinates, which makes it flexible for both deterministic automation and exploratory scripts.

## Key options
| Flag | Description |
| --- | --- |
| `--from <id>` / `--from-coords x,y` | Source location (ID requires a valid snapshot). |
| `--to <id>` / `--to-coords x,y` | Destination location (also supports IDs or literal coordinates). |
| `--snapshot <id>` | Needed whenever you reference IDs so the command can look up bounds. Auto-resolves to the most recent snapshot if omitted. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before swiping. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| Focus flags | `FocusCommandOptions` control Space switching + retries. |
| `--duration <ms>` | Default 500 ms; controls how long the swipe lasts. |
| `--steps <count>` | Number of intermediate points for smoothing (default 20). |
| `--right-button` | Currently rejected — the implementation throws a validation error because right-button drags are not yet wired up. |
| `--profile <linear\|human>` | Use `human` for gesture traces that look like real pointer motion. |

## Implementation notes
- The command validates that both ends are provided (mixing IDs and coordinates is fine) before doing any work.
- Element lookups reuse the `[waitForElement + bounds.midpoint]` flow with a 5 s timeout, so swipes tolerate elements that pop in slightly late.
- Coordinate parsing accepts `"x,y"` with optional whitespace; invalid strings result in immediate validation errors.
- After issuing the swipe it waits ~0.1 s before reporting success to give AppKit time to settle (matching what integration tests expect).
- JSON output surfaces both endpoints and the computed Euclidean distance. Element endpoints also include `fromTargetPoint`/`toTargetPoint` diagnostics with the original snapshot midpoint, final resolved point, snapshot ID, and moved-window adjustment status.
- `--profile human` enables adaptive duration/samples and posts the swipe along a bounded eased arc; see `docs/human-mouse-move.md` for details.

## Examples
```bash
# Swipe between two element IDs captured by `see`
peekaboo swipe --from card_1 --to card_2 --duration 650 --steps 30

# Drag from coordinates (x1,y1) to (x2,y2)
peekaboo swipe --from-coords 120,880 --to-coords 120,200

# Human-style swipe with adaptive easing
peekaboo swipe --from-coords 80,640 --to-coords 820,320 --profile human

# Mix coordinate → element drag using the most recent snapshot
peekaboo swipe --from-coords 400,400 --to drawer_toggle
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see` (or omit `--snapshot` to use the most recent one).
- Re-run with `--json` or `--verbose` to surface detailed errors.
