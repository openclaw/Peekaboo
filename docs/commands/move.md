---
summary: 'Position the cursor via peekaboo move'
read_when:
  - 'hovering elements without clicking'
  - 'lining up the pointer before a screenshot or drag sequence'
---

# `peekaboo move`

`move` repositions the macOS cursor using coordinate targets, element IDs, fuzzy queries, or a simple “center of screen” flag. It’s useful for hover-driven menus, tooltips, or aligning the cursor before taking a screenshot.

## Key options
| Flag | Description |
| --- | --- |
| `[x,y]` | Optional positional coordinates (e.g., `540,320`). |
| `--coords <x,y>` | Coordinate target as an option (alias for the positional argument). |
| `--on <element-id>` | Jump to a Peekaboo element’s midpoint based on the latest snapshot. |
| `--id <element-id>` | Alias for `--on`. |
| `--to <query>` | Resolve an element by text/query using `waitForElement` (5 s timeout). |
| `--center` | Move to the main screen’s center (exclusive with other targets). |
| `--snapshot <id>` | Required when using `--on`/`--id`/`--to`; defaults to the most recent snapshot. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before moving. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| Focus flags | `FocusCommandOptions` control Space switching + retries. |
| `--smooth` | Use natural eased movement with distance-aware timing. |
| `--duration <ms>` / `--steps <n>` | Override movement timing/sample count; a positive duration opts into natural movement unless `--profile linear` is explicit. |
| `--profile <linear\|human>` | Select a movement profile. Animated moves default to `human`; instant moves default to `linear`. |

## Implementation notes
- Validation enforces exactly one target: coordinates (`[x,y]` or `--coords`), `--on`/`--id`, `--to`, or `--center`.
- Element-based moves reuse snapshot data via `services.snapshots.getDetectionResult`; query-based moves run `AutomationServiceBridge.waitForElement`, so they automatically wait up to 5 s for dynamic UIs.
- Smooth moves compute a bounded minimum-jerk Bézier path and track the previous cursor location so the result payload can include the travel distance.
- `--smooth`, a positive `--duration`, or `--profile human` enables natural movement with distance-aware duration and sample defaults. Use `--profile linear` for a straight path. See `docs/human-mouse-move.md` for deeper guidance.
- JSON output reports `fromLocation`, `targetLocation`, `targetDescription`, total distance, and run time. Element/query targets also include `targetPoint` diagnostics with the original snapshot midpoint, final resolved point, snapshot ID, and moved-window adjustment status.

## Examples
```bash
# Instantly move to a coordinate
peekaboo move 1024,88
peekaboo move --coords 1024,88

# Natural movement with one flag
peekaboo move 520,360 --smooth

# Hover the element with ID `menu_gear` using the latest snapshot
peekaboo move --on menu_gear --smooth

# Center the cursor on the main display before taking a screenshot
peekaboo move --center --duration 250 --steps 15
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
