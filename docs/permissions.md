---
summary: 'Grant required macOS permissions and understand performance trade-offs for Peekaboo.'
read_when:
  - 'Peekaboo cannot capture screens or focus windows'
  - 'tuning capture performance or troubleshooting permission dialogs'
---

# Permissions & Performance

## Requirements

- **macOS 15.0+ (Sequoia)** – core automation APIs depend on Sequoia.
- **Screen Recording (required)** – enables CGWindow capture and multi-app automation.
- **Accessibility (recommended)** – improves window focus, menu interaction, and dialog control.
- **Event Synthesizing (optional)** – enables background input delivery such as `hotkey --focus-background` and default `click` delivery to post events to a target process without activating it.

For build and runtime version details, see [platform-support.md](platform-support.md).

## Granting Permissions

1. **Screen Recording**
   - System Settings → Privacy & Security → Screen & System Audio Recording.
   - Enable Terminal, your editor, or whatever shell runs `peekaboo`.
   - Benefit: fast CGWindow enumeration and background captures.

2. **Accessibility**
   - System Settings → Privacy & Security → Accessibility.
   - Enable the same terminals/IDEs so Peekaboo can send clicks/keystrokes reliably.

3. **Event Synthesizing**
   - Run `peekaboo permissions request-event-synthesizing`.
   - By default this requests access for the selected Peekaboo Bridge host, which is the process that sends background input. Add `--no-remote` to request access for the local CLI process instead.
   - If needed, enable Peekaboo in System Settings → Privacy & Security → Accessibility.
   - Benefit: process-targeted background hotkeys and clicks without focus stealing.

4. **Check Permissions**
   ```bash
   peekaboo permissions status    # Check current permission status
   peekaboo permissions status --all-sources
   peekaboo permissions grant     # Show grant instructions
   ```

## Bridge and subprocess runners

`peekaboo permissions status` prints a `Source:` line. If it says `Peekaboo Bridge`, capture and automation
permissions are being checked on the selected host app. Grant Screen Recording and Accessibility to that host,
or bypass Bridge for local capture when the caller already has Screen Recording:

```bash
peekaboo see --mode screen --screen-index 0 --no-remote --capture-engine cg --json
```

This is useful for OpenClaw or other Node/subprocess runners where the parent process has TCC grants but the
Bridge host does not.

Use `peekaboo permissions status --all-sources` to compare the selected Bridge host and local CLI process side by side.

## Performance Tips

- **Hybrid enumeration** – with Screen Recording enabled, Peekaboo prefers the CGWindowList APIs and falls back to AX only when necessary.
- **Built-in timeouts** – window/menu operations have ~2 s default timeouts to avoid hangs; adjust via CLI options if needed.
- **Parallel processing** – when both permissions are enabled, window queries and captures stream concurrently.

If automation feels sluggish, confirm permissions, then re-run with `--verbose` to inspect timings.
