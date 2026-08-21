#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"

TEST_DIR="$(mktemp -d /tmp/peekaboo-terminal-env-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'test-terminal-artifact-env: %s\n' "$*" >&2
  exit 1
}

cat > "$TEST_DIR/probe" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"
terminal_artifact_assert_build_env_is_clean
printf 'clean\n'
EOF
chmod 755 "$TEST_DIR/probe"

for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
  printf -v "$secret_name" sentinel
  export "${secret_name?}"
done

[[ "$(terminal_artifact_run_build "$TEST_DIR/probe")" == clean ]] || \
  fail 'build child observed a release credential variable'

if terminal_artifact_assert_build_env_is_clean >/dev/null 2>&1; then
  fail 'dirty parent environment was not detected'
fi

wrapper="$ROOT_DIR/scripts/build-terminal-artifacts.sh"
rg -Fq 'terminal_artifact_run_build "$ROOT_DIR/scripts/build-terminal-artifacts.sh" build' "$wrapper" || \
  fail 'all mode does not isolate its complete build process'
rg -Fq 'MAC_RELEASE_MANIFEST="$ROOT_DIR/.mac-release-terminal.env"' "$wrapper" || \
  fail 'finalization does not use the terminal-only credential manifest'
rg -Fq 'codesign-run --with-package-secrets' "$wrapper" || \
  fail 'finalization does not enter the narrow credentialed lane'
for publication_secret in GH_TOKEN GITHUB_TOKEN NODE_AUTH_TOKEN NPM_CONFIG_USERCONFIG NPM_TOKEN; do
  rg -Fq -- "-u $publication_secret" "$wrapper" || \
    fail "finalization does not remove inherited $publication_secret"
done
rg -Fq -- '--skip-build' "$wrapper" || fail 'credentialed Peekaboo.app finalization can still compile'
if rg -n 'create-github-release|publish-npm|gh release (create|upload)|npm publish' "$wrapper"; then
  fail 'terminal-only wrapper contains a public publication path'
fi

(
  cd "$ROOT_DIR"
  # shellcheck source=.mac-release-terminal.env
  source .mac-release-terminal.env
  [[ -z "${MAC_RELEASE_OP_ENV_REFS:-}" ]]
) || fail 'terminal credential manifest still imports npm environment references'

for build_script in scripts/build-swift-arm.sh scripts/build-swift-universal.sh; do
  rg -Fq 'PEEKABOO_USE_RESOLVED_VERSIONS' "$ROOT_DIR/$build_script" || \
    fail "$build_script cannot enforce the canonical CLI dependency graph"
  rg -Fq -- '--only-use-versions-from-resolved-file' "$ROOT_DIR/$build_script" || \
    fail "$build_script omits fail-closed Swift dependency resolution"
done
rg -Fq 'cp "$CANONICAL_LOCK" "$CLI_LOCK"' "$wrapper" || \
  fail 'terminal CLI build is not seeded from the canonical tracked dependency graph'
rg -Fq 'MAC_APP_NOTARY_RESULT_PATH=' "$wrapper" || fail 'app notary receipt is not persisted'
rg -Fq 'MAC_DMG_NOTARY_RESULT_PATH=' "$wrapper" || fail 'DMG notary receipt is not persisted'
for inventory_name in cli peekaboo-app playground-app; do
  rg -Fq "inventories/$inventory_name.json" "$wrapper" || \
    fail "complete $inventory_name payload inventory is not sealed"
done
for toolchain_field in developer_dir xcodebuild_version sdk_version swiftc_version; do
  rg -Fq "$toolchain_field" "$wrapper" || fail "toolchain receipt omits $toolchain_field"
done

printf 'test-terminal-artifact-env: ok\n'
