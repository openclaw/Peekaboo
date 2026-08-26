---
summary: 'Automate macOS Dock interactions via peekaboo dock'
read_when:
  - 'launching/closing apps through Dock affordances'
  - 'toggling Dock visibility or iterating over Dock items in scripts'
---

# `peekaboo dock`

`dock` exposes Dock-specific helpers so you don’t have to rely on brittle coordinate clicks. It leverages `DockServiceBridge`, which uses AX to locate Dock items, right-click menus, and visibility toggles.

## Subcommands
| Name | Purpose | Key options |
| --- | --- | --- |
| `launch <app>` | Left-click a Dock icon to launch/activate it. | Requires `--foreground`; add `--verify` to wait for the app to be running. |
| `right-click` | Open a Dock item’s context menu (and optionally pick a menu item). | Requires `--foreground`; use `--app <Dock title>` plus optional `--select <title>`. |
| `hide` / `show` | Toggle Dock visibility (same as System Settings ➝ Dock & Menu Bar). | Requires `--foreground` because this changes shared desktop UI and restarts Dock. |
| `list` | Enumerate Dock items, their bundle IDs, and whether they’re running/pinned. | `--json` prints structured info; prefer `data.dock_items`. |

## Implementation notes
- Item resolution is AX-based, so names match what VoiceOver would read (case-sensitive). Launch and right-click open global Dock UI, while hide/show change the shared Dock preference and restart Dock; all four refuse before dispatch unless `--foreground` is explicit.
- `launch --verify` polls for the app to appear in the running-application list before returning success.
- `right-click` first finds the item, then triggers the context menu, then optionally selects `--select <title>`. If you omit `--select`, it just opens the menu (useful if you want to inspect it with `see`).
- Hide/show operations update the Dock auto-hide preference and restart Dock, then verify the preference readback. The setting is reversible, but the restart is visible shared-desktop work.
- `dock list --json` keeps legacy `data.dockItems` and also emits preferred `data.dock_items`.
- Errors coming from `DockServiceBridge` (item not found, Dock unavailable) are mapped to structured error codes when `--json` is active, which helps CI detect missing icons.

## Examples
```bash
# Launch Safari directly from the Dock
peekaboo dock launch Safari --foreground

# Launch and verify the app is running
peekaboo dock launch Safari --verify --foreground

# Right-click Finder and choose "New Window"
peekaboo dock right-click --app Finder --select "New Window" --foreground

# Hide the Dock before recording a video
peekaboo dock hide --foreground
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
