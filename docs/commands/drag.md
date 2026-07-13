---
summary: 'Execute drag-and-drop flows via peekaboo drag'
read_when:
  - 'moving elements/files with precision between apps or coordinates'
  - 'testing multi-step drags (Trash, Dock targets, selection gestures)'
---

# `peekaboo drag`

`drag` simulates click-and-drag gestures. You can start/end on element IDs, raw coordinates, or even another application (e.g., `--to-app Trash`). Modifiers (Cmd/Shift/Option/Ctrl) are supported, so multi-select drags behave like real keyboard-assisted gestures.

## Key options
| Flag | Description |
| --- | --- |
| `--from <id>` / `--from-coords x,y` | Source handle. Exactly one of these is required. |
| `--to <id>` / `--to-coords x,y` / `--to-app <name>` | Destination. Use `--to-app Trash` for Dock drops or any bundle ID/name for app-centric drops. |
| `--snapshot <id>` | Needed whenever IDs are involved. Defaults to the most recent snapshot otherwise. |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before dragging. (`--window-title`/`--window-index` require `--app` or `--pid`; `--window-id` does not.) |
| `--duration <ms>` | Drag length (default 500 ms). |
| `--steps <count>` | Number of interpolation points (default 20) to control smoothness. |
| `--modifiers cmd,shift,…` | Comma-separated list of modifier keys held during the drag. |
| `--profile <linear\|human>` | `human` enables natural-looking arcs and jitter; defaults to `linear`. |
| Focus flags | `FocusCommandOptions` ensure the correct window is frontmost before the drag starts. |

## Implementation notes
- Input validation enforces “pick exactly one source and one destination flavor,” so you can’t accidentally mix coordinate + ID on the same side.
- When you pass `--to-app`, the command resolves the app’s focused window via AX and drags to its midpoint; `Trash` is handled specially by scraping the Dock’s accessibility hierarchy.
- Element IDs are resolved through `AutomationServiceBridge.waitForElement` (5 s timeout) and use the element’s bounds midpoint as the drag point.
- Modifier strings are forwarded verbatim to `DragRequest`, so `--modifiers cmd,shift` behaves like holding Cmd+Shift while dragging.
- `--profile human` chooses adaptive duration/samples and posts drag events along the generated curve; `--steps` is honored up to the 96-sample safety cap.
- Results are logged in both human-readable form and JSON (`DragResult`) with start/end coordinates, duration, steps, modifiers, execution time, and `fromTargetPoint`/`toTargetPoint` diagnostics when either endpoint resolves from a snapshot element.

## Examples
```bash
# Drag a file element into the Trash
peekaboo drag --from file_tile_3 --to-app Trash

# Coordinate → coordinate drag with longer duration
peekaboo drag --from-coords "120,880" --to-coords "480,220" --duration 1200 --steps 40

# Human-style drag with adaptive timing
peekaboo drag --from-coords "80,80" --to-coords "420,260" --profile human

# Range-select items by holding Shift
peekaboo drag --from row_1 --to row_5 --modifiers shift
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- If you see `SNAPSHOT_NOT_FOUND`, regenerate the snapshot with `peekaboo see` (or omit `--snapshot` to use the most recent one).
- Re-run with `--json` or `--verbose` to surface detailed errors.
