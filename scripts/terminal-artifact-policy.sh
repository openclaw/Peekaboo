#!/usr/bin/env bash

TERMINAL_ARTIFACT_BUILD_MANIFEST_KEYS_JSON='[
  "build_mode",
  "dependency_lock_path",
  "dependency_lock_sha256",
  "marketing_version",
  "release_helper",
  "source_commit",
  "toolchain",
  "unsigned_inputs",
  "version"
]'

terminal_artifact_assert_no_xattrs() {
  local target="$1"
  local names
  names="$(/usr/bin/xattr -r "$target")" || return 1
  [[ -z "$names" ]]
}

terminal_artifact_signature_details() {
  local target="$1"
  local architecture="${2:-}"
  if [[ -n "$architecture" ]]; then
    /usr/bin/codesign -dvvv --arch "$architecture" "$target" 2>&1
  else
    /usr/bin/codesign -dvvv "$target" 2>&1
  fi
}

terminal_artifact_signature_field_from_details() {
  local details="$1"
  local field="$2"
  /usr/bin/awk -F= -v field="$field" \
    '$1 == field && !seen { value = $2; seen = 1 } END { print value }' <<<"$details"
}

terminal_artifact_cdhash() {
  local details
  details="$(terminal_artifact_signature_details "$1" "${2:-}")" || return 1
  terminal_artifact_signature_field_from_details "$details" CDHash
}

terminal_artifact_tree_manifest() {
  local root_dir="$1"
  local output="$2"
  /usr/bin/ruby "${TERMINAL_ARTIFACT_ROOT:?}/scripts/artifact-tree-manifest.rb" "$root_dir" > "$output"
}

terminal_artifact_zip_has_appledouble() {
  /usr/bin/unzip -Z1 "$1" | /usr/bin/awk '
    /(^|\/)__MACOSX(\/|$)/ || /(^|\/)\._[^\/]+$/ { found = 1 }
    END { exit !found }
  '
}

terminal_artifact_zip_app_exact() {
  local app="$1"
  local zip_path="$2"
  local retained_tree="$3"
  local verify_dir extracted_app verify_tree

  terminal_artifact_assert_no_xattrs "$app" || {
    printf 'App contains unbound extended attributes: %s\n' "$app" >&2
    return 1
  }
  [[ ! -e "$zip_path" && ! -L "$zip_path" ]] || return 1
  [[ ! -e "$retained_tree" && ! -L "$retained_tree" ]] || return 1
  terminal_artifact_tree_manifest "$app" "$retained_tree" || return 1
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path" || return 1
  if terminal_artifact_zip_has_appledouble "$zip_path"; then
    printf 'Zip contains AppleDouble payload: %s\n' "$zip_path" >&2
    return 1
  fi

  verify_dir="$(mktemp -d /tmp/peekaboo-terminal-zip-verify.XXXXXX)" || return 1
  extracted_app="$verify_dir/$(basename "$app")"
  verify_tree="$verify_dir/tree.json"
  if ! /usr/bin/ditto -x -k "$zip_path" "$verify_dir" || \
     [[ ! -d "$extracted_app" ]] || \
     ! terminal_artifact_assert_no_xattrs "$extracted_app" || \
     ! terminal_artifact_tree_manifest "$extracted_app" "$verify_tree" || \
     ! /usr/bin/cmp -s "$retained_tree" "$verify_tree"; then
    rm -rf -- "$verify_dir"
    printf 'Zip roundtrip changed the signed app payload: %s\n' "$zip_path" >&2
    return 1
  fi
  rm -rf -- "$verify_dir"
}
