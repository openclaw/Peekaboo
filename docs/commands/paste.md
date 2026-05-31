---
summary: 'Paste text or rich content via peekaboo paste'
read_when:
  - 'you want fewer steps than clipboard set + menu/hotkey paste + clipboard restore'
  - 'pasting rich text (RTF) into a targeted app/window without drift'
---

# `peekaboo paste`

`paste` is an atomic “clipboard + Cmd+V + restore” helper. It temporarily replaces the system clipboard with your payload, pastes into the focused target, then restores the previous clipboard contents (or clears it if it was empty).

This reduces drift by collapsing multiple CLI steps into one command.

## Key options
| Flag | Description |
| --- | --- |
| `[text]` / `--text` | Plain text to paste. |
| `--file-path` / `--image-path` | Copy a file or image into the clipboard, then paste. |
| `--data-base64` + `--uti` | Paste raw base64 payload with explicit UTI (e.g. `public.rtf`). |
| `--also-text` | Optional plain-text companion when pasting binary. |
| `--restore-delay-ms` | Delay before restoring the previous clipboard (default 150ms). |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — focus a specific app/window before pasting. |
| Focus flags | Foreground focus controls (`--space-switch`, `--no-auto-focus`, etc.). |

## Examples
```bash
# Paste plain text into TextEdit
peekaboo paste "Hello, world" --app TextEdit

# Paste rich text (RTF) into a specific window title
peekaboo paste --data-base64 "$RTF_B64" --uti public.rtf --also-text "fallback" --app TextEdit --window-title "Untitled"

# Paste a PNG into Notes
peekaboo paste --file-path /tmp/snippet.png --app Notes
```

## Notes
- File paths for `--file-path` and `--image-path` accept `~/...`.

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
