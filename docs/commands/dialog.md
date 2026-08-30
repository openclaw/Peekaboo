---
summary: 'Handle macOS dialogs via peekaboo dialog'
read_when:
  - 'clicking buttons or entering text in save/open/system dialogs'
  - 'needing to inspect dialog structure for automation debugging'
---

# `peekaboo dialog`

`dialog` wraps `DialogService` so you can programmatically inspect, click, set text in, dismiss, or drive file
dialogs without re-running `see`. Exact targeted click, non-forced dismiss, and input stay in the background by
default. Global keyboard/coordinate paths are never implicit: targetless input, `file`, and `dismiss --force`
require `--foreground`.

## Subcommands
| Name | Purpose | Key options |
| --- | --- | --- |
| `click` | Press a dialog button with AX. | `--button <exact label>` and an app/PID/window target are required; `--foreground` may focus first but never enables pointer fallback. |
| `input` | Set text in a dialog field. | `--text` plus an app/PID/window target default to background AXValue. Use `--foreground` only for targetless/global keyboard input. Optional `--field <label>` or `--index <0-based>` and `--clear`. |
| `file` | Drive NSOpenPanel/NSSavePanel style dialogs. | `--foreground` is required; an app/PID/window target is optional and recommended. Supports `--path <dir>`, `--name <filename>`, `--select <button>`, `--ensure-expanded`, and `--timeout <duration>`. Save-like actions verify the file exists and return `saved_path`. |
| `dismiss` | Close the current dialog. | Normal dismissal requires a target and uniquely resolves one cancel/close AXPress button in the background. `--force --foreground` explicitly sends global Escape. |
| `list` | Read dialog metadata (buttons, text fields, static text) without focusing or mutating it. | Optional `--app`/`--pid`, optional `--window-id`/`--window-title`/`--window-index`, and `--timeout <duration>`. |

## Implementation notes
- Every `dialog list` form is read-only/background and creates no mutation or snapshot debt. A targeted list must resolve exactly one dialog; ambiguity reports candidate window IDs.
- Static text includes nested `AXStaticText` descendants of the resolved dialog in depth-first child order, once per AX element. Extraction follows structural children and does not enter other application/window roots. It uses the first nonblank string from `AXValue`, `AXTitle`, `AXLabel`, then `AXDescription`, preserving the selected string's whitespace; button labels and editable field values remain in their separate lists. Alert message and informative text do not replace the dialog's own title.
- When an exact titled parent AX window contains one structural child sheet or alert, Peekaboo treats that child as the active dialog while retaining the parent window receipt. The parent remains targetable when it has no structural child, and multiple child dialogs remain ambiguous. If a blank-title transient sheet CGWindow ID does not resolve, use the titled parent AX window ID reported by `window list`.
- Default background click and non-forced dismiss use Bridge protocol 1.25's two-phase contract: a read-only prepare operation uniquely upgrades app/PID/title selectors to one exact process-generation/window receipt and retains the raw AX window, dialog, and button identities under a short-lived one-shot token.
- Immediately before AXPress, Peekaboo consumes the token, reacquires the exact-window write lane, re-enumerates and compares all three raw AX identities, and rechecks owner generation, window bounds, enabled state, and AXPress support. It never falls back to the physical pointer, clipboard, focus, or global input.
- Success is confirmed only after the retained dialog or sheet disappears. An accepted press without a verified postcondition is retry-unsafe and requires fresh observation; planning or identity ambiguity is a retry-safe pre-dispatch refusal.
- Remote targeted list/prepare/click/dismiss require the exact advertised and enabled operation, not merely a 1.25 version number. Missing capabilities refuse before operation transport.
- Exact targeted `dialog input` resolves and revalidates one process-generation/window target, then sets the selected
  field through background AXValue. Targetless input uses global keyboard delivery and requires `--foreground`
  (or `foreground: true` over MCP).
- `dialog file` and forced dismissal use global keyboard or coordinate events and therefore require foreground
  consent. For compatibility with interactive foreground workflows, input and file may target the current dialog only
  in that foreground mode. Receipt-pinned background click and non-forced dismiss never allow a targetless path.
- Button clicks and text entry route through `services.dialogs` helpers, which return dictionaries describing what happened; JSON output exposes those details verbatim (`button`, `field`, `text_length`, etc.).
- `dialog input` accepts either a field label (`--field`) or an index; when neither is provided it targets the first
  text field. `--clear` replaces the value directly in background AXValue mode; the targetless foreground route uses
  Cmd+A/Delete before typing.
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

# Set a targeted password field through background AXValue
peekaboo dialog input --text hunter2 --field "Password" --clear --app Safari

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
