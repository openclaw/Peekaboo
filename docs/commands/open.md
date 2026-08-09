---
summary: 'Open files/URLs with Peekaboo focus controls via peekaboo open'
read_when:
  - 'handing documents/URLs to specific apps from automation scripts'
  - 'needing structured output around macOS open events'
---

# `peekaboo open`

`open` mirrors macOS `open` but layers on Peekaboo’s conveniences: background-by-default delivery, session-level logging, JSON output, explicit focus control, and “wait until ready” behavior. It resolves paths (with `~` expansion), honors URLs with schemes, and optionally forces a specific handler.

## Key options
| Flag | Description |
| --- | --- |
| `[target]` | Required positional path or URL. Relative paths are resolved against the current working directory. |
| `--app <name|path>` | Force a particular application by friendly name, bundle ID, or `.app` path. |
| `--bundle-id <id>` | Resolve the handler via bundle ID directly. Overrides `--app` if both are set. |
| `--wait-until-ready` | Block until the handler reports `isFinishedLaunching` (10 s timeout). |
| `--wait-for-window` | Block until the handler exposes an exact WindowServer window ID (10 s timeout). |
| `--foreground` | Activate the handling application after opening. Without this flag, it stays in the background. |
| `--no-focus` | Deprecated compatibility alias for the background default. |
| Global flags | `--json` prints an `OpenResult` (target, resolved target, handler name, PID, focus state). |

## Implementation notes
- Targets without a URL scheme are treated as filesystem paths; relative values are combined with `FileManager.default.currentDirectoryPath`, and `~` prefixes expand to the user’s home.
- Handler resolution runs on the selected Peekaboo runtime host and accepts a bundle ID, friendly name, `.app` path, or direct path. This keeps LaunchServices lookup outside a sandboxed caller.
- When no handler is specified, the default macOS association handles the file/URL, but you still get structured output describing whichever app actually opened it.
- The selected runtime host sets `NSWorkspace.OpenConfiguration.activates = false` by default, so opening a target does not interrupt the user. `--foreground` opts into activation and launch feedback UI.
- `--wait-until-ready` waits only for LaunchServices startup completion. Use `--wait-for-window` when a follow-up exact capture or automation step needs a real WindowServer window ID; neither wait activates the handler.

## Examples
```bash
# Open a PDF in the default viewer without stealing focus
peekaboo open ~/Docs/spec.pdf

# Force TextEdit to open a scratch file and wait for an exact automatable window
peekaboo open /tmp/notes.txt --bundle-id com.apple.TextEdit --wait-for-window

# Launch Safari with a URL, activate it, and report the resulting PID as JSON
peekaboo open https://example.com --foreground --json
```

## Design notes
- Purpose: mirror `open -a` workflows while keeping Peekaboo’s logging, focus control, and structured JSON output.
- Target resolution: if the argument has a URL scheme, use it; otherwise expand `~`, resolve relative paths against CWD, and build a file URL (path need not exist).
- Handler selection order: explicit `--bundle-id` → `--app` (bundle lookup, `.app` path, or common app directories) → system default handler. Invalid selectors throw `NotFoundError.application`.
- Execution: the selected runtime host builds `NSWorkspace.OpenConfiguration` with `activates = foreground` and polls up to 10s for either requested readiness contract.
- Output shape (JSON): includes success flag, original + resolved target, handler app name + bundle id, PID, launch readiness, refreshed window count/IDs/identity status, and focus state.

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
