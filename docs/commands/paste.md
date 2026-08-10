---
summary: 'Paste text or rich content via peekaboo paste'
read_when:
  - 'you want fewer steps than clipboard set + menu/hotkey paste + clipboard restore'
  - 'pasting rich text (RTF) into a targeted app/window without drift'
---

# `peekaboo paste`

`paste` sends Cmd+V. With no payload, it pastes the current clipboard contents. With text, a file, an image, or base64 data, it becomes an atomic “clipboard + Cmd+V + restore” helper: temporarily replace the system clipboard with your payload, paste into the target, then restore the previous clipboard contents (or clear it if it was empty).

This reduces drift by collapsing multiple CLI steps into one command. Plain text uses direct process-targeted typing in background mode. Rich/current-clipboard payloads use Cmd+V; pass `--foreground` when the caller needs a confirmed command result because macOS does not acknowledge whether a process-targeted Cmd+V was consumed.

## Key options
| Flag | Description |
| --- | --- |
| `[text]` / `--text` | Plain text to paste; omit payload flags to paste the current clipboard. |
| `--file-path` | Copy a file or image into the clipboard, then paste. |
| `--data-base64` + `--uti` | Paste raw base64 payload with explicit UTI (e.g. `public.rtf`). |
| `--also-text` | Optional plain-text companion when pasting binary. |
| `--restore-delay <duration>` | Delay before restoring the previous clipboard (default `150ms`; bare values are milliseconds). |
| Target flags | `--app <name>` or `--pid <pid>` for process-targeted background paste. Window selectors require `--foreground`. |
| `--foreground` | Focus a supplied target or intentionally send foreground/global Cmd+V. |
| Focus flags | Foreground focus controls (`--space-switch`, `--no-auto-focus`, etc.). |

## Delivery modes
- **Background** is the default when Peekaboo can resolve a target process from target flags or snapshot metadata. Plain text is delivered directly without touching the clipboard. Binary/rich content and current-clipboard requests still post process-targeted Cmd+V without activating the app, but macOS provides no receiver-consumption acknowledgement. Peekaboo therefore returns a nonzero, explicit “may have pasted; do not retry” result after the settle/restore transaction instead of claiming success. Observe the target before taking another action.
- **Foreground** (`--foreground`) focuses the target first and sends normal/global Cmd+V. Use it for apps that ignore background paste or for flows where focus should visibly move.
- Without an app/PID target, `paste` fails before mutating the clipboard. Add `--foreground` only when global delivery is intentional.
- Window selectors are rejected in background mode because process-targeted events cannot prove which window owns the process's focused element.
- Clipboard-backed transactions are serialized across CLI, daemon, and GUI processes with a private per-user lock under `~/Library/Application Support/Peekaboo`, independent of each process's temporary directory.
- Target capability checks, cancellation checks, and the prior-clipboard snapshot must all succeed before Peekaboo writes a temporary payload. A read failure is never treated as an empty clipboard; if a write fails after partially changing the pasteboard, Peekaboo restores the exact saved state before returning the error.
- Background binary/rich paste still mutates the system clipboard briefly; `paste` completes the noncancellable `--restore-delay` settle and restores the previous contents before releasing the transaction lock, even when delivery throws or the caller cancels.

## Examples
```bash
# Paste the current clipboard into the focused app
peekaboo paste --foreground

# Paste plain text into TextEdit
peekaboo paste "Hello, world" --app TextEdit

# Paste rich text (RTF) into a specific window title
peekaboo paste --data-base64 "$RTF_B64" --uti public.rtf --also-text "fallback" --app TextEdit --window-title "Untitled" --foreground

# Paste a PNG into Notes with a confirmed foreground dispatch result
peekaboo paste --file-path /tmp/snippet.png --app Notes --foreground

# Force foreground paste for apps that ignore background Cmd+V
peekaboo paste "Hello" --app TextEdit --foreground
```

## Notes
- File paths for `--file-path` accept `~/...`.
- Successful background text JSON reports delivery mode and target PID. Clipboard-backed background delivery returns `INTERACTION_FAILED` with the explicit retry-unsafe message instead of a success payload.
- After Cmd+V dispatch begins, cancellation or a delivery error is indeterminate. Peekaboo reports that the target may have pasted and marks retry unsafe; inspect fresh UI state rather than replaying the paste.

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`). Background paste also requires Event Synthesizing access for the sending process; request it with `peekaboo permissions request event-synthesizing`.
- Confirm your target with `peekaboo app list`, `peekaboo window list`, or `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
