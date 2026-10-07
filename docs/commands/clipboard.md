---
summary: 'Read/write the macOS clipboard via peekaboo clipboard'
read_when:
  - 'you need to seed or inspect clipboard content in automation flows'
  - 'saving/restoring the user clipboard around scripted actions'
---

# `peekaboo clipboard`

Work with the macOS pasteboard. Supports text, files/images, raw base64 payloads, and save/restore slots to avoid clobbering the user's clipboard.

## Subcommands
| Subcommand | Description |
| --- | --- |
| `status` | Report the caller-local read policy without reading contents, types, items, or the clipboard generation. |
| `get` | Read the clipboard. Use `--prefer <uti>` to bias type selection and `--output <path|->` to write binary data. |
| `set` | Write text (`--text`), file/image (`--file-path`), or base64 + `--uti`. Optional `--also-text` sets a plain-text companion. Use `--verify` to read back. |
| `clear` | Empty the clipboard. |
| `save` / `restore` | Snapshot and restore clipboard contents. Default slot is `"0"`; use `--slot` to name slots. |

## Key options
| Flag | Description |
| --- | --- |
| `--text` | Plain text to set. |
| `--file-path` | File or image to copy (UTI inferred from extension). |
| `--data-base64` + `--uti` | Raw payload + explicit UTI. |
| `--prefer <uti>` | Preferred UTI when reading. |
| `--output <path|->` | Where to write binary data on `get`; `-` streams to stdout. |
| `--slot <name>` | Save/restore slot (default `0`). |
| `--also-text <string>` | Add a text representation when setting binary data. |
| `--allow-large` | Permit payloads over 10 MB (guard is 10 MB by default). |
| `--verify` | Read back clipboard after `set` and validate contents. |
| `--allow-prompt` | Explicit manual opt-in for a macOS privacy alert on `get`, `save`, or `set --verify`; never enabled by MCP or automatic context/paste reads. |

## Examples
```bash
# Inspect this reader's policy without exposing clipboard contents
peekaboo clipboard status --json

# Copy text
peekaboo clipboard set --text "hello world"

# Copy text and verify readback
peekaboo clipboard set --text "hello world" --verify

# Read clipboard and save binary to a file
peekaboo clipboard get --output /tmp/clip.bin

# Save, clear, then restore the user's clipboard
peekaboo clipboard save --slot original
peekaboo clipboard clear
peekaboo clipboard restore --slot original
```

## Notes
- Binary reads without `--output` return a summary; use `--output -` to pipe data.
- File paths for `--file-path` and `--output` accept `~/...`.
- Slot saves are stored in a dedicated named pasteboard so they work across separate `peekaboo clipboard` invocations. Restore reads that board’s current saved contents, preserving separate items and each item’s representations; an older service instance does not reuse a stale local copy.
- `restore` removes the saved slot after applying it to avoid leaving clipboard snapshots around indefinitely.
- Size guard: writes larger than 10 MB require `--allow-large`; the guard counts all representations plus any `--also-text` companion text.
- `--text` writes both `public.plain-text` and `.string` (`public.utf8-plain-text`) for compatibility.
- `--verify` reads back each representation written and compares payloads (text is normalized for line endings).
- On macOS 15.4+, General-clipboard reads require native `alwaysAllow` policy by default. `default`, `ask`, `alwaysDeny`, and unknown policies refuse before any content access; this also protects automatic Agent context and current-clipboard paste reads. A policy check cannot atomically exclude a concurrent change in System Settings.
- `status` reports `policy`, `policy_available`, `read_admitted`, `reader_context: "caller_local"`, and `contents_read: false`. This is an observation, not a grant or reusable permission lease. The built-in clipboard reader remains caller-local even when UI work uses a Bridge host. Named pasteboards remain exempt; on macOS 14–15.3 the native policy API is unavailable and legacy read admission is preserved, not reported as a granted permission.
- An intentional manual `get --allow-prompt` or `save --allow-prompt` may display the native privacy alert, including the first alert needed for this reader to appear in System Settings. Only use it with human consent outside unattended automation. MCP does not expose this opt-in.
- Writes do not require read permission. If optional set/clear/restore verification is not silently admitted, the accepted write reports `dispatched_unverified` and remains retry-unsafe. Explicit `set --verify` instead fails retry-unsafe after a refused readback; add `--allow-prompt` only when a manual alert is intended. Temporary paste cleanup still restores only its owned generation and does not require another content read.

## Troubleshooting
- Use `peekaboo clipboard status`; Screen Recording, Accessibility, and a GUI Bridge's grants do not determine the caller's clipboard-read policy.
- A refused unattended read does not grant permission. Arrange the native permission outside automation, then inspect status again.
- Re-run with `--json` or `--verbose` to surface detailed errors.
