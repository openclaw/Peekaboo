---
summary: 'How to build Peekaboo from source, run release scripts, and use the Poltergeist watcher.'
read_when:
  - 'compiling the CLI locally'
  - 'prepping release artifacts or tweaking Poltergeist workflows'
---

# Building Peekaboo

## Prerequisites

- macOS 15.0+
- Xcode 16.4+ (includes Swift 6)
- Node.js 22+ (Corepack-enabled) — only needed for pnpm helper scripts; core Swift builds do not require Node.
- pnpm (`corepack enable pnpm`)

See [platform-support.md](platform-support.md) for the support matrix across released binaries, apps,
Swift packages, source builds, and pnpm helper scripts.

## Common Builds

```bash
# Clone
git clone https://github.com/steipete/peekaboo.git
cd peekaboo

# Install JS deps
pnpm install

# Build everything (CLI + Swift support scripts)
pnpm run build:all

# Swift CLI only (debug)
pnpm run build:swift

# Release binary (universal)
pnpm run build:swift:all

# Standalone helper
./scripts/build-cli-standalone.sh [--install]
```

## Releases

For full release automation (tarballs, npm package, checksums), follow [RELEASING.md](RELEASING.md). Quick recap:

```bash
# Validate + prep
pnpm run prepare-release

# Generate artifacts / publish
./scripts/release-binaries.sh --create-github-release --publish-npm
```

## Poltergeist Watcher

Peekaboo’s repo already includes [poltergeist.md](poltergeist.md) with tuning tips. Typical workflow:

```bash
pnpm run poltergeist:haunt   # start watcher
pnpm run poltergeist:status  # health
pnpm run poltergeist:rest    # stop
```

Poltergeist rebuilds the CLI whenever Swift files change so `polter peekaboo …` always runs a fresh binary.
