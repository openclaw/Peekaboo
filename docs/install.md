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
Raw SwiftPM and manual unstamped Xcode builds use stable `unknown` placeholders for source and build-time metadata.
Use the repository's debug or release build scripts from a clean checkout when `peekaboo --version --json` must
include immutable provenance. Dirty or unverifiable debug builds remain available but report `sourceCommit: unknown`;
release builds and debug builds with `PEEKABOO_REQUIRE_SOURCE_PROVENANCE=1` refuse that source state.
`peekaboo --version --json` exposes the canonical 40-hex `sourceCommit`; background certification requires it and
pins one exact Bridge socket for remote execution, requiring that host to advertise the same source commit.
Raw builds remain available for ordinary CLI development, but `capture action` is deliberately stricter because its
manifest claims end-to-end artifact and execution-host provenance around an arbitrary child command. That subcommand
requires either an Apple-anchored, source-stamped local executable or an authenticated selected Bridge host; an
unstamped local build refuses before focus or child dispatch instead of publishing a non-certified manifest.

## Verify

```bash
peekaboo --version
peekaboo permissions status
peekaboo app list
```

If any of those error out, jump to [permissions.md](permissions.md).
