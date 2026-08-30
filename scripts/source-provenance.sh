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

# Read-only receipts must be regular files, including when the caller owns them.
peekaboo_is_immutable_receipt() {
  local receipt="${1:?receipt required}" mode
  [[ -f "$receipt" && ! -L "$receipt" ]] || return 1
  mode="$(/usr/bin/stat -f '%Lp' "$receipt")" || return 1
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 0222) == 0 ))
}

# Expected values come from the caller's trusted checkout/build context, never
# from the candidate receipt. Signing and notarization remain caller-owned.
peekaboo_verify_playground_v2_receipt() {
  local receipt="${1:?receipt required}"
  peekaboo_is_immutable_receipt "$receipt" || return 1
  jq -se \
    --arg sourceCommit "${2:?source commit required}" \
    --arg sourceTree "${3:?source tree required}" \
    --arg lockPath "${4:?canonical lock path required}" \
    --arg lockSHA "${5:?canonical lock hash required}" \
    --arg marketingVersion "${6:?marketing version required}" \
    --arg developerDir "${7:?developer directory required}" \
    --arg xcodebuildVersion "${8:?Xcode version required}" \
    --arg sdkVersion "${9:?SDK version required}" \
    --arg swiftcVersion "${10:?Swift version required}" '
      length == 1 and (.[0] |
      type == "object" and keys == [
        "bundle_identifier", "configuration", "dependency_lock_path", "dependency_lock_sha256",
        "developer_dir", "marketing_version", "scheme", "sdk_version", "source_commit",
        "source_tree", "swiftc_version", "version", "workspace", "xcodebuild_version"
      ] and .version == 2 and .source_commit == $sourceCommit and .source_tree == $sourceTree and
      .dependency_lock_path == $lockPath and .dependency_lock_sha256 == $lockSHA and
      .workspace == "Apps/Peekaboo.xcworkspace" and .scheme == "Playground" and
      .configuration == "Debug" and .bundle_identifier == "boo.peekaboo.playground.debug" and
      .marketing_version == $marketingVersion and .developer_dir == $developerDir and
      .xcodebuild_version == $xcodebuildVersion and .sdk_version == $sdkVersion and
      .swiftc_version == $swiftcVersion)
    ' "$receipt" >/dev/null
}

# Check this boundary before general checkout cleanliness so lock failures are
# actionable, including an ignored/untracked or assume-unchanged resolver file.
peekaboo_playground_lock_sha256() {
  local root="${1:?repository root required}"
  local relative=Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved
  local lock="$root/$relative" competing digest committed_digest
  [[ -f "$lock" && ! -L "$lock" ]] || {
    echo 'Canonical Playground dependency lock missing or symlinked.' >&2; return 1;
  }
  git -C "$root" ls-files --error-unmatch "$relative" >/dev/null 2>&1 || {
    echo 'Canonical Playground dependency lock is not tracked.' >&2; return 1;
  }
  for competing in \
    Apps/Playground/Package.resolved \
    Apps/Playground/Playground.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; do
    [[ ! -e "$root/$competing" && ! -L "$root/$competing" ]] || {
      echo "Noncanonical Playground dependency lock: $competing" >&2; return 1;
    }
  done
  digest="$(shasum -a 256 "$lock" | awk '{print $1}')" || return 1
  committed_digest="$(git -C "$root" show "HEAD:$relative" | shasum -a 256 | awk '{print $1}')" || return 1
  [[ "$digest" == "$committed_digest" ]] &&
    git -C "$root" diff --quiet --cached HEAD -- "$relative" &&
    git -C "$root" diff --quiet -- "$relative" || {
      echo 'Canonical Playground dependency lock differs from HEAD.' >&2; return 1;
    }
  printf '%s\n' "$digest"
}
