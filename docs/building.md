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
- Python 3.9+ for the checkout-local Swift workspace setup (Xcode provides `python3`).
- Node.js 22+ (Corepack-enabled) — only needed for pnpm helper scripts; core Swift builds do not require Node.
- pnpm (`corepack enable pnpm`)
- SwiftLint and SwiftFormat for the repository validation helpers (`brew install swiftlint swiftformat`)

See [platform-support.md](platform-support.md) for the support matrix across released binaries, apps,
Swift packages, source builds, and pnpm helper scripts.

## Common Builds

```bash
# Clone
git clone --recurse-submodules https://github.com/openclaw/Peekaboo.git
cd Peekaboo

# Install JS deps
pnpm install

# Swift CLI only (debug)
pnpm run build:cli

# Signed release binary (Apple Silicon)
pnpm run build:swift

# Signed release binary (universal)
pnpm run build:swift:all

# Standalone helper
./scripts/build-cli-standalone.sh [--install]
```

The universal CLI build uses `--triple x86_64-apple-macosx15.0` for Intel compilation and binary-directory lookup,
matching the CLI package's existing `.macOS(.v15)` minimum. It also sets Swift Build's aggregate deployment minimum,
preventing the SDK's macOS 27 default from producing an Intel architecture deprecation warning. ARM compilation still
uses `--arch arm64`; supported
architectures and the minimum macOS version are unchanged.

## Commander dependency resolution

Run this once in each initialized source checkout before using Swift or opening Xcode directly, and again after moving
the checkout. It does not need Node, network access, or a Swift invocation:

```bash
python3 scripts/setup-swift-workspace.py setup
# Equivalent pnpm entrypoint:
pnpm run setup:swift

# Direct commands retain their normal arguments after setup:
swift build --package-path Apps/CLI
swift package --package-path Core/PeekabooCore --scratch-path /tmp/peekaboo-core-graph show-dependencies
open Apps/Peekaboo.xcworkspace
```

The pnpm build/test commands, standalone build helpers, release compilation, and source CI entrypoints perform setup
themselves. Installing the published npm binary does not run source setup. The helper verifies the initialized Commander
and AXorcist submodule identities and HEADs against this checkout's gitlinks. Uncommitted local Commander edits remain
visible to development builds; source-stamped release builds still require the existing clean-source gate.

AXorcist always declares remote Commander at exact `0.2.4`. Peekaboo's internal package graph already selects the live
Commander submodule through explicit filesystem dependencies. The helper aligns the remote URL with that same canonical
absolute directory using a `file://` URL; it neither changes a dependency requirement nor substitutes SwiftPM's version
checkout. A bare absolute mirror path is classified as local source control by SwiftPM, whose validation rejects the
normal submodule `.git` file even when Git confirms the repository is initialized. The file URL retains the canonical
location of the explicit live package without that local-source-control validation. Relative mirror paths are not supported.
No global/home settings or sibling directory discovery are involved.

Use a stable, non-aliased checkout path for direct Xcode builds. Xcode 27 can treat `/var` and `/private/var` as different
package locations when reading workspace-local mappings; the build wrapper's explicit mapping avoids that diagnostic.
Paths containing `#` remain unsupported by this mapping on SwiftPM 6.4 because its file-URL canonicalization can fail.
Normal paths and paths containing spaces are covered by the real-submodule compilation fixture.

The generated `mirrors.json` files belong to the consuming contexts: `Apps/CLI`, `Apps/Mac`, `Apps/Playground`,
`Apps/PeekabooInspector`, `Core/PeekabooCore`, `Core/PeekabooExternalDependencies`, and `Core/PeekabooUICore` use
`.swiftpm/configuration/`; the shared Xcode workspace and the three projects' embedded `project.xcworkspace` contexts use
`xcshareddata/swiftpm/configuration/`. `.swiftpm/peekaboo-workspace/` holds the ownership receipt and the build wrapper's
mapping. All are ignored source-checkout state and must never be copied into release artifacts or checked in.

Xcode uses the same explicit filesystem dependencies and file-URL mapping without a separate Commander workspace or
navigator package-root reference. Promoting Commander to a root package also resolves its unused documentation-plugin
dependency, which is outside the consuming graph's canonical lock. Keep Commander as a dependency rather than adding
it as another workspace root; the compile-only real-submodule fixture verifies that its uncommitted source stays live.

The public root `Package.swift` retains AXorcist exact `0.1.9`. Standalone AutomationKit, Foundation, Protocols, Visualizer,
and submodule builds are not given a Commander override: those graphs do not select Peekaboo's live Commander package.
Adding another consuming package requires adding its explicit context to the helper and qualifying it. A transitive
`.package(path:)` declaration is not an Xcode workspace-root override.

`python3 scripts/setup-swift-workspace.py check` verifies generated state without regenerating it. The helper rejects
inherited `SWIFTPM_MIRROR_CONFIG`, Git repository-location overrides, symlinks, unmanaged mirror files, and altered owned
files without printing their contents. Preserve and explicitly move conflicting files aside for review before setup;
there is no force/adopt mode. Other settings, including registry configuration, remain untouched. `remove` deletes only
verified owned files; it leaves unrelated settings and directories in place. A relocated checkout must run `setup`
before another direct Swift/Xcode command. If an interrupted operation leaves `.swiftpm/peekaboo-workspace.lock`, verify
that no setup/build wrapper is running before removing that empty lock directory. Interrupted partial generation without
an ownership receipt requires explicit inspection and removal of the generated files before retrying.

Release entrypoints use `run --release -- COMMAND` around compilation. That wrapper supplies its verified mapping via
`SWIFTPM_MIRROR_CONFIG`, holds the setup lock, and checks mapping integrity and the existing source commit/cleanliness
gate before and after the command. Strict resolution flags and canonical lock owners are unchanged. Run
`pnpm run test:swift-workspace` for the offline ownership and fake-tool contracts; real package graphs and Xcode builds
remain separate qualification gates.

The opt-in `PEEKABOO_TEST_REAL_SWIFT_WORKSPACE=1 python3 scripts/test-swift-workspace.py RealSubmoduleContract`
compiles inert SwiftPM and Xcode fixtures created with real absorbed Git submodules. It checks strict resolution and
compilation against an uncommitted Commander symbol without running a test bundle or built product. It does not qualify
Peekaboo's production graph or replace its compile, test, and release gates.

## Shared CodeQL build graph

The workspace's `CodeQL` scheme builds the CLI, certification controller, Mac app, Playground, and Inspector
in one graph so shared dependencies are analyzed without separate builds. Its CLI scheme references select
the public SwiftPM products `peekaboo` and `peekaboo-certification-controller`.

The CLI package's internal project name is `PeekabooCLIPackage`, and the `peekaboo` product uses the
`PeekabooExec` entry target in `Sources/PeekabooExec`. Keep both internal names distinct from the Mac app's
`Peekaboo` identity under case folding. Xcode 26 derives executable intermediate directories from the package
and product names: renaming only the Swift entry target does not separate `peekaboo.build/Debug/peekaboo.build`
from the app's `Peekaboo.build/Debug/Peekaboo.build` on a case-insensitive volume. Colliding file lists can compile
the app's sources and generated assets as the CLI. The package name separates those directories; the entry
target name also separates the Swift module where the build system uses it. Public binaries, `PeekabooCLI`
imports, source paths, and embedded Info.plist/source stamps remain unchanged.

Run `pnpm run test:codeql-build-graph` to check product coverage, internal ownership, and the CLI's exact
`PeekabooMain.swift` entrypoint. These structural checks do not replace a successful hosted CodeQL build.

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
