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
| `launch` | Start an app by name/path/bundle ID, optionally opening documents. | `--bundle-id`, `--open <path|url>` (repeatable), `--wait-until-ready`, `--no-focus`. |
| `quit` | Quit one app or *all* regular apps (with optional exclusions). | `--app <name>`, `--pid`, `--all`, `--except "Finder,Terminal"`, `--force`. |
| `relaunch` | Quit + relaunch the same app in one step. | Positional `<app>`, `--wait <seconds>` between quit/launch, `--force`, `--wait-until-ready`. |
| `hide` / `unhide` | Toggle app visibility. | Accept the same targeting flags as `launch`/`quit`. |
| `switch` | Activate a specific app (`--to`) or cycle Cmd+Tab style (`--cycle`). | `--to <name|bundle|PID:1234>`, `--cycle`, `--verify` (only with `--to`). |
| `list` | App-management view of running apps, filtering hidden/background apps by default. | `--include-hidden`, `--include-background`. |

## Implementation notes
- Launch resolves explicit paths, bundle IDs, and friendly names on the selected runtime host. `--open` can be repeated to pass multiple documents/URLs to the launched app; `--no-focus` is preserved across the bridge and suppresses activation and launch feedback UI.
- Quit mode supports `--all` plus `--except`, automatically ignoring core system processes (`Finder`, `Dock`, `SystemUIServer`, `WindowServer`). When quits fail, the command prints hints about unsaved changes and suggests `--force`.
- Hide/unhide uses `NSRunningApplication.hide()` / `.unhide()` and surfaces JSON output with per-app success data.
- `switch --cycle` synthesizes Cmd+Tab events using `CGEvent` so it behaves like the real keyboard shortcut; `switch --to` activates the exact PID resolved via AX.
- `switch --verify` confirms the requested app is frontmost after activation (only supported with `--to`).
- `relaunch` sends quit, termination polling (up to 5 s), the requested delay, and launch as one daemon-held transaction, so even a short daemon idle timeout cannot strand the app closed. It refuses to relaunch its own daemon, launches via bundle ID or bundle path, and can wait for `isFinishedLaunching` before reporting success.
- `app list` is the app-management view and filters hidden/background apps unless `--include-hidden` or `--include-background` is passed. `peekaboo list apps` is the full inventory view; it accepts the same flags for parity and emits both legacy `data.applications` and preferred `data.apps`.

## Examples
```bash
# Launch Xcode with a project and keep it backgrounded
peekaboo app launch "Xcode" --open ~/Projects/Peekaboo.xcodeproj --no-focus

# Quit everything but Finder and Terminal
peekaboo app quit --all --except "Finder,Terminal"

# Cycle to the next app exactly once
peekaboo app switch --cycle

# Switch and verify the app is frontmost
peekaboo app switch --to Safari --verify
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
