---
summary: 'How to build Peekaboo from source and run release scripts.'
read_when:
  - 'compiling the CLI locally'
  - 'prepping release artifacts'
---

# Building Peekaboo

## Prerequisites

- macOS 15.0+
- Swift 6.2+ toolchain (Xcode 26.x or newer recommended)
- Node.js 22+ (Corepack-enabled) — only needed for pnpm helper scripts; core Swift builds do not require Node.
- pnpm (`corepack enable pnpm`)
- SwiftLint and SwiftFormat for the repository validation helpers (`brew install swiftlint swiftformat`)

See [platform-support.md](platform-support.md) for the support matrix across released binaries, apps,
Swift packages, source builds, and pnpm helper scripts.

## Common Builds

```bash
# Clone
git clone https://github.com/openclaw/Peekaboo.git
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

## Debug build-staleness checks

Debug CLI builds leave staleness checks disabled unless Git config contains
`check-build-staleness = true` in a `[peekaboo]` section or `PEEKABOO_CHECK_BUILD_STALENESS` enables them.
Set `PEEKABOO_CHECK_BUILD_STALENESS=0` to skip both config discovery and staleness checks;
`1`, `true`, and `yes` enable them (case-insensitive, with surrounding whitespace ignored).
Any other nonempty override disables them; an unset or blank override falls back to config.
Config settings are read in system, XDG, home, then nearest repository order, with later settings taking precedence.

Repository discovery visits each ancestor once, stopping after the filesystem root even when Git metadata is
missing or inaccessible. It accepts `.git` directories and `.git` files with absolute or relative `gitdir:` paths.
It reads `config` directly in the referenced Git directory; it does not follow a linked worktree's `commondir`.
Release builds do not run this startup check.

## Releases

For full release automation (tarballs, npm package, checksums), follow [RELEASING.md](RELEASING.md). Quick recap:

```bash
# Validate + prep
pnpm run prepare-release

# Deterministic metadata/docs/CLI contract only (no registry or artifact checks)
pnpm run prepare-release -- --dry-run --bin Apps/CLI/.build/debug/peekaboo

# Generate artifacts / publish
./scripts/release-binaries.sh --create-github-release --publish-npm \
  --proof-file /path/to/reviewed-release-proof.md
```
