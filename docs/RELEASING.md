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
- Update `package.json`, both `version.json` files, `Apps/CLI/Sources/Resources/Info.plist`,
  `Apps/CLI/TestHost/Info.plist`, `PeekabooMCPVersion.current`, the README release-status copy, and
  `MARKETING_VERSION` in the Mac, Inspector, and Playground Xcode projects.
- Candidate version and changelog sections may remain `Unreleased` only while running the deterministic preparation
  dry run. Date both changelogs before the publication commit and full release preflight.
- Update user-facing docs and `release/release-notes.md`. Release notes contain only that version's changelog section.
- The tracked release notes are publication authority: full preflight requires them to match the root changelog section,
  and the GitHub draft body is created from those exact bytes.
- Update submodule repositories first only when their code or release metadata changed, then commit the gitlink here.
- Use the supported Xcode 26.x release toolchain; do not substitute an older SDK for publication builds.

## 2. Validate the preparation patch

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

Run `pnpm run test:automation` and live provider tests when the release changes those surfaces. Before committing,
run the repository autoreview workflow until no accepted actionable findings remain.

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
`xcodebuild -version`, macOS SDK version, and `swiftc --version`. This receipt does not make an unsupported toolchain
supported; an Xcode 27 beta build remains visibly distinct from the documented Xcode 26.x publication baseline.
The published `terminal-artifacts.json` is portable schema 7 with `root:"."`; every path is relative to its own
directory. It retains its validator, canonical tree generator, commit-materialized controller/monitor/lock snapshot,
rich universal Foundation-signed controller and monitor records, and pinned Node runtime. Copying the sealed directory to another absolute
path must leave every byte and manifest hash unchanged and validate without a Peekaboo or OpenClaw checkout.

## 3. Date, commit, push, and run publication preflight

Replace `Unreleased` with the actual release date, then use standard Git commands with Conventional Commits. Push
`main`, pull with `--ff-only`, and confirm the publication commit is current and the tree is clean. Only then run the
full publication preflight:

```bash
pnpm run prepare-release
```

Do not build release artifacts until publication preflight succeeds; dirty trees produce invalid version metadata.

## 4. Publish

Load release credentials through the maintainer 1Password workflow, then run interactively:

```bash
./scripts/release-binaries.sh \
  --create-github-release \
  --publish-npm \
  --proof-file /path/to/reviewed-release-proof.md
```

The script runs release preparation, builds the universal CLI and npm package, signs/notarizes/staples the macOS app
and branded DMG, generates checksums and Sparkle metadata, and uploads a draft GitHub release. Install `uv`
with Homebrew before running it; the pinned `dmgbuild` environment writes Finder layout metadata directly. The npm
step requires either an authenticated npm session or `NPM_TOKEN`; the
maintainer release command provides `NPM_TOKEN` automatically through the manifest's credential pass. A 404 response
to a registry PUT means npm authentication is missing or invalid, not that the package is missing. When the script
pauses at the npm confirmation, leave the process waiting, inspect the draft assets and notes, then answer `y` to
publish npm. The signing identity must be:

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
- The mounted DMG app tree is byte/mode/symlink-identical to the app zip and therefore carries the same source commit.
- Extracted CLI, app, and mounted DMG report the new version; codesign, stapler, Gatekeeper, layout, background, and Applications-link verification pass.
- A fresh temporary `npx @steipete/peekaboo@<version> --help` succeeds.
- Release and Homebrew workflows complete successfully.

Commit and push the generated `appcast.xml` update if the release script leaves it dirty.

## 6. Close out

After all public verification passes, add `Unreleased` sections to both changelogs for the next patch version, commit,
push, pull `--ff-only`, and finish on clean `main`.
