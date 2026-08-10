---
summary: 'Execute drag-and-drop flows via peekaboo drag'
read_when:
  - 'moving elements/files with precision between apps or coordinates'
  - 'testing multi-step drags (Trash, Dock targets, selection gestures)'
---

# `peekaboo drag`

`drag` simulates click-and-drag gestures with the shared physical cursor. It always affects the foreground desktop and requires explicit `--foreground` consent.

## Key options
| Flag | Description |
| --- | --- |
| `--from <id-or-x,y>` | Source element ID or coordinates. |
| `--to <id-or-x,y>` / `--to-app <name>` | Destination element, coordinates, or app. Use `--to-app Trash` for Dock drops. |
| `--snapshot <id>` | Needed whenever IDs are involved. Defaults to the most recent snapshot otherwise. |
| `--foreground` | Required confirmation that Peekaboo may use the shared physical cursor. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before dragging. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| `--duration <duration>` | Drag length (default `500ms`; bare values are milliseconds). |
| `--steps <count>` | Number of interpolation points (default 20) to control smoothness. |
| `--modifiers cmd,shift,…` | Comma-separated list of modifier keys held during the drag. |
| `--button left\|right` | Mouse button held during the drag (default `left`). |
| `--profile <linear\|human>` | `human` enables natural-looking arcs and jitter; defaults to `linear`. |
| Focus flags | `FocusCommandOptions` ensure the correct window is frontmost before the drag starts. |

## Implementation notes
- Input validation enforces “pick exactly one source and one destination flavor,” so you can’t accidentally mix coordinate + ID on the same side.
- When you pass `--to-app`, the command resolves the app’s focused window via AX and drags to its midpoint; `Trash` is handled specially by scraping the Dock’s accessibility hierarchy.
- Element IDs are resolved through `AutomationServiceBridge.waitForElement` (5 s timeout) and use the element’s bounds midpoint as the drag point.
- Modifiers are validated and normalized to `cmd|shift|option|ctrl|fn`; aliases `command|alt|control` are accepted.
- `--profile human` chooses adaptive duration/samples and posts drag events along the generated curve; `--steps` is honored up to the 96-sample safety cap.
- Results are logged in both human-readable form and JSON (`DragResult`) with start/end coordinates, duration, steps, modifiers, execution time, and `fromTargetPoint`/`toTargetPoint` diagnostics when either endpoint resolves from a snapshot element.

## Examples
```bash
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
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see` (or omit `--snapshot` to use the most recent one).
- Re-run with `--json` or `--verbose` to surface detailed errors.
