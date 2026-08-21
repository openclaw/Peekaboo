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
  GH_TOKEN
  GITHUB_TOKEN
  MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD
  MAC_RELEASE_SPARKLE_KEY_FILE
  MAC_RELEASE_SPARKLE_OP_REF
  MAC_RELEASE_SIGNING_KEY_FILE
  MOLTY_OP_SERVICE_ACCOUNT_TOKEN
  NODE_AUTH_TOKEN
  NOTARYTOOL_KEYCHAIN_PROFILE
  NOTARYTOOL_ISSUER
  NOTARYTOOL_KEY
  NOTARYTOOL_KEY_ID
  NOTARYTOOL_PROFILE
  NPM_CONFIG_USERCONFIG
  NPM_TOKEN
  OP_SERVICE_ACCOUNT_TOKEN
  SPARKLE_PRIVATE_KEY
  SPARKLE_PRIVATE_KEY_FILE
)

terminal_artifact_run_build() {
  local -a scrub_args=()
  local secret_name

  for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
    scrub_args+=(-u "$secret_name")
  done
  env "${scrub_args[@]}" "$@"
}

terminal_artifact_assert_build_env_is_clean() {
  local secret_name

  for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do
    if [[ -n "${!secret_name+x}" ]]; then
      printf 'Build environment contains forbidden credential variable: %s\n' "$secret_name" >&2
      return 1
    fi
  done
}
