---
summary: 'Grant required macOS permissions and understand performance trade-offs for Peekaboo.'
read_when:
  - 'Peekaboo cannot capture screens or focus windows'
  - 'tuning capture performance or troubleshooting permission dialogs'
---

# Permissions & Performance

## 3.9.6 signing migration

Peekaboo 3.9.6 completes the move from Peter Steinberger's Developer ID team to `Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)` for every shipped macOS executable. Bundle identifiers and the Sparkle update key are unchanged, but macOS still treats the newly signed CLI as a different TCC client. After updating, re-grant Screen Recording, Accessibility, and any Automation permissions your workflows use.

Peekaboo.app reopens its permission checklist once when required grants are missing. You can also open Peekaboo.app → Settings → Permissions, choose Permissions Onboarding from the menu bar item, or run:

```bash
peekaboo permissions status --all-sources
peekaboo permissions grant
```

If you use a Bridge host, grant permissions to the host reported by `peekaboo permissions status`, not only to the shell that launched the CLI.

## Requirements

- **macOS 15.0+ (Sequoia)** – core automation APIs depend on Sequoia.
- **Screen Recording (required)** – enables CGWindow capture and multi-app automation.
- **Accessibility (recommended)** – improves window focus, menu interaction, dialog control, and action-based element/query clicks.
- **Event Synthesizing (optional)** – enables background keyboard input, coordinate clicks, and synthetic click fallback without activating the target app.

For build and runtime version details, see [platform-support.md](platform-support.md).

## Granting Permissions

1. **Screen Recording**
   - System Settings → Privacy & Security → Screen & System Audio Recording.
   - Run `peekaboo permissions request-screen-recording` to trigger the prompt when macOS allows one.
   - Enable Terminal, your editor, or whatever shell runs `peekaboo`.
   - If you installed with Homebrew, make sure the enabled entry points at the current Peekaboo binary; upgrades can move it to a new Cellar version path.
   - Benefit: fast CGWindow enumeration and background captures.

2. **Accessibility**
   - System Settings → Privacy & Security → Accessibility.
   - Enable the same terminals/IDEs so Peekaboo can send clicks/keystrokes reliably.

3. **Event Synthesizing**
   - Run `peekaboo permissions request-event-synthesizing`.
   - By default this requests access for the selected Peekaboo Bridge host, which is the process that sends background input. Add `--no-remote` to request access for the local CLI process instead.
   - If needed, enable Peekaboo in System Settings → Privacy & Security → Accessibility.
   - Benefit: process-targeted typing, hotkeys, key presses, paste, coordinate clicks, and click fallback without focus stealing.
   - If you prefer focused/global input, pass `--foreground` to the interaction command; foreground mode still benefits from Accessibility for focusing windows.

4. **Check Permissions**
   ```bash
   peekaboo permissions status    # Check current permission status
   peekaboo permissions status --all-sources
   peekaboo permissions grant     # Show grant instructions
   ```

## Bridge and subprocess runners

`peekaboo permissions status` prints a `Source:` line. If it says `Peekaboo Bridge`, capture and automation
permissions are being checked through an explicit socket, the selected reusable daemon, or a healthy Peekaboo.app
fallback. Grant Screen Recording and Accessibility to that host process,
or bypass Bridge for local capture only when the caller is known to run in the active Aqua GUI session:

```bash
peekaboo see --mode screen --screen-index 0 --no-remote --capture-engine cg --json
```

This is useful for app-launched subprocess runners where the parent process has TCC grants but the selected host
does not. For SSH, LaunchAgent, Codex, and other background launchd sessions, prefer the Bridge path even when
TCC appears granted; CoreGraphics can otherwise report success while returning only the desktop wallpaper or a
redacted image. Passing `--capture-engine` is a local-debug override and disables Bridge selection for that
command.

Use `peekaboo permissions status --all-sources` to compare the selected Bridge host and local CLI process side by side.

## Performance Tips

- **Hybrid enumeration** – with Screen Recording enabled, Peekaboo prefers the CGWindowList APIs and falls back to AX only when necessary.
- **Built-in timeouts** – window/menu operations have ~2 s default timeouts to avoid hangs; adjust via CLI options if needed.
- **Parallel processing** – when both permissions are enabled, window queries and captures stream concurrently.

If automation feels sluggish, confirm permissions, then re-run with `--verbose` to inspect timings.
