---
summary: 'Control macOS apps via peekaboo app'
read_when:
  - 'launching/quitting/focusing apps as part of an automation flow'
  - 'auditing running apps or force cycling foreground focus'
---

# `peekaboo app`

`app` bundles every app-management primitive Peekaboo exposes: launching, quitting, hiding, relaunching, switching focus, and listing processes. Commands run through the selected Peekaboo runtime host so they share its macOS session, LaunchServices, and AX view instead of the caller's sandbox.

## Subcommands
| Name | Purpose | Key flags |
| --- | --- | --- |
| `launch` | Start an app by name/path/bundle ID in the background, optionally opening documents. | `--bundle-id`, `--open <path|url>` (repeatable), `--new-instance`, `--wait-ready`, `--wait-for-window`, `--foreground`. |
| `quit` | Quit one app or *all* regular apps (with optional exclusions). | `--app <name>`, `--pid`, `--expected-process-start-identity`, `--all`, `--except "Finder,Terminal"`, `--force`. |
| `relaunch` | Quit + relaunch the same app in the background in one step. | Positional `<app>` or `--pid`, `--wait <seconds>` between quit/launch, `--force`, `--wait-until-ready`, `--foreground`. |
| `hide` / `unhide` | Toggle app visibility. | Accept the same targeting flags as `launch`/`quit`. |
| `switch` | Activate a specific app (`--to`) or cycle Cmd+Tab style (`--cycle`). | `--to <name|bundle|PID:1234>`, `--cycle`, `--verify` (only with `--to`). |
| `list` | App-management view of running apps, filtering hidden/background apps by default. | `--include-hidden`, `--include-background`. |

## Implementation notes
- Launch resolves explicit paths, bundle IDs, and friendly names on the selected runtime host. It stays in the background by default, including when `--open` passes documents or URLs. Add `--foreground` only when activation is intended. `--new-instance` uses LaunchServices to start a distinct process even when the app is already running; it does not activate either instance. The deprecated `--no-focus` flag remains a no-op compatibility alias for the background default.
- `launch --wait-ready` preserves the launch-completion contract and works for windowless/accessory apps. Add `--wait-for-window` when the next step needs a real WindowServer window with an exact ID; it waits up to 10 seconds and fails honestly for an app that never creates one. Neither readiness probe activates or focuses the target. `relaunch` retains its single `--wait-until-ready` spelling.
- Background launch holds a bounded native activation guard through launch/readiness and for 500 ms after the PID resolves. Opening a document or URL extends the same guard to two seconds to cover delayed handler self-activation. If the caller cancels during readiness, a native heartbeat retains the guard only through that original deadline. If the target self-activates despite `activates = false`, Peekaboo restores the app that was frontmost before launch.
- JSON launch output returns the launch-bound `process_start_identity` beside `pid`, plus the refreshed `window_count`, `window_ready`, and `window_ids`. Relaunch returns the same receipt as `new_pid` and `new_process_start_identity`. A current native host captures that process generation from the exact process selected by LaunchServices and refuses the result if the PID is recycled before return. Older runtime hosts decode compatibly but may omit the process identity; cleanup callers must fail closed instead of probing the returned PID to manufacture a new receipt. `window_identity` is `exact` when the window IDs came from WindowServer and `unknown` for an older runtime host that cannot provide that metadata.
- Quit mode supports `--all` plus `--except`, automatically ignoring core system processes (`Finder`, `Dock`, `SystemUIServer`, `WindowServer`). Controlled cleanup can pair `--pid` with `--expected-process-start-identity`; Peekaboo atomically rejects a recycled PID instead of terminating its replacement. When quits fail, the command prints hints about unsaved changes and suggests `--force`.
- Hide/unhide uses `NSRunningApplication.hide()` / `.unhide()` and surfaces JSON output with per-app success data.
- `switch --cycle` synthesizes Cmd+Tab events using `CGEvent` so it behaves like the real keyboard shortcut; `switch --to` activates the exact PID resolved via AX.
- `switch --verify` confirms the requested app is frontmost after activation (only supported with `--to`).
- `relaunch` sends the initially selected PID/process-generation receipt, quit, termination polling (up to 5 s), the requested delay, and launch as one daemon-held transaction, so even a short daemon idle timeout cannot strand the app closed. The host rejects PID reuse before quit. It refuses to relaunch its own daemon, launches via bundle ID or bundle path, stays backgrounded unless `--foreground` is set, can wait for `isFinishedLaunching`, and returns the new process generation for race-free follow-up cleanup.
- `app list` filters hidden/background apps unless `--include-hidden` or `--include-background` is passed and emits its established `data.apps` payload.

## Examples
```bash
# Launch Xcode with a project without interrupting the current app
peekaboo app launch "Xcode" --open ~/Projects/Peekaboo.xcodeproj

# Start an independent TextEdit process and wait for its first automatable window
peekaboo app launch "TextEdit" --new-instance --wait-for-window

# Explicitly activate Safari after launching it
peekaboo app launch "Safari" --foreground

# Quit everything but Finder and Terminal
peekaboo app quit --all --except "Finder,Terminal"

# Atomically quit only the saved process generation
peekaboo app quit --pid 1234 --expected-process-start-identity 987654321 --force

# Cycle to the next app exactly once
peekaboo app switch --cycle

# Switch and verify the app is frontmost
peekaboo app switch --to Safari --verify
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target with `peekaboo app list`, `peekaboo window list`, or `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
