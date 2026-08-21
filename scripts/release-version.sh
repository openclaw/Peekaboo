#!/usr/bin/env bash

peekaboo_release_build_number() {
  local version=${1:?'version required'}
  local core prerelease major minor patch suffix prerelease_label prerelease_number
  core=${version%%-*}
  prerelease=
  if [[ "$version" == *-* ]]; then
    prerelease=${version#*-}
  fi
  IFS=. read -r major minor patch <<<"$core"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ || ! "$patch" =~ ^[0-9]+$ ]]; then
    printf 'ERROR: Version must be numeric semver: %s\n' "$version" >&2
    return 1
  fi
  if ((10#$minor > 99 || 10#$patch > 99)); then
    printf 'ERROR: Minor and patch versions must be <= 99: %s\n' "$version" >&2
    return 1
  fi

  suffix=99
  if [[ -n "$prerelease" ]]; then
    prerelease_label=${prerelease%%.*}
    prerelease_label=${prerelease_label%%-*}
    prerelease_label=${prerelease_label%%[0-9]*}
    prerelease_label="$(printf '%s' "$prerelease_label" | /usr/bin/tr '[:upper:]' '[:lower:]')"
    if [[ "$prerelease" =~ ([0-9]+)$ ]]; then
      prerelease_number=${BASH_REMATCH[1]}
    else
      prerelease_number=1
    fi
    if ((10#$prerelease_number < 1 || 10#$prerelease_number > 29)); then
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
