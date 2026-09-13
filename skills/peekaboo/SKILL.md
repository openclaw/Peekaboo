---
name: peekaboo
description: "Use Peekaboo for macOS screenshots, Accessibility inspection, and background app/window/UI automation, including fallback computer use when the primary tool cannot handle an authorized task."
---

# Peekaboo

Use native Peekaboo commands for macOS apps, windows, menus, dialogs, browser chrome, and pixels. Prefer existing browser tooling for page content, DOM, forms, console, and network; Peekaboo's `browser` command is available when that integration is configured. Stay within the user's authorized task and verify the resulting UI.

## Select the CLI and execution host

Use the installed signed CLI for ordinary automation; building Peekaboo is a development task, not a prerequisite. Honor an explicit binary override and inspect its version:

```bash
PB="${PEEKABOO_BIN:-$(command -v peekaboo)}"
"$PB" --version
"$PB" bridge status --verbose --json
"$PB" permissions status --all-sources --json
```

The CLI ships separately from `Peekaboo.app`. Keep the release archive's CLI and accompanying compatibility dylibs together. The app's executable is a GUI host, not the CLI; current releases reject CLI-style arguments before Bridge startup. Using the same current signed CLI/app release avoids capability drift, but compatibility is negotiated by protocol and operation capabilities, not simple version equality.

Host selection depends on the operation. Ordinary automation prefers a healthy reusable daemon, then a capable GUI host, before starting a daemon. Capture, AX inspection, browser, and snapshot-state work first prefer and may start the current CLI build's daemon. An explicit snapshot routes to its unique live producer; explicit socket or local-only overrides remain authoritative. Do not stop hosts merely because several candidates exist.

When app-held permissions are needed, launch the GUI host and pin the same socket for permission checks and observation:

```bash
open -gj -a Peekaboo
GUI_SOCKET="$HOME/Library/Application Support/Peekaboo/bridge.sock"
"$PB" bridge status --bridge-socket "$GUI_SOCKET" --verbose --json
"$PB" permissions status --bridge-socket "$GUI_SOCKET" --json
"$PB" see --bridge-socket "$GUI_SOCKET" --no-elements --mode screen --path /tmp/peekaboo-screen.png --json
```

`open -gj` requests a background/hidden launch; first-run onboarding or missing-configuration prompts can still activate the app. Verify the reported host rather than assuming it was selected. The GUI app, daemon, and caller-local CLI have separate TCC contexts. Screen Recording is checked where capture runs, Accessibility where AX runs, and Event Synthesizing where events are sent. Both local and Bridge sources need not have identical grants.

## Observe, target, act, verify

1. Resolve the target with `app list` and `window list`; prefer exact PID/window IDs over broad app names or titles.
2. Observe with pixels, Accessibility, or both. Ordinary `see` does not activate the target; `--web-focus` explicitly permits a focus action and is not a read-only retry.
3. Copy opaque element and snapshot IDs from that observation. Prefer an element click, `set-value` for an intended value replacement, or a suitable state-only AX action over coordinate input.
4. Use background delivery with an exact target. Add `--foreground` when shared-desktop interaction is authorized and needed; do not silently promote a refused background command.
5. Read the canonical outcome and verify the intended change with a fresh `see`, `verify`, or other readback. A successful dispatch alone does not prove the app changed.

```bash
"$PB" app list --include-hidden --include-background --json
"$PB" window list --app Safari --json

# Pixels only; an exact window also publishes a coordinate receipt.
"$PB" see --window-id "$WINDOW_ID" --no-elements --path /tmp/peekaboo-window.png --json

# Pixels and element IDs, with an annotated artifact.
"$PB" see --window-id "$WINDOW_ID" --annotate --path /tmp/peekaboo-elements.png --json

# AX text and IDs without screenshot capture.
"$PB" see --window-id "$WINDOW_ID" --tree --no-screenshot --json

# Use IDs from the applicable fresh observation, not all examples in sequence.
"$PB" click --on "$ELEMENT_ID" --snapshot "$SNAPSHOT_ID" --json
"$PB" scroll --direction down --on "$ELEMENT_ID" --snapshot "$SNAPSHOT_ID" --json
```

After a mutation changes the UI, capture again before using IDs for another action. `requires_fresh_observation: true` consumes the snapshot for mutation. Partial, indeterminate, and unverified results may already have changed the app; never repeat input blindly. Inspect image contents to verify capture and visual results. `sips -g pixelWidth -g pixelHeight <path>` checks dimensions only.

## Background input and coordinates

Background `click` can invoke an element's AX action or focus a writable text field without activating its app. `--input-strategy actionOnly` selects the AX route; coordinate clicks can also use it by hit-testing a pressable AX element. Generic `action AXPress` and `action AXShowMenu` require `--foreground`; only generic `AXIncrement`/`AXDecrement` are background-safe. Prefer dedicated `click` for background activation.

Background typing/paste accept exact window routes even when the app has several windows. App/PID-only routes require a complete inventory with at most one eligible window. Prefer a fresh exact-window snapshot for `type`; it must identify the focused field in the intended internal key window. If needed, click the field, observe again, then type using the new snapshot. Exact routes revalidate process generation, window bounds, and focus. AX text edits need Accessibility; event fallback needs Event Synthesizing.

```bash
"$PB" type "text" --snapshot "$SNAPSHOT_ID" --json
"$PB" press Return --app TextEdit --window-id "$WINDOW_ID" --json
"$PB" paste "text" --app TextEdit --window-id "$WINDOW_ID" --json
```

`type` normally succeeds only for a confirmed change. It can return non-success after accepted dispatch, so read the outcome before retrying. Scripts doing their own follow-up observation may opt into `--accept-dispatched`; this does not confirm delivery. Raw background `press` needs an exact window selector or fresh exact-window snapshot; app/PID-only chords require `--foreground`. Default background-only Agent/MCP typing is stricter than the direct CLI: it requires a fresh exact non-dialog snapshot without competing selectors.

Background `scroll` requires `--on`; app/window flags alone do not establish an element target. Targetless scrolling, `--smooth`, and nonzero `--delay` need `--foreground`. Shared-cursor `move`, `drag`, targetless keyboard input, and `click --long-press` also require explicit foreground mode.

`click --at` uses logical points. Background coordinates are relative to the snapshot window even without target flags; add `--global` for global logical coordinates inside that window. Foreground coordinates are window-relative with target flags and global without them. Ordinary `see` produces logical1x images; do not divide their coordinates by a Retina scale. For `--retina`, crops, or resized previews, use the capture's coordinate metadata and `screen list` bounds/scale to map pixels to logical points.

```bash
"$PB" see --window-id "$WINDOW_ID" --no-elements --path /tmp/peekaboo-click.png --json
# Copy the returned snapshot ID before clicking window-local logical points.
"$PB" click --window-id "$WINDOW_ID" --at 20,40 --snapshot "$SNAPSHOT_ID" --json
```

Background coordinate clicks require a fresh screenshot snapshot with an exact process/window/bounds receipt; AX-only observations are insufficient. Moved, replaced, or unverifiable targets fail before dispatch. Background right/double/middle/triple clicks can use exact routed events, but completed dispatch remains effect-unverifiable. Observe before deciding whether another click is needed.

## Troubleshooting and references

- Capture permissions belong to the executing host. Compare `permissions status --all-sources`, then pin the intended host for diagnostics and capture. Request only permissions needed for the selected operation; do not replace signed installs with ad-hoc builds against saved TCC/Keychain state.
- ScreenCaptureKit ownership checks use known potential host identities and ownership records, including Claude Desktop; another process linking the framework does not by itself block capture. If ownership cannot be established, explicit `see --capture-engine classic` (alias `cg`) avoids in-process ScreenCaptureKit on the selected host. `auto` has conditional fallback paths and is not guaranteed to fail whenever Claude is running. Classic still needs valid capture permission evidence on its executing host.
- Prefer Bridge capture from SSH or background launchd sessions. `--no-remote --capture-engine cg` is a caller-local diagnostic for a known active Aqua session; elsewhere it can return wallpaper-only or redacted pixels despite reporting success.
- If a concrete snapshot's producer is unavailable or an explicit host does not own it, observe again on the intended host. Do not substitute an unrelated snapshot or weaken the target merely to retry.
- Use `capture live` for change-aware capture and `capture video` to sample an existing video. Store task captures under an explicit temporary path and inspect/redact them before any authorized sharing.
- Discover current syntax with `<command> --help`, `learn`, `tools --json`, and `tools describe <name> --json` (MCP schema, not CLI flags). Timing options accept bare milliseconds or `ms`/`s`; prefer explicit suffixes.
- v4 uses noun inventories (`app list`, `window list`, `screen list`), `see`, `press`, `action`, and `click --at`; use live help when translating older examples.

Canonical references stay usable when this skill is linked into another repository or agent directory:

- [Command index](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/README.md), especially [type](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/type.md), [click](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/click.md), and [scroll](https://github.com/openclaw/Peekaboo/blob/main/docs/commands/scroll.md).
- [Bridge host](https://github.com/openclaw/Peekaboo/blob/main/docs/bridge-host.md), [permissions](https://github.com/openclaw/Peekaboo/blob/main/docs/permissions.md), and [subprocess integration](https://github.com/openclaw/Peekaboo/blob/main/docs/integrations/subprocess.md).
- For Peekaboo development, read the checkout's [AGENTS.md](https://github.com/openclaw/Peekaboo/blob/main/AGENTS.md) and [building guide](https://github.com/openclaw/Peekaboo/blob/main/docs/building.md); follow their source-build and test workflow for code changes.
