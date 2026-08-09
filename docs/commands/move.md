---
summary: 'Position the cursor via peekaboo move'
read_when:
  - 'hovering elements without clicking'
  - 'lining up the pointer before a screenshot or drag sequence'
---

# `peekaboo move`

`move` repositions the shared macOS cursor using coordinate targets, element IDs, fuzzy queries, or a simple “center of screen” flag. It always affects the foreground desktop and therefore requires explicit `--foreground` consent.

## Key options
| Flag | Description |
| --- | --- |
| `[x,y]` | Optional positional coordinates (e.g., `540,320`). |
| `--coords <x,y>` | Coordinate target as an option (alias for the positional argument). |
| `--on <element-id>` | Jump to a Peekaboo element’s midpoint based on the latest snapshot. |
| `--to <query>` | Resolve an element by text/query using `waitForElement` (5 s timeout). |
| `--center` | Move to the main screen’s center (exclusive with other targets). |
| `--foreground` | Required confirmation that Peekaboo may move the shared physical cursor. |
| `--snapshot <id>` | Required when using `--on`/`--to`; defaults to the most recent snapshot. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before moving. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| Foreground focus flags | Space switching + retries; Peekaboo aborts if a requested target cannot be focused. |
| `--smooth` | Use natural eased movement with distance-aware timing. |
| `--duration <ms>` / `--steps <n>` | Override movement timing/sample count; a positive duration opts into natural movement unless `--profile linear` is explicit. |
| `--profile <linear\|human>` | Select a movement profile. Animated moves default to `human`; instant moves default to `linear`. |

## Implementation notes
- Validation enforces exactly one target: coordinates (`[x,y]` or `--coords`), `--on`, `--to`, or `--center`.
- Element-based moves reuse snapshot data via `services.snapshots.getDetectionResult`; query-based moves run `AutomationServiceBridge.waitForElement`, so they automatically wait up to 5 s for dynamic UIs.
- Smooth moves compute a bounded minimum-jerk Bézier path and track the previous cursor location so the result payload can include the travel distance.
- `--smooth`, a positive `--duration`, or `--profile human` enables natural movement with distance-aware duration and sample defaults. Use `--profile linear` for a straight path. See `docs/human-mouse-move.md` for deeper guidance.
- JSON output reports `fromLocation`, `targetLocation`, `targetDescription`, total distance, and run time. Element/query targets also include `targetPoint` diagnostics with the original snapshot midpoint, final resolved point, snapshot ID, and moved-window adjustment status.

## Examples
```bash
# Instantly move to a coordinate
peekaboo move 1024,88 --foreground
peekaboo move --coords 1024,88 --foreground

# Natural movement with one flag
peekaboo move 520,360 --smooth --foreground

# Hover the element with ID `menu_gear` using the latest snapshot
peekaboo move --on menu_gear --smooth --foreground

# Center the cursor on the main display before taking a screenshot
peekaboo move --center --duration 250 --steps 15 --foreground
```

## Troubleshooting
- Verify Event Synthesizing permission (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
