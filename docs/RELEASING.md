---
summary: 'Release Peekaboo CLI, npm package, signed macOS app/DMG, and Sparkle appcast.'
read_when:
  - 'preparing, publishing, or verifying a Peekaboo release'
---

# Peekaboo release checklist

Run from the repository root. Releases publish `@steipete/peekaboo`, universal CLI archives, checksums, and an
OpenClaw Foundation Developer ID signed/notarized `Peekaboo.app`, standalone and npm CLIs, branded drag-to-Applications DMG, and Sparkle appcast entry.

Every shipped macOS code object uses `Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)`. Peekaboo 3.8 and later bridge hosts continue accepting both the Foundation team and transition-era personal-team clients so staged upgrades remain possible; Foundation-signed 3.9.6+ CLIs do not authenticate to pre-3.8 GUI bridge hosts. The release driver signs through the shared managed passwordless Foundation keychain, notarizes the standalone CLI as well as the app and DMG, and verifies exact authority, Team ID, Developer ID requirement, and online notarization for extracted archive payloads.

### Signing environment

Run the release from a shell inside the logged-in GUI session. A `tmux` server bootstrapped outside that session
cannot reach codesign private keys, and every signing step fails with `errSecInternalComponent` even though
`security find-identity` lists the identity. Confirm with a scratch `codesign --sign "$MAC_RELEASE_CODESIGN_IDENTITY"`
before blaming the keychain.

The Foundation release keychain is passwordless and must never auto-lock. If it has locked, repair it with
`security unlock-keychain -p "" <keychain>` and `security set-keychain-settings <keychain>`; a locked keychain
produces the same `errSecInternalComponent`. Do not export a bare `SIGN_IDENTITY` in a shell used for releases —
it is a fallback for the build scripts and will substitute for the Foundation identity wherever
`MAC_RELEASE_CODESIGN_IDENTITY` is not explicitly set.

Every Developer ID signing surface passes Apple's timestamp authority explicitly as
`http://timestamp.apple.com/ts01`. The current toolchain can fail with “A timestamp was expected but was not found”
when it is left to choose its own endpoint, even while the canonical TSA is reachable.

Notarization resolves the three App Store Connect API fields from the canonical Molty release item, validates them
with `notarytool history`, and submits with S3 acceleration disabled. The tracked manifest clears both supported
keychain-profile variables so a stale value inherited from the caller cannot override the current release item.
Sparkle signing receives `MAC_RELEASE_SPARKLE_OP_REF` from the private release environment and resolves it through
the shared release helper's prompt-free service-account path. The helper writes a mode-0600 temporary key, verifies
its public key against the tracked `SUPublicEDKey`, and removes it on success or failure; releases do not use
login-keychain or Dropbox fallbacks, and the private locator is never tracked in this repository.

## 1. Prepare

- Confirm `main` is clean, current, and all submodules are at the intended commits.
- Run `python3 scripts/setup-swift-workspace.py setup --release` in the publication checkout after submodule initialization; repeat after relocation. See [workspace ownership and recovery](building.md#commander-dependency-resolution). Build helpers generate and verify the same ignored, source-only Commander mapping around compilation; do not copy another checkout's absolute-path configuration into staging or sealed artifacts. Existing canonical locks, clean-source checks, materialized source snapshots, and strict-resolution flags remain authoritative.
- Update `package.json`, both `version.json` files, `Apps/CLI/Sources/Resources/Info.plist`,
  `Apps/CLI/TestHost/Info.plist`, `PeekabooMCPVersion.current`, the README release-status copy, and
  `MARKETING_VERSION` in the Mac, Inspector, and Playground Xcode projects.
- Candidate version and changelog sections may remain `Unreleased` only while running the deterministic preparation
  dry run. Date both changelogs before the publication commit and full release preflight.
- Update user-facing docs and `release/release-notes.md`. Release notes contain only that version's changelog section.
- The tracked release notes are publication authority: full preflight requires them to match the root changelog section,
  and the GitHub draft body is created from those exact bytes.
- Update submodule repositories first only when their code or release metadata changed, then commit the gitlink here.
- Use Xcode 27 for the 4.3.0 publication build and record its exact build, Swift compiler, and SDK versions. The selected
  beta build must pass the same complete release gates; hosted Xcode 26.x tests provide additional compatibility coverage,
  not proof of the Xcode 27 publication build. Do not change the machine's global toolchain selection during release.

### Release helper pin and relocated publication checkout

The build-number helper accepts numeric `major.minor.patch` versions, optionally followed by case-insensitive `alpha`/`a`, `beta`/`b`, or `rc` prereleases. Unnumbered prereleases mean 1; `.2`, `-2`, and compact `2` suffixes remain supported. Prerelease numbers must be 1–29, minor/patch components 0–99, and numeric components cannot have leading zeroes. Extra identifiers, build metadata, empty suffixes, and overflowing values fail without a build-number result. The conservative major limit is 9223372036853, leaving room for every supported minor, patch, and suffix; it is not the largest individually representable version. Stable build-number mappings are unchanged.

Credentialed release steps run through the shared `agent-scripts` `release-mac-app` helper, pinned by commit plus
executable and library SHA-256 (`EXPECTED_RELEASE_HELPER_*` in `scripts/build-terminal-artifacts.sh`). The helper is
found only at `../agent-scripts` beside the publication checkout, then at `~/Projects/agent-scripts`; it must be a
clean Git checkout at exactly the pinned commit, and the terminal pipeline refuses `MAC_RELEASE_TOOL` overrides. The
release plan freezes the pin, and `--resume-publication` refuses any change to it. Check it before starting:

```bash
scripts/build-terminal-artifacts.sh check-helper
```

The shared `~/Projects/agent-scripts` checkout normally moves ahead of the pin (61 commits ahead during 4.7.0), and
every release entry point then stops with `mac-release helper commit mismatch: <sha>`. Do not reset the shared checkout
or bump the pin mid-release. Publish from a relocated checkout instead: a fresh clone of Peekaboo `main` in a staging
directory, with a detached `agent-scripts` worktree at the pinned commit beside it so the `../agent-scripts` lookup wins.

```bash
STAGE="$HOME/Projects/.release-staging-peekaboo-<version>"
mkdir -p "$STAGE"
git clone --recurse-submodules https://github.com/openclaw/Peekaboo.git "$STAGE/Peekaboo"
PIN="$(sed -n 's/^EXPECTED_RELEASE_HELPER_COMMIT=//p' "$STAGE/Peekaboo/scripts/build-terminal-artifacts.sh")"
git -C "$HOME/Projects/agent-scripts" worktree add --detach "$STAGE/agent-scripts" "$PIN"
cd "$STAGE/Peekaboo"
python3 scripts/setup-swift-workspace.py setup --release
pnpm install --frozen-lockfile
scripts/build-terminal-artifacts.sh check-helper
```

Configure the maintainer Git identity in that clone, and after pushing the dated publication commit, pull it there with
`--ff-only`. Everything from preflight through closeout then runs in `$STAGE/Peekaboo`: the retained `build/release`
directory and generated `appcast.xml` live there, `--resume-publication` must run from the same clone, and the appcast
commit is pushed from it. Remove the clone and `git -C ~/Projects/agent-scripts worktree remove "$STAGE/agent-scripts"`
only after closeout.

When other work keeps landing on `main` during the release, publish from a `release/<version>` branch instead: create it
from the current `origin/main`, push it, check it out in the staging clone, and pass `--release-branch` to
`scripts/release-binaries.sh`. The driver refuses unless exactly that branch is checked out. The branch is frozen at
its cut: the preflight requires HEAD to match the pushed `origin/release/<version>` and only reports commits that
landed on `main` afterwards, so a relaunch (including `--reuse-built-cli`) does not need a new cut. Land the branch
with a merge commit afterwards so the `v<version>` tag stays in `main`'s history.

Bumping the pin is a separate reviewed change, never a release-time fix. Review every `skills/release-mac-app` change
between the pin and the candidate (`git -C ~/Projects/agent-scripts log -p <pin>..<candidate> -- skills/release-mac-app`)
for credential, signing, notarization, Sparkle, and PATH behavior. Then update the commit and both hashes together
wherever they are asserted: the `EXPECTED_RELEASE_HELPER_*` constants and embedded manifest literals in
`scripts/build-terminal-artifacts.sh`, `scripts/validate-terminal-artifact-manifest.mjs`,
`scripts/test-terminal-artifact-env.sh`, and `scripts/test-terminal-manifest-portability.sh`. As of 2026-09-30 the
helper executable is unchanged since `20ab9a5e`, but `lib/mac_release.sh` has changed, so a bump changes the library
hash and needs that library's diff reviewed.

## 2. Validate the preparation patch

On a busy Mac, run the commands below and the release driver under `nice -n 19`.
Set `PEEKABOO_BUILD_JOBS=2` to cap the preflight, safe tests, consumer check, and app build;
append `--jobs 2` to `SWIFT_OPTIMIZATION_FLAGS` for the architecture-specific CLI builds
(default optimization flags: `-Xswiftc -Osize -Xlinker -dead_strip`). The preflight compiler
check allows 90 minutes so low-priority builds can complete without skipping a gate.

```bash
pnpm run format
pnpm run lint
pnpm run lint:docs
pnpm run docs:site
pnpm run test:safe
```

While the version/changelog decision is still in progress, run the deterministic subset without registry, git-fetch,
or artifact work:

```bash
pnpm run build:cli
BIN_PATH="$(swift build --package-path Apps/CLI --show-bin-path)"
pnpm run prepare-release -- --dry-run --bin "$BIN_PATH/peekaboo"
```

The dry run validates metadata consistency, docs/links, generated v4 help, retired-command rejection, and the
`app list`/`window list`/`screen list` JSON contracts. It is intentionally not release-readiness proof. Dry-run
accepts the candidate's `Unreleased` changelog headings; full preflight requires exact `YYYY-MM-DD` headings and a
clean, current publication commit on `main`.

Run `pnpm run test:automation` and live provider tests when the release changes those surfaces, using an isolated
fixture desktop and explicitly scoped provider credentials rather than the operator's saved app state. Before committing,
run the repository autoreview workflow until no accepted actionable findings remain.

For the complete safe gate on a fresh hosted runner plus non-live package coverage beyond the normal macOS CI filters,
run the supplemental hosted workflow against the exact publication commit:

```bash
gh workflow run release-validation.yml --ref main -f target_ref=<full-40-character-publication-SHA>
```

Manual dispatch checks out only the selected workflow ref's resolved `github.sha`; `target_ref` is an expected-source
assertion and must match that SHA exactly after hex normalization. If `main` moves before the dispatch resolves it,
the mismatch fails before checkout or tests. To validate another reviewed revision, select its trusted branch or tag
with `--ref` and supply the matching full SHA. An arbitrary historical or fork SHA cannot be tested under the `main`
workflow context. PR runs independently check out only the event's PR head; a manual input cannot override it.

This read-only, secretless macOS lane runs unfiltered suites for PeekabooCore, AutomationKit, Protocols, Visualizer,
UICore, Inspector, Playground, and all five pinned submodules. It keeps per-package logs, exit status, built-in skips,
submodule revisions, and actual toolchain metadata. A separate `full-safe` matrix job uses the pinned CI Node version, the exact repository
pnpm pin, and a frozen dependency install. Before that install, it installs ripgrep for the shell contracts and `uv`
for the real fixture DMG integration, retaining their actual versions in `full-safe/ripgrep-version.txt` and
`full-safe/uv-version.txt`. It then invokes the unchanged `pnpm run test:safe` command once. It covers the
artifact/script contracts, synthetic background-certification checks, public SwiftPM consumer build, Foundation suite,
and full safe CLI configuration with the repository's existing compile exclusions and ambient-state opt-out. It retains
the command definition, combined stage/test output, command and log-writer exits, failures/skips index, and actual
source/toolchain. The command's existing fail-fast chain stops at its first failed stage; later stages are not covered,
and missing exit evidence or an interrupted run is never a pass. Each matrix job has its own checkout and package state.

Its workflow-specific PR trigger validates changes to the lane;
publication requires a separate exact-source dispatch. The normal macOS CI still owns the complete Mac app suite and
its genuinely hosted-only credential tests. Never spoof hosted-runner identity on a personal Mac. Hosted Xcode 26.x
compatibility coverage does not replace the Xcode 27 release preflight or signed isolated desktop and provider integration
proof. Built-in automation/provider skips and synthetic certification checks are not live proof; report exclusions and
unavailable live environments explicitly. Do not rerun the full safe gate against the operator's saved state: a temporary
HOME is not a secretless OS account.

### Terminal-only artifact set

For exact-head machine qualification or fleet deployment without a public release, use the terminal artifact wrapper.
It produces a universal CLI archive, signed/notarized Peekaboo app zip and DMG, a signed/notarized Playground fixture,
and the pinned signed/notarized `PeekabooQualificationNode.app` used to run every qualification JavaScript program. It
never tags, uploads, publishes npm, signs Sparkle metadata, or edits `appcast.xml`.

The default `all` mode compiles with notary, Sparkle, npm, signing-keychain-password, and 1Password service variables
removed. It then creates a private verified snapshot, uses a codesign-only keychain lane, submits each code object through
the single notary-only helper, constructs the DMG without credentials, and atomically publishes only fully verified
artifacts and receipts:

```bash
SOURCE_COMMIT="$(git rev-parse HEAD)"
scripts/build-terminal-artifacts.sh all \
  --stage "/tmp/peekaboo-terminal-build-$SOURCE_COMMIT" \
  --output "/tmp/peekaboo-terminal-artifacts-$SOURCE_COMMIT"
```

For failure recovery, rerun the individual phase that has no completed output. The tracked terminal manifest must be
selected for every credentialed command; the ordinary release manifest also imports npm and Sparkle credentials and is
not valid here. The phase order is:

```bash
scripts/build-terminal-artifacts.sh check-helper
scripts/build-terminal-artifacts.sh build --stage /absolute/new/stage
/usr/bin/env -u GH_TOKEN -u GITHUB_TOKEN -u NODE_AUTH_TOKEN -u NPM_CONFIG_USERCONFIG -u NPM_TOKEN \
  -u MAC_RELEASE_TOOL \
  MAC_RELEASE_MANIFEST="$PWD/.mac-release-terminal.env" \
  "$PWD/scripts/mac-release" codesign-run -- \
  /usr/bin/env -u OP_SERVICE_ACCOUNT_TOKEN -u MOLTY_OP_SERVICE_ACCOUNT_TOKEN \
  -u PEEKABOO_OP_SERVICE_TOKEN_FILE -u PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE \
  -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH -u GLOBIGNORE \
  PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin \
  /bin/bash --noprofile --norc -p -c 'exec "$@"' peekaboo-codesign-phase \
  "$PWD/scripts/build-terminal-artifacts.sh" sign-code --stage /absolute/new/stage
/usr/bin/env -u GH_TOKEN -u GITHUB_TOKEN -u NODE_AUTH_TOKEN -u NPM_CONFIG_USERCONFIG -u NPM_TOKEN \
  -u MAC_RELEASE_TOOL \
  MAC_RELEASE_MANIFEST="$PWD/.mac-release-terminal.env" \
  "$PWD/scripts/mac-release" package-run -- \
  /usr/bin/env -u OP_SERVICE_ACCOUNT_TOKEN -u MOLTY_OP_SERVICE_ACCOUNT_TOKEN \
  -u PEEKABOO_OP_SERVICE_TOKEN_FILE -u PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE \
  -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH -u GLOBIGNORE \
  -u MAC_RELEASE_CODESIGN_KEYCHAIN -u MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD -u CODESIGN_KEYCHAIN \
  PATH=/usr/bin:/bin /bin/bash --noprofile --norc -p -c 'exec "$@"' peekaboo-notary-phase \
  "$PWD/scripts/notarize-terminal-artifact.sh" --kind cli-tree \
  --artifact /absolute/new/stage/signed/cli \
  --transaction /absolute/new/stage/notary/cli
# Repeat only that protected helper shape for Peekaboo.app, Playground.app, and
# PeekabooQualificationNode.app; app transactions contain the stapled copy,
# receipt.json, and the exact post-staple tree.json.
scripts/build-terminal-artifacts.sh build-dmg --stage /absolute/new/stage
/usr/bin/env -u GH_TOKEN -u GITHUB_TOKEN -u NODE_AUTH_TOKEN -u NPM_CONFIG_USERCONFIG -u NPM_TOKEN \
  -u MAC_RELEASE_TOOL \
  MAC_RELEASE_MANIFEST="$PWD/.mac-release-terminal.env" \
  "$PWD/scripts/mac-release" codesign-run -- \
  /usr/bin/env -u OP_SERVICE_ACCOUNT_TOKEN -u MOLTY_OP_SERVICE_ACCOUNT_TOKEN \
  -u PEEKABOO_OP_SERVICE_TOKEN_FILE -u PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE \
  -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH -u GLOBIGNORE \
  PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin \
  /bin/bash --noprofile --norc -p -c 'exec "$@"' peekaboo-codesign-phase \
  "$PWD/scripts/build-terminal-artifacts.sh" sign-dmg --stage /absolute/new/stage
# Notarize the signed DMG through the same protected notary-only helper.
scripts/build-terminal-artifacts.sh publish \
  --stage /absolute/new/stage --output /absolute/new/artifacts
```

The simplest and least error-prone command remains `all`; it owns those exact transitions. `package-run` resolves only
the notarization fields and never prepares or unlocks the Developer ID keychain. Non-notary phases reject raw ASC,
Sparkle, npm, GitHub, and service-account variables. Notary receipts bind submission bytes, Foundation code
identity for every universal architecture, and the post-staple output, and appear only after staple/online verification
succeeds. Exact submitted bytes are retained under `notary/submissions/`; the DMG additionally carries a mounted payload
receipt that binds its exact notarized `Peekaboo.app`, Applications link, and allowed metadata before signing.
The orchestrator stores inherited 1Password service tokens in owner-private temporary files and exposes them only to the
pinned credential helper; build/sign/notary children never inherit them. The pinned Node runtime is re-signed with the
tracked JIT entitlement policy, verifies both architecture entitlements, and must execute generated JavaScript after
notarization before publication.

`Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved` is the sole dependency graph for these builds.
Remove generated `Apps/Playground/Package.resolved` and standalone Playground Xcode-workspace locks before building;
the helper refuses them so a local resolver cannot silently replace the graph recorded in fixture provenance.
The build and final manifests also record and revalidate the canonicalized `DEVELOPER_DIR`, complete
`xcodebuild -version`, macOS SDK version, and `swiftc --version`. The 4.3.0 publication toolchain is Xcode 27; retain its
exact beta/build identity in proof rather than conflating it with hosted Xcode 26.x compatibility results. A toolchain
receipt does not replace successful universal builds, tests, runtime-library validation, signing, or notarization.
Controller source receipts require regular source files and a regular catalog. Worktree mode rejects symbolic links in either the file or its ancestors, as well as directories and special files. Frozen-commit mode reads regular Git blobs (including executable files), never a symlink's target-text blob; later worktree changes do not alter the frozen receipt. These checks do not claim an atomic snapshot of a concurrently changing worktree.
Runtime-library verification, including reused binaries, audits strong `libswift*` imports against the oldest
eligible installed macOS SDK older than 27 and prints the SDK used; see
[Swift runtime compatibility](building.md#swift-runtime-compatibility).
The published `terminal-artifacts.json` is portable schema 7 with `root:"."`; every path is relative to its own
directory. It retains its validator, canonical tree generator, commit-materialized controller/monitor/lock snapshot,
rich universal Foundation-signed controller and monitor records, and pinned Node runtime. Copying the sealed directory to another absolute
path must leave every byte and manifest hash unchanged and validate without a Peekaboo or OpenClaw checkout.

## 3. Date, commit, push, and run publication preflight

Use `## X.Y.Z - YYYY-MM-DD` in both changelogs; square brackets around the version are also accepted. Each target
version must have exactly one heading with a valid calendar date. Replace `Unreleased` with the actual release date,
then use standard Git commands with Conventional Commits. Push
`main`, pull with `--ff-only`, and confirm the publication commit is current and the tree is clean. Only then run the
full publication preflight:

```bash
pnpm run prepare-release
```

Do not build release artifacts until publication preflight succeeds; dirty trees produce invalid version metadata.

The release driver runs this preflight again, usually from an interactive terminal, so tests must not depend on the
controlling terminal or on pipe capacity. During 4.7.0 a test captured process-wide stdout into an in-memory pipe it
read only after the command returned, deadlocking once the output passed the 16 KB pipe buffer, and fixture scripts ran
bare `rm` on read-only files, which prompts whenever stdin is a terminal. Commit `test: keep release preflight tests
from blocking on output or prompts` fixed both; use the shared file-backed `captureStandardOutputBytes` helper and
`rm -f` for intended deletions. A preflight that stops producing output while a test process stays alive is almost
always one of these rather than a slow build, so inspect the process tree before waiting longer.

## 4. Publish

Load release credentials through the maintainer 1Password workflow and satisfy the
[caller environment](#caller-environment), then run interactively:

```bash
./scripts/release-binaries.sh \
  --create-github-release \
  --publish-npm \
  --proof-file /path/to/reviewed-release-proof.md
```

ZIP validation requires each DEFLATE stream to consume its entire declared compressed range before extraction.
Trailing bytes or a second compressed stream are refused even when the first payload's inflated size and CRC match.

App ZIP creation uses `scripts/create-app-zip.sh` for both the notary submission and the final Sparkle archive. It omits
resource forks, extended attributes, and quarantine metadata instead of emitting `__MACOSX`/AppleDouble entries, without
modifying the source app's file bytes, modes, symlinks, signatures, or stapled ticket. The terminal artifact packager uses
the same producer while retaining its stricter source-xattr guard and exact-tree roundtrip check. Final release ZIP
validation still requires the exact app root and verifies the extracted app's signatures and notarization ticket.
Before extraction, ZIP data-descriptor gaps are bounded to the format's 24-byte maximum before allocation or reading;
the existing descriptor checksum and size checks still apply.
Artifact-tree and archive validation resolve composed symlink components before accepting containment. Traversal is
limited to Darwin's 32 links including the original link; contained framework chains and dangling targets remain valid.
Archives continue to reject absolute targets, even though native tree receipts can represent contained absolute links.
Typed archive inventories also reject entries beneath a known regular file or symlink in either entry order.
Name-only entries retain path-only validation because they have no file-type evidence.
Tar size/checksum text and PAX record lengths/keys must contain only ASCII bytes before decoding; valid base-256 tar numbers and UTF-8 PAX values remain supported.

The script runs release preparation, builds the universal CLI and npm package, signs/notarizes/staples the macOS app
and branded DMG, generates checksums and Sparkle metadata, and uploads a draft GitHub release. The complete preparation
child uses `terminal-artifact-env.sh` to remove protected credential/startup variables and force
`PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`, excluding the managed codesign shim. Provision the required tools
on that path. Signing-keychain paths remain available for the preflight's signed CLI build; only its `pnpm test` child
removes those paths and `CODESIGN_IDENTITY`, using the same sanitizer even when preparation is invoked directly.
The parent retains its credentials and signing environment on success or failure. This is an environment boundary,
not OS-account isolation: run safe tests in a fresh VM before introducing task credentials. Workspace mapping and lock
ownership remain with the existing compilation helpers; do not wrap the whole preflight in the workspace runner.
Publication eligibility still requires the same complete successful gate. Install `uv`
with Homebrew before running it; the pinned `dmgbuild` environment writes Finder layout metadata directly. The npm
step requires `NPM_TOKEN` in the driver's own environment (see [caller environment](#caller-environment)). A 404
response to a registry PUT means npm authentication is missing or invalid, not that the package is missing. When the
script pauses at the npm confirmation, inspect the prepared artifacts, release plan, notes, and proof, then answer `y`
to authorize publication. This confirmation occurs before GitHub draft creation. The signing identity must be:

```text
Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)
```

If a fully signed and notarized CLI was already built from the current clean checkout, pass `--reuse-built-cli` to
avoid rebuilding it. Reuse fails closed unless the full Git porcelain status is clean, the candidate has the expected
Foundation signer, safe entitlements, native-only surface, complete runtime libraries and architectures, online
notarization, and an embedded source commit exactly equal to `HEAD`. All non-executing checks complete before the
candidate's first `--version` invocation.
Reuse is only a build optimization before any public action. GitHub draft creation and npm publication are one bound
driver operation; separate invocations are refused because rebuilt archives cannot safely resume an existing draft.
The npm confirmation happens before GitHub draft creation. If a failure still occurs after the first public action,
leave the generated appcast and release directory intact, then run `./scripts/release-binaries.sh --resume-publication`.
Resume accepts only the retained canonical plan, proof, checksums, exact artifact set, generated appcast, matching helper
pin, and frozen source commit. It verifies the existing draft/tag/assets, skips an already-published identical npm
tarball, repairs an interrupted expected-asset upload, and idempotently completes registry verification and the final
draft body. A full `appcast.xml` snapshot is checksummed with the receipt so resume cannot bless unrelated feed drift.
If npm accepted an upload but still returns E404, resume stops on its retained attempt marker; wait for propagation.
An absent-version probe requires an explicit npm `E404` error code. Authentication/server failures, contradictory codes, or `E404`/`404 Not Found` appearing only in a URL or diagnostic are unknown publication state and stop the driver; they do not authorize a new upload.
Use `--retry-npm-publish` only after independently confirming the version truly was not accepted.
Publication requires `NPM_TOKEN`; the driver writes an owner-only temporary npm config that pins both the default and
`@steipete` registries to npmjs, passes the registry explicitly to every probe/publish, and pins every GitHub mutation
and API check to `github.com/openclaw/Peekaboo` so ambient npm or `GH_REPO` settings cannot redirect a release.
The default release output remains under `build/`. A custom existing `RELEASE_DIR` is accepted only when it retains the
exact `.peekaboo-release-output` ownership marker created by the driver; symlinks, unmarked directories, and source-tree
paths are refused before recursive cleanup.
Reuse runs the full source preflight in no-build mode after that initial safety verification and rejects any candidate
or checkout change before packaging. Public npm or GitHub actions always require full checks, universal CLI and app
artifacts, notarization, and appcast generation; reduced-safety build flags are local-only.

The driver freezes one `release-plan.json` containing the clean source commit, version, and exact external release-helper
pin. The plan also records completed full preflight and explicit publication eligibility; proof files are refused on
local-only builds, so resume cannot promote artifacts produced with reduced checks. It revalidates that plan around
every CLI/app/DMG and publication boundary and uploads the plan with the release.
Immediately before each GitHub action it also freezes a local publication receipt for the exact canonical body and
artifact inventory, then verifies the local files, peeled remote tag commit, release body, and remote asset digests
against that receipt.
Before draft creation, the driver idempotently creates the official lightweight tag at the frozen source SHA through
the pinned GitHub API, peels and verifies it, then creates the draft with `--verify-tag`. A lost response or interrupted
draft creation therefore resumes against the same exact tag rather than the moving default branch.
The pending receipt is immutable and remains the artifact/checksum authority across resume. npm publication derives a
separate final-body receipt; it never replaces the pending receipt, and resume recomputes the original pending body and
inventory before allowing either missing-action recovery or expected-asset repair.

The app, every nested Mach-O payload, standalone CLI archive, npm CLI archive, and DMG must report the Foundation authority and Team ID `FWJYW4S8P8`. Online verification must pass `codesign --verify --strict --check-notarization -R=notarized` for the CLI, extracted app, and DMG.

The proof file is bounded, retained, hashed into the release plan, and uploaded with the artifacts. The driver keeps
the tracked changelog notes as the immutable body prefix, adds source/plan/checksum/proof authority, then updates the
draft after npm verification with the exact registry tarball, integrity, and publish time. Inspect the rendered body
once more, then publish it:

```bash
gh release edit v<version> --draft=false
```

For beta versions, the script publishes with the `beta` tag. Peekaboo beta releases are still the default release, so
also run `npm dist-tag add @steipete/peekaboo@<version> latest` before publishing the GitHub draft.

### Caller environment

The driver shell must already hold `NPM_TOKEN`. The tracked manifest's `MAC_RELEASE_OP_ENV_REFS` names the token's
`op://` reference, but the helper resolves it only for children of its own credential passes; nothing places it in the
driver's environment. Add that same reference as `NPM_TOKEN=...` to the `op run` env file next to the App Store Connect
fields. With `--publish-npm` the driver now refuses to start without the token; previously the missing token surfaced
only at the npm step, after the full build and notarization. Secret references cannot contain parentheses, so the env
file must address the App Store Connect item by its 1Password item ID rather than its title. The manifest's
`MAC_RELEASE_OP_ITEM` keeps the title because the helper looks that item up by name, not through an `op://` reference.

`scripts/mac-release` narrows `PATH` to `/usr/bin:/bin` before it executes the pinned helper, and the helper records its
inherited `PATH` as `MAC_RELEASE_CALLER_PATH`, which becomes the wrapped command's `PATH` behind the codesign shim. The
CLI build's `codesign-run -- pnpm run build:swift:all` therefore could not find `pnpm`. The driver now passes
`MAC_RELEASE_CALLER_PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`, the preflight's tool path, unless the caller
already set one; an explicit value still wins. Export that value yourself when publishing a commit that predates this
change, as 4.7.0 did. The terminal pipeline and the manual recovery commands above set an explicit `PATH` inside the
wrapped command and are unaffected.

### npm two-factor publication

The npm account enforces a one-time password on every publish, and the release tarball is about 32 MB. The driver's
`pnpm publish` cannot answer that challenge when its input or output is piped: `printf 'y\n' | ...` or `| tee log`
makes pnpm stop with `ERR_PNPM_OTP_NON_INTERACTIVE`, and by then the GitHub draft already exists. A TOTP supplied up
front does not survive the upload either. During 4.7.0, codes passed through `NPM_CONFIG_OTP` expired during the two- to
three-minute upload and npm answered `EOTP`, from a faster fleet Mac as well. Retrying through the driver with
`--retry-npm-publish` or longer fetch timeouts hits the same wall.

Publish npm through the `Publish npm release tarball` workflow (`.github/workflows/npm-publish.yml`) instead. It is
registered as the npm trusted publisher for `@steipete/peekaboo`, so npm accepts its GitHub OIDC identity without a
token or one-time password, and the upload runs from GitHub's network. After the driver has created the draft and
uploaded its assets, dispatch it for the release version:

```bash
gh workflow run npm-publish.yml --repo openclaw/Peekaboo --ref main -f version=<version>
```

The workflow never packs or builds. It downloads the exact `steipete-peekaboo-<version>.tgz` asset from the draft or
published release, requires its SHA-256 to match the release's `checksums.txt` and its embedded package name/version to
match, publishes with `--tag latest` (`beta` for prerelease versions), and fails unless the registry integrity equals
the asset's SHA-512. A version already published with the identical tarball is a no-op; different bytes fail closed.

If the workflow is unavailable, the interactive fallback is still valid: in a real terminal authenticated to npmjs as
`steipete`, `npm publish "$PWD/build/release/steipete-peekaboo-<version>.tgz" --registry https://registry.npmjs.org
--access public --tag latest`, completing npm's browser authentication with the npmjs TOTP as soon as npm prints the URL.

Either way, rerun `./scripts/release-binaries.sh --resume-publication` from the same checkout and credentialed shell
afterwards. Resume finds the published version, verifies that
the registry integrity equals the retained tarball's SHA-512, skips its own publish, and finishes the draft body;
a different tarball fails closed. `--retry-npm-publish` is unnecessary once the version is visible. If the driver
already attempted its own publish, its retained attempt marker makes resume refuse to publish again until the registry
shows the version.

### Resume cost

When the draft already exists, resume compares each asset's size and server-reported SHA-256 digest with the frozen
receipt. It re-uploads with `gh release upload --clobber` only assets that are missing, differ, or have no digest yet;
an intact draft uploads nothing. Duplicate or unexpected asset names still fail closed. The strict check that follows
verifies the exact inventory, sizes, and digests against the frozen receipt and remains the gate before npm.

An interrupted large asset still costs that asset's full re-upload on a slow uplink, whether it is the DMG, app zip,
or ~32 MB npm tarball.

## 5. Verify

- `npm view @steipete/peekaboo@<version>` reports the version, tarball, integrity, and publish time; `latest` points to
  the new version for stable and beta releases.
- Git tag and non-draft GitHub Release `v<version>` exist.
- Release body contains the complete changelog section plus npm metadata and exact CI/test proof.
- GitHub assets include the CLI archive, npm tarball, app zip, branded DMG, and checksums expected by the script.
- GitHub draft body, exact asset inventory, sizes, and server-reported SHA-256 digests match the local release.
- npm's published SRI integrity matches the exact local tarball.
- `appcast.xml` is valid, strictly build-monotonic, and its newest item matches the app's build/minimum-system version,
  GitHub app zip URL, length, and Sparkle signature.
  The generator XML-escapes metadata, including URL query separators; verification compares the decoded values with
  the original artifact metadata. Do not pre-escape release or asset URLs before passing them to the generator.
- The mounted DMG app tree is byte/mode/symlink-identical to the app zip and therefore carries the same source commit.
- Extracted CLI, app, and mounted DMG report the new version; codesign, stapler, Gatekeeper, layout, background, and Applications-link verification pass.
- A fresh temporary `npx @steipete/peekaboo@<version> --help` succeeds.
- Release and Homebrew workflows complete successfully.

Commit and push the generated `appcast.xml` update if the release script leaves it dirty.

## 6. Close out

After all public verification passes, add `Unreleased` sections to both changelogs for the next patch version, commit,
push, pull `--ff-only`, and finish on clean `main`.
