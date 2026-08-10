---
summary: 'Drive application menus via peekaboo menu'
read_when:
  - 'navigating File/Edit/... menus without UI scripting'
  - 'listing menu trees to grab exact command paths for automation'
---

# `peekaboo menu`

`menu` controls classic macOS application menus. Application menu listing and clicking use Accessibility in the background by default, so inspecting or choosing a menu does not activate the target app. Add `--foreground` only for an app whose menu is unavailable until its window is focused. Status items belong to `peekaboo menubar`.

## Subcommands
| Subcommand | Purpose | Key options |
| --- | --- | --- |
| `click` | Activate an application menu item via `--item` (single-level) or `--path "File > Export > PDF"`. | Background delivery requires `--app` or `--pid`; `--foreground` explicitly permits the frontmost app fallback and focus options. Paths are normalized automatically if you accidentally pass a `'>'` string to `--item`. |
| `list` | Dump the menu tree for a specific app (optionally showing disabled items). | Same target flags as `click`, plus `--include-disabled`; remains background unless `--foreground` is explicit. |

## Implementation notes
- `click`/`list` accept the same target flags as other interaction commands (`--app`/`--pid` plus optional `--window-id`/`--window-title`/`--window-index`) without changing focus. A background click refuses before menu lookup unless `--app` or `--pid` is explicit. The frontmost-menu fallback remains available only with `--foreground`; read-only list may still inspect the frontmost app without that consent.
- `--foreground` opts into `ensureFocusIgnoringMissingWindows`, which tolerates apps that keep a menu bar without a visible window (e.g., Finder when all windows are closed). Focus options without `--foreground` are rejected instead of silently activating the app.
- Any `--item` string that already contains `'>'` is automatically interpreted as a `--path` so agents don’t have to rewrite their inputs. The command even prints a note when this normalization occurs.
- Errors bubble up as typed `MenuError`s; JSON mode maps them to specific error codes (`MENU_ITEM_NOT_FOUND`, `MENU_BAR_NOT_FOUND`, etc.) so CI can distinguish between missing apps vs. absent menu items.

## Examples
```bash
# Click File > New Window in Safari
peekaboo menu click --app Safari --path "File > New Window"

# Intentionally use the current frontmost application's menu
peekaboo menu click --foreground --path "File > Close"

# Inspect the Finder menu tree, including disabled actions
peekaboo menu list --app Finder --include-disabled

# List or click status items through the dedicated menubar command
peekaboo menubar list --json
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target with `peekaboo app list`, `peekaboo window list`, or `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
