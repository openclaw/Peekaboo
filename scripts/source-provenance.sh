#!/usr/bin/env bash

peekaboo_is_exact_source_commit() {
  [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]]
}

peekaboo_source_commit_from_repo() {
  local repository_root="${1:?repository root required}"
  local commit
  commit="$(git -C "$repository_root" rev-parse HEAD 2>/dev/null || true)"
  if peekaboo_is_exact_source_commit "$commit"; then
    printf '%s\n' "$commit"
  else
    printf '%s\n' unknown
  fi
}

peekaboo_require_source_commit() {
  local repository_root="${1:?repository root required}"
  local commit
  local checkout_status
  commit="$(peekaboo_source_commit_from_repo "$repository_root")"
  if ! peekaboo_is_exact_source_commit "$commit"; then
    printf 'Unable to resolve an exact source commit from %s\n' "$repository_root" >&2
    return 1
  fi
  if ! checkout_status="$(git -C "$repository_root" status \
    --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null)"; then
    printf 'Unable to verify checkout cleanliness: %s\n' "$repository_root" >&2
    return 1
  fi
  if [[ -n "$checkout_status" ]]; then
    printf 'Refusing to stamp a source commit for a dirty checkout: %s\n' "$repository_root" >&2
    return 1
  fi
  printf '%s\n' "$commit"
}

peekaboo_debug_source_commit() {
  local repository_root="${1:?repository root required}"
  local require_provenance="${PEEKABOO_REQUIRE_SOURCE_PROVENANCE:-0}"
  local commit
  case "$require_provenance" in
    0|false|no|off|'') ;;
    1|true|yes|on)
      peekaboo_require_source_commit "$repository_root"
      return
      ;;
    *)
      printf 'Invalid PEEKABOO_REQUIRE_SOURCE_PROVENANCE value: %s\n' "$require_provenance" >&2
      return 1
      ;;
  esac
  if commit="$(peekaboo_require_source_commit "$repository_root" 2>/dev/null)"; then
    printf '%s\n' "$commit"
  else
    printf '%s\n' unknown
  fi
}

peekaboo_verify_source_commit() {
  local repository_root="${1:?repository root required}"
  local expected_commit="${2:?expected source commit required}"
  local current_commit
  current_commit="$(peekaboo_require_source_commit "$repository_root")" || return 1
  if [[ "$current_commit" != "$expected_commit" ]]; then
    printf 'Source commit changed during the build: expected %s, found %s\n' \
      "$expected_commit" "$current_commit" >&2
    return 1
  fi
}

# Validates an embedded artifact stamp independently for verify-only workflows,
# or against the still-clean build checkout when an expected commit is supplied.
peekaboo_validate_artifact_source_commit() {
  local repository_root="${1:?repository root required}"
  local artifact_commit="${2:-}"
  local expected_commit="${3:-}"

  peekaboo_is_exact_source_commit "$artifact_commit" || return 2
  [[ -z "$expected_commit" ]] && return 0
  peekaboo_is_exact_source_commit "$expected_commit" || return 3
  peekaboo_verify_source_commit "$repository_root" "$expected_commit" || return 4
  [[ "$artifact_commit" == "$expected_commit" ]] || return 5
}

peekaboo_source_dirty_suffix() {
  local repository_root="${1:?repository root required}"
  local checkout_status
  if ! checkout_status="$(git -C "$repository_root" status \
    --porcelain=v1 --untracked-files=all --ignore-submodules=none 2>/dev/null)" || \
     [[ -n "$checkout_status" ]]; then
    printf '%s\n' -dirty
  fi
}

peekaboo_short_source_commit() {
  local commit="${1:-}"
  if peekaboo_is_exact_source_commit "$commit"; then
    printf '%.9s\n' "$commit"
  else
    printf '%s\n' unknown
  fi
}
