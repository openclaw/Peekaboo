#!/usr/bin/env bash

# Credential names that must never reach dependency resolution, compilation, or linking.
# Signing/notarization children are launched separately after all build outputs are sealed.
TERMINAL_ARTIFACT_SECRET_NAMES=(
  APP_STORE_CONNECT_API_KEY_P8
  APP_STORE_CONNECT_ISSUER_ID
  APP_STORE_CONNECT_KEY_ID
  ASC_ISSUER_ID
  ASC_KEY_ID
  ASC_PRIVATE_KEY_P8
  BASH_ENV
  ENV
  DYLD_INSERT_LIBRARIES
  DYLD_LIBRARY_PATH
  GH_TOKEN
  GITHUB_TOKEN
  MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
  MAC_RELEASE_TOOL
  MAC_RELEASE_SPARKLE_KEY_FILE
  MAC_RELEASE_SPARKLE_OP_REF
  MAC_RELEASE_SIGNING_KEY_FILE
  MOLTY_OP_SERVICE_ACCOUNT_TOKEN
  NODE_AUTH_TOKEN
  NODE_OPTIONS
  NODE_PATH
  NOTARYTOOL_KEYCHAIN_PROFILE
  NOTARYTOOL_ISSUER
  NOTARYTOOL_KEY
  NOTARYTOOL_KEY_ID
  NOTARYTOOL_PROFILE
  NPM_CONFIG_USERCONFIG
  NPM_TOKEN
  OP_SERVICE_ACCOUNT_TOKEN
  PERL5LIB
  PERL5OPT
  PYTHONHOME
  PYTHONPATH
  RUBYLIB
  RUBYOPT
  SPARKLE_PRIVATE_KEY
  SPARKLE_PRIVATE_KEY_FILE
  ZDOTDIR
)

terminal_artifact_run_build() (
  local -a scrub_args=(-u PEEKABOO_OP_SERVICE_TOKEN_FILE -u PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE)
  local secret_name environment_name

  # Scrub before launching env: its loader sees inherited variables before -u runs.
  # The subshell keeps the caller's environment intact, including on child failure.
  builtin unset PEEKABOO_OP_SERVICE_TOKEN_FILE PEEKABOO_MOLTY_OP_SERVICE_TOKEN_FILE || return
  for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
    builtin unset "$secret_name" || return
    scrub_args+=(-u "$secret_name")
  done
  while IFS= read -r environment_name; do
    case "$environment_name" in
      BASH_FUNC_*|BASH_ENV|ENV|CDPATH|GLOBIGNORE)
        builtin unset "$environment_name" || return
        scrub_args+=(-u "$environment_name")
        ;;
    esac
  done < <(builtin compgen -v)
  /usr/bin/env "${scrub_args[@]}" PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin "$@"
)

terminal_artifact_run_orchestrator() (
  local -a scrub_args=()
  local secret_name environment_name
  for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
    builtin unset "$secret_name" || return
    scrub_args+=(-u "$secret_name")
  done
  while IFS= read -r environment_name; do
    case "$environment_name" in
      BASH_FUNC_*|BASH_ENV|ENV|CDPATH|GLOBIGNORE)
        builtin unset "$environment_name" || return
        scrub_args+=(-u "$environment_name")
        ;;
    esac
  done < <(builtin compgen -v)
  /usr/bin/env "${scrub_args[@]}" PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin "$@"
)

terminal_artifact_assert_build_env_is_clean() {
  local secret_name

  for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
    if [[ -n "${!secret_name+x}" ]]; then
      printf 'Build environment contains forbidden credential variable: %s\n' "$secret_name" >&2
      return 1
    fi
  done
}
