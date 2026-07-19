---
name: release-peekaboo
description: "Peekaboo release: notarization, npm/GitHub release, appcast, verify, closeout."
metadata: {"clawdbot":{"emoji":"👁️","requires":{"bins":["pnpm","op","tmux","gh","xcrun","jq","node","npm","create-dmg"]}}}
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

- Repo `.mac-release.env` has the current fallback.
- Do not set `SPARKLE_PRIVATE_KEY_FILE` for normal releases.

Developer ID release keychain:

- Resolve the release keychain item/path from `$release-private`.
- If macOS shows `codesign wants to use the release keychain`, enter the keychain item password, not the Developer ID `.p12` password.
- The Developer ID certificate password is only for importing the `.p12` while creating the keychain.
- After setup/import, run `security unlock-keychain` and `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"` so `codesign` can use the identity without GUI prompts.

npm publish token:

- Resolve token/TOTP locators from `$release-private`.
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
```

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
6. Commit release prep with `committer`.
7. Push `main`.
8. Run:

```bash
op run --env-file "$ENVFILE" -- \
  bash -c 'printf "y\n" | ./scripts/release-binaries.sh --create-github-release --publish-npm'
```

The script builds universal CLI, npm package, signed/notarized app zip and branded DMG, appcast, checksums, draft GitHub release, and npm publish.
Use a non-login shell: profile exports can replace current 1Password ASC IDs with stale values while leaving the current `.p8`, producing a misleading `401`.

Every notarized release payload must sign with `Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)`, not a personal or development identity. This includes Peekaboo.app, nested helpers and frameworks, the standalone and npm CLIs, and the DMG. The tracked release manifest resolves the shared passwordless signing keychain from the `OpenClaw-Core` vault; never copy the keychain path or signing material into the repository. Peekaboo 3.8+ bridge hosts keep accepting transition-era personal-team clients for staged upgrades, but Foundation-signed 3.9.6+ CLIs require a 3.8+ host.

If npm upload is slow and TOTP expires, use the stored npm token through a temp npmrc and complete npm web auth immediately when prompted with the configured TOTP. Do not create granular bypass tokens for this; if one was created by mistake, delete it before closeout.

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
2. Commit with `committer "docs(changelog): open <next-version>" CHANGELOG.md Apps/CLI/CHANGELOG.md`.
3. Push.
4. Watch release/homebrew/CI workflows if triggered.
5. `git checkout main && git pull --ff-only && git status --short --branch`.
6. Clear tmux `OP_SERVICE_ACCOUNT_TOKEN`, remove temp env/key files, and final with what landed.
