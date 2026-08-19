#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_LOCK="$ROOT_DIR/Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved"
MAC_LOCK="$ROOT_DIR/Apps/Mac/Package.resolved"
EXPECTED_SPARKLE_VERSION=2.9.5
EXPECTED_SPARKLE_REVISION=79bc9e872948e47877e76f194cb0c8e0412b0b90
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/peekaboo-release-resolution-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
  printf 'test-release-package-resolution: %s\n' "$*" >&2
  exit 1
}

git -C "$ROOT_DIR" ls-files --error-unmatch \
  Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved >/dev/null || \
  fail 'canonical Xcode workspace Package.resolved is not tracked'
if git -C "$ROOT_DIR" ls-files --error-unmatch Apps/CLI/Package.resolved >/dev/null 2>&1; then
  fail 'the mutable Swift CLI Package.resolved must not own the Xcode workspace graph'
fi

jq -e '.version == 3 and (.pins | type == "array") and (.pins | length > 0)' "$WORKSPACE_LOCK" >/dev/null || \
  fail 'workspace lock is not a nonempty version-3 Package.resolved file'
jq -e '.version == 3 and (.pins | type == "array") and (.pins | length > 0)' "$MAC_LOCK" >/dev/null || \
  fail 'Mac package lock is not a nonempty version-3 Package.resolved file'

for lock in "$WORKSPACE_LOCK" "$MAC_LOCK"; do
  duplicate_count="$(jq '[.pins | group_by(.identity)[] | select(length != 1)] | length' "$lock")"
  [[ "$duplicate_count" == 0 ]] || fail "duplicate package identities in $lock"
done

sparkle_pin="$(jq -r \
  '[.pins[] | select(.identity == "sparkle") | .state | [.version, .revision] | @tsv] | if length == 1 then .[0] else empty end' \
  "$WORKSPACE_LOCK")"
[[ "$sparkle_pin" == "$EXPECTED_SPARKLE_VERSION"$'\t'"$EXPECTED_SPARKLE_REVISION" ]] || \
  fail "workspace Sparkle pin changed: ${sparkle_pin:-<missing-or-duplicate>}"

lock_mismatches="$(jq -nr --slurpfile workspace "$WORKSPACE_LOCK" --slurpfile mac "$MAC_LOCK" '
  [
    $mac[0].pins[] as $macPin
    | [$workspace[0].pins[] | select(.identity == $macPin.identity)] as $matches
    | select(($matches | length) != 1 or $matches[0].kind != $macPin.kind or
        $matches[0].state != $macPin.state)
    | $macPin.identity
  ]
  | join(",")
')"
[[ -z "$lock_mismatches" ]] || fail "workspace and Mac locks disagree: $lock_mismatches"

for flag in \
  -disableAutomaticPackageResolution \
  -onlyUsePackageVersionsFromResolvedFile \
  -skipPackageUpdates; do
  rg -Fq -- "$flag" "$ROOT_DIR/scripts/release-macos-app.sh" || \
    fail "release build is missing $flag"
  rg -Fq -- "$flag" "$ROOT_DIR/.github/workflows/macos-ci.yml" || \
    fail "mac-app CI build is missing $flag"
done

rg -Fq 'Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved' "$ROOT_DIR/.gitignore" || \
  fail 'canonical workspace lock is not explicitly unignored'
rg -Fq 'test ! -e CLI/Package.resolved' "$ROOT_DIR/.github/workflows/macos-ci.yml" || \
  fail 'mac-app CI does not reject an ignored CLI-owned workspace lock'
rg -Fq 'SourcePackages/checkouts/Sparkle rev-parse HEAD' "$ROOT_DIR/.github/workflows/macos-ci.yml" || \
  fail 'mac-app CI does not verify the checked-out Sparkle revision'

release_source="$ROOT_DIR/scripts/release-macos-app.sh"
payload_line="$(rg -n '^verify_app_payload "\$APP_BUNDLE"$' "$release_source" | cut -d: -f1)"
resolution_line="$(rg -n -F 'verify-release-package-resolution.sh' "$release_source" | cut -d: -f1)"
signing_line="$(rg -n '^log "Developer ID signing"$' "$release_source" | cut -d: -f1)"
[[ -n "$payload_line" && -n "$resolution_line" && -n "$signing_line" && \
  "$payload_line" -lt "$resolution_line" && "$resolution_line" -lt "$signing_line" ]] || \
  fail 'release package resolution must run after app provenance validation and before signing'

fixture_root="$TEST_DIR/source"
fixture_derived="$TEST_DIR/Derived Data"
fixture_app="$fixture_derived/Build/Products/Release/Peekaboo.app"
fixture_workspace_lock="$fixture_root/Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved"
fixture_cli_lock="$fixture_root/Apps/CLI/Package.resolved"
fixture_sparkle_info="$fixture_app/Contents/Frameworks/Sparkle.framework/Versions/B/Resources/Info.plist"
fixture_checkout="$fixture_derived/SourcePackages/checkouts/Sparkle"
mkdir -p \
  "$(dirname "$fixture_workspace_lock")" \
  "$(dirname "$fixture_cli_lock")" \
  "$(dirname "$fixture_sparkle_info")" \
  "$fixture_checkout"
cat >"$fixture_workspace_lock" <<EOF
{
  "pins": [{
    "identity": "sparkle",
    "state": {
      "revision": "$EXPECTED_SPARKLE_REVISION",
      "version": "$EXPECTED_SPARKLE_VERSION"
    }
  }],
  "version": 3
}
EOF
cat >"$fixture_cli_lock" <<'EOF'
{"pins": [], "version": 3}
EOF
ln -s B "$fixture_app/Contents/Frameworks/Sparkle.framework/Versions/Current"

write_sparkle_info() {
  local version="$1"

  cat >"$fixture_sparkle_info" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>$version</string></dict></plist>
EOF
}

cat >"$TEST_DIR/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PACKAGE_RESOLUTION_TEST_REVISION"
EOF
chmod 755 "$TEST_DIR/git"

verify_fixture() {
  MAC_RELEASE_GIT_BIN="$TEST_DIR/git" \
    "$ROOT_DIR/scripts/verify-release-package-resolution.sh" \
    --source-root "$fixture_root" \
    --derived-data "$fixture_derived" \
    --app "$fixture_app"
}

assert_fixture_refused() {
  local label="$1"
  local expected_error="$2"

  if verify_fixture >"$TEST_DIR/$label.out" 2>"$TEST_DIR/$label.err"; then
    fail "$label unexpectedly passed release resolution verification"
  fi
  grep -Fq "$expected_error" "$TEST_DIR/$label.err" || fail "$label returned the wrong refusal"
}

export PACKAGE_RESOLUTION_TEST_REVISION="$EXPECTED_SPARKLE_REVISION"
write_sparkle_info "$EXPECTED_SPARKLE_VERSION"
verify_fixture >/dev/null

write_sparkle_info 2.9.6
assert_fixture_refused embedded-version 'does not match locked version'
write_sparkle_info "$EXPECTED_SPARKLE_VERSION"

export PACKAGE_RESOLUTION_TEST_REVISION=0123456789abcdef0123456789abcdef01234567
assert_fixture_refused checkout-revision 'does not match locked revision'
export PACKAGE_RESOLUTION_TEST_REVISION="$EXPECTED_SPARKLE_REVISION"

rm -f "$fixture_cli_lock"
ln -s "$fixture_workspace_lock" "$fixture_cli_lock"
assert_fixture_refused cli-lock-symlink 'Ignored CLI package lock is not a regular file'

printf 'test-release-package-resolution: ok\n'
