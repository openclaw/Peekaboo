#!/usr/bin/env bash
# Sourced by test-build-playground-artifact.sh after the real producer runs.
# All candidate changes below are deliberate corruptions of disposable fixtures.

COMPATIBILITY_SOURCE_ROOT="$ROOT_DIR"
export FIXTURE_FORBIDDEN_LOG="$TEST_DIR/forbidden-operations.log"
export FIXTURE_SIGNATURE_LOG="$TEST_DIR/signature-checks.log"
export FIXTURE_VERIFY_ONLY=1
mkdir -p "$TEST_DIR/forbidden-tools"
for tool in swiftc open security peekaboo codesign xcodebuild; do
  cat > "$TEST_DIR/forbidden-tools/$tool" <<'EOF'
#!/bin/bash
echo "unexpected operation: $0 $*" >> "${FIXTURE_FORBIDDEN_LOG:?}"
exit 90
EOF
  chmod 755 "$TEST_DIR/forbidden-tools/$tool"
done
export PATH="$TEST_DIR/forbidden-tools:$PATH"
cat > "$TEST_DIR/codesign-verifier" <<'EOF'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "${FIXTURE_SIGNATURE_LOG:?}"
requirement='-R=anchor apple generic and certificate leaf[subject.OU] = "FWJYW4S8P8" and certificate leaf[subject.CN] = "Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)" and identifier "boo.peekaboo.playground.debug"'
if [[ $# == 5 && "$1" == --verify && "$2" == --deep && "$3" == --strict && "$4" == "$requirement" ]]; then
  [[ "${FIXTURE_SIGNATURE_FAILURE:-}" != invalid && "${FIXTURE_SIGNATURE_FAILURE:-}" != adhoc ]] || exit 1
  [[ "$(cat "$5/Contents/_CodeSignature/CodeResources")" == 'synthetic signature resource seal' ]] || exit 1
  [[ "$(cat "$5/Contents/Resources/fixture.txt")" == 'fixture resource' ]] || exit 1
elif [[ $# == 3 && "$1" == -dv && "$2" == --verbose=2 ]]; then
  team=FWJYW4S8P8
  identifier=boo.peekaboo.playground.debug
  authority='Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)'
  case "${FIXTURE_SIGNATURE_FAILURE:-}" in
    team) team=WRONGTEAM1 ;;
    identifier) identifier=wrong.identifier ;;
    authority) authority='Developer ID Application: Someone Else (FWJYW4S8P8)' ;;
    adhoc-details) team='not set'; authority='' ;;
  esac
  printf 'Identifier=%s\nAuthority=%s\nAuthority=Apple Root CA\nTeamIdentifier=%s\n' "$identifier" "$authority" "$team"
else
  echo "unexpected codesign operation/omitted verification: $*" >> "${FIXTURE_FORBIDDEN_LOG:?}"
  exit 90
fi
EOF
chmod 755 "$TEST_DIR/codesign-verifier"

native_validate() {
  env PEEKABOO_PLAYGROUND_TEST_MODE=1 \
    PEEKABOO_PLAYGROUND_CODESIGN_BIN="$TEST_DIR/codesign-verifier" \
    PEEKABOO_PLAYGROUND_XCODEBUILD_BIN="$TEST_DIR/xcodebuild" \
    PEEKABOO_PLAYGROUND_XCRUN_BIN="$TEST_DIR/xcrun" \
    PEEKABOO_PLAYGROUND_XCODE_SELECT_BIN="$TEST_DIR/xcode-select" \
    "$FIXTURE_ROOT/scripts/test-background-computer-use.sh" \
    --validate-playground-only --playground-app "$1" --skip-playground-build
}

shared_validate() {
  peekaboo_verify_playground_v2_receipt "$1/Contents/Resources/PeekabooPlaygroundSource.json" \
    "$SOURCE_COMMIT" "$(git -C "$FIXTURE_ROOT" rev-parse HEAD:Apps/Playground)" \
    "$CANONICAL_LOCK_RELATIVE" "$DEPENDENCY_LOCK_SHA256" "$VERSION" \
    "$EFFECTIVE_DEVELOPER_DIR" "$XCODEBUILD_VERSION" "$SDK_VERSION" "$SWIFTC_VERSION"
}

terminal_validate() {
  (ROOT_DIR="$FIXTURE_ROOT"; verify_playground_manifest "$1")
}

inventory() {
  /usr/bin/ruby "$COMPATIBILITY_SOURCE_ROOT/scripts/artifact-tree-manifest.rb" "$1" > "$2.tree"
  /usr/bin/xattr -lr -x -s "$1" > "$2.xattrs"
}

assert_native() {
  local app="$1" expected="$2" diagnostic="${3:-}" result=0
  inventory "$app" "$TEST_DIR/before"
  native_validate "$app" > "$TEST_DIR/native-result.log" 2>&1 || result=$?
  inventory "$app" "$TEST_DIR/after"
  cmp "$TEST_DIR/before.tree" "$TEST_DIR/after.tree" || fail 'native validation mutated artifact bytes/modes/symlinks'
  cmp "$TEST_DIR/before.xattrs" "$TEST_DIR/after.xattrs" || fail 'native validation mutated xattrs'
  [[ ! -e "$FIXTURE_FORBIDDEN_LOG" ]] || fail "forbidden operation: $(cat "$FIXTURE_FORBIDDEN_LOG")"
  if [[ "$expected" == accept && "$result" != 0 ]] || [[ "$expected" == refuse && "$result" == 0 ]]; then
    cat "$TEST_DIR/native-result.log" >&2
    fail "native $expected failed for $app (exit $result)"
  fi
  [[ -z "$diagnostic" ]] || grep -Fq "$diagnostic" "$TEST_DIR/native-result.log" || {
    cat "$TEST_DIR/native-result.log" >&2
    fail "missing refusal diagnostic: $diagnostic"
  }
}

inventory "$OUTPUT_APP" "$TEST_DIR/producer"
shared_validate "$OUTPUT_APP" || fail 'shared validator rejected producer v2'
terminal_validate "$OUTPUT_APP" || fail 'terminal wrapper rejected producer v2'
assert_native "$OUTPUT_APP" accept
inventory "$OUTPUT_APP" "$TEST_DIR/consumed"
cmp "$TEST_DIR/producer.tree" "$TEST_DIR/consumed.tree"
cmp "$TEST_DIR/producer.xattrs" "$TEST_DIR/consumed.xattrs"
[[ "$(wc -l < "$FIXTURE_SIGNATURE_LOG" | tr -d ' ')" == 2 ]] || fail 'native omitted signature verification or display'
printf 'producer -> shared validator -> terminal wrapper -> native preflight: unchanged v2 accepted\n'

new_candidate() {
  candidate="$TEST_DIR/candidate-$1.app"
  /usr/bin/ditto "$OUTPUT_APP" "$candidate"
  candidate_receipt="$candidate/Contents/Resources/PeekabooPlaygroundSource.json"
}

assert_receipt_refused() {
  local label="$1"
  inventory "$candidate" "$TEST_DIR/receipt-before"
  if shared_validate "$candidate" >/dev/null 2>&1; then fail "shared validator accepted $label"; fi
  if terminal_validate "$candidate" >/dev/null 2>&1; then fail "terminal wrapper accepted $label"; fi
  assert_native "$candidate" refuse
  inventory "$candidate" "$TEST_DIR/receipt-after"
  cmp "$TEST_DIR/receipt-before.tree" "$TEST_DIR/receipt-after.tree"
  cmp "$TEST_DIR/receipt-before.xattrs" "$TEST_DIR/receipt-after.xattrs"
}

# Mutate the real producer receipt; no separately authored happy-path v2 schema.
receipt_cases=0
for field in $(jq -r 'keys[]' "$manifest"); do
  for mutation in wrong removed type; do
    new_candidate "$field-$mutation"
    jq --arg field "$field" --arg mutation "$mutation" '
      if $mutation == "removed" then del(.[$field])
      elif $mutation == "type" then .[$field] = (if $field == "version" then "2" else 2 end)
      elif $field == "version" then .[$field] = 3
      elif $field == "source_commit" or $field == "source_tree" then .[$field] = ("a" * 40)
      elif $field == "dependency_lock_sha256" then .[$field] = ("a" * 64)
      else .[$field] += "-wrong" end
    ' "$manifest" > "$TEST_DIR/receipt.json"
    chmod u+w "$candidate_receipt"
    cp "$TEST_DIR/receipt.json" "$candidate_receipt"
    chmod 444 "$candidate_receipt"
    assert_receipt_refused "$field/$mutation"
    receipt_cases=$((receipt_cases + 1))
  done
done
for mutation in extra malformed multiple array writable symlink missing; do
  new_candidate "$mutation"
  case "$mutation" in
    extra) jq '.extra = true' "$manifest" > "$TEST_DIR/receipt.json" ;;
    malformed) printf '{bad json\n' > "$TEST_DIR/receipt.json" ;;
    multiple) cat "$manifest" "$manifest" > "$TEST_DIR/receipt.json" ;;
    array) jq -s '.' "$manifest" > "$TEST_DIR/receipt.json" ;;
  esac
  case "$mutation" in
    writable) chmod 644 "$candidate_receipt" ;;
    symlink) mv "$candidate_receipt" "$candidate/Contents/Resources/receipt-target.json"
      ln -s receipt-target.json "$candidate_receipt" ;;
    missing) rm "$candidate_receipt" ;;
    *) chmod u+w "$candidate_receipt"; cp "$TEST_DIR/receipt.json" "$candidate_receipt"; chmod 444 "$candidate_receipt" ;;
  esac
  assert_receipt_refused "$mutation"
  receipt_cases=$((receipt_cases + 1))
done
printf 'strict v2 refusals: %s field/schema/file corruptions, all three consumers\n' "$receipt_cases"

# Each source-lock mutation must reach its own boundary, before generic dirtiness.
lock="$FIXTURE_ROOT/$CANONICAL_LOCK_RELATIVE"
cp "$lock" "$TEST_DIR/original-lock"
mv "$lock" "$TEST_DIR/absent-lock"
assert_native "$OUTPUT_APP" refuse 'lock missing or symlinked'
mv "$TEST_DIR/absent-lock" "$lock"
mv "$lock" "$TEST_DIR/symlink-lock"
ln -s "$TEST_DIR/symlink-lock" "$lock"
assert_native "$OUTPUT_APP" refuse 'lock missing or symlinked'
rm "$lock"
mv "$TEST_DIR/symlink-lock" "$lock"
git -C "$FIXTURE_ROOT" rm --cached -q "$CANONICAL_LOCK_RELATIVE"
assert_native "$OUTPUT_APP" refuse 'lock is not tracked'
git -C "$FIXTURE_ROOT" add "$CANONICAL_LOCK_RELATIVE"
printf '\n' >> "$lock"
assert_native "$OUTPUT_APP" refuse 'lock differs from HEAD'
git -C "$FIXTURE_ROOT" update-index --assume-unchanged "$CANONICAL_LOCK_RELATIVE"
assert_native "$OUTPUT_APP" refuse 'lock differs from HEAD'
git -C "$FIXTURE_ROOT" update-index --no-assume-unchanged "$CANONICAL_LOCK_RELATIVE"
cp "$TEST_DIR/original-lock" "$lock"
for relative in Apps/Playground/Package.resolved \
  Apps/Playground/Playground.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; do
  mkdir -p "$(dirname "$FIXTURE_ROOT/$relative")"
  printf '{}\n' > "$FIXTURE_ROOT/$relative"
  assert_native "$OUTPUT_APP" refuse 'Noncanonical Playground dependency lock'
  rm "$FIXTURE_ROOT/$relative"
  ln -s missing "$FIXTURE_ROOT/$relative"
  assert_native "$OUTPUT_APP" refuse 'Noncanonical Playground dependency lock'
  rm "$FIXTURE_ROOT/$relative"
done
printf 'source lock refusals: absent, symlinked, untracked, dirty, assume-unchanged, competing\n'

for field in CFBundleIdentifier CFBundleShortVersionString CFBundleExecutable; do
  for mutation in wrong missing; do
    new_candidate "plist-$field-$mutation"
    if [[ "$mutation" == wrong ]]; then
      /usr/libexec/PlistBuddy -c "Set :$field wrong" "$candidate/Contents/Info.plist"
    else
      /usr/libexec/PlistBuddy -c "Delete :$field" "$candidate/Contents/Info.plist"
    fi
    assert_native "$candidate" refuse 'bundle metadata differs'
  done
done
for mutation in missing nonexecutable symlink; do
  new_candidate "executable-$mutation"
  case "$mutation" in
    missing) rm "$candidate/Contents/MacOS/Playground" ;;
    nonexecutable) chmod 644 "$candidate/Contents/MacOS/Playground" ;;
    symlink) mv "$candidate/Contents/MacOS/Playground" "$candidate/Contents/MacOS/target"
      ln -s target "$candidate/Contents/MacOS/Playground" ;;
  esac
  assert_native "$candidate" refuse 'Playground executable'
done
for failure in invalid adhoc adhoc-details team identifier authority; do
  FIXTURE_SIGNATURE_FAILURE="$failure" assert_native "$OUTPUT_APP" refuse
done
for resource in Resources/fixture.txt _CodeSignature/CodeResources; do
  new_candidate "tamper-${resource##*/}"
  printf 'tampered\n' >> "$candidate/Contents/$resource"
  assert_native "$candidate" refuse
done
printf 'bundle metadata/executable and signature enforcement refusals passed\n'

# Actual selected toolchain changes must invalidate the unchanged receipt.
for tool in xcodebuild xcrun; do
  cp "$TEST_DIR/$tool" "$TEST_DIR/$tool.saved"
  # Replace only this disposable external tool double, never a candidate receipt.
  cat > "$TEST_DIR/$tool" <<'EOF'
#!/bin/bash
printf 'different toolchain\n'
EOF
  assert_native "$OUTPUT_APP" refuse 'current-source/toolchain v2 receipt'
  cp "$TEST_DIR/$tool.saved" "$TEST_DIR/$tool"
done
mkdir "$TEST_DIR/OtherDeveloper"
DEVELOPER_DIR="$TEST_DIR/OtherDeveloper" assert_native "$OUTPUT_APP" refuse 'current-source/toolchain v2 receipt'
# Resolve the selector's alias to the same canonical directory.
ln -s "$FIXTURE_DEVELOPER_DIR" "$TEST_DIR/DeveloperAlias"
DEVELOPER_DIR="$TEST_DIR/DeveloperAlias" assert_native "$OUTPUT_APP" accept
(unset DEVELOPER_DIR; assert_native "$OUTPUT_APP" accept)

# Execute the production local builder and preflight in a shell with explicit
# build/sign doubles. There is no production CLI option granting v1 ownership.
(
  eval "$(sed -n '/^build_playground() {/,/^}/p' "$ROOT_DIR/scripts/test-background-computer-use.sh")"
  eval "$(sed -n '/^validate_playground_fixture() {/,/^}/p' "$ROOT_DIR/scripts/test-background-computer-use.sh")"
  ROOT_DIR="$FIXTURE_ROOT"
  ARTIFACT_ROOT="$TEST_DIR/local-build"
  mkdir "$ARTIFACT_ROOT"
  PLAYGROUND_APP=""
  PLAYGROUND_BUILT_APP=""
  PLAYGROUND_BUNDLE_ID=boo.peekaboo.playground.debug
  PLAYGROUND_SOURCE_COMMIT="$SOURCE_COMMIT"
  PLAYGROUND_SOURCE_TREE="$(git -C "$ROOT_DIR" rev-parse HEAD:Apps/Playground)"
  PLAYGROUND_CODESIGN_BIN="$TEST_DIR/codesign-verifier"
  PEEKABOO_PLAYGROUND_SIGN_IDENTITY='Synthetic test identity'
  xcodebuild() {
    FIXTURE_VERIFY_ONLY=0 "$TEST_DIR/xcodebuild" "$@"
  }
  sign_playground_app() {
    [[ "$2" == 'Synthetic test identity' ]] || return 1
    printf '%s\n' "$1" > "$TEST_DIR/local-sign-call"
  }
  build_playground
  [[ "$(cat "$TEST_DIR/local-sign-call")" == "$PLAYGROUND_APP" ]] || fail 'local builder did not sign'
  validate_playground_fixture || fail 'fresh internally built v1 rejected'
  jq -e '.version == 1' "$PLAYGROUND_SOURCE_MANIFEST" >/dev/null
  assert_native "$PLAYGROUND_APP" refuse 'supplied v1 is refused'
  export PLAYGROUND_BUILT_APP="$PLAYGROUND_APP"
  assert_native "$PLAYGROUND_APP" refuse 'supplied v1 is refused'
  PLAYGROUND_BUILT_APP="$PLAYGROUND_APP" validate_playground_fixture || fail 'internal ownership lost'
  PLAYGROUND_BUILT_APP=""
  if validate_playground_fixture >/dev/null 2>&1; then fail 'unowned v1 accepted'; fi
)

if env PEEKABOO_PLAYGROUND_TEST_MODE=1 \
  "$FIXTURE_ROOT/scripts/test-background-computer-use.sh" --playground-app "$OUTPUT_APP" \
  --skip-playground-build > "$TEST_DIR/live-mode.log" 2>&1; then
  fail 'test mode accepted on live path'
fi
grep -Fq 'restricted to --validate-playground-only' "$TEST_DIR/live-mode.log"
for override in PEEKABOO_PLAYGROUND_CODESIGN_BIN PEEKABOO_PLAYGROUND_XCODEBUILD_BIN \
  PEEKABOO_PLAYGROUND_XCRUN_BIN PEEKABOO_PLAYGROUND_XCODE_SELECT_BIN; do
  if env "$override=/not/a/tool" "$FIXTURE_ROOT/scripts/test-background-computer-use.sh" \
    --playground-app "$OUTPUT_APP" --skip-playground-build > "$TEST_DIR/override.log" 2>&1; then
    fail 'test override accepted on live path'
  fi
  grep -Fq 'is test-only' "$TEST_DIR/override.log"
done
for args in '--validate-playground-only' '--validate-playground-only --skip-playground-build'; do
  # Intentional splitting of these fixed test arguments.
  if "$FIXTURE_ROOT/scripts/test-background-computer-use.sh" $args > "$TEST_DIR/arguments.log" 2>&1; then
    fail 'validation-only accepted missing explicit fixture options'
  fi
  grep -Fq 'requires --playground-app and --skip-playground-build' "$TEST_DIR/arguments.log"
done
[[ ! -e "$FIXTURE_FORBIDDEN_LOG" ]] || fail 'test performed a forbidden live operation'
[[ ! -e "$FIXTURE_ROOT/.artifacts" ]] || fail 'validation-only entered artifact/probe setup'
printf 'local v1 ownership, supplied-v1 refusal, headless-only overrides, and early exit passed\n'
unset FIXTURE_VERIFY_ONLY
