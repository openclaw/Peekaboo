---
summary: 'Cheat sheet for every Peekaboo CLI command grouped by category.'
read_when:
  - 'learning what each CLI subcommand does'
  - 'mapping agent tools to direct CLI usage'
---

# CLI Command Reference

Peekaboo’s CLI covers most of what agents can do, and selected MCP/agent tools also have dedicated CLI surfaces such as `browser`. Run `peekaboo tools` to see the MCP/agent catalog and `peekaboo --help` for the CLI command list. Commands share the same snapshot cache and most support `--json` for scripting. Run `peekaboo` with no arguments to print the root help menu, and `peekaboo --version` at any time to see the embedded build/commit metadata stamped into the binary.

Use `peekaboo <command> --help` for inline flag descriptions; this page links to the authoritative docs in `docs/commands/`.

Timing flags share one grammar: bare numbers mean milliseconds, while `ms` and `s` suffixes are accepted (`500`, `500ms`, `2s`, `1.5s`). Input commands also share `--foreground`, `--no-auto-focus`, `--space-switch`, and `--bring-to-current-space`; click/type/press/paste additionally expose explicit `--focus-background` delivery.

## Vision & Capture

- [`see`](commands/see.md) – Capture pixels and annotated UI maps, print AX trees, produce snapshot IDs, and optionally run AI analysis.
- [`verify`](commands/verify.md) – Poll stable window and element predicates with satisfied, unsatisfied, or unknown results.
- `capture` – Long-running capture. `capture live` (adaptive PNG frames) replaces watch; `capture action` records around a child command; `capture video` ingests a video and samples frames. Outputs frames, contact sheet, metadata, optional MP4.
- [`tools`](commands/tools.md) – List the MCP/agent tool catalog, or use `tools describe <name>` for one full input schema.
- [`completions`](commands/completions.md) – Generate shell-native completions for zsh, bash, and fish from Commander metadata.
- [`clean`](commands/clean.md) – Remove snapshot caches by ID, age, or all at once (`--dry-run` supported).
- [`config`](commands/config.md) – `init`, `show`, `edit`, `validate`, `status`, `login`, plus `provider add|remove|list|test|models` and `credential set`.
- [`daemon`](commands/daemon.md) – Start/stop/status for the headless daemon (live window tracking, in-memory snapshots).
- [`permissions`](commands/permissions.md) – `status` (default), `grant`, and `request accessibility|screen-recording|event-synthesizing`.
- [`learn`](commands/learn.md) – Print the complete agent guide (system prompt, tool catalog, Commander signatures).

## Interaction

- [`click`](commands/click.md) – Target elements by ID/query or `--at x,y` with smart waits and focus helpers.
- [`type`](commands/type.md) – Send text with `--clear`, fixed-delay, or human cadence.
- [`press`](commands/press.md) – Send xdotool-style chords such as `cmd+shift+t` and chord sequences.
- [`paste`](commands/paste.md) – Atomically set clipboard → paste (Cmd+V) → restore clipboard.
- [`scroll`](commands/scroll.md) – Directional scrolling with optional element targeting and smooth mode.
- [`drag`](commands/drag.md) – Drag between element IDs or coordinates with modifiers and left/right button selection.
- [`action`](commands/action.md) – Invoke a named accessibility action such as `AXPress` on an element.
- [`move`](commands/move.md) – Position the cursor at coordinates or element centers with optional smoothing.

## Windows, Menus, Apps, Spaces

- [`window`](commands/window.md) – Subcommands: `close`, `minimize`, `restore`, `maximize`, `move`, `resize`, `set-bounds`, `focus`, `list`.
- [`space`](commands/space.md) – `list`, `switch`, `move-window` for Spaces/virtual desktops.
- [`menu`](commands/menu.md) – `click` and `list` for application menus.
- [`menubar`](commands/menubar.md) – `list` and `click` status-bar icons by name or index.
- [`app`](commands/app.md) – `launch`, `quit`, `relaunch`, `hide`, `unhide`, `switch`, `focus`, `list`; lifecycle targets accept a positional app or their named flag.
- [`dock`](commands/dock.md) – `launch`, `right-click`, `hide`, `show`, `list` Dock items.
- [`dialog`](commands/dialog.md) – `click`, `input`, `file`, `dismiss`, `list` system dialogs.
- [`visualizer`](commands/visualizer.md) – Run the built-in visual feedback smoke suite (fires screenshot flash, capture HUD, cursor click, menu highlights, etc.) to verify Peekaboo.app overlays.

## Automation & Integrations

- [`agent`](commands/agent.md) – `run` (default), `resume`, `sessions`, and `chat`, with dry-run planning, audio modes, and model overrides.
- [`browser`](browser-mcp.md) – Dedicated CLI wrapper for the browser MCP tool: Chrome page status/connect/navigation/snapshot/click/fill/type/console/network/screenshot/trace.
- `see --tree --no-screenshot` – Accessibility-tree text/control inspection without pixel capture.
- [`mcp`](commands/mcp.md) – Run Peekaboo's MCP server; `serve` is the only subcommand and stdio is the implemented transport.

Need structured payloads? Pass `--json` (or the Commander-provided `--json-output` alias) where supported and compose commands with your shell.
