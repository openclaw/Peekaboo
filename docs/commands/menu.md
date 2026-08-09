---
summary: 'Drive application menus via peekaboo menu'
read_when:
  - 'navigating File/Edit/... menus or menu extras without UI scripting'
  - 'listing menu trees to grab exact command paths for automation'
---

# `peekaboo menu`

`menu` controls classic macOS menu bars and menu extras from the CLI. Application menu listing and clicking use Accessibility in the background by default, so inspecting or choosing a menu does not activate the target app. Add `--foreground` only for an app whose menu is unavailable until its window is focused.

## Subcommands
| Subcommand | Purpose | Key options |
| --- | --- | --- |
| `click` | Activate an application menu item via `--item` (single-level) or `--path "File > Export > PDF"`. | Target flags `--app <name|bundle|PID:1234>`, optional `--pid`, optional `--window-id`/`--window-title`/`--window-index`; `--foreground` opts into focus flags. Paths are normalized automatically if you accidentally pass a `'>'` string to `--item`. |
| `click-extra` | Click status-bar menu extras (Wi-Fi, Bluetooth, custom icons). | `--title <menu-extra>` is required; `--verify` confirms the popover opened; `--item` fails with a nonzero exit because nested extra-menu selection is not implemented yet. |
| `list` | Dump the menu tree for a specific app (optionally showing disabled items). | Same target flags as `click`, plus `--include-disabled`; remains background unless `--foreground` is explicit. |
| `list-all` | Snapshot the frontmost app’s full menu tree *and* all system menu extras in one go. | `--include-disabled`, `--include-frames` (adds pixel coordinates for extras). |

## Implementation notes
- `click`/`list` accept the same target flags as other interaction commands (`--app`/`--pid` plus optional `--window-id`/`--window-title`/`--window-index`) without changing focus. When no `--app`/`--pid` is provided, Peekaboo targets the frontmost app.
- `--foreground` opts into `ensureFocusIgnoringMissingWindows`, which tolerates apps that keep a menu bar without a visible window (e.g., Finder when all windows are closed). Focus options without `--foreground` are rejected instead of silently activating the app.
- Any `--item` string that already contains `'>'` is automatically interpreted as a `--path` so agents don’t have to rewrite their inputs. The command even prints a note when this normalization occurs.
- Errors bubble up as typed `MenuError`s; JSON mode maps them to specific error codes (`MENU_ITEM_NOT_FOUND`, `MENU_BAR_NOT_FOUND`, etc.) so CI can distinguish between missing apps vs. absent menu items.
- `list-all` pairs `MenuServiceBridge.listFrontmostMenus` with `listMenuExtras`, filters disabled entries unless asked otherwise, and emits a structured `apps:[{menus,statusItems}]` payload when `--json` is used.
- `click-extra --verify` uses the same popover/window verification logic as `peekaboo menubar click --verify` (including OCR title/owner matching when needed).

## Examples
```bash
# Click File > New Window in Safari
peekaboo menu click --app Safari --path "File > New Window"

# Inspect the Finder menu tree, including disabled actions
peekaboo menu list --app Finder --include-disabled

# Capture the current menu + menu extras as JSON (with coordinates)
peekaboo menu list-all --include-frames --json > /tmp/menu.json
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
