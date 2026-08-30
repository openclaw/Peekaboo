#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"

TEST_DIR="$(mktemp -d /tmp/peekaboo-terminal-env-test.XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
  printf 'test-terminal-artifact-env: %s\n' "$*" >&2
  exit 1
}

cat > "$TEST_DIR/probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
printf 'entered\n' > "$2/child-entered"
assertion=protected-variables
trap 'printf "terminal-env-probe: assertion=%s tool=%s exit=%s\n" "$assertion" "${tool:-none}" "$?" >&2' ERR
terminal_artifact_assert_build_env_is_clean
for name in CDPATH GLOBIGNORE BASH_FUNC_terminal_fixture; do
  assertion="unset-$name"
  [[ -z "${!name+x}" ]]
done
assertion=exact-trusted-path
[[ "$PATH" == /opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin ]]
assertion=allowed-values
[[ "$HOME" == "$2/home" && "$TMPDIR" == "$2/tmp" ]]
[[ "$DEVELOPER_DIR" == "$2/developer" ]]
[[ "$MAC_RELEASE_CODESIGN_KEYCHAIN" == "$2/keychain" && "$CODESIGN_KEYCHAIN" == "$2/keychain" ]]
[[ "$CODESIGN_IDENTITY" == fixture-identity ]]
[[ "$SWIFTPM_MIRROR_CONFIG" == "$2/verified-source-mapping.json" ]]
[[ "$PEEKABOO_USE_RESOLVED_VERSIONS" == 1 && "$TERMINAL_FIXTURE_ALLOWED" == $'allowed value\nsecond line' ]]
assertion=tool-resolution
for tool in node pnpm npm python3 git codesign bash "peekaboo-rejected-${2##*.}" "peekaboo-absent-${2##*.}"; do
  # This checks the environment boundary, not the host's build-tool readiness.
  if resolved="$(command -v "$tool")"; then
    case "$resolved" in
      /opt/homebrew/bin/*|/usr/local/bin/*|/usr/bin/*|/bin/*) ;;
      *) printf 'terminal-env-probe: tool=%s unsafe-resolution\n' "$tool" >&2; exit 94 ;;
    esac
    [[ "$tool" != peekaboo-rejected-* && "$tool" != peekaboo-absent-* ]]
    printf 'tool=%s resolution=trusted\n' "$tool"
  else
    lookup_exit=$?
    [[ "$lookup_exit" == 1 && "$tool" != bash ]]
    printf 'tool=%s resolution=unavailable safe-refusal=true\n' "$tool"
  fi
done
assertion=custody
if [[ "$3" == build ]]; then
  [[ -z "${PEEKABOO_OP_SERVICE_TOKEN_FILE+x}" && -z "${PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE+x}" ]]
else
  [[ "$PEEKABOO_OP_SERVICE_TOKEN_FILE" == "$2/primary-custody" ]]
  [[ "$PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE" == "$2/legacy-custody" ]]
fi
assertion=arguments
[[ "$5" == 'argument one' && "$6" == 'argument=two' ]]
printf 'child-clean=true allowed-values-preserved=true arguments-preserved=true\n'
exit "$4"
EOF
chmod 755 "$TEST_DIR/probe"
mkdir -p "$TEST_DIR/hostile-bin"
cat > "$TEST_DIR/hostile-bin/env" <<'EOF'
#!/bin/sh
printf 'invoked\n' > "${HOSTILE_ENV_MARKER:?}"
exit 97
EOF
chmod 755 "$TEST_DIR/hostile-bin/env"
for tool in codesign node pnpm npm python3 git bash "peekaboo-rejected-${TEST_DIR##*.}"; do
  cp "$TEST_DIR/hostile-bin/env" "$TEST_DIR/hostile-bin/$tool"
done

startup_marker="$TEST_DIR/startup-marker"
printf 'printf "startup" > %q\n' "$startup_marker" > "$TEST_DIR/hostile-bash-env"
# Prove the harmless hook is effective before testing that it is stripped.
BASH_ENV="$TEST_DIR/hostile-bash-env" /bin/bash --noprofile --norc -c ':'
[[ -f "$startup_marker" && "$(<"$startup_marker")" == startup ]] || fail 'startup-hook control did not execute'
rm "$startup_marker"

run_dirty_fixture() (
  local lane="$1" child_exit="$2" secret_name
  for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
    printf -v "$secret_name" sentinel
    export "${secret_name?}"
  done
  export BASH_ENV="$TEST_DIR/hostile-bash-env" ENV="$TEST_DIR/hostile-bash-env"
  export CDPATH=sentinel GLOBIGNORE=sentinel BASH_FUNC_terminal_fixture=sentinel
  export PEEKABOO_OP_SERVICE_TOKEN_FILE="$TEST_DIR/primary-custody"
  export PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE="$TEST_DIR/legacy-custody"
  export HOME="$TEST_DIR/home" TMPDIR="$TEST_DIR/tmp" DEVELOPER_DIR="$TEST_DIR/developer"
  export MAC_RELEASE_CODESIGN_KEYCHAIN="$TEST_DIR/keychain" CODESIGN_KEYCHAIN="$TEST_DIR/keychain"
  export CODESIGN_IDENTITY=fixture-identity SWIFTPM_MIRROR_CONFIG="$TEST_DIR/verified-source-mapping.json"
  export PEEKABOO_USE_RESOLVED_VERSIONS=1 TERMINAL_FIXTURE_ALLOWED=$'allowed value\nsecond line'
  export HOSTILE_ENV_MARKER="$TEST_DIR/hostile-env-marker"
  PATH="$TEST_DIR/hostile-bin:$PATH"
  local parent_path="$PATH"
  [[ "$(command -v codesign)" == "$TEST_DIR/hostile-bin/codesign" ]] || return 94
  [[ "$(command -v "peekaboo-rejected-${TEST_DIR##*.}")" == "$TEST_DIR/hostile-bin/peekaboo-rejected-${TEST_DIR##*.}" ]] || return 94
  if command -v "peekaboo-absent-${TEST_DIR##*.}" >/dev/null; then return 94; fi

  # Observe shell state before the native loader can strip DYLD variables for us.
  # Forward to the real executable so the child environment is also verified.
  # shellcheck disable=SC2329 # Called indirectly by the sourced sanitizer.
  /usr/bin/env() {
    local name
    printf 'entered\n' > "$TEST_DIR/env-entered"
    for name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}" CDPATH GLOBIGNORE BASH_FUNC_terminal_fixture; do
      [[ -z "${!name+x}" ]] || { printf 'pre-exec variable remains: %s\n' "$name" >&2; return 91; }
    done
    if [[ "$lane" == build ]]; then
      [[ -z "${PEEKABOO_OP_SERVICE_TOKEN_FILE+x}" && -z "${PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE+x}" ]] || return 92
    else
      [[ "$PEEKABOO_OP_SERVICE_TOKEN_FILE" == "$TEST_DIR/primary-custody" &&
         "$PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE" == "$TEST_DIR/legacy-custody" ]] || return 92
    fi
    command /usr/bin/env "$@"
  }

  local result=0
  "terminal_artifact_run_$lane" "$TEST_DIR/probe" "$ROOT_DIR/scripts/terminal-artifact-env.sh" \
    "$TEST_DIR" "$lane" "$child_exit" 'argument one' 'argument=two' || result=$?
  # Sanitizing a child must not mutate its caller, even after a failed command.
  for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
    case "$secret_name" in
      BASH_ENV|ENV) [[ "${!secret_name}" == "$TEST_DIR/hostile-bash-env" ]] || return 93 ;;
      *) [[ "${!secret_name}" == sentinel ]] || return 93 ;;
    esac
  done
  [[ "$PEEKABOO_OP_SERVICE_TOKEN_FILE" == "$TEST_DIR/primary-custody" &&
     "$PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE" == "$TEST_DIR/legacy-custody" ]] || return 93
  [[ "$PATH" == "$parent_path" && "$(command -v codesign)" == "$TEST_DIR/hostile-bin/codesign" &&
     "$MAC_RELEASE_CODESIGN_KEYCHAIN" == "$TEST_DIR/keychain" && "$CODESIGN_KEYCHAIN" == "$TEST_DIR/keychain" &&
     "$CODESIGN_IDENTITY" == fixture-identity &&
     "$SWIFTPM_MIRROR_CONFIG" == "$TEST_DIR/verified-source-mapping.json" ]] || return 93
  return "$result"
)

for lane in build orchestrator; do
  for child_exit in 0 37; do
    rm -f "$TEST_DIR/env-entered" "$TEST_DIR/child-entered"
    fixture_exit=0
    run_dirty_fixture "$lane" "$child_exit" > "$TEST_DIR/probe-output" || fixture_exit=$?
    cat "$TEST_DIR/probe-output"
    [[ -e "$TEST_DIR/env-entered" ]] || fail "$lane did not reach the pre-exec boundary (exit $fixture_exit)"
    [[ -e "$TEST_DIR/child-entered" ]] || fail "$lane did not reach the child assertion (exit $fixture_exit)"
    [[ "$fixture_exit" == "$child_exit" ]] || fail "$lane changed child exit $child_exit to $fixture_exit"
    [[ "$(<"$TEST_DIR/probe-output")" == *$'\nchild-clean=true allowed-values-preserved=true arguments-preserved=true' ]] || \
      fail "$lane child environment assertion failed"
    [[ ! -e "$TEST_DIR/hostile-env-marker" ]] || fail "$lane resolved env through hostile PATH"
    [[ ! -e "$startup_marker" ]] || fail "$lane processed a startup hook"
    # This runs outside the poisoned subshell, including after the exit-37 case.
    mkdir "$TEST_DIR/cleanup-probe"
    rm -rf "$TEST_DIR/cleanup-probe"
    [[ ! -e "$TEST_DIR/cleanup-probe" ]] || fail "$lane left cleanup poisoned"
    printf 'test-terminal-artifact-env: %s exit=%s pre-exec-clean=true child-clean=true cleanup-clean=true\n' \
      "$lane" "$fixture_exit"
  done
done

# Safe lookup refusal must still fail when a caller actually needs the command.
for lane in build orchestrator; do
  for availability in rejected absent; do
    missing_tool="peekaboo-$availability-${TEST_DIR##*.}"
    command_exit=0
    PATH="$TEST_DIR/hostile-bin:$PATH" "terminal_artifact_run_$lane" "$missing_tool" \
      > "$TEST_DIR/missing-output" 2>&1 || command_exit=$?
    [[ "$command_exit" == 127 ]] || fail "$lane $availability command exit=$command_exit (expected 127)"
    [[ ! -e "$TEST_DIR/hostile-env-marker" ]] || fail "$lane invoked the rejected command"
    printf 'test-terminal-artifact-env: %s tool-case=%s actual-command-exit=127 safe-refusal=true\n' "$lane" "$availability"
  done
done

# Check every name independently, including forbidden variables set to empty.
for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
  for marker_value in sentinel ''; do
    assertion_exit=0
    (
      for protected_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
        builtin unset "$protected_name"
      done
      printf -v "$secret_name" '%s' "$marker_value"
      terminal_artifact_assert_build_env_is_clean
    ) > "$TEST_DIR/assertion-output" 2>&1 || assertion_exit=$?
    [[ "$assertion_exit" == 1 ]] || fail "dirty $secret_name was not detected (exit $assertion_exit)"
    [[ "$(<"$TEST_DIR/assertion-output")" == "Build environment contains forbidden credential variable: $secret_name" ]] || \
      fail "dirty $secret_name did not reach the intended assertion"
  done
done

# Use the real entrypoint and source libraries in an isolated fixture tree. Its
# helper lookup must fail closed without consulting an operator's helper checkout.
entry_root="$TEST_DIR/entrypoint"
mkdir -p "$entry_root/scripts" "$TEST_DIR/entry-home" "$TEST_DIR/entry-tmp"
sed "s|/tmp/peekaboo-|$TEST_DIR/entry-tmp/peekaboo-|g" \
  "$ROOT_DIR/scripts/build-terminal-artifacts.sh" > "$entry_root/scripts/build-terminal-artifacts.sh"
for library in source-provenance terminal-artifact-env terminal-artifact-policy native-only-policy release-version; do
  cp "$ROOT_DIR/scripts/$library.sh" "$entry_root/scripts/"
done
entry_wrapper="$entry_root/scripts/build-terminal-artifacts.sh"
chmod 755 "$entry_wrapper"

function_marker="$TEST_DIR/imported-function-marker"
FUNCTION_MARKER="$function_marker" HOME="$TEST_DIR/entry-home" /bin/bash --noprofile --norc -c '
  dirname() { printf "invoked\n" > "$FUNCTION_MARKER"; }
  export -f dirname
  result=0
  BASH_ENV="$2" OP_SERVICE_ACCOUNT_TOKEN=sentinel "$1" check-helper > "$3" 2>&1 || result=$?
  [[ "$result" == 1 && "$(<"$3")" == "Service-token invocation refuses an exported-function environment." ]]
' bash "$entry_wrapper" "$TEST_DIR/hostile-bash-env" "$TEST_DIR/function-rejection"
[[ ! -e "$function_marker" ]] || fail 'entrypoint invoked an imported function with service authority'
[[ ! -e "$startup_marker" ]] || fail 'entrypoint processed BASH_ENV with service authority'

caller_owned_token_file="$TEST_DIR/caller-owned-token"
printf 'caller-owned\n' > "$caller_owned_token_file"
helper_exit=0
HOME="$TEST_DIR/entry-home" PEEKABOO_OP_SERVICE_TOKEN_FILE="$caller_owned_token_file" \
  "$entry_wrapper" check-helper > "$TEST_DIR/helper-output" 2>&1 || helper_exit=$?
[[ "$helper_exit" == 1 && "$(<"$TEST_DIR/helper-output")" == \
  'build-terminal-artifacts: trusted mac-release helper is missing' ]] || \
  fail 'isolated non-all child did not reach the missing-helper boundary'
[[ "$(cat "$caller_owned_token_file")" == caller-owned ]] || \
  fail 'non-all child deleted or changed its caller-owned token custody file'

before_token_files="$TEST_DIR/token-files-before"
after_token_files="$TEST_DIR/token-files-after"
find "$TEST_DIR/entry-tmp" -maxdepth 1 -type f -name 'peekaboo-op-token.*' -print | sort > "$before_token_files"
caller_owned_molty_file="$TEST_DIR/caller-owned-molty-token"
printf 'caller-owned-molty\n' > "$caller_owned_molty_file"
custody_exit=0
HOME="$TEST_DIR/entry-home" OP_SERVICE_ACCOUNT_TOKEN=first-token MOLTY_OP_SERVICE_ACCOUNT_TOKEN=second-token \
  PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE="$caller_owned_molty_file" \
  "$entry_wrapper" check-helper > "$TEST_DIR/custody-output" 2>&1 || custody_exit=$?
[[ "$custody_exit" == 1 && "$(<"$TEST_DIR/custody-output")" == 'Conflicting legacy service-token custody.' ]] || \
  fail 'conflicting second-token custody did not reach its intended assertion'
find "$TEST_DIR/entry-tmp" -maxdepth 1 -type f -name 'peekaboo-op-token.*' -print | sort > "$after_token_files"
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
sed "s|/tmp/peekaboo-|$TEST_DIR/entry-tmp/peekaboo-|g" \
  "$release_wrapper" > "$entry_root/scripts/mac-release"
release_wrapper="$entry_root/scripts/mac-release"
chmod 755 "$release_wrapper"
cat > "$TEST_DIR/release-helper-probe" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${OP_SERVICE_ACCOUNT_TOKEN:-}" == primary && "${MOLTY_OP_SERVICE_ACCOUNT_TOKEN:-}" == legacy ]]
printf 'service-tokens-preserved=true\n'
EOF
chmod 755 "$TEST_DIR/release-helper-probe"
/bin/bash --noprofile --norc -c '
  hostile_release_function() { return 97; }
  export -f hostile_release_function
  result=0
  OP_SERVICE_ACCOUNT_TOKEN=primary MOLTY_OP_SERVICE_ACCOUNT_TOKEN=legacy \
    MAC_RELEASE_TOOL="$2" "$1" > "$3" 2>&1 || result=$?
  [[ "$result" == 1 && "$(<"$3")" == "Service-token invocation refuses an exported-function environment." ]]
' bash "$release_wrapper" "$TEST_DIR/release-helper-probe" "$TEST_DIR/release-function-rejection" || \
  fail 'credential-bearing release wrapper did not reject the exported-function environment'
release_probe_output="$(OP_SERVICE_ACCOUNT_TOKEN=primary MOLTY_OP_SERVICE_ACCOUNT_TOKEN=legacy \
  MAC_RELEASE_TOOL="$TEST_DIR/release-helper-probe" \
  /usr/bin/env -u BASH_FUNC_raw_exported_probe%% "$release_wrapper")"
[[ "$release_probe_output" == service-tokens-preserved=true ]] || \
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
  rg -Fq 'SWIFT_RESOLUTION_ARGS=(--only-use-versions-from-resolved-file)' "$ROOT_DIR/$build_script" || \
    fail "$build_script omits fail-closed Swift dependency resolution"
  if rg -Fq -- '--skip-update' "$ROOT_DIR/$build_script"; then
    fail "$build_script uses deprecated Swift dependency resolution flags"
  fi
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

/bin/bash "$ROOT_DIR/scripts/test-swift-build-target.sh"

printf 'test-terminal-artifact-env: ok\n'
