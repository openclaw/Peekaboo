---
summary: 'Peekaboo 3.x release checklist (main repo + submodules)'
read_when:
  - 'preparing for a release'
  - 'cleaning up repos before release'
---

# Peekaboo Release Checklist

> **Note:** Run commands from the repo root unless a step says otherwise. For long Swift builds/tests, use tmux as documented in AGENTS.
> **No-warning policy:** Lint/format/build/test steps must finish cleanly (no SwiftLint/SwiftFormat warnings, no pnpm warnings). Fix issues before moving on.
>
> **Release policy (betas):** Beta versions are **normal GitHub releases** (not prereleases) and **npm `latest`** must always point at the newest beta. Only use prerelease flags for truly experimental builds that should not be the default. Release notes must be **only the changelog entries** for that version (no install steps, no extra prose).

**Scope:** Main Peekaboo repo plus submodules `/AXorcist`, `/Commander`, `/Tachikoma`, `/TauTUI`. Each has its own `CHANGELOG.md` and must be released in lock-step.

## 0) Version + metadata prep
- [ ] Bump versions: `package.json`, `version.json`, app Info.plists (CLI + macOS targets), and all MCP server/tool banners (`Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/**`).
- [ ] Cut `CHANGELOG.md`: move items from **Unreleased** into the new 3.x section with the correct date.
- [ ] Align docs that mention the version (`docs/tui.md`, `docs/reports/playground-test-result.md`, `AGENTS.md`, any beta strings).
- [ ] Submodules: bump versions + changelogs in AXorcist, Commander, Tachikoma, TauTUI before updating submodule SHAs here.

## 1) Format & lint (all repos)
- [ ] Main: `pnpm run format:swift`, `pnpm run lint:swift`, plus `pnpm run format` / `pnpm run lint` if JS/TS changed.
- [ ] AXorcist: `swift run swiftformat .` then `swiftlint`.
- [ ] Commander: `swift run swiftformat .` then `swiftlint`.
- [ ] Tachikoma: `swift run swiftformat .` then `swiftlint`.
- [ ] TauTUI: `swift run swiftformat .` then `swiftlint`.

## 2) Tests & builds
- [ ] Main Swift build: `swift build`.
- [ ] Main tests: `(cd Apps/CLI && swift test)`; remove or rewrite any constructs that trigger the known SILGen/frontend crash before continuing.
- [ ] JS/TS tests: `pnpm test` (and `pnpm check` if applicable).
- [ ] Submodules: `swift build && swift test` in AXorcist, Commander, Tachikoma, TauTUI.
- [ ] Optional automation sweep: `pnpm run test:automation` when touching agent flows.

## 3) Release artifacts
- [ ] `pnpm run prepare-release` (validates versions, changelog, and Swift/TS entry points).
- [ ] `./scripts/release-binaries.sh --create-github-release --publish-npm` (Default: universal arm64+x86_64 binary, npm package, signed/notarized `Peekaboo.app` zip, Sparkle appcast update, and checksums; use `--arm64-only` to skip Intel support or `--skip-mac-app` for CLI-only emergency releases).
- [ ] Verify `dist/` outputs and the generated checksum files.
- [ ] `npm pack --dry-run` to inspect the npm tarball if release scripts changed.

## 3b) macOS app (Sparkle)
Peekaboo’s macOS app now ships Sparkle updates (Settings → About). Updates are **disabled** unless the app is a bundled `.app` and **Developer ID signed** (see `Apps/Mac/Peekaboo/Core/Updater.swift`).

The main release script runs this step automatically. Use this section only to dry-run, repair, or upload the app zip for an existing release.

- [ ] Ensure `Apps/Mac/Peekaboo/Info.plist` has `SUFeedURL`, `SUPublicEDKey`, and `SUEnableAutomaticChecks` set (defaults are already wired to the repo appcast).
- [ ] Ensure release credentials are available:
  - Developer ID Application certificate in the login keychain.
  - Sparkle EdDSA private key from `.mac-release.env` or `SPARKLE_PRIVATE_KEY_FILE`.
  - Notarization credentials via `NOTARYTOOL_PROFILE` or `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID`, and `APP_STORE_CONNECT_API_KEY_P8`.
- [ ] Optional local dry run before touching Apple/GitHub/appcast:
  - `pnpm run release:mac-app -- --dry-run`
- [ ] Build, **Developer ID sign**, notarize, staple, zip, Sparkle-sign, verify, update `appcast.xml`, and upload. If `release/checksums.txt` already came from `release-binaries.sh`, include `--upload-checksums`; otherwise upload only the app zip and update checksums separately:
  - `pnpm run release:mac-app -- --upload --upload-checksums`
- [ ] Confirm the script prints the expected GitHub asset URL, SHA256, zip length, and Sparkle signature. The script also validates `codesign`, `stapler`, `spctl`, extracted zip contents, and `xmllint` when available.
- [ ] Verify with an installed previous build: Settings → About → “Check for Updates…” installs the new build.

## 3c) Non-Sparkle app bundles for GitHub release
`Peekaboo.app` is owned by the Sparkle step above. Use this section only for additional app bundles that are not distributed through Sparkle, such as Playground.

- [ ] Build **warning-free** Release apps:
  - `./runner xcodebuild -workspace Apps/Peekaboo.xcworkspace -scheme Playground -configuration Release -destination "platform=macOS,arch=arm64" -derivedDataPath /tmp/peekaboo-release-dd build`
- [ ] Launch smoke (optional but preferred): `open -n /tmp/peekaboo-release-dd/Build/Products/Release/Playground.app`, then quit it.
- [ ] Zip the app separately (resource forks preserved):
  - `ditto -c -k --sequesterRsrc --keepParent /tmp/peekaboo-release-dd/Build/Products/Release/Playground.app release/Playground.app.zip`
- [ ] Update checksums to include app zips:
  - `cd release && shasum -a 256 peekaboo-macos-universal.tar.gz steipete-peekaboo-<version>.tgz Peekaboo-<version>.app.zip Playground.app.zip > checksums.txt`
- [ ] Upload assets (clobber existing checksums): `gh release upload v<version> release/Playground.app.zip release/checksums.txt --clobber`

## 4) Git hygiene
- [ ] Commit and push submodules first (conventional commits in each subrepo).
- [ ] Update submodule pointers in the main repo and commit via `./scripts/committer`.
- [ ] Commit main repo release changes (changelog, version bumps, generated assets if tracked) via `./scripts/committer`.
- [ ] `git status -sb` should be clean.

## 5) Tag & publish
- [ ] Tag the release: `git tag v<version>` then `git push --tags`.
- [ ] Publish npm if the release script didn’t: `pnpm publish --tag latest`.
- [ ] Ensure npm points `latest` at the new beta: `npm dist-tag add @steipete/peekaboo@<version> latest`.
- [ ] Create GitHub release **without** prerelease flag; upload macOS binaries/tarballs + checksum, and paste **only** the CHANGELOG section for that version as the release notes.

## 6) Post-publish verification
- [ ] `polter peekaboo --version` to confirm the stamped build date matches the new tag.
- [ ] `npm view @steipete/peekaboo dist-tags` to ensure `latest` matches the new beta.
- [ ] Homebrew tap: confirm the `Update Homebrew Formula` release workflow dispatched `steipete/homebrew-tap` and completed successfully.
- [ ] npm install: `npm install -g @steipete/peekaboo@latest` then `peekaboo --version` (or `npx @steipete/peekaboo@latest --version` for a no-install smoke).
- [ ] Homebrew verify: `brew update && brew upgrade steipete/tap/peekaboo && peekaboo --version` and **leave Homebrew-installed** at the end.
- [ ] Fresh-temp smoke: `rm -rf /tmp/peekaboo-empty && mkdir /tmp/peekaboo-empty && cd /tmp/peekaboo-empty && npx peekaboo@<version> --help` (no runner; outside repo). Ensure CLI/help prints and exits 0.

## Quick status helpers
```bash
git status -sb
git submodule status
```

## Notes
- Conventional Commits only. Submodules first, main repo last.
- No stale binaries: run user-facing tests/verification via `polter peekaboo …` so the built binary matches the tree.
