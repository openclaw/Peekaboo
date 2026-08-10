---
summary: 'Position the cursor via peekaboo move'
read_when:
  - 'hovering elements without clicking'
  - 'lining up the pointer before a screenshot or drag sequence'
---

# `peekaboo move`

`move` repositions the shared macOS cursor using coordinate targets or element IDs. It always affects the foreground desktop and therefore requires explicit `--foreground` consent.

## Key options
| Flag | Description |
| --- | --- |
| `--at <x,y>` | Coordinate target; target-relative with app/window selectors, global otherwise. Add `--global` for explicit screen coordinates. |
| `--on <element-id>` | Jump to a Peekaboo element’s midpoint based on the latest snapshot. |
| `--foreground` | Required confirmation that Peekaboo may move the shared physical cursor. |
| `--snapshot <id>` | Used with `--on`; defaults to the most recent snapshot. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before moving. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| Foreground focus flags | Space switching + retries; Peekaboo aborts if a requested target cannot be focused. |
| `--smooth` | Use natural eased movement with distance-aware timing. |
| `--duration <duration>` / `--steps <n>` | Override movement timing/sample count; bare durations are milliseconds and `ms`/`s` suffixes are accepted. |
| `--profile <linear\|human>` | Select a movement profile. Animated moves default to `human`; instant moves default to `linear`. |

## Implementation notes
- Validation enforces exactly one target: `--at` or `--on`.
- Element-based moves reuse snapshot data via `services.snapshots.getDetectionResult`.
- Smooth moves compute a bounded minimum-jerk Bézier path and track the previous cursor location so the result payload can include the travel distance.
- `--smooth`, a positive `--duration`, or `--profile human` enables natural movement with distance-aware duration and sample defaults. Use `--profile linear` for a straight path. See `docs/human-mouse-move.md` for deeper guidance.
- JSON output reports `fromLocation`, `targetLocation`, `targetDescription`, total distance, and run time. Element targets also include `targetPoint` diagnostics with the original snapshot midpoint, final resolved point, snapshot ID, and moved-window adjustment status.

## Examples
```bash
# Instantly move to a coordinate
peekaboo move --at 1024,88 --global --foreground

# Natural movement with one flag
peekaboo move --at 520,360 --smooth --foreground

# Hover the element with ID `menu_gear` using the latest snapshot
peekaboo move --on menu_gear --smooth --foreground

```

## Troubleshooting
- Verify Event Synthesizing permission (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
