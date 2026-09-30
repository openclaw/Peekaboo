---
name: release-peekaboo
description: "Peekaboo release: notarization, npm/GitHub release, appcast, verify, closeout."
metadata: {"clawdbot":{"emoji":"👁️","requires":{"bins":["pnpm","op","tmux","gh","xcrun","jq","node","npm","uv"]}}}
---

# Peekaboo Release

Release `~/Projects/Peekaboo` as the npm package `@steipete/peekaboo` plus signed/notarized macOS app assets.

Use `$one-password`, `$browser-use`, `$npm`, `$autoreview`, and repo `AGENTS.md` rules. Load `$release-private` if it exists before resolving Peter-owned credential locators. Read `$npm` before any npm auth, token, or publish recovery work. Keep all `op` secret work inside one persistent tmux session. Never print `.p8`, npm tokens, passwords, or OTPs.

## Current Secrets

- Peter-owned credential item names, key ids, issuer ids, keychain paths, and npm token locators live in `$release-private`.
- Required ASC fields: `key_id`, `issuer_id`, `private_key_p8`.
- Stale/revoked key symptom: `xcrun notarytool submit` fails with `HTTP status code: 401. Unauthenticated`.
- All ASC fields must come from the same current item; do not mix profile values with 1Password refs.

Sparkle key:

- Resolve the exact `MAC_RELEASE_SPARKLE_OP_REF` from `$release-private` into the private release environment or tmux
  session; never add the locator to this public repo, status output, or logs.
- The shared release helper uses the prompt-free service account, verifies the public key, and owns its mode-0600
  temporary file cleanup. Do not set `SPARKLE_PRIVATE_KEY_FILE` for normal releases.

Developer ID release keychain:

- Resolve the release keychain item/path from `$release-private`.
- The canonical release keychain is passwordless and never-locking. If macOS shows `codesign wants to use the release keychain`, cancel the prompt and repair that setup through the owning credential workflow; there is no keychain password to enter.
- The Developer ID certificate password is only for importing a transported `.p12`, not unlocking the local release keychain.
- The shared release helper owns keychain preparation, partition access, and the signing canary. Do not proceed to packaging until that canary succeeds without GUI prompts.

npm publish token:

- Resolve token/TOTP locators from `$release-private`.
- `NPM_TOKEN` must be in the driver's own environment: add the `NPM_TOKEN` op:// ref from `MAC_RELEASE_OP_ENV_REFS` in `.mac-release.env` to the `op run` env file. The manifest ref only reaches helper children, never the driver; with `--publish-npm` the driver refuses to start without it.
- Use `$npm` rules. Run inside the same tmux session, write only a temp npmrc, delete it immediately, and use the `npmjs` TOTP item for web auth if npm prompts.
- Do not create short-lived/granular bypass tokens for a normal Peekaboo publish. They add cleanup risk and did not help the 3.2.1 slow-upload/web-auth path.

## Notary Credential Check

Use the service account from `$release-private` first. Put the token in the tmux environment without printing it:

```bash
# Resolve SERVICE_ACCOUNT_TOKEN from $release-private first.
tmux -S "$SOCKET" set-environment -t "$SESSION" OP_SERVICE_ACCOUNT_TOKEN "$SERVICE_ACCOUNT_TOKEN"
```

Create a temp env file with service-account refs from `$release-private`:

```text
APP_STORE_CONNECT_API_KEY_P8=<1Password ref from release-private>
APP_STORE_CONNECT_KEY_ID=<1Password ref from release-private>
APP_STORE_CONNECT_ISSUER_ID=<1Password ref from release-private>
NPM_TOKEN=<NPM_TOKEN op:// ref from MAC_RELEASE_OP_ENV_REFS in .mac-release.env>
```

op:// refs cannot contain parentheses. The App Store Connect item title has them, so address it by 1Password item ID
(`op://<vault>/<item-id>/<field>`); fetch the ID as metadata only, never the values.

Before a release, verify shape and Apple auth without printing values:

```bash
op run --env-file "$ENVFILE" -- bash -c '
  set -euo pipefail
  KEY_FILE="/tmp/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  printf "%s\n" "$APP_STORE_CONNECT_API_KEY_P8" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  xcrun notarytool history \
    --key "$KEY_FILE" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --output-format json >/dev/null
  rm -f "$KEY_FILE"
'
```

Peekaboo forces `notarytool submit --no-s3-acceleration`; the default S3 accelerated upload path can return a misleading `401` even when `history` auth succeeds.

If both `history` and non-S3 `submit` fail, suspect wrong access level or stale key. Browser route:

1. Use `$browser-use` real Chrome profile.
2. Open `https://appstoreconnect.apple.com/access/integrations/api`.
3. Generate Team Key named `Peekaboo Release <version>` with `Admin` access.
4. Download `.p8` once from the key row.
5. Store immediately into the private credential map; verify `notarytool history`; delete `~/Downloads/AuthKey_<key_id>.p8`.
6. Revoke the older Peekaboo release key after the new key validates.

## Release Flow

1. Start on clean `main`; pull ff-only if needed.
2. Set version in:
   - `package.json`
   - `version.json`
   - `Apps/CLI/Sources/Resources/version.json`
   - README npm badge
   - `Core/PeekabooCore/Sources/PeekabooAgentRuntime/MCP/PeekabooMCPVersion.swift`
   - Xcode marketing versions under `Apps/*`
3. Date `CHANGELOG.md` and `Apps/CLI/CHANGELOG.md` for the release.
4. Run focused proof or release script preflight. Release gates must be warning-free.
5. Use `$autoreview` before commit unless the change is trivial/docs-only.
6. Stage the intended release files and commit with standard Git.
7. Push `main`.
8. Run:

Before building, run `scripts/build-terminal-artifacts.sh check-helper`. On `mac-release helper commit mismatch`, do not
reset `~/Projects/agent-scripts` or bump the pin mid-release: publish from a fresh staging clone of `main` with a
detached `agent-scripts` worktree at the pinned commit beside it (`docs/RELEASING.md`, "Release helper pin and
relocated publication checkout"). Preflight, the driver, resume, and the appcast commit then all run in that clone;
remove the clone and the worktree only after closeout. A pin bump is its own reviewed PR.

Prepare a bounded reviewed Markdown proof file containing the exact hosted CI and local release-gate results, then set
`RELEASE_PROOF_FILE` to its absolute path. The driver retains and hashes it into the release plan and GitHub body.

```bash
op run --env-file "$ENVFILE" -- \
  bash -c 'printf "y\n" | ./scripts/release-binaries.sh --create-github-release --publish-npm --proof-file "$RELEASE_PROOF_FILE"'
```

The script builds universal CLI, npm package, signed/notarized app zip and branded DMG, appcast, checksums, draft GitHub release, and npm publish.
Use a non-login shell: profile exports can replace current 1Password ASC IDs with stale values while leaving the current `.p8`, producing a misleading `401`.
The piped `y` (and any `| tee`) makes pnpm non-interactive, so with npm 2FA enforced the npm step stops with
`ERR_PNPM_OTP_NON_INTERACTIVE` after the draft exists; finish with the npm 2FA path below.
The driver passes `MAC_RELEASE_CALLER_PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin` to the CLI build's
`codesign-run`. Publication commits that predate that default (4.7.0 and earlier) need it exported, or `pnpm` is not
found because `scripts/mac-release` narrows `PATH` before the helper records it.
If the preflight goes silent while a test process stays alive, suspect a test blocked on a pipe or terminal prompt
(fixed for 4.7.0 in `test: keep release preflight tests from blocking on output or prompts`), not a slow build.

When resuming before any public action after a release interruption with a CLI already built from the same clean `HEAD`, add
`--reuse-built-cli`. The script verifies the full signer, entitlement, native-only, runtime-library, architecture,
online-notarization, version, and exact-source contract before packaging; it never executes the candidate before the
non-executing safety checks finish.

The npm confirmation occurs before GitHub draft creation. After any partial public action, preserve `build/release` and
the generated `appcast.xml`, then rerun `./scripts/release-binaries.sh --resume-publication` inside the same credentialed
shell. Resume verifies the retained source-bound plan, proof, checksums, artifacts, helper pin, remote tag/draft/assets,
and npm integrity; it skips an already-published identical tarball and completes the final draft body idempotently.
The retained checksummed full appcast prevents unrelated feed drift. An E404 after an attempted npm publish fails closed
on the retained attempt marker; wait for registry propagation, and use `--retry-npm-publish` only after independently
confirming the version was not accepted.
The retained plan must record both completed full preflight and publication eligibility. The driver refuses proof files
on local-only or reduced-check builds, preventing `--resume-publication` from promoting those artifacts.

Every notarized release payload must sign with `Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)`, not a personal or development identity. This includes Peekaboo.app, nested helpers and frameworks, the standalone and npm CLIs, and the DMG. The tracked release manifest and shared credential helper resolve the shared passwordless signing keychain; never copy its machine-specific path or signing material into the repository. Peekaboo 3.8+ bridge hosts keep accepting transition-era personal-team clients for staged upgrades, but Foundation-signed 3.9.6+ CLIs require a 3.8+ host.

npm 2FA: the ~32 MB upload outlives any TOTP. Codes from `--otp`/`NPM_CONFIG_OTP` fail with `EOTP`, even from a faster
fleet Mac, and driver retries (`--retry-npm-publish`, longer fetch timeouts) hit the same wall. Publish the exact retained
tarball from an interactive terminal (no pipes) authenticated as `steipete`, using the stored npm token through a temp
npmrc or an existing login, and complete npm's browser auth with the configured TOTP as soon as npm prints the URL:

```bash
npm publish "$PWD/build/release/steipete-peekaboo-<version>.tgz" \
  --registry https://registry.npmjs.org --access public --tag latest   # --tag beta for prereleases
```

Then rerun `./scripts/release-binaries.sh --resume-publication`. It accepts the already-published version only if the
registry integrity equals the retained tarball, and it finishes the draft body. Do not create granular bypass tokens for
this; if one was created by mistake, delete it before closeout.

Resume cost: whenever the draft exists, resume re-uploads every asset with `gh release upload --clobber` before npm,
because its pre-upload check compares names, not digests. On a slow uplink expect the full asset upload each time.

## Verify

Required before closeout:

```bash
npm view @steipete/peekaboo@<version> version dist-tags dist.tarball dist.integrity time --json
(cd /tmp && npm exec --yes --package=@steipete/peekaboo@<version> -- peekaboo --version)
gh release view v<version> --repo openclaw/Peekaboo --json tagName,isDraft,isPrerelease,url,assets,body
xmllint --noout appcast.xml
git status --short --branch
```

Confirm:

- npm version exists and `latest` points to it.
- npm-downloaded CLI reports the release version from a neutral cwd.
- GitHub release/tag/assets exist; release body is from changelog.
- app zip and DMG assets exist; appcast points at the zip under `v<version>`.
- `appcast.xml` changes are committed and pushed.
- Publish draft release if the script leaves it draft.

## Closeout

1. Add next patch `Unreleased` section to root and CLI changelogs.
2. Stage both changelogs and commit with `git commit -m "docs(changelog): open <next-version>"`.
3. Push.
4. Watch release/homebrew/CI workflows if triggered.
5. `git checkout main && git pull --ff-only && git status --short --branch`.
6. Clear tmux `OP_SERVICE_ACCOUNT_TOKEN`, remove temp env/key files, and final with what landed.
