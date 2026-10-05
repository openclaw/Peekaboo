#!/usr/bin/env bash

peekaboo_release_build_number() {
  local version=${1:?'version required'}
  local prerelease major minor patch suffix prerelease_label prerelease_number
  # Parse the complete supported version, so extra identifiers cannot alias a
  # different prerelease's build number. Retain beta2/beta-2 legacy spellings.
  if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([A-Za-z]+)([.-]?([1-9][0-9]*))?)?$ ]]; then
    printf 'ERROR: Version must be numeric semver with a supported prerelease: %s\n' "$version" >&2
    return 1
  fi
  major=${BASH_REMATCH[1]}
  minor=${BASH_REMATCH[2]}
  patch=${BASH_REMATCH[3]}
  prerelease=${BASH_REMATCH[4]}
  prerelease_label=${BASH_REMATCH[5]}
  prerelease_number=${BASH_REMATCH[7]:-1}
  # Check lengths before evaluating shell arithmetic, which otherwise wraps
  # oversized decimal strings. This bound leaves room for every suffix.
  if [[ ${#major} -gt 13 || ${#minor} -gt 2 || ${#patch} -gt 2 ]] ||
    ((10#$major > 9223372036853)); then
    printf 'ERROR: Version components exceed the build number range: %s\n' "$version" >&2
    return 1
  fi

  suffix=99
  if [[ -n "$prerelease" ]]; then
    prerelease_label="$(printf '%s' "$prerelease_label" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    if [[ ${#prerelease_number} -gt 2 ]] || ((10#$prerelease_number > 29)); then
      printf 'ERROR: Prerelease number must be 1..29: %s\n' "$version" >&2
      return 1
    fi
    case "$prerelease_label" in
      alpha|a) suffix=$((10#$prerelease_number)) ;;
      beta|b) suffix=$((30 + 10#$prerelease_number)) ;;
      rc) suffix=$((60 + 10#$prerelease_number)) ;;
      *)
        printf 'ERROR: Prerelease label must be alpha, beta, or rc: %s\n' "$version" >&2
        return 1
        ;;
    esac
  fi

  printf '%d\n' $((((10#$major * 100 + 10#$minor) * 100 + 10#$patch) * 100 + 10#$suffix))
}
