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

"$ROOT_DIR/scripts/validate-release-version-surfaces.sh" >/dev/null
printf 'test-release-version: ok\n'
