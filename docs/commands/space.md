---
summary: 'Manage macOS Spaces via peekaboo space'
read_when:
  - 'switching desktops or moving windows for multi-space automation'
  - 'needing JSON snapshots of every Space and its windows'
---

# `peekaboo space`

`space` wraps Peekaboo’s SpaceManagementService (private macOS APIs) to list Spaces, switch among them, and move windows. It’s best-effort—Apple may change these APIs—but it gives agents a reliable hook into Mission Control style workflows.

## Subcommands
| Name | Purpose | Key options |
| --- | --- | --- |
| `list` | Enumerate Spaces (per display) and, optionally, every window assigned to them. | `--detailed` triggers a per-window crawl so you see which apps live on each Space. |
| `switch` | Jump to a Space by number. | `--to <n>` (1-based). The command validates against the current count. |
| `move-window` | Move an app window to another Space or the current one. | `--app`, `--pid`, `--window-title`, `--window-index` to pick the window; `--to <n>` or `--to-current`; `--follow` switches to the destination Space after moving. |

## Implementation notes
- `list --detailed` enumerates every running app, lists its windows via `applications.listWindows`, and maps them back to Spaces using CoreGraphics window IDs. That means it may take a second on multi-display setups but yields accurate assignments.
- `switch` and `move-window` both call `SpaceCommandEnvironment.service`, which can be overridden in tests; production runs use the live actor that talks to SpaceManagementService.
- `move-window` reuses `WindowIdentificationOptions`, so apps can be resolved via names or `PID:1234`, and you can specify a particular window by title or index.
- JSON output from `list` is a compact `{spaces:[{id,type,is_active,display_id}]}` structure; action subcommands return `{action,success,...}` payloads that match the arguments you passed (space number, window title, follow flag, etc.).

## Examples
```bash
# Show every Space plus its assigned windows
peekaboo space list --detailed

# Move the frontmost Safari window to Space 3 and follow it
peekaboo space move-window --app Safari --to 3 --follow

# Switch back to Space 1
peekaboo space switch --to 1
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
