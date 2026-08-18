---
summary: 'Move, resize, restore, and focus windows via peekaboo window'
read_when:
  - 'wrangling app windows before issuing UI interactions'
  - 'needing JSON receipts for close/minimize/restore/maximize/focus actions'
---

# `peekaboo window`

`window` gives you programmatic control over macOS windows. Every subcommand accepts `WindowIdentificationOptions` (`--app`, `--pid`, `--window-id`, `--window-title`, `--window-index`) so you can pinpoint the exact window before acting. Output is mirrored in JSON and text for easy scripting.

## Subcommands
| Name | Purpose | Key options |
| --- | --- | --- |
| `close` / `minimize` / `restore` / `maximize` | Perform the respective exact-window state action. | Standard window-identification flags. `restore` clears only the exact window's minimized state in the background. `close --foreground` permits focused Cmd-W fallbacks when AX close does not work. |
| `focus` | Bring the window forward, optionally hopping Spaces or moving it to the current Space. | Adds `FocusCommandOptions` plus `--verify` to confirm focus. |
| `move` | Move the window to new coordinates. | `-x <int>` / `-y <int>` specify the new origin. |
| `resize` | Adjust width/height while keeping the origin. | `-w <int>` / `--height <int>`. |
| `set-bounds` | Set both origin and size in one go. | `--x`, `--y`, `--width`, `--height`. |
| `list` | Lists an app's renderable windows with canonical IDs and indexes for interaction targeting. | `--app` or `--pid`; adds `--group-by-space`. |

## Implementation notes
- Every action validates that at least an app, PID, or window ID is supplied. Use only one of `--window-id`, `--window-title`, or `--window-index`; title matching prefers one exact case-insensitive match, then requires one unique partial match. Ambiguous matches fail before dispatch instead of choosing the first window.
- Window mutations require an exact application name, exact bundle ID, or PID before resolving any title/index selector. Read-only `window list` retains its compatibility fuzzy lookup, but partial application names are never promoted into mutation authority.
- Destructive state and geometry actions resolve broad selectors once, pin the selected window's session-scoped CGWindowID plus owner PID/process-start identity, and revalidate that receipt after Bridge queue admission and around native dispatch/readback. PID generation protects against process-ID reuse; because Apple exposes no stronger public window-incarnation token, disappeared, wrong-owner, or bounds-changed windows fail closed instead of retargeting a sibling or newer process.
- Hybrid window inventory lets AX minimized state override stale WindowServer visibility metadata. Exact `--pid` plus `--window-id` state mutations use a bounded AX-backed exact-ID lookup, so a minimized window omitted by WindowServer remains addressable with its original bounds and process receipt. Successful minimize is verified from the same AX window/process generation.
- `close` is AX-only in its default background mode. It pins broad app/title/index selectors to the selected exact window ID before dispatch and verifies through WindowServer that the same ID stays gone. If AX reports success but the window remains, Peekaboo fails instead of focusing the app or sending Cmd-W to whatever is frontmost. Add `--foreground` only when you explicitly want focused Cmd-W fallbacks.
- A minimized exact window may be absent from the public WindowServer catalog. Default close refuses it with explicit `window restore` or `--foreground` guidance. `window restore` resolves that ID through a bounded background AX scan, revalidates its owner generation and capture-time bounds, and clears only its `AXMinimized` attribute without activation, focus, a global shortcut, or cursor movement.
- Remote background close requires a Bridge host that advertises the strict close operation. A stale host is rejected before dispatch; update it or use `--no-remote` rather than risking its legacy global fallback.
- `move`, `resize`, `set-bounds`, and `maximize` read the window frame back after acting; `new_bounds` in the JSON payload always reflects the frame the window actually settled at, not the requested one.
- `move`, `resize`, and `set-bounds` also verify the achieved frame against the request. macOS accepts geometry requests and then lets the app constrain them (e.g. a SwiftUI `minWidth`/`minHeight`), so the request can be applied only partially or not at all:
  - Partially applied (frame changed but missed the request): the command still succeeds, `requested_bounds` and a `warning` string are included in the JSON payload, and the text output prints the actual frame plus the warning.
  - Fully ignored (frame did not change at all): the command fails with exit code 1 and error code `WINDOW_MANIPULATION_ERROR`, because reporting success would silently lie to scripts. Typical cause: shrinking a window below its minimum size when it already sits at that minimum.
  - If the frame cannot be re-read after the operation, the command succeeds with a `warning` that the reported bounds may be stale.
- `maximize` is background-safe geometry, not macOS full screen and not a green-button toggle. Peekaboo pins the selected exact window ID, chooses the screen with the greatest overlap, and applies that screen's visible frame with a 750 ms per-message AX deadline off MainActor. It never activates the app, enters full screen, or switches Spaces.
- `maximize` verifies the exact WindowServer frame for up to two seconds and fails rather than claiming success when the app ignores or constrains the request. A window already at the target visible frame is an idempotent no-op. The CLI then reads the exact ID back until its frame is stable before emitting `new_bounds`.
- `focus` routes through the exact CG window ID, makes the window main, raises it, and honors the global focus flags (`--space-switch` to jump Spaces, `--bring-to-current-space` to move the window instead, etc.). Success requires macOS Accessibility to report that exact window as focused and Workspace to report its app as frontmost.
- `focus --verify` performs a second command-level check against the exact focused window ID. A merely topmost/renderable sibling no longer counts as focused.
- `window list` filters to renderable windows for interaction targeting: entries on non-zero layers, smaller than 60x60, fully transparent, or excluded from the Windows menu are dropped. The surviving windows keep their canonical `index` values, so indexes shown here can have gaps yet still match `--window-index`.
- Window inventory is CG-first and generation-pinned. Accessibility only enriches titles, focus, minimized state, and AX-only windows on a detached per-process lane with a two-second default bound. If enrichment stalls, an updated host returns the verified CG rows promptly instead of holding the Bridge request after caller timeout; AX-only metadata may be omitted from that result.
- `window list --json` includes `is_frontmost`, `is_key`, `layer`, and accessibility `subrole` when the host can resolve them. When no window selector is supplied, interaction commands prefer the exact key/frontmost window, then titled standard windows over small untitled panels.

## Examples
```bash
# Move Finder’s 2nd window to (100,100)
peekaboo window move --app Finder --window-index 1 -x 100 -y 100

# Close a specific window deterministically (window_id from `peekaboo window list --json`)
peekaboo window close --window-id 12345

# Explicitly allow focus/Cmd-W fallback for a window that ignores AX close
peekaboo window close --window-id 12345 --foreground

# Restore a minimized exact window in the background, then close it safely
peekaboo window restore --pid 4242 --window-id 12345
peekaboo window close --pid 4242 --window-id 12345

# Resize Safari’s frontmost window to 1200x800
peekaboo window resize --app Safari -w 1200 --height 800

# Focus Terminal even if it lives on another Space
peekaboo window focus --app Terminal --space-switch

# Focus and verify the frontmost window
peekaboo window focus --app Terminal --verify
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
