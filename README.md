# Peekaboo 🫣 - Mac automation that sees the screen and does the clicks.

![Peekaboo Banner](assets/peekaboo.png)

[![npm package](https://img.shields.io/badge/npm_package-3.5.3-brightgreen?logo=npm&logoColor=white&style=flat-square)](https://www.npmjs.com/package/@steipete/peekaboo)
[![License: MIT](https://img.shields.io/badge/License-MIT-ffd60a?style=flat-square)](https://opensource.org/licenses/MIT)
[![macOS 15.0+ (Sequoia)](https://img.shields.io/badge/macOS-15.0%2B_(Sequoia)-0078d7?logo=apple&logoColor=white&style=flat-square)](https://www.apple.com/macos/)
[![Swift 6.2](https://img.shields.io/badge/Swift-6.2-F05138?logo=swift&logoColor=white&style=flat-square)](https://swift.org/)
[![node >=22](https://img.shields.io/badge/node-%3E%3D22.0.0-2ea44f?logo=node.js&logoColor=white&style=flat-square)](https://nodejs.org/)
[![Download macOS](https://img.shields.io/badge/Download-macOS-000000?logo=apple&logoColor=white&style=flat-square)](https://github.com/openclaw/Peekaboo/releases/latest)
[![Homebrew](https://img.shields.io/badge/Homebrew-steipete%2Ftap-b28f62?logo=homebrew&logoColor=white&style=flat-square)](https://github.com/steipete/homebrew-tap)
[![Ask DeepWiki](https://img.shields.io/badge/Ask-DeepWiki-0088cc?style=flat-square)](https://deepwiki.com/openclaw/Peekaboo)

Peekaboo brings high-fidelity screen capture, AI analysis, and complete GUI automation to macOS. Version 3 adds native agent flows and multi-screen automation across the CLI and MCP server.

## What you get
- Pixel-accurate captures (windows, screens, menu bar) with optional Retina 2x scaling.
- Natural-language agent that chains Peekaboo tools (see, click, type, scroll, hotkey, menu, window, app, dock, space).
- Action-first UI automation for routine clicks/scrolls, with background process-targeted input by default when a target is known.
- Direct accessibility tools for settable values and named actions (`set-value`, `perform-action`).
- Menu and menubar discovery with structured JSON; no clicks required.
- Multi-provider AI through Tachikoma, including hosted, local, and OpenAI-/Anthropic-compatible providers.
- Claude Fable 5 support with 1M context and a 128K output ceiling; saved temperature/max-token settings are shared by the app and CLI and clamped to each model's capabilities.
- MCP server for Codex, Claude Code, and Cursor plus a native CLI; the same tools in both.
- Warm daemon and Peekaboo.app Bridge hosts for permission-bound automation, with distinct lease-owned sockets and local fallback.
- Configurable, testable workflows with reproducible sessions and strict typing.
- Requires macOS Screen Recording + Accessibility permissions (see [docs/permissions.md](docs/permissions.md)).

## Install
- macOS app + CLI (Homebrew):
  ```bash
  brew install steipete/tap/peekaboo
  ```
- MCP server (Node 22+, no global install needed):
  ```bash
  npx -y @steipete/peekaboo
  ```

## Quick start
```bash
# Capture full screen at Retina scale and save to Desktop
peekaboo image --mode screen --retina --path ~/Desktop/screen.png

# Capture current UI state, then copy its snapshot and opaque element IDs exactly
peekaboo see --app Safari --json
SNAPSHOT="<snapshot-id>"
TEXT_FIELD_ID="<text-field-id>"
BUTTON_ID="<button-id>"

# Click a button by label
peekaboo click --on "Reload this page" --snapshot "$SNAPSHOT"

# Directly set a text field value when the accessibility value is settable
peekaboo set-value --on "$TEXT_FIELD_ID" --value "hello" --snapshot "$SNAPSHOT"

# Invoke a named accessibility action on an element
peekaboo perform-action --on "$BUTTON_ID" --action AXPress --snapshot "$SNAPSHOT"

# Run a natural-language automation
peekaboo agent "Open Notes and create a TODO list with three items"

# Run as an MCP server (Codex, Claude Code, Cursor)
npx -y @steipete/peekaboo

# Minimal MCP client config snippet:
# {
#   "mcpServers": {
#     "peekaboo": {
#       "command": "npx",
#       "args": ["-y", "@steipete/peekaboo"],
#       "env": {
#         "PEEKABOO_AI_PROVIDERS": "openai/gpt-5.5,anthropic/claude-opus-4-8"
#       }
#     }
#   }
# }
```

## Shell completions

Peekaboo can generate shell-native completions directly from the same Commander
metadata that powers CLI help and docs:

```bash
# Current shell (recommended)
eval "$(peekaboo completions $SHELL)"

# Explicit shells
eval "$(peekaboo completions zsh)"
eval "$(peekaboo completions bash)"
peekaboo completions fish | source
```

For persistent setup and troubleshooting, see
[docs/commands/completions.md](docs/commands/completions.md).

## Background vs foreground input

`click`, `type`, `press`, `hotkey`, and `paste` default to **background** delivery when Peekaboo can resolve a target process from `--app`, `--pid`, `--window-id`, or snapshot metadata. Background delivery posts process-targeted input without making the target app frontmost, so scripts can interact with Safari, Notes, Terminal, etc. without stealing focus.

Use `--foreground` when the app only accepts input in its focused key window, when you need a real foreground mouse event, or when you are intentionally driving the current focus. Focus flags such as `--space-switch` and `--bring-to-current-space` also imply foreground delivery. Element/query clicks first use Accessibility actions; keyboard input, coordinate clicks, and synthetic click fallback require Event Synthesizing for the sending process. Run `peekaboo permissions request-event-synthesizing` if `permissions status` reports it missing.

```bash
# Background: target Safari without activating it
peekaboo click "Address and search bar" --app Safari
peekaboo type "github.com/openclaw/Peekaboo" --app Safari --return

# Foreground: focus Safari first for apps/fields that reject background input
peekaboo click "Address and search bar" --app Safari --foreground
peekaboo type "github.com/openclaw/Peekaboo" --app Safari --return --foreground
```

| Command | Key flags / subcommands | What it does |
| --- | --- | --- |
| [see](docs/commands/see.md) | `--app`, `--mode screen/window`, `--retina`, `--json` | Capture and annotate UI, return snapshot + element IDs |
| [click](docs/commands/click.md) | `--on <id/query>`, `--snapshot`, `--wait-for`, `--coords`, `--foreground` | Click by element ID, label, or coordinates |
| [type](docs/commands/type.md) | `--text`, `--clear`, `--profile`, `--delay`, `--foreground` | Enter text with pacing options |
| [set-value](docs/commands/set-value.md) | `--on <id/query>`, `--value`, `--snapshot` | Directly set a settable accessibility value |
| [perform-action](docs/commands/perform-action.md) | `--on <id/query>`, `--action`, `--snapshot` | Invoke a named accessibility action |
| [press](docs/commands/press.md) | key names, `--count`, `--delay`, `--hold`, `--foreground` | Special keys and sequences |
| [hotkey](docs/commands/hotkey.md) | combos like `cmd,shift,t`, `--foreground` | Modifier combos (cmd/ctrl/alt/shift) |
| [paste](docs/commands/paste.md) | text/file/image payloads, `--restore-delay-ms`, `--foreground` | Paste with clipboard restore |
| [scroll](docs/commands/scroll.md) | `--on <id>`, `--direction up/down`, `--amount` | Scroll views or elements |
| [swipe](docs/commands/swipe.md) | `--from/--to`, `--duration`, `--steps` | Smooth gesture-style drags |
| [drag](docs/commands/drag.md) | `--from/--to`, modifiers, Dock/Trash targets | Drag-and-drop between elements/coords |
| [move](docs/commands/move.md) | `--to <id/coords>`, `--screen-index` | Position the cursor without clicking |
| [window](docs/commands/window.md) | `list`, `move`, `resize`, `focus`, `set-bounds` | Move/resize/focus windows and Spaces |
| [app](docs/commands/app.md) | `launch`, `quit`, `relaunch`, `switch`, `list` | Launch, quit, relaunch, switch apps |
| [space](docs/commands/space.md) | `list`, `switch`, `move-window` | List or switch macOS Spaces |
| [menu](docs/commands/menu.md) | `list`, `list-all`, `click`, `click-extra` | List/click app menus and extras |
| [menubar](docs/commands/menubar.md) | `list`, `click` | Target status-bar items by name/index |
| [dock](docs/commands/dock.md) | `launch`, `right-click`, `hide`, `show`, `list` | Interact with Dock items |
| [dialog](docs/commands/dialog.md) | `list`, `click`, `input`, `file`, `dismiss` | Drive system dialogs (open/save/etc.) |
| [image](docs/commands/image.md) | `--mode screen/window/menu`, `--retina`, `--analyze` | Screenshot screen/window/menu bar (+analyze) |
| [list](docs/commands/list.md) | `apps`, `windows`, `screens`, `menubar`, `permissions` | Enumerate apps, windows, screens, permissions |
| [tools](docs/commands/tools.md) | `--verbose`, `--json`, `--no-sort` | Inspect native Peekaboo tools |
| [completions](docs/commands/completions.md) | `[shell]` | Generate zsh/bash/fish completion scripts from Commander metadata |
| [config](docs/commands/config.md) | `init`, `show`, `add`, `login`, `models` | Manage credentials/providers/settings |
| [permissions](docs/commands/permissions.md) | `status`, `grant`, `request-screen-recording`, `request-event-synthesizing` | Check/grant required macOS permissions |
| [run](docs/commands/run.md) | `.peekaboo.json`, `--output`, `--no-fail-fast` | Execute `.peekaboo.json` automation scripts |
| [sleep](docs/commands/sleep.md) | `--duration` (ms) | Millisecond delays between steps |
| [clean](docs/commands/clean.md) | `--all-snapshots`, `--older-than`, `--snapshot` | Prune snapshots and caches |
| [agent](docs/commands/agent.md) | `--model`, `--dry-run`, `--resume`, `--max-steps`, audio | Natural-language multi-step automation |
| [mcp](docs/commands/mcp.md) | `serve` (default) | Run Peekaboo as an MCP server |

## Models and providers

Peekaboo's provider list changes with Tachikoma and the tested model catalog. See
[docs/providers.md](docs/providers.md) for the current provider reference, including OpenAI, Anthropic, xAI/Grok,
Google Gemini, MiniMax, Ollama, LM Studio, and compatible custom endpoints.

Set providers via `PEEKABOO_AI_PROVIDERS` or `peekaboo config add`.
Agent generation settings live under `agent.temperature` and `agent.maxTokens` in `~/.peekaboo/config.json`; the
macOS Settings UI reads and writes the same values.

## Learn more
- Project direction: [VISION.md](VISION.md)
- Command reference: [docs/commands/](docs/commands/)
- Platform support: [docs/platform-support.md](docs/platform-support.md)
- Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Building from source: [docs/building.md](docs/building.md)
- Testing guide: [docs/testing/tools.md](docs/testing/tools.md)
- MCP setup: [docs/commands/mcp.md](docs/commands/mcp.md)
- Permissions: [docs/permissions.md](docs/permissions.md)
- Ollama/local models: [docs/ollama.md](docs/ollama.md)
- Agent chat loop: [docs/agent-chat.md](docs/agent-chat.md)
- Service API reference: [docs/service-api-reference.md](docs/service-api-reference.md)

## Community

- [PeekabooWin](https://github.com/FelixKruger/PeekabooWin) — Windows-first rewrite of the Peekaboo automation loop (JavaScript + PowerShell) by [@FelixKruger](https://github.com/FelixKruger)
- [PeekabooX](https://github.com/nordbyte/PeekabooX) — Linux-first rewrite of the Peekaboo automation loop (Rust + Python) by [@nordbyte](https://github.com/nordbyte)

## Development basics
- Requirements: see [docs/platform-support.md](docs/platform-support.md). Node 22+ is only needed for the npm MCP wrapper and pnpm helper scripts.
- Install deps: `pnpm install` then `pnpm run build:cli` or `pnpm run test:safe`.
- Lint/format: `pnpm run lint && pnpm run format`.

## License
MIT
