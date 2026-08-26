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
cat > "$TEST_DIR/orchestrator-probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]
[[ -z "${APP_STORE_CONNECT_API_KEY_P8+x}" ]]
[[ -z "${NPM_TOKEN+x}" ]]
printf 'orchestrator-clean\n'
EOF
chmod 755 "$TEST_DIR/probe"
chmod 755 "$TEST_DIR/orchestrator-probe"
mkdir -p "$TEST_DIR/hostile-bin"
cat > "$TEST_DIR/hostile-bin/env" <<'EOF'
#!/bin/sh
printf '%s\n' "${OP_SERVICE_ACCOUNT_TOKEN:-missing}" > "${HOSTILE_ENV_MARKER:?}"
exit 97
EOF
chmod 755 "$TEST_DIR/hostile-bin/env"

for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
  printf -v "$secret_name" sentinel
  export "${secret_name?}"
done

[[ "$(terminal_artifact_run_build "$TEST_DIR/probe")" == clean ]] || \
  fail 'build child observed a release credential variable'
original_path="$PATH"
export HOSTILE_ENV_MARKER="$TEST_DIR/hostile-env-marker"
PATH="$TEST_DIR/hostile-bin:$PATH"
orchestrator_output="$(terminal_artifact_run_orchestrator "$TEST_DIR/orchestrator-probe")"
PATH="$original_path"
unset HOSTILE_ENV_MARKER
[[ "$orchestrator_output" == orchestrator-clean ]] || \
  fail 'orchestrator did not preserve only its service token'
[[ ! -e "$TEST_DIR/hostile-env-marker" ]] || fail 'orchestrator resolved env through hostile PATH'

if terminal_artifact_assert_build_env_is_clean >/dev/null 2>&1; then
  fail 'dirty parent environment was not detected'
fi
for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
  unset "$secret_name"
done

function_marker="$TEST_DIR/imported-function-marker"
startup_marker="$TEST_DIR/startup-marker"
printf 'printf "startup" > %q\n' "$startup_marker" > "$TEST_DIR/hostile-bash-env"
FUNCTION_MARKER="$function_marker" /bin/bash --noprofile --norc -c '
  dirname() { printf "%s\n" "${OP_SERVICE_ACCOUNT_TOKEN:-missing}" > "$FUNCTION_MARKER"; }
  export -f dirname
  if BASH_ENV="$2" OP_SERVICE_ACCOUNT_TOKEN=sentinel "$1" check-helper >/dev/null 2>&1; then
    exit 95
  fi
' bash "$ROOT_DIR/scripts/build-terminal-artifacts.sh" "$TEST_DIR/hostile-bash-env"
[[ ! -e "$function_marker" ]] || fail 'entrypoint invoked an imported function with service authority'
[[ ! -e "$startup_marker" ]] || fail 'entrypoint processed BASH_ENV with service authority'

caller_owned_token_file="$TEST_DIR/caller-owned-token"
printf 'caller-owned\n' > "$caller_owned_token_file"
PEEKABOO_OP_SERVICE_TOKEN_FILE="$caller_owned_token_file" \
  "$ROOT_DIR/scripts/build-terminal-artifacts.sh" check-helper >/dev/null
[[ "$(cat "$caller_owned_token_file")" == caller-owned ]] || \
  fail 'non-all child deleted or changed its caller-owned token custody file'

before_token_files="$TEST_DIR/token-files-before"
after_token_files="$TEST_DIR/token-files-after"
find /tmp -maxdepth 1 -type f -name 'peekaboo-op-token.*' -print | sort > "$before_token_files"
caller_owned_molty_file="$TEST_DIR/caller-owned-molty-token"
printf 'caller-owned-molty\n' > "$caller_owned_molty_file"
if OP_SERVICE_ACCOUNT_TOKEN=first-token MOLTY_OP_SERVICE_ACCOUNT_TOKEN=second-token \
  PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE="$caller_owned_molty_file" \
  "$ROOT_DIR/scripts/build-terminal-artifacts.sh" check-helper >/dev/null 2>&1; then
  fail 'conflicting second-token custody unexpectedly succeeded'
fi
find /tmp -maxdepth 1 -type f -name 'peekaboo-op-token.*' -print | sort > "$after_token_files"
[[ -z "$(comm -13 "$before_token_files" "$after_token_files")" ]] || \
  fail 'first token file leaked after second-token custody failure'
[[ "$(cat "$caller_owned_molty_file")" == caller-owned-molty ]] || \
  fail 'failure cleanup changed caller-owned second-token custody'

release_wrapper="$ROOT_DIR/scripts/mac-release"
release_entry_prefix="$(awk '/^raw_function_names_file=/{exit} {print}' "$release_wrapper")"
for secret_name in OP_SERVICE_ACCOUNT_TOKEN MOLTY_OP_SERVICE_ACCOUNT_TOKEN; do
  grep -Fwq "$secret_name" <<< "$release_entry_prefix" || \
    fail "release wrapper does not de-export $secret_name before its environment scan"
done
cat > "$TEST_DIR/release-helper-probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s:%s\n' "${OP_SERVICE_ACCOUNT_TOKEN:-}" "${MOLTY_OP_SERVICE_ACCOUNT_TOKEN:-}"
EOF
chmod 755 "$TEST_DIR/release-helper-probe"
if /bin/bash --noprofile --norc -c '
  hostile_release_function() { return 97; }
  export -f hostile_release_function
  OP_SERVICE_ACCOUNT_TOKEN=primary MOLTY_OP_SERVICE_ACCOUNT_TOKEN=legacy \
    MAC_RELEASE_TOOL="$2" "$1" >/dev/null 2>&1
' bash "$release_wrapper" "$TEST_DIR/release-helper-probe"; then
  fail 'credential-bearing release wrapper accepted an exported-function environment'
fi
release_probe_output="$(OP_SERVICE_ACCOUNT_TOKEN=primary MOLTY_OP_SERVICE_ACCOUNT_TOKEN=legacy \
  MAC_RELEASE_TOOL="$TEST_DIR/release-helper-probe" \
  /usr/bin/env -u BASH_FUNC_raw_exported_probe%% "$release_wrapper")"
[[ "$release_probe_output" == primary:legacy ]] || \
  fail 'release wrapper did not re-export service credentials only for the selected helper'

wrapper="$ROOT_DIR/scripts/build-terminal-artifacts.sh"
entry_prefix="$(awk '/^raw_function_names_file=/{exit} {print}' "$wrapper")"
for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
  grep -Fwq "$secret_name" <<< "$entry_prefix" || \
    fail "entrypoint does not de-export $secret_name before its environment scan"
done
rg -Fq 'terminal_artifact_run_build /bin/bash --noprofile --norc -p' "$wrapper" || \
  fail 'all mode does not isolate its complete build process'
rg -Fq 'MAC_RELEASE_MANIFEST="$ROOT_DIR/.mac-release-terminal.env"' "$wrapper" || \
  fail 'finalization does not use the terminal-only credential manifest'
rg -Fq 'scripts/mac-release" package-run' "$wrapper" || \
  fail 'notary phase does not use the keychain-free package credential runner'
if rg -Fq 'codesign-run --with-package-secrets' "$wrapper"; then
  fail 'notary phase still unlocks the Developer ID keychain'
fi
for publication_secret in GH_TOKEN GITHUB_TOKEN NODE_AUTH_TOKEN NPM_CONFIG_USERCONFIG NPM_TOKEN; do
  rg -Fq -- "-u $publication_secret" "$wrapper" || \
    fail "finalization does not remove inherited $publication_secret"
done
rg -Fq 'run_notary_only --kind' "$wrapper" || fail 'notarization is not split into direct narrow children'
if rg -n 'release-macos-app|sign_update' "$wrapper"; then
  fail 'terminal finalization still inherits public-release or Sparkle machinery'
fi
if rg -n 'create-github-release|publish-npm|gh release (create|upload)|npm publish' "$wrapper"; then
  fail 'terminal-only wrapper contains a public publication path'
fi

(
  cd "$ROOT_DIR"
  # shellcheck source=.mac-release-terminal.env
  source .mac-release-terminal.env
  [[ -z "${MAC_RELEASE_OP_ENV_REFS:-}" ]]
  [[ -z "${MAC_RELEASE_SPARKLE_OP_REF:-}" ]]
) || fail 'terminal credential manifest still imports npm environment references'

for build_script in scripts/build-swift-arm.sh scripts/build-swift-universal.sh; do
  rg -Fq 'PEEKABOO_USE_RESOLVED_VERSIONS' "$ROOT_DIR/$build_script" || \
    fail "$build_script cannot enforce the canonical CLI dependency graph"
  rg -Fq -- '--only-use-versions-from-resolved-file' "$ROOT_DIR/$build_script" || \
    fail "$build_script omits fail-closed Swift dependency resolution"
done
rg -Fq 'cp "$CANONICAL_LOCK" "$cli_lock"' "$wrapper" || \
  fail 'terminal CLI build is not seeded from the canonical tracked dependency graph'
rg -Fq -- '--transaction "$APP_NOTARY_TRANSACTION"' "$wrapper" || fail 'app notary transaction is not atomic'
rg -Fq -- '--transaction "$DMG_NOTARY_TRANSACTION"' "$wrapper" || fail 'DMG notary transaction is not atomic'
for inventory_name in cli peekaboo-app playground-app qualification-node-app; do
  rg -Fq "inventories/$inventory_name.json" "$wrapper" || \
    fail "complete $inventory_name payload inventory is not sealed"
done
for toolchain_field in developer_dir xcodebuild_version sdk_version swiftc_version; do
  rg -Fq "$toolchain_field" "$wrapper" || fail "toolchain receipt omits $toolchain_field"
done
rg -Fq 'build_mode: $buildMode' "$wrapper" || fail 'build provenance omits production/test mode'
rg -Fq 'signing refuses fixture-built stage' "$wrapper" || fail 'signing accepts fixture-built stages'
rg -Fq 'qualification_source_inventory_sha256' "$wrapper" || \
  fail 'build provenance omits the commit-materialized source snapshot'
rg -Fq 'qualification_monitor:' "$wrapper" || fail 'portable manifest omits the rich monitor record'
rg -Fq 'materialize_committed_file' "$wrapper" || fail 'published source/tools still come from the mutable worktree'
rg -Fq '20ab9a5e6bb1107788366726868f1a9b4c16d953' "$wrapper" || \
  fail 'terminal pipeline does not pin the package-run helper contract'
rg -Fq 'scripts/build-terminal-artifacts.sh check-helper' "$ROOT_DIR/docs/RELEASING.md" || \
  fail 'manual release flow does not preflight the credential runner'
releasing_docs="$ROOT_DIR/docs/RELEASING.md"
[[ "$(grep -Fc "/bin/bash --noprofile --norc -p -c 'exec \"\$@\"'" "$releasing_docs")" == 3 ]] || \
  fail 'manual recovery phases do not use the required non-login bash -c wrappers'
[[ "$(grep -Fc 'peekaboo-codesign-phase' "$releasing_docs")" == 2 ]] || \
  fail 'manual codesign recovery wrappers are incomplete'
[[ "$(grep -Fc 'peekaboo-notary-phase' "$releasing_docs")" == 1 ]] || \
  fail 'manual notary recovery wrapper is incomplete'
[[ "$(grep -Fc -- '-u MAC_RELEASE_TOOL' "$releasing_docs")" == 3 ]] || \
  fail 'manual credentialed recovery permits a release helper override'
[[ "$(grep -Fc "/bin/bash --noprofile --norc -p -c 'exec \"\$@\"'" "$wrapper")" == 2 ]] || \
  fail 'credentialed phase children do not use the required non-login bash -c wrapper'
rg -Fq 'peekaboo-codesign-phase' "$wrapper" || fail 'codesign phase wrapper label is missing'
rg -Fq 'peekaboo-notary-phase' "$wrapper" || fail 'notary phase wrapper label is missing'
cat > "$TEST_DIR/phase-child-probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ -z "${BASH_ENV+x}" ]]
printf '<%s>\n' "$@"
EOF
chmod 755 "$TEST_DIR/phase-child-probe"
phase_child_output="$(/usr/bin/env -u BASH_ENV -u ENV PATH=/usr/bin:/bin \
  /bin/bash --noprofile --norc -p -c 'exec "$@"' peekaboo-test-phase \
  "$TEST_DIR/phase-child-probe" 'argument one' 'argument=two')"
[[ "$phase_child_output" == $'<argument one>\n<argument=two>' ]] || \
  fail 'credentialed bash -c wrapper changed phase arguments'
if rg -Fq 'env -i APP_STORE_CONNECT_API_KEY_P8=' "$ROOT_DIR/scripts/notarize-terminal-artifact.sh"; then
  fail 'notary helper exposes the P8 through argv'
fi
rg -Fq 'my $pem = <STDIN>' "$ROOT_DIR/scripts/notarize-terminal-artifact.sh" || \
  fail 'notary helper does not materialize the P8 from stdin'
rg -Fq 'all refuses fixture mode' "$wrapper" || fail 'all mode accepts fixture tools'
rg -Fq 'env -u OP_SERVICE_ACCOUNT_TOKEN -u MOLTY_OP_SERVICE_ACCOUNT_TOKEN' "$wrapper" || \
  fail 'credential loader service token reaches a phase child'
for architecture in arm64 x86_64; do
  rg -Fq "codesign -dvvv --arch $architecture" "$wrapper" || \
    fail "qualification Node omits $architecture signature inspection"
done

printf 'test-terminal-artifact-env: ok\n'
