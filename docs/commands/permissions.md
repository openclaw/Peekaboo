---
summary: 'Check or explain required macOS permissions via peekaboo permissions'
read_when:
  - 'verifying screen recording + accessibility entitlements before a run'
  - 'needing grant instructions for CI or remote machines'
---

# `peekaboo permissions`

`peekaboo permissions` centralizes entitlement checks. The default `status` subcommand reports the runtime view of Screen Recording, Accessibility, and Event Synthesizing. `grant` prints the same table plus human-readable steps so you can fix issues without hunting through docs.

Status is one snapshot from the execution host selected by normal runtime routing. A Bridge-backed CLI or MCP session
therefore reports the Bridge host's three grants with one request; it never mixes remote Screen Recording or
Accessibility with caller-local Event Synthesizing state. Screen Recording and Accessibility are required. Event
Synthesizing remains optional globally and is reported with the actions it limits: background keyboard input and
foreground synthetic pointer input.

Peekaboo's application, Dock, and UI operations use native macOS APIs. It does not probe, request, or require
Automation (AppleScript) permission. The Bridge protocol still decodes the legacy field so mixed-version clients
receive a structured compatibility result instead of failing the whole handshake.
If an older Bridge host reports an AppleScript denial, update the CLI and Bridge host instead of granting Automation
access; current hosts perform these operations natively.

## Subcommands
| Name | Purpose |
| --- | --- |
| `status` (default) | Fetches the current permission set and prints each entry (`granted`, `denied`, etc.). Honors `--json` so agents can block proactively. Add `--all-sources` to compare Bridge and local CLI permissions side by side. |
| `grant` | Reuses the same snapshot but focuses on remediation: when in text mode it prints the exact System Settings pane/location for each missing entitlement. |
| `request <kind>` | Request `accessibility`, `screen-recording`, or `event-synthesizing`. Screen Recording and Accessibility target the local process; Event Synthesizing follows runtime routing unless `--no-remote` is used. |

## Implementation notes
- All subcommands conform to `RuntimeOptionsConfigurable`, so they inherit global `--json`/`--verbose` flags even when invoked from compound commands like `peekaboo learn`.
- The command executes entirely on the main actor, avoiding extra prompts or sandbox warnings—the same code path runs at CLI startup to warn if entitlements are missing.
- JSON mode uses `outputSuccessCodable`, which means status results include a `permissions` array with `{name, isRequired, isGranted, grantInstructions}` entries that can be diffed over time.
- `--all-sources --json` returns `{selectedSource, sources}` so callers can distinguish Bridge TCC grants from local CLI grants.
- The MCP `permissions` tool returns an error when either required permission is missing, while retaining all three
  permission fields and the action-specific Event Synthesizing limitations in response metadata.

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
peekaboo permissions request screen-recording

# Request Accessibility for the local Peekaboo binary
peekaboo permissions request accessibility

# Request Event Synthesizing for background input
peekaboo permissions request event-synthesizing
```

## Troubleshooting
- Verify Screen Recording + Accessibility permissions (`peekaboo permissions status`).
- Check the printed `Source:` line. If it says `Peekaboo Bridge`, the status reflects an explicit socket, the selected
  reusable daemon, or a healthy Peekaboo.app fallback and its TCC grants. Grant Screen Recording to that host process,
  or force a local pixel capture with `peekaboo see --no-elements --no-remote --capture-engine cg` only when the caller process is
  running in the active
  Aqua GUI session and already has permission. SSH, LaunchAgent, Codex, and other background launchd sessions can
  still return wallpaper-only pixels despite TCC grants, so prefer Bridge there.
- `see --capture-engine` applies the engine on the selected Bridge host without changing TCC ownership. Add
  `--no-remote` only for an intentional caller-local debug capture; without it, an unavailable compatible host fails
  before local fallback.
- If capture returns a blank desktop, wallpaper, or no windows while `permissions status` reports Screen Recording as denied, run `peekaboo permissions request screen-recording` and then restart the affected Peekaboo process. Homebrew upgrades can move the CLI to a new Cellar path, so confirm the enabled System Settings row belongs to the current binary.
- Confirm your target with `peekaboo app list`, `peekaboo window list`, or `peekaboo see` before rerunning.
- Re-run with `--json` or `--verbose` to surface detailed errors.
