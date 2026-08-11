---
title: Install Peekaboo
summary: 'Install Peekaboo through Homebrew, npm/MCP, the Mac app, or a source checkout.'
description: Install the Peekaboo CLI, MCP server, or Mac app. Homebrew, npm, and source paths.
read_when:
  - 'setting up Peekaboo for the first time'
  - 'choosing between Homebrew, npm, Mac app, and source builds'
---

# Install

Peekaboo ships in three flavors. They all use the same Swift core and the same toolset — pick whichever surface fits your workflow.

## Homebrew (recommended)

The CLI is signed, notarized, and lives in [steipete/homebrew-tap](https://github.com/steipete/homebrew-tap).

```bash
brew install steipete/tap/peekaboo
peekaboo --version
```

Update with `brew upgrade steipete/tap/peekaboo`.

## npm (for MCP clients)

The npm package wraps the same CLI plus an MCP shim, so you can launch the server with `npx`:

```bash
npx -y @steipete/peekaboo mcp
```

This is the form you point Codex, Claude Code, and Cursor at. See [MCP.md](MCP.md).

## Mac app

The full menu-bar app (visualizer, permission flows, status item) ships as a drag-to-Applications DMG on the [Releases](https://github.com/openclaw/Peekaboo/releases/latest) page. The app and CLI are separate installs; use Homebrew or npm above when you also need the `peekaboo` command on your `PATH`.

## Build from source

Requires macOS 15.0+ and a Swift 6.2+ toolchain. See [platform-support.md](platform-support.md)
for the support matrix across the CLI, app, Swift packages, and pnpm helper scripts.

```bash
git clone --recurse-submodules https://github.com/openclaw/Peekaboo.git
cd Peekaboo
pnpm install
pnpm run build:cli         # debug build
pnpm run build:swift:all   # universal release
```

The output binary lives under `Apps/CLI/.build/...`. See [building.md](building.md) for signing and notarization.
Raw SwiftPM/debug builds use stable `unknown` placeholders for Git and build-time metadata. Use the repository's
stamped debug or release build scripts when `peekaboo --version` must include immutable commit and build-date provenance.

## Verify

```bash
peekaboo --version
peekaboo permissions status
peekaboo app list
```

If any of those error out, jump to [permissions.md](permissions.md).
