#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/terminal-artifact-env.sh
source "$ROOT_DIR/scripts/terminal-artifact-env.sh"
for secret_name in "${TERMINAL_ARTIFACT_SECRET_NAMES[@]}"; do unset "$secret_name"; done
TEST_DIR="$(mktemp -d /tmp/peekaboo-terminal-notary-test.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT
LOG_FILE="$TEST_DIR/invocations"
CLI_TREE="$TEST_DIR/cli"
APP_ARTIFACT="$TEST_DIR/Playground.app"
CONTROLLER_TREE="$TEST_DIR/qualification"

fail() {
  printf 'test-notarize-terminal-artifact: %s\n' "$*" >&2
  exit 1
}

notary_entry_prefix="$(awk '/^raw_function_names_file=/{exit} {print}' \
  "$ROOT_DIR/scripts/notarize-terminal-artifact.sh")"
for secret_name in \
  APP_STORE_CONNECT_API_KEY_P8 APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID \
  ASC_PRIVATE_KEY_P8 ASC_KEY_ID ASC_ISSUER_ID CODESIGN_KEYCHAIN DYLD_INSERT_LIBRARIES \
  DYLD_LIBRARY_PATH GH_TOKEN GITHUB_TOKEN MAC_RELEASE_CODESIGN_KEYCHAIN \
  MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD MAC_RELEASE_SPARKLE_KEY_FILE \
  MAC_RELEASE_SPARKLE_OP_REF MOLTY_OP_SERVICE_ACCOUNT_TOKEN NODE_AUTH_TOKEN NODE_OPTIONS \
  NODE_PATH NOTARYTOOL_KEY NOTARYTOOL_KEY_ID NOTARYTOOL_ISSUER NPM_CONFIG_USERCONFIG NPM_TOKEN \
  OP_SERVICE_ACCOUNT_TOKEN SIGN_IDENTITY SPARKLE_PRIVATE_KEY SPARKLE_PRIVATE_KEY_FILE; do
  grep -Fwq "$secret_name" <<< "$notary_entry_prefix" || \
    fail "notary entrypoint does not de-export $secret_name before its environment scan"
done

mkdir -p "$CLI_TREE"
printf 'int main(void) { return 0; }\n' > "$TEST_DIR/main.c"
/usr/bin/clang -arch arm64 "$TEST_DIR/main.c" -o "$TEST_DIR/cli-arm64"
/usr/bin/clang -arch x86_64 "$TEST_DIR/main.c" -o "$TEST_DIR/cli-x86_64"
/usr/bin/lipo -create "$TEST_DIR/cli-arm64" "$TEST_DIR/cli-x86_64" -output "$CLI_TREE/peekaboo"
mkdir -p "$APP_ARTIFACT/Contents/MacOS"
cp "$CLI_TREE/peekaboo" "$APP_ARTIFACT/Contents/MacOS/Playground"
cat > "$APP_ARTIFACT/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Playground</string></dict></plist>
EOF
mkdir -p "$CONTROLLER_TREE"
cp "$CLI_TREE/peekaboo" "$CONTROLLER_TREE/peekaboo-certification-controller"
cp "$CLI_TREE/peekaboo" "$CONTROLLER_TREE/background-computer-use-probe"
cp /usr/bin/true "$CONTROLLER_TREE/libswiftCompatibilityFixture.dylib"

cat > "$TEST_DIR/ditto" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ditto %s\n' "$*" >> "${LOG_FILE:?}"
exec /usr/bin/ditto "$@"
EOF
cat > "$TEST_DIR/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcrun %s\n' "$*" >> "${LOG_FILE:?}"
case "${1:-}:${2:-}" in
  notarytool:history) printf '{}\n' ;;
  notarytool:submit)
    case "${TERMINAL_NOTARY_MODE:-accepted}" in
      accepted) printf '{"id":"00000000-0000-4000-8000-000000000001","status":"Accepted"}\n' ;;
      rejected) printf '{"id":"00000000-0000-4000-8000-000000000001","status":"Invalid"}\n' ;;
      malformed) printf 'not-json\n' ;;
      *) exit 91 ;;
    esac
    ;;
  stapler:*) [[ "${TERMINAL_STAPLER_FAIL:-0}" != 1 ]] ;;
esac
EOF
cat > "$TEST_DIR/codesign" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'codesign %s\n' "$*" >> "${LOG_FILE:?}"
if [[ "${1:-}" == -dvvv ]]; then
  target="${!#}"
  identifier="${TERMINAL_CODE_IDENTIFIER:-boo.peekaboo.peekaboo}"
  case "$(basename "$target")" in
    background-computer-use-probe) identifier=boo.peekaboo.background-computer-use-probe ;;
    libswiftCompatibility*.dylib) identifier=com.apple.dt.runtime.swiftCompatibilityFixture ;;
  esac
  cat <<DETAILS
Identifier=$identifier
CDHash=0123456789abcdef0123456789abcdef01234567
Authority=Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=FWJYW4S8P8
DETAILS
  for counter in $(seq 1 5000); do printf 'Trailing=%s\n' "$counter"; done
  exit 0
fi
[[ "${TERMINAL_CODESIGN_FAIL_VERIFY:-0}" != 1 ]]
EOF
cat > "$TEST_DIR/xattr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec /usr/bin/xattr "$@"
EOF
chmod 755 "$TEST_DIR/ditto" "$TEST_DIR/xcrun" "$TEST_DIR/codesign" "$TEST_DIR/xattr"
export LOG_FILE

run_notary() {
  PEEKABOO_TERMINAL_TEST_MODE=1 \
    TERMINAL_NOTARY_XCRUN_BIN="$TEST_DIR/xcrun" \
    TERMINAL_NOTARY_DITTO_BIN="$TEST_DIR/ditto" \
    TERMINAL_NOTARY_CODESIGN_BIN="$TEST_DIR/codesign" \
    TERMINAL_NOTARY_XATTR_BIN="$TEST_DIR/xattr" \
    TERMINAL_NOTARY_UNZIP_BIN=/usr/bin/unzip \
    /bin/bash --noprofile --norc -p "$ROOT_DIR/scripts/notarize-terminal-artifact.sh" "$@"
}

profile_transaction="$TEST_DIR/profile-transaction"
run_notary --kind cli-tree --artifact "$CLI_TREE" --transaction "$profile_transaction" \
  --notary-profile __peekaboo_fixture__ >/dev/null
jq -e '
  .version == 2 and .kind == "cli_tree" and .status == "Accepted" and
  .submission.path == ("notary/submissions/" + .submission.sha256) and
  .submission.size > 0 and (.submission.sha256 | test("^[0-9a-f]{64}$")) and
  .code_identity.authority == "Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)" and
  .code_identity.identifier == "boo.peekaboo.peekaboo" and .code_identity.team_id == "FWJYW4S8P8" and
  .code_identity.cdhash == "0123456789abcdef0123456789abcdef01234567" and
  (.code_identity.architectures | sort) == ["arm64", "x86_64"] and
  (.code_identity.cdhashes | keys | sort) == ["arm64", "x86_64"] and
  .final_artifact.tree_manifest_size > 0 and
  (.final_artifact.tree_manifest_sha256 | test("^[0-9a-f]{64}$"))
' "$profile_transaction/receipt.json" >/dev/null || fail 'profile receipt schema is incomplete'
[[ -f "$profile_transaction/submission.bin" ]]
history_line="$(grep -n 'xcrun notarytool history --keychain-profile __peekaboo_fixture__' "$LOG_FILE" | cut -d: -f1)"
submit_line="$(grep -n 'xcrun notarytool submit .*--keychain-profile __peekaboo_fixture__ --no-s3-acceleration --wait --output-format json' \
  "$LOG_FILE" | cut -d: -f1)"
[[ -n "$history_line" && -n "$submit_line" && "$history_line" -lt "$submit_line" ]] || \
  fail 'profile history did not precede the exact submit command'

profile_reexec_transaction="$TEST_DIR/profile-reexec-transaction"
if (
  hostile_notary_function() { return 97; }
  export -f hostile_notary_function
  export OP_SERVICE_ACCOUNT_TOKEN=unrelated-credential
  run_notary --kind cli-tree --artifact "$CLI_TREE" \
    --transaction "$profile_reexec_transaction" \
    --notary-profile __peekaboo_fixture__ >/dev/null 2>&1
); then
  fail 'credential-bearing notary accepted an exported-function environment'
fi
[[ ! -e "$profile_reexec_transaction" ]] || \
  fail 'function-environment refusal published a notary transaction'

assert_cli_failure() {
  local label="$1"
  local mode="$2"
  local verify_fail="${3:-0}"
  local transaction="$TEST_DIR/$label-transaction"
  if TERMINAL_NOTARY_MODE="$mode" TERMINAL_CODESIGN_FAIL_VERIFY="$verify_fail" \
    run_notary --kind cli-tree --artifact "$CLI_TREE" --transaction "$transaction" \
      --notary-profile __peekaboo_fixture__ >/dev/null 2>&1; then
    fail "$label unexpectedly succeeded"
  fi
  [[ ! -e "$transaction" ]] || fail "$label published a partial transaction"
}

assert_cli_failure rejected rejected
assert_cli_failure malformed malformed
assert_cli_failure online-verify accepted 1
staple_transaction="$TEST_DIR/staple-transaction"
if TERMINAL_CODE_IDENTIFIER=boo.peekaboo.playground.debug TERMINAL_STAPLER_FAIL=1 \
  run_notary --kind app --artifact "$APP_ARTIFACT" --transaction "$staple_transaction" \
    --notary-profile __peekaboo_fixture__ >/dev/null 2>&1; then
  fail 'staple failure unexpectedly succeeded'
fi
[[ ! -e "$staple_transaction" ]] || fail 'staple failure published a partial transaction'

live_fixture_transaction="$TEST_DIR/live-fixture-transaction"
if APP_STORE_CONNECT_API_KEY_P8=secret run_notary --kind cli-tree --artifact "$CLI_TREE" \
  --transaction "$live_fixture_transaction" --notary-profile __peekaboo_fixture__ >/dev/null 2>&1; then
  fail 'fixture tools accepted a live credential variable'
fi
[[ ! -e "$live_fixture_transaction" ]]

xattr_cli="$TEST_DIR/xattr-cli"
/usr/bin/ditto "$CLI_TREE" "$xattr_cli"
/usr/bin/xattr -w com.openclaw.peekaboo.fixture value "$xattr_cli/peekaboo"
xattr_transaction="$TEST_DIR/xattr-transaction"
if run_notary --kind cli-tree --artifact "$xattr_cli" --transaction "$xattr_transaction" \
  --notary-profile __peekaboo_fixture__ >/dev/null 2>&1; then
  fail 'xattr-bearing artifact unexpectedly succeeded'
fi
[[ ! -e "$xattr_transaction" ]]

app_transaction="$TEST_DIR/app-transaction"
TERMINAL_CODE_IDENTIFIER=boo.peekaboo.playground.debug \
  run_notary --kind app --artifact "$APP_ARTIFACT" --transaction "$app_transaction" \
    --notary-profile __peekaboo_fixture__ >/dev/null
tree_sha="$(/usr/bin/shasum -a 256 "$app_transaction/tree.json" | /usr/bin/awk '{print $1}')"
jq -e --arg treeSHA "$tree_sha" --argjson treeSize "$(/usr/bin/stat -f%z "$app_transaction/tree.json")" '
  .final_artifact == {tree_manifest_sha256: $treeSHA, tree_manifest_size: $treeSize}
' "$app_transaction/receipt.json" >/dev/null || fail 'app receipt does not bind its atomic post-staple tree'
[[ -d "$app_transaction/Playground.app" ]]

controller_transaction="$TEST_DIR/controller-transaction"
symlink_tree="$TEST_DIR/symlink-qualification"
/usr/bin/ditto "$CONTROLLER_TREE" "$symlink_tree"
ln -s /usr/bin/true "$symlink_tree/foreign-helper"
if TERMINAL_CODE_IDENTIFIER=boo.peekaboo.peekaboo-certification-controller \
  run_notary --kind controller-tree --artifact "$symlink_tree" \
    --transaction "$TEST_DIR/symlink-controller-transaction" \
    --notary-profile __peekaboo_fixture__ >/dev/null 2>&1; then
  fail 'controller tree accepted a symlink helper'
fi
[[ ! -e "$TEST_DIR/symlink-controller-transaction" ]]

TERMINAL_CODE_IDENTIFIER=boo.peekaboo.peekaboo-certification-controller \
  run_notary --kind controller-tree --artifact "$CONTROLLER_TREE" --transaction "$controller_transaction" \
    --notary-profile __peekaboo_fixture__ >/dev/null
controller_tree_sha="$(/usr/bin/shasum -a 256 "$controller_transaction/tree.json" | /usr/bin/awk '{print $1}')"
jq -e --arg sha "$controller_tree_sha" '
  .kind == "controller_tree" and .final_artifact.tree_manifest_sha256 == $sha
' "$controller_transaction/receipt.json" >/dev/null || fail 'controller tree receipt is incomplete'

if TERMINAL_NOTARY_XCRUN_BIN="$TEST_DIR/xcrun" \
  "$ROOT_DIR/scripts/notarize-terminal-artifact.sh" --kind cli-tree --artifact "$CLI_TREE" \
  --transaction "$TEST_DIR/override-transaction" --notary-profile __peekaboo_fixture__ >/dev/null 2>&1; then
  fail 'production accepted a test tool override'
fi

printf 'test-notarize-terminal-artifact: ok\n'
