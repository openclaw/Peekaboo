#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/release-version.sh
source "${PEEKABOO_RELEASE_VERSION_HELPER:-$ROOT_DIR/scripts/release-version.sh}"

fail() {
  printf 'test-release-version: %s\n' "$*" >&2
  exit 1
}

valid_cases=0
invalid_cases=0
expect_build() {
  local actual
  actual="$(peekaboo_release_build_number "$1")" || fail "supported version rejected: $1"
  [[ "$actual" == "$2" ]] || fail "wrong build number for $1: $actual (expected $2)"
  valid_cases=$((valid_cases + 1))
}

expect_build 0.0.0 99
expect_build 4.2.3 4020399
expect_build 4.99.99 4999999
expect_build 9223372036853.99.99 9223372036853999999
expect_build 9223372036853.99.99-RC.29 9223372036853999989

for label in alpha ALPHA AlPhA a A beta BETA BeTa b B rc RC Rc rC; do
  case "$label" in
    alpha|ALPHA|AlPhA|a|A) offset=0 ;;
    beta|BETA|BeTa|b|B) offset=30 ;;
    *) offset=60 ;;
  esac
  expect_build "4.2.3-$label" "$((4020300 + offset + 1))"
  for separator in '' '.' '-'; do
    expect_build "4.2.3-$label${separator}1" "$((4020300 + offset + 1))"
    expect_build "4.2.3-$label${separator}2" "$((4020300 + offset + 2))"
    expect_build "4.2.3-$label${separator}29" "$((4020300 + offset + 29))"
  done
done

# Unsupported prerelease forms must not alias a different published build.
for invalid_version in 4.2.3- 4.2.3-beta.1.2 4.2.3-beta.foo.2 4.2.3-beta. \
  04.2.3 4.02.3 4.2.03 4.2.3-beta.02 4.2.3-beta.999999999999999999999 \
  999999999999999999999.2.3 9223372036854.0.0 4.100.0 4.0.100 \
  4.2.3-alpha.30 4.2.3-beta.30 4.2.3-RC.30 4.2.3-beta.0 \
  4.2.3-preview.1 4.2.3-beta-1.2 4.2.3+local 4..3 ' 4.2.3' $'4.2.3\n'; do
  if actual="$(peekaboo_release_build_number "$invalid_version" 2>/dev/null)"; then
    fail "invalid or overflowing release version was accepted: $invalid_version"
  fi
  [[ -z "$actual" ]] || fail "rejected version emitted a build number: $invalid_version"
  invalid_cases=$((invalid_cases + 1))
done

"$ROOT_DIR/scripts/validate-release-version-surfaces.sh" >/dev/null
printf 'test-release-version: ok (%d supported, %d rejected)\n' "$valid_cases" "$invalid_cases"
