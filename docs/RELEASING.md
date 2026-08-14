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
- Keep the candidate sections in `CHANGELOG.md` and `Apps/CLI/CHANGELOG.md` marked `Unreleased` while preparing and
  validating the release. Replace `Unreleased` with the actual release date only in the publication commit.
- Update user-facing docs and `release/release-notes.md`. Release notes contain only that version's changelog section.
- Update submodule repositories first only when their code or release metadata changed, then commit the gitlink here.

## 2. Validate

```bash
pnpm run format
pnpm run lint
pnpm run lint:docs
pnpm run docs:site
pnpm run test:safe
pnpm run prepare-release
```

While the version/changelog decision is still in progress, run the deterministic subset without registry, git-fetch,
or artifact work:

```bash
pnpm run build:cli
pnpm run prepare-release -- --dry-run --bin Apps/CLI/.build/debug/peekaboo
```

The dry run validates metadata consistency, docs/links, generated v4 help, retired-command rejection, and the
`app list`/`window list`/`screen list` JSON contracts. It is intentionally not release-readiness proof; the full
preflight remains required after the version is final and the tree is clean. Dry-run accepts the candidate's
`Unreleased` changelog headings; full preflight requires exact `YYYY-MM-DD` headings before publication.

Run `pnpm run test:automation` and live provider tests when the release changes those surfaces. Before committing,
run the repository autoreview workflow until no accepted actionable findings remain.

## 3. Commit and push

Use standard Git commands with Conventional Commits. Push `main`, pull with `--ff-only`, and confirm a clean tree
before building release artifacts; dirty trees produce invalid version metadata.

## 4. Publish

Load release credentials through the maintainer 1Password workflow, then run interactively:

```bash
./scripts/release-binaries.sh \
  --create-github-release \
  --publish-npm
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

The app, every nested Mach-O payload, standalone CLI archive, npm CLI archive, and DMG must report the Foundation authority and Team ID `FWJYW4S8P8`. Online verification must pass `codesign --verify --strict --check-notarization -R=notarized` for the CLI, extracted app, and DMG.

After npm verification, append a `Verification` section to the draft body with the npm version page, registry tarball
URL, integrity value, publish time, and exact CI/test proof. Keep the changelog section intact, update the draft with
`gh release edit v<version> --notes-file <reviewed-body-file>`, inspect the rendered body once more, then publish it:

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
- `appcast.xml` is valid and its newest item points to the new GitHub app zip with matching length and signature.
- Extracted CLI, app, and mounted DMG report the new version; codesign, stapler, Gatekeeper, layout, background, and Applications-link verification pass.
- A fresh temporary `npx @steipete/peekaboo@<version> --help` succeeds.
- Release and Homebrew workflows complete successfully.

Commit and push the generated `appcast.xml` update if the release script leaves it dirty.

## 6. Close out

After all public verification passes, add `Unreleased` sections to both changelogs for the next patch version, commit,
push, pull `--ff-only`, and finish on clean `main`.
