#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/release-version.sh
source "$ROOT_DIR/scripts/release-version.sh"

fail() {
  printf 'test-release-version: %s\n' "$*" >&2
  exit 1
}

[[ "$(peekaboo_release_build_number 4.2.3)" == 4020399 ]] || fail 'stable build number changed'
[[ "$(peekaboo_release_build_number 4.2.3-alpha.2)" == 4020302 ]] || fail 'alpha build number changed'
[[ "$(peekaboo_release_build_number 4.2.3-beta.2)" == 4020332 ]] || fail 'beta build number changed'
[[ "$(peekaboo_release_build_number 4.2.3-rc.2)" == 4020362 ]] || fail 'rc build number changed'
if peekaboo_release_build_number 4.2.3-preview.1 >/dev/null 2>&1; then
  fail 'unknown prerelease label was accepted'
fi
if peekaboo_release_build_number 4.2.3-beta.30 >/dev/null 2>&1; then
  fail 'out-of-range prerelease was accepted'
fi

# Unsupported prerelease forms must not alias a different published build.
for invalid_version in 4.2.3- 4.2.3-beta.1.2 4.2.3-beta.foo.2 4.2.3-beta. \
  04.2.3 4.02.3 4.2.03 4.2.3-beta.02 4.2.3-beta.999999999999999999999 \
  999999999999999999999.2.3; do
  if peekaboo_release_build_number "$invalid_version" >/dev/null 2>&1; then
    fail "invalid or overflowing release version was accepted: $invalid_version"
  fi
done
[[ "$(peekaboo_release_build_number 4.2.3-beta)" == 4020331 ]] || fail 'unnumbered beta changed'
[[ "$(peekaboo_release_build_number 4.2.3-beta2)" == 4020332 ]] || fail 'compact beta changed'
[[ "$(peekaboo_release_build_number 4.2.3-beta-2)" == 4020332 ]] || fail 'hyphenated beta changed'

"$ROOT_DIR/scripts/validate-release-version-surfaces.sh" >/dev/null
printf 'test-release-version: ok\n'
