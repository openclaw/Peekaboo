---
summary: 'Check or explain required macOS permissions via peekaboo permissions'
read_when:
  - 'verifying screen recording + accessibility entitlements before a run'
  - 'needing grant instructions for CI or remote machines'
---

# `peekaboo permissions`

`peekaboo permissions` centralizes entitlement checks. The default `status` subcommand reports the runtime view of Screen Recording, Accessibility, and Event Synthesizing. `grant` prints the same table plus human-readable steps so you can fix issues without hunting through docs.

## Subcommands
| Name | Purpose |
| --- | --- |
| `status` (default) | Fetches the current permission set and prints each entry (`granted`, `denied`, etc.). Honors `--json` so agents can block proactively. Add `--all-sources` to compare Bridge and local CLI permissions side by side. |
| `grant` | Reuses the same snapshot but focuses on remediation: when in text mode it prints the exact System Settings pane/location for each missing entitlement. |
| `request-screen-recording` | Triggers the macOS Screen Recording prompt for the local Peekaboo process. If macOS has already recorded a denial or stale entry, it prints the manual System Settings path instead. |
| `request-event-synthesizing` | Triggers the macOS Event Synthesizing prompt needed by background input such as default `click`, `type`, `hotkey`, `press`, and `paste` delivery. With the default remote runtime it requests the permission for the selected bridge host; use `--no-remote` to request it for the local CLI process. |

## Implementation notes
- All subcommands conform to `RuntimeOptionsConfigurable`, so they inherit global `--json`/`--verbose` flags even when invoked from compound commands like `peekaboo learn`.
- The command executes entirely on the main actor, avoiding extra prompts or sandbox warnings—the same code path runs at CLI startup to warn if entitlements are missing.
- JSON mode uses `outputSuccessCodable`, which means status results include a `permissions` array with `{name, isRequired, isGranted, grantInstructions}` entries that can be diffed over time.
- `--all-sources --json` returns `{selectedSource, sources}` so callers can distinguish Bridge TCC grants from local CLI grants.

## Examples
```bash
# Quick sanity check before running UI automation
peekaboo permissions

# Feed the status into an agent to ensure entitlements are set
peekaboo permissions --json | jq '.data.permissions[] | select(.isGranted == false)'

# Compare Bridge and local CLI TCC state
peekaboo permissions status --all-sources

# Hand someone clear remediation steps
peekaboo permissions grant

# Request Screen Recording for the local Peekaboo binary
peekaboo permissions request-screen-recording

# Request Event Synthesizing for background input
peekaboo permissions request-event-synthesizing
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Check the printed `Source:` line. If it says `Peekaboo Bridge`, the status reflects the explicit Bridge socket or selected reusable daemon's TCC grants. Grant Screen Recording to that host process, or force local capture with `--no-remote --capture-engine cg` only when the caller process is running in the active Aqua GUI session and already has permission. SSH, LaunchAgent, Codex, and other background launchd sessions can still return wallpaper-only pixels despite TCC grants, so prefer Bridge there.
- Treat `--capture-engine` as a local-debug override: it disables Bridge selection for that command.
- If capture returns a blank desktop, wallpaper, or no windows while `permissions status` reports Screen Recording as denied, run `peekaboo permissions request-screen-recording` and then restart the affected Peekaboo process. Homebrew upgrades can move the CLI to a new Cellar path, so confirm the enabled System Settings row belongs to the current binary.
- Confirm your target (app/window/selector) with `peekaboo list`/`peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
