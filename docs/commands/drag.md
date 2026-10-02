---
summary: 'Execute drag-and-drop flows via peekaboo drag'
read_when:
  - 'moving elements/files with precision between apps or coordinates'
  - 'testing multi-step drags (Trash, Dock targets, selection gestures)'
---

# `peekaboo drag`

`drag` defaults to one bounded, linear background gesture inside the exact window owned by an explicit fresh `--snapshot`. It routes primer, button-down, drag samples, and button-up to that window without moving the physical cursor, activating an app, or showing an overlay. Coordinates are global logical screen points; both endpoints must remain inside the captured window.

Cross-window/application drops, modifiers, human movement, and shared physical cursor input require explicit `--foreground` consent. A completed dispatch is **unverified and retry-unsafe**: mouse-up is not proof that the application performed the requested drop. Observe the exact window before another action.

## Key options
| Flag | Description |
| --- | --- |
| `--from <id-or-x,y>` | Source element ID or coordinates. |
| `--to <id-or-x,y>` / `--to-app <name>` | Destination element, coordinates, or app. Use `--to-app Trash` for Dock drops. |
| `--snapshot <id>` | Required explicit fresh exact-window snapshot in background mode; both IDs resolve from this same snapshot. Foreground retains latest-snapshot resolution. |
| `--foreground` | Opt in to shared physical cursor input and foreground focus. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before dragging. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| `--duration <duration>` | Drag length (default `500ms`; bare values are milliseconds). Background range: 1–10000 ms. |
| `--steps <count>` | Number of drag samples (default 20). Background range: 1–96. |
| `--modifiers cmd,shift,…` | Comma-separated list of modifier keys held during the drag. |
| `--button left\|right` | Mouse button held during the drag (default `left`). |
| `--profile <linear\|human>` | `human` enables natural-looking arcs and jitter; defaults to `linear`. |
| Focus flags | `FocusCommandOptions` ensure the correct window is frontmost before the drag starts. |

## Implementation notes
- Background drag has its own capability-gated Bridge protocol 1.39 request. Older hosts refuse before dispatch; there is no implicit foreground fallback. Background targeting comes only from the snapshot, so app/window selectors require foreground mode.
- Signed drag receipts preserve the snapshot's optional focused-element evidence alongside its exact process/window identity and bounds. This is captured context, not proof of current focus or drop success.
- The existing held-pointer lifecycle owns the exact-window lane, validates generation and immutable bounds at every sample, and performs terminal cleanup once at the last accepted point. Cancellation, expiry, and target drift await cleanup; a recycled PID never receives mouse-up.
- Results count the routing primer, down, each accepted drag sample, and cleanup up. The complete count is `steps + 3`; interrupted drags retain the exact accepted prefix and target receipt with `indeterminate`/`completion_unknown` evidence, never a claim of verified drop or failed cleanup merely because the path stopped.
- Input validation enforces “pick exactly one source and one destination flavor,” so you can’t accidentally mix coordinate + ID on the same side.
- When you pass `--to-app`, the command resolves the app’s focused window via AX and drags to its midpoint; `Trash` is handled specially by scraping the Dock’s accessibility hierarchy.
- Background element IDs resolve immediately from the supplied immutable snapshot; a missing source or destination ID retains `ELEMENT_NOT_FOUND` with explicit retry-safe, zero-dispatch refusal metadata. No target receipt is invented before target validation. Foreground IDs use `AutomationServiceBridge.waitForElement` (5 s timeout). Both use the element’s bounds midpoint as the drag point.
- Modifiers are validated and normalized to `cmd|shift|option|ctrl|fn`; aliases `command|alt|control` are accepted.
- `--profile human` chooses adaptive duration/samples and posts drag events along the generated curve; `--steps` is honored up to the 96-sample safety cap.
- Results are logged in both human-readable form and JSON (`DragResult`) with start/end coordinates, duration, steps, modifiers, execution time, and `fromTargetPoint`/`toTargetPoint` diagnostics when either endpoint resolves from a snapshot element.

## Examples
```bash
# Background drag inside one captured exact window (global logical coordinates)
peekaboo drag --from "120,180" --to "300,180" --snapshot "$SNAPSHOT_ID"

# Drag a file element into the Trash
peekaboo drag --from file_tile_3 --to-app Trash --foreground

# Coordinate → coordinate drag with longer duration
peekaboo drag --from "120,880" --to "480,220" --duration 1.2s --steps 40 --foreground

# Human-style drag with adaptive timing
peekaboo drag --from "80,80" --to "420,260" --profile human --button right --foreground

# Range-select items by holding Shift
peekaboo drag --from row_1 --to row_5 --modifiers shift --foreground
```

## Troubleshooting
- Verify Event Synthesizing permission (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, observe again with `peekaboo see` and pass its new snapshot explicitly. Only foreground mode may omit `--snapshot` to use the most recent one.
- Re-run with `--json` or `--verbose` to surface detailed errors.
