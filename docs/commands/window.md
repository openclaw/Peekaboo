---
summary: 'Move, resize, and focus windows via peekaboo window'
read_when:
  - 'wrangling app windows before issuing UI interactions'
  - 'needing JSON receipts for close/minimize/maximize/focus actions'
---

# `peekaboo window`

`window` gives you programmatic control over macOS windows. Every subcommand accepts `WindowIdentificationOptions` (`--app`, `--pid`, `--window-id`, `--window-title`, `--window-index`) so you can pinpoint the exact window before acting. Output is mirrored in JSON and text for easy scripting.

## Subcommands
| Name | Purpose | Key options |
| --- | --- | --- |
| `close` / `minimize` / `maximize` | Perform the respective window chrome action. | Standard window-identification flags. |
| `focus` | Bring the window forward, optionally hopping Spaces or moving it to the current Space. | Adds `FocusCommandOptions` plus `--verify` to confirm focus. |
| `move` | Move the window to new coordinates. | `-x <int>` / `-y <int>` specify the new origin. |
| `resize` | Adjust width/height while keeping the origin. | `-w <int>` / `--height <int>`. |
| `set-bounds` | Set both origin and size in one go. | `--x`, `--y`, `--width`, `--height`. |
| `list` | Lists an app's renderable windows (filtered view of `list windows`). | Same targeting flags; adds `--group-by-space`. |

## Implementation notes
- Every action validates that at least an app, PID, or window ID is supplied; optional `--window-title` and `--window-index` disambiguate when multiple windows exist.
- `move`, `resize`, `set-bounds`, and `maximize` read the window frame back after acting; `new_bounds` in the JSON payload always reflects the frame the window actually settled at, not the requested one.
- `move`, `resize`, and `set-bounds` also verify the achieved frame against the request. macOS accepts geometry requests and then lets the app constrain them (e.g. a SwiftUI `minWidth`/`minHeight`), so the request can be applied only partially or not at all:
  - Partially applied (frame changed but missed the request): the command still succeeds, `requested_bounds` and a `warning` string are included in the JSON payload, and the text output prints the actual frame plus the warning.
  - Fully ignored (frame did not change at all): the command fails with exit code 1 and error code `WINDOW_MANIPULATION_ERROR`, because reporting success would silently lie to scripts. Typical cause: shrinking a window below its minimum size when it already sits at that minimum.
  - If the frame cannot be re-read after the operation, the command succeeds with a `warning` that the reported bounds may be stale.
- `maximize` presses the green zoom button, which is animated, so the read-back polls until the frame stops changing (stable across two consecutive reads) before reporting; `new_bounds` is the settled frame, not a mid-animation frame. If the frame never stabilizes within the poll budget, the command still succeeds but adds a `warning` that the bounds may be approximate.
- `maximize` is idempotent. AppKit's zoom button is a toggle (pressing it on an already-maximized window would restore the previous size), so `maximize` first checks whether the window already occupies its screen's visible frame, matched on both origin and size (screen frames are flipped into the window's coordinate space first). If it does, the zoom press is skipped: the window stays maximized and the text output prints `is already maximized`. The match is conservative — a screen-sized window that has been moved or pushed partly off-screen does not match, so `maximize` presses zoom and repositions it; and an app whose zoom target is smaller than the whole screen is never treated as "already maximized". In both cases `maximize` presses zoom rather than no-op'ing a real request.
- `focus` routes through the exact CG window ID, makes the window main, raises it, and honors the global focus flags (`--space-switch` to jump Spaces, `--bring-to-current-space` to move the window instead, etc.). Success requires macOS Accessibility to report that exact window as focused and Workspace to report its app as frontmost.
- `focus --verify` performs a second command-level check against the exact focused window ID. A merely topmost/renderable sibling no longer counts as focused.
- `peekaboo list windows --app <app>` is the full per-application enumeration and may include utility, off-screen, tiny, transparent, or otherwise non-renderable windows. `window list` uses the same window IDs and indexes but filters to renderable windows for interaction targeting: entries on non-zero layers, smaller than 60x60, fully transparent, or excluded from the Windows menu are dropped. The surviving windows keep their canonical `index` values, so indexes shown here can have gaps yet still match `--window-index` and `list windows` output.
- `window list --json` includes `is_frontmost`, `is_key`, `layer`, and accessibility `subrole` when the host can resolve them. When no window selector is supplied, interaction commands prefer the exact key/frontmost window, then titled standard windows over small untitled panels.

## Examples
```bash
# Move Finder’s 2nd window to (100,100)
peekaboo window move --app Finder --window-index 1 -x 100 -y 100

# Close a specific window deterministically (window_id from `peekaboo window list --json`)
peekaboo window close --window-id 12345

# Resize Safari’s frontmost window to 1200x800
peekaboo window resize --app Safari -w 1200 --height 800

# Focus Terminal even if it lives on another Space
peekaboo window focus --app Terminal --space-switch

# Focus and verify the frontmost window
peekaboo window focus --app Terminal --verify
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
