---
summary: 'Cheat sheet for every Peekaboo CLI command grouped by category.'
read_when:
  - 'learning what each CLI subcommand does'
  - 'mapping agent tools to direct CLI usage'
---

# CLI Command Reference

Peekaboo’s CLI covers most of what agents can do, and selected MCP/agent tools also have dedicated per-tool CLI wrappers such as `browser` and `inspect-ui`. Run `peekaboo tools` to see the MCP/agent catalog and `peekaboo --help` for the CLI command list. Commands share the same snapshot cache and most support `--json` (alias: `--json-output`) for scripting. Run `peekaboo` with no arguments to print the root help menu, and `peekaboo --version` at any time to see the embedded build/commit metadata stamped into the binary.

Use `peekaboo <command> --help` for inline flag descriptions; this page links to the authoritative docs in `docs/commands/`.

## Vision & Capture

- [`see`](commands/see.md) – Capture annotated UI maps, produce snapshot IDs, and optionally run AI analysis.
- [`image`](commands/image.md) – Save raw PNG/JPG captures of screens, windows, or menu bar regions; supports `--analyze` prompts.
- `capture` – Long-running capture. `capture live` (adaptive PNG frames) replaces watch; `capture action` records around a child command; `capture video` ingests a video and samples frames. Outputs frames, contact sheet, metadata, optional MP4.
- [`list`](commands/list.md) – Subcommands: `apps`, `windows`, `screens`, `menubar`, `permissions`.
- [`tools`](commands/tools.md) – List the MCP/agent tool catalog; supports `--verbose` and `--json`.
- [`completions`](commands/completions.md) – Generate shell-native completions for zsh, bash, and fish from Commander metadata.
- [`run`](commands/run.md) – Execute `.peekaboo.json` scripts (`--output`, `--no-fail-fast`).
- [`sleep`](commands/sleep.md) – Millisecond pauses between steps.
- [`clean`](commands/clean.md) – Remove snapshot caches by ID, age, or all at once (`--dry-run` supported).
- [`config`](commands/config.md) – Subcommands: `init`, `show`, `status`, `edit`, `validate`, `add`, `login`, `set-credential` (legacy), `add-provider`, `list-providers`, `test-provider`, `remove-provider`, `models-provider`.
- [`daemon`](commands/daemon.md) – Start/stop/status for the headless daemon (live window tracking, in-memory snapshots).
- [`permissions`](commands/permissions.md) – `status` (default), `grant`, and Event Synthesizing request helpers.
- [`learn`](commands/learn.md) – Print the complete agent guide (system prompt, tool catalog, Commander signatures).

## Interaction

- [`click`](commands/click.md) – Target elements by ID/query/coords with smart waits and focus helpers.
- [`type`](commands/type.md) – Send text and control keys; supports `--clear`, `--delay`, tab counts, etc.
- [`press`](commands/press.md) – Fire `SpecialKey` sequences with repeat counts.
- [`hotkey`](commands/hotkey.md) – Emit modifier combos like `cmd,shift,t` in one shot.
- [`paste`](commands/paste.md) – Atomically set clipboard → paste (Cmd+V) → restore clipboard.
- [`scroll`](commands/scroll.md) – Directional scrolling with optional element targeting and smooth mode.
- [`swipe`](commands/swipe.md) – Gesture-style drags between IDs or coordinates (`--duration`, `--steps`).
- [`drag`](commands/drag.md) – Drag-and-drop across elements, coordinates, or Dock destinations with modifiers.
- [`move`](commands/move.md) – Position the cursor at coordinates, element centers, or screen center with optional smoothing.

## Windows, Menus, Apps, Spaces

- [`window`](commands/window.md) – Subcommands: `close`, `minimize`, `maximize`, `move`, `resize`, `set-bounds`, `focus`, `list`.
- [`space`](commands/space.md) – `list`, `switch`, `move-window` for Spaces/virtual desktops.
- [`menu`](commands/menu.md) – `click`, `click-extra`, `list`, `list-all` for application menus + menu extras.
- [`menubar`](commands/menubar.md) – `list` and `click` status-bar icons by name or index.
- [`app`](commands/app.md) – `launch`, `quit`, `relaunch`, `hide`, `unhide`, `switch`, `list`; `launch` now accepts repeatable `--open <url|path>` arguments (plus `--wait-until-ready`, `--no-focus`) to pass documents/URLs directly to the target app.
- [`open`](commands/open.md) – Enhanced macOS `open` that respects `--app/--bundle-id`, `--wait-until-ready`, `--no-focus`, and emits JSON payloads for scripting.
- [`dock`](commands/dock.md) – `launch`, `right-click`, `hide`, `show`, `list` Dock items.
- [`dialog`](commands/dialog.md) – `click`, `input`, `file`, `dismiss`, `list` system dialogs.
- [`visualizer`](commands/visualizer.md) – Run the built-in visual feedback smoke suite (fires screenshot flash, capture HUD, cursor click, menu highlights, etc.) to verify Peekaboo.app overlays.

## Automation & Integrations

- [`agent`](commands/agent.md) – Natural-language automation with dry-run planning, resume, audio modes, and model overrides.
- [`browser`](browser-mcp.md) – Dedicated CLI wrapper for the browser MCP tool: Chrome page status/connect/navigation/snapshot/click/fill/type/console/network/screenshot/trace.
- `inspect-ui` – Dedicated CLI wrapper for the `inspect_ui` MCP tool, useful for accessibility-tree text/control inspection without screenshots.
- [`mcp`](commands/mcp.md) – Run Peekaboo's MCP server; `serve` is the only subcommand and stdio is the implemented transport.

Need structured payloads? Pass `--json` (or `--json-output`) where supported, or orchestrate multiple commands inside `.peekaboo.json` scripts executed via [`peekaboo run`](commands/run.md).
