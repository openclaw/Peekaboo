---
summary: 'Paste text or rich content via peekaboo paste'
read_when:
  - 'you want fewer steps than clipboard set + menu/hotkey paste + clipboard restore'
  - 'pasting rich text (RTF) into a targeted app/window without drift'
---

# `peekaboo paste`

`paste` sends Cmd+V. With no payload, it pastes the current clipboard contents. With text, a file, an image, or base64 data, it becomes an atomic “clipboard + Cmd+V + restore” helper: temporarily replace the system clipboard with your payload, paste into the target, then restore the previous clipboard contents (or clear it if it was empty).

This reduces drift by collapsing multiple CLI steps into one command. Background process-targeted Cmd+V delivery is the default when Peekaboo can resolve a target process; pass `--foreground` for focused/global paste.

## Key options
| Flag | Description |
| --- | --- |
| `[text]` / `--text` | Plain text to paste; omit payload flags to paste the current clipboard. |
| `--file-path` / `--image-path` | Copy a file or image into the clipboard, then paste. |
| `--data-base64` + `--uti` | Paste raw base64 payload with explicit UTI (e.g. `public.rtf`). |
| `--also-text` | Optional plain-text companion when pasting binary. |
| `--restore-delay-ms` | Delay before restoring the previous clipboard (default 150ms). |
| Target flags | `--app <name>`, `--pid <pid>`, `--window-id <id>`, `--window-title <title>`, `--window-index <n>` — send Cmd+V to a specific app/window in the background when possible. |
| `--foreground` | Focus target and send foreground/global Cmd+V. Focus flags also imply foreground delivery. |
| Focus flags | Foreground focus controls (`--space-switch`, `--no-auto-focus`, etc.). |

## Delivery modes
- **Background** is the default when Peekaboo can resolve a target process from target flags or snapshot metadata. With no payload it posts process-targeted Cmd+V using the current clipboard. With a payload it sets the clipboard, posts process-targeted Cmd+V, then restores the previous clipboard without activating the app.
- **Foreground** (`--foreground`) focuses the target first and sends normal/global Cmd+V. Use it for apps that ignore background paste or for flows where focus should visibly move.
- Background paste still mutates the system clipboard briefly; `paste` restores the previous contents after `--restore-delay-ms`.

## Examples
```bash
# Paste the current clipboard into the focused app
peekaboo paste

# Paste plain text into TextEdit
peekaboo paste "Hello, world" --app TextEdit

# Paste rich text (RTF) into a specific window title
peekaboo paste --data-base64 "$RTF_B64" --uti public.rtf --also-text "fallback" --app TextEdit --window-title "Untitled"

# Paste a PNG into Notes
peekaboo paste --file-path /tmp/snippet.png --app Notes

# Force foreground paste for apps that ignore background Cmd+V
peekaboo paste "Hello" --app TextEdit --foreground
```

## Notes
- File paths for `--file-path` and `--image-path` accept `~/...`.
- JSON output reports delivery mode and target PID when background delivery is used.

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`). Background paste also requires Event Synthesizing access for the sending process; request it with `peekaboo permissions request-event-synthesizing`.
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
