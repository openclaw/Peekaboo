---
summary: 'Handle macOS dialogs via peekaboo dialog'
read_when:
  - 'clicking buttons or entering text in save/open/system dialogs'
  - 'needing to inspect dialog structure for automation debugging'
---

# `peekaboo dialog`

`dialog` wraps `DialogService` so you can programmatically inspect, click, type into, dismiss, or drive file dialogs without re-running `see`. Target resolution and AX button presses stay in the background by default. Global keyboard/coordinate paths are never implicit: `input`, `file`, and `dismiss --force` require `--foreground`.

## Subcommands
| Name | Purpose | Key options |
| --- | --- | --- |
| `click` | Press a dialog button with AX. | `--button <label>` (required), optional target flags; `--foreground` permits focus and a coordinate fallback if AXPress fails. |
| `input` | Enter text into a dialog field. | `--foreground` (required), `--text`, optional `--field <label>` or `--index <0-based>`, `--clear`, plus optional target flags. |
| `file` | Drive NSOpenPanel/NSSavePanel style dialogs. | `--foreground` (required), `--path <dir>`, `--name <filename>`, `--select <button>`, `--ensure-expanded`, `--timeout <duration>`, plus optional target flags. Save-like actions verify the file exists and return `saved_path`. |
| `dismiss` | Close the current dialog. | Normal dismissal searches for and AX-presses a cancel/close button in the background. `--force --foreground` explicitly sends global Escape. |
| `list` | Read dialog metadata (buttons, text fields, static text) without focusing or mutating it. | Optional `--app`/`--pid`, optional `--window-id`/`--window-title`/`--window-index`, and `--timeout <duration>`. |

## Implementation notes
- `dialog list` is always read-only/background. `dialog click` is AX-only by default and fails honestly if AXPress is unsupported; `--foreground` explicitly permits focus and coordinate fallback.
- Remote background button clicks require a Bridge host that advertises the strict AX-only operation; Peekaboo rejects stale hosts before dispatch instead of letting them apply legacy coordinate fallback.
- `dialog input`, `dialog file`, and forced dismissal use global keyboard or coordinate events and therefore reject calls without `--foreground` (or `foreground: true` over MCP).
- Button clicks and text entry route through `services.dialogs` helpers, which return dictionaries describing what happened; JSON output exposes those details verbatim (`button`, `field`, `text_length`, etc.).
- `dialog input` accepts either a field label (`--field`) or an index; when neither is provided it targets the first text field. `--clear` issues a Cmd+A/Delete before typing.
- `dialog file` can both navigate to a path and fill the filename field, then clicks the action button you specify (`--select Save`, `--select Open`, etc.). Leave `--path` blank to simply confirm the current directory.
- `dialog file` defaults to clicking the dialog’s `OKButton` when `--select` is omitted (or set to `default`). Prefer this when you don’t want to guess whether the button is labeled “Save”, “Open”, “Choose”, etc.
- `--ensure-expanded` expands the dialog (Show Details) before applying `--path`. If no `PathTextField` is present, Peekaboo falls back to the standard “Go to Folder…” shortcut to reliably land in the requested directory.
- For save-like actions (resolved by the actual clicked button title), `dialog file` verifies that the saved file appears on disk (5s timeout). On success it returns `saved_path` and `saved_path_verified=true`. If you provided `--path` + `--name`, Peekaboo also enforces that the file landed in the requested directory (symlinks like `/tmp` → `/private/tmp` are normalized).
- JSON output includes additional provenance for debugging without screenshots, including `dialog_identifier`, `found_via`, `button_identifier`, `saved_path_found_via`, and `path_navigation_method` (e.g. `path_textfield_typed+fallback_go_to_folder`).
- `dialog list` is invaluable before scripting a dialog: it prints button titles, placeholders, and static text so you can pick stable labels instead of guessing.

## Examples
```bash
# Click "Don't Save" on a TextEdit sheet
peekaboo dialog click --button "Don't Save" --app TextEdit

# Enter credentials into a password prompt
peekaboo dialog input --text hunter2 --field "Password" --clear --app Safari --foreground

# Choose a file in an open panel and confirm
peekaboo dialog file --path ~/Downloads --name report.pdf --select Open --foreground

# Save a file and verify the resulting path exists
peekaboo dialog file --path /tmp --name poem.rtf --select Save --app TextEdit --foreground --json

# Click the default action (OKButton) and include dialog provenance in JSON output
peekaboo dialog file --path ~/Downloads --name report.pdf --ensure-expanded --app TextEdit --foreground --json
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your process with `peekaboo app list`, its exact window with `peekaboo window list`, and current UI with `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
