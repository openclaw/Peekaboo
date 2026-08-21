#!/bin/bash -p

# Narrow notarization boundary for an already-signed CLI, app, or DMG. In
# production all security-sensitive tools are fixed; overrides exist only in
# explicit fixture mode. The accepted receipt is published only after stapling
# and final online verification succeed.

builtin set +vx
PATH=/usr/bin:/bin
builtin export PATH
raw_function_names_file=$(/usr/bin/mktemp /tmp/peekaboo-functions.XXXXXX) || builtin exit 1
/usr/bin/env -0 | /usr/bin/env -i /usr/bin/perl -0ne '
  if (index($_, "BASH_FUNC_") == 0) { my ($name) = split(/=/, $_, 2); print $name, chr(0); }
' > "$raw_function_names_file"
raw_function_scan_status=("${PIPESTATUS[@]}")
if [[ ${raw_function_scan_status[0]} -ne 0 || ${raw_function_scan_status[1]} -ne 0 ]]; then
  /bin/rm -f "$raw_function_names_file"
  /bin/echo 'Could not inspect exported-function environment safely.' >&2
  builtin exit 1
fi
raw_function_scrub_args=()
while IFS= read -r -d '' raw_function_name; do
  [[ -n "$raw_function_name" ]] || { /bin/rm -f "$raw_function_names_file"; builtin exit 1; }
  raw_function_scrub_args+=(-u "$raw_function_name")
done < "$raw_function_names_file"
/bin/rm -f "$raw_function_names_file"
if (("${#raw_function_scrub_args[@]}" > 0)); then
  builtin exec /usr/bin/env "${raw_function_scrub_args[@]}" \
    -u BASH_ENV -u ENV -u CDPATH -u GLOBIGNORE \
    PATH=/usr/bin:/bin \
    /bin/bash -p "${BASH_SOURCE[0]}" "$@"
fi
for imported_function in $(builtin compgen -A function); do
  builtin unset -f -- "$imported_function"
done
builtin unset BASH_ENV ENV CDPATH GLOBIGNORE 2>/dev/null || true
builtin set +p

builtin set -euo pipefail
umask 077

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIND=""
ARTIFACT=""
TRANSACTION_DIR=""
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-${NOTARYTOOL_KEYCHAIN_PROFILE:-}}"
TEST_MODE="${PEEKABOO_TERMINAL_TEST_MODE:-0}"

fail() {
  printf 'notarize-terminal-artifact: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/notarize-terminal-artifact.sh --kind cli-tree|app|controller-tree|dmg --artifact PATH --transaction PATH [options]

Options:
  --notary-profile NAME   Use an existing notarytool keychain profile.
EOF
}

while (($# > 0)); do
  case "$1" in
    --kind) KIND="$2"; shift 2 ;;
    --artifact) ARTIFACT="$2"; shift 2 ;;
    --transaction) TRANSACTION_DIR="$2"; shift 2 ;;
    --notary-profile) NOTARYTOOL_PROFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; fail "unknown argument: $1" ;;
  esac
done

[[ "$KIND" == cli-tree || "$KIND" == app || "$KIND" == controller-tree || "$KIND" == dmg ]] || fail 'invalid --kind'
RECEIPT_KIND="$KIND"
[[ "$KIND" != cli-tree ]] || RECEIPT_KIND=cli_tree
[[ "$KIND" != controller-tree ]] || RECEIPT_KIND=controller_tree
[[ "$ARTIFACT" == /* ]] || ARTIFACT="$(pwd)/$ARTIFACT"
[[ "$TRANSACTION_DIR" == /* && ! -e "$TRANSACTION_DIR" && ! -L "$TRANSACTION_DIR" ]] || \
  fail 'transaction path must be new and absolute'

case "$TEST_MODE" in
  1|true|yes|on)
    for credential_name in APP_STORE_CONNECT_API_KEY_P8 APP_STORE_CONNECT_KEY_ID \
      APP_STORE_CONNECT_ISSUER_ID ASC_PRIVATE_KEY_P8 ASC_KEY_ID ASC_ISSUER_ID \
      MAC_RELEASE_CODESIGN_KEYCHAIN MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD OP_SERVICE_ACCOUNT_TOKEN \
      MOLTY_OP_SERVICE_ACCOUNT_TOKEN; do
      [[ -z "${!credential_name+x}" ]] || fail "fixture mode contains live credential variable: $credential_name"
    done
    [[ "$NOTARYTOOL_PROFILE" == __peekaboo_fixture__ ]] || fail 'fixture mode requires literal fixture profile'
    XCRUN_BIN="${TERMINAL_NOTARY_XCRUN_BIN:?test xcrun required}"
    DITTO_BIN="${TERMINAL_NOTARY_DITTO_BIN:?test ditto required}"
    CODESIGN_BIN="${TERMINAL_NOTARY_CODESIGN_BIN:?test codesign required}"
    XATTR_BIN="${TERMINAL_NOTARY_XATTR_BIN:-/usr/bin/xattr}"
    UNZIP_BIN="${TERMINAL_NOTARY_UNZIP_BIN:-/usr/bin/unzip}"
    ;;
  0|false|no|off|'')
    for override_name in \
      TERMINAL_NOTARY_XCRUN_BIN TERMINAL_NOTARY_DITTO_BIN TERMINAL_NOTARY_CODESIGN_BIN \
      TERMINAL_NOTARY_XATTR_BIN TERMINAL_NOTARY_UNZIP_BIN; do
      [[ -z "${!override_name+x}" ]] || fail "$override_name is test-only"
    done
    XCRUN_BIN=/usr/bin/xcrun
    DITTO_BIN=/usr/bin/ditto
    CODESIGN_BIN=/usr/bin/codesign
    XATTR_BIN=/usr/bin/xattr
    UNZIP_BIN=/usr/bin/unzip
    ;;
  *) fail 'PEEKABOO_TERMINAL_TEST_MODE must be boolean' ;;
esac

for tool_path in "$XCRUN_BIN" "$DITTO_BIN" "$CODESIGN_BIN" "$XATTR_BIN" "$UNZIP_BIN"; do
  [[ "$tool_path" == /* && -x "$tool_path" ]] || fail "tool is missing or not absolute: $tool_path"
done
for publication_name in DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH GH_TOKEN GITHUB_TOKEN NODE_AUTH_TOKEN \
  NODE_OPTIONS NODE_PATH NPM_CONFIG_USERCONFIG NPM_TOKEN OP_SERVICE_ACCOUNT_TOKEN \
  MOLTY_OP_SERVICE_ACCOUNT_TOKEN MAC_RELEASE_CODESIGN_KEYCHAIN MAC_RELEASE_CODESIGN_KEYCHAIN_PASSWORD \
  CODESIGN_KEYCHAIN ASC_PRIVATE_KEY_P8 ASC_KEY_ID ASC_ISSUER_ID NOTARYTOOL_KEY NOTARYTOOL_KEY_ID \
  NOTARYTOOL_ISSUER \
  SPARKLE_PRIVATE_KEY SPARKLE_PRIVATE_KEY_FILE MAC_RELEASE_SPARKLE_KEY_FILE MAC_RELEASE_SPARKLE_OP_REF; do
  [[ -z "${!publication_name+x}" ]] || fail "publication credential reached notary boundary: $publication_name"
done

if [[ "$KIND" == app || "$KIND" == controller-tree || "$KIND" == cli-tree ]]; then
  [[ -d "$ARTIFACT" && ! -L "$ARTIFACT" ]] || fail 'app artifact is invalid'
else
  [[ -f "$ARTIFACT" && ! -L "$ARTIFACT" ]] || fail 'file artifact is invalid'
fi

mkdir -p "$(dirname "$TRANSACTION_DIR")"
WORK_DIR="$(mktemp -d "$(dirname "$TRANSACTION_DIR")/.notary.XXXXXX")"
KEY_FILE=""
cleanup() {
  if [[ -n "$KEY_FILE" && -f "$KEY_FILE" ]]; then
    /bin/rm -P "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
  fi
  rm -rf -- "$WORK_DIR"
  [[ -z "${publish_dir:-}" ]] || rm -rf -- "$publish_dir"
}
trap cleanup EXIT

key_id=""
issuer_id=""
if [[ -z "$NOTARYTOOL_PROFILE" ]]; then
  key_id="${APP_STORE_CONNECT_KEY_ID:-}"
  issuer_id="${APP_STORE_CONNECT_ISSUER_ID:-}"
  [[ -n "$key_id" && -n "$issuer_id" && -n "${APP_STORE_CONNECT_API_KEY_P8:-}" ]] || \
    fail 'App Store Connect fields are missing'
  KEY_FILE="$WORK_DIR/AuthKey_${key_id}.p8"
  perl_materializer="$WORK_DIR/materialize-key.pl"
  /bin/cat > "$perl_materializer" <<'EOF'
local $/;
my $pem = <STDIN> // "";
$pem =~ s/\\n/\n/g;
$pem =~ s/^\s+|\s+$//g;
if ($pem !~ /\n/ && $pem =~ /^(-----BEGIN [^-]+-----)\s*(.+?)\s*(-----END [^-]+-----)$/) {
  my ($head, $body, $tail) = ($1, $2, $3);
  $body =~ s/\s+//g;
  $body =~ s/(.{1,64})/$1\n/g;
  $pem = "$head\n$body$tail";
}
print "$pem\n";
EOF
  chmod 500 "$perl_materializer"
  printf '%s' "$APP_STORE_CONNECT_API_KEY_P8" | \
    /usr/bin/env -i /usr/bin/perl "$perl_materializer" > "$KEY_FILE"
  chmod 600 "$KEY_FILE"
  unset APP_STORE_CONNECT_API_KEY_P8 APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID
fi

working_artifact="$ARTIFACT"
if [[ "$KIND" == app || "$KIND" == controller-tree || "$KIND" == cli-tree || "$KIND" == dmg ]]; then
  working_artifact="$WORK_DIR/$(basename "$ARTIFACT")"
  if [[ "$KIND" == app || "$KIND" == controller-tree || "$KIND" == cli-tree ]]; then
    "$DITTO_BIN" "$ARTIFACT" "$working_artifact"
  else
    cp "$ARTIFACT" "$working_artifact"
  fi
fi

assert_no_xattrs() {
  local target="$1"
  local names
  names="$($XATTR_BIN -r "$target")" || fail "could not inspect xattrs: $target"
  [[ -z "$names" ]] || fail "artifact contains unbound extended attributes: $target"
}
assert_no_xattrs "$working_artifact"

code_target="$working_artifact"
if [[ "$KIND" == controller-tree ]]; then
  code_target="$working_artifact/peekaboo-certification-controller"
  [[ -f "$code_target" && ! -L "$code_target" && -x "$code_target" ]] || \
    fail 'controller tree main executable missing'
  monitor_target="$working_artifact/background-computer-use-probe"
  [[ -f "$monitor_target" && ! -L "$monitor_target" && -x "$monitor_target" ]] || \
    fail 'controller tree monitor missing'
  while IFS= read -r -d '' qualification_file; do
    qualification_relative="${qualification_file#"$working_artifact/"}"
    [[ "$qualification_relative" != */* && -f "$qualification_file" && ! -L "$qualification_file" ]] || \
      fail "qualification tree entry is not a flat regular file: $qualification_relative"
    case "$qualification_relative" in
      peekaboo-certification-controller|background-computer-use-probe|libswiftCompatibility*.dylib) ;;
      *) fail "unexpected qualification tree file: $qualification_relative" ;;
    esac
  done < <(find "$working_artifact" -mindepth 1 -print0)
elif [[ "$KIND" == cli-tree ]]; then
  code_target="$working_artifact/peekaboo"
  [[ -f "$code_target" && ! -L "$code_target" && -x "$code_target" ]] || \
    fail 'CLI tree main executable missing'
  while IFS= read -r -d '' cli_file; do
    cli_relative="${cli_file#"$working_artifact/"}"
    [[ "$cli_relative" != */* && -f "$cli_file" && ! -L "$cli_file" ]] || \
      fail "CLI tree entry is not a flat regular file: $cli_relative"
    case "$cli_relative" in
      peekaboo|libswiftCompatibility*.dylib) ;;
      *) fail "unexpected CLI tree file: $cli_relative" ;;
    esac
  done < <(find "$working_artifact" -mindepth 1 -print0)
fi
signature_details="$($CODESIGN_BIN -dvvv "$code_target" 2>&1)" || fail 'could not inspect code identity'
parse_signature_field() {
  local field="$1"
  /usr/bin/awk -F= -v field="$field" '$1 == field && !seen { value = $2; seen = 1 } END { print value }' \
    <<<"$signature_details"
}
code_cdhash="$(parse_signature_field CDHash)"
code_identifier="$(parse_signature_field Identifier)"
code_team_id="$(parse_signature_field TeamIdentifier)"
code_authority="$(parse_signature_field Authority)"
[[ "$code_cdhash" =~ ^[0-9a-fA-F]{40,64}$ && -n "$code_identifier" && -n "$code_team_id" && \
  -n "$code_authority" ]] || fail 'incomplete code identity'
[[ "$code_authority" == 'Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)' && \
  "$code_team_id" == FWJYW4S8P8 ]] || fail 'artifact is not Foundation-signed'
case "$KIND:$code_identifier" in
  cli-tree:boo.peekaboo.peekaboo|app:boo.peekaboo.mac|app:boo.peekaboo.playground.debug|\
    app:boo.peekaboo.qualification-node|controller-tree:boo.peekaboo.peekaboo-certification-controller|dmg:*) ;;
  *) fail "unexpected signed identifier: $code_identifier" ;;
esac

if [[ "$KIND" == dmg ]]; then
  code_architectures_json='["container"]'
  code_cdhash="$(printf '%s' "$code_cdhash" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  code_cdhashes_json="{\"container\":\"$code_cdhash\"}"
else
  architecture_binary="$code_target"
  if [[ "$KIND" == app ]]; then
    app_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' \
      "$working_artifact/Contents/Info.plist")" || fail 'app executable metadata missing'
    architecture_binary="$working_artifact/Contents/MacOS/$app_executable"
  fi
  architecture_list="$(/usr/bin/lipo -archs "$architecture_binary")" || \
    fail 'could not inspect code architectures'
  code_architectures_json='['
  code_cdhashes_json='{'
  json_separator=''
  first_architecture_cdhash=''
  arm_architecture_cdhash=''
  for architecture in $architecture_list; do
    [[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || fail "unsupported architecture: $architecture"
    architecture_details="$($CODESIGN_BIN -dvvv --arch "$architecture" "$code_target" 2>&1)" || \
      fail "could not inspect $architecture code identity"
    architecture_cdhash="$(/usr/bin/awk -F= '$1 == "CDHash" && !seen { print tolower($2); seen = 1 }' \
      <<<"$architecture_details")"
    [[ "$architecture_cdhash" =~ ^[0-9a-f]{40,64}$ ]] || fail "invalid $architecture CDHash"
    code_architectures_json="$code_architectures_json$json_separator\"$architecture\""
    code_cdhashes_json="$code_cdhashes_json$json_separator\"$architecture\":\"$architecture_cdhash\""
    json_separator=,
    [[ -n "$first_architecture_cdhash" ]] || first_architecture_cdhash="$architecture_cdhash"
    [[ "$architecture" != arm64 ]] || arm_architecture_cdhash="$architecture_cdhash"
  done
  code_architectures_json="$code_architectures_json]"
  code_cdhashes_json="$code_cdhashes_json}"
  code_cdhash="${arm_architecture_cdhash:-$first_architecture_cdhash}"
fi

verify_controller_tree_identities() {
  local require_notarized="$1"
  local candidate relative details authority team identifier
  while IFS= read -r -d '' candidate; do
    /usr/bin/file -b "$candidate" | /usr/bin/grep -q Mach-O || continue
    "$CODESIGN_BIN" --verify --strict \
      '-R=anchor apple generic and certificate leaf[subject.OU] = "FWJYW4S8P8"' "$candidate" || return 1
    if [[ "$require_notarized" == true ]]; then
      "$CODESIGN_BIN" --verify --strict --check-notarization -R=notarized "$candidate" || return 1
    fi
    details="$($CODESIGN_BIN -dvvv "$candidate" 2>&1)" || return 1
    authority="$(/usr/bin/awk -F= '$1 == "Authority" && !seen { print $2; seen = 1 }' <<<"$details")"
    team="$(/usr/bin/awk -F= '$1 == "TeamIdentifier" && !seen { print $2; seen = 1 }' <<<"$details")"
    identifier="$(/usr/bin/awk -F= '$1 == "Identifier" && !seen { print $2; seen = 1 }' <<<"$details")"
    [[ "$authority" == 'Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)' && \
      "$team" == FWJYW4S8P8 ]] || return 1
    relative="${candidate#"$working_artifact/"}"
    case "$relative" in
      peekaboo-certification-controller)
        [[ "$identifier" == boo.peekaboo.peekaboo-certification-controller ]] || return 1 ;;
      background-computer-use-probe)
        [[ "$identifier" == boo.peekaboo.background-computer-use-probe ]] || return 1 ;;
      libswiftCompatibility*.dylib)
        [[ "$identifier" == com.apple.dt.runtime.swiftCompatibility* ]] || return 1 ;;
      *) return 1 ;;
    esac
  done < <(find "$working_artifact" -type f -print0)
}
if [[ "$KIND" == controller-tree ]]; then
  verify_controller_tree_identities false || fail 'qualification tree pre-submit identity mismatch'
fi

verify_cli_tree_identities() {
  local require_notarized="$1"
  local candidate relative details authority team identifier
  while IFS= read -r -d '' candidate; do
    /usr/bin/file -b "$candidate" | /usr/bin/grep -q Mach-O || return 1
    "$CODESIGN_BIN" --verify --strict \
      '-R=anchor apple generic and certificate leaf[subject.OU] = "FWJYW4S8P8"' "$candidate" || return 1
    if [[ "$require_notarized" == true ]]; then
      "$CODESIGN_BIN" --verify --strict --check-notarization -R=notarized "$candidate" || return 1
    fi
    details="$($CODESIGN_BIN -dvvv "$candidate" 2>&1)" || return 1
    authority="$(/usr/bin/awk -F= '$1 == "Authority" && !seen { print $2; seen = 1 }' <<<"$details")"
    team="$(/usr/bin/awk -F= '$1 == "TeamIdentifier" && !seen { print $2; seen = 1 }' <<<"$details")"
    identifier="$(/usr/bin/awk -F= '$1 == "Identifier" && !seen { print $2; seen = 1 }' <<<"$details")"
    [[ "$authority" == 'Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)' && \
      "$team" == FWJYW4S8P8 ]] || return 1
    relative="${candidate#"$working_artifact/"}"
    case "$relative" in
      peekaboo) [[ "$identifier" == boo.peekaboo.peekaboo ]] || return 1 ;;
      libswiftCompatibility*.dylib)
        [[ "$identifier" == com.apple.dt.runtime.swiftCompatibility* ]] || return 1 ;;
      *) return 1 ;;
    esac
  done < <(find "$working_artifact" -type f -print0)
}
if [[ "$KIND" == cli-tree ]]; then
  verify_cli_tree_identities false || fail 'CLI tree pre-submit identity mismatch'
fi

if [[ "$KIND" == dmg ]]; then
  submission="$working_artifact"
else
  submission="$WORK_DIR/submission.zip"
  /usr/bin/env -u APP_STORE_CONNECT_API_KEY_P8 "$DITTO_BIN" -c -k --sequesterRsrc --keepParent \
    "$working_artifact" "$submission"
  if "$UNZIP_BIN" -Z1 "$submission" | /usr/bin/awk '
    /(^|\/)__MACOSX(\/|$)/ || /(^|\/)\._[^\/]+$/ { found = 1 }
    END { exit !found }
  '; then
    fail 'notary submission contains AppleDouble payload'
  fi
fi
submission_sha256="$(/usr/bin/shasum -a 256 "$submission" | /usr/bin/awk '{print $1}')"
submission_size="$(/usr/bin/stat -f%z "$submission")"
retained_submission="$WORK_DIR/submission.bin"
cp "$submission" "$retained_submission"
chmod 444 "$retained_submission"

if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
  for api_name in APP_STORE_CONNECT_API_KEY_P8 APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID; do
    [[ -z "${!api_name+x}" ]] || fail "profile route contains API credential variable: $api_name"
  done
  "$XCRUN_BIN" notarytool history --keychain-profile "$NOTARYTOOL_PROFILE" --output-format json >/dev/null
  result_json="$($XCRUN_BIN notarytool submit "$submission" \
    --keychain-profile "$NOTARYTOOL_PROFILE" --no-s3-acceleration --wait --output-format json)"
else
  "$XCRUN_BIN" notarytool history --key "$KEY_FILE" --key-id "$key_id" --issuer "$issuer_id" \
    --output-format json >/dev/null
  result_json="$($XCRUN_BIN notarytool submit "$submission" --key "$KEY_FILE" --key-id "$key_id" \
    --issuer "$issuer_id" --no-s3-acceleration --wait --output-format json)"
  /bin/rm -P "$KEY_FILE" 2>/dev/null || /bin/rm -f "$KEY_FILE"
  KEY_FILE=""
fi

result_status="$(printf '%s' "$result_json" | /usr/bin/plutil -extract status raw -o - - 2>/dev/null)" || \
  fail 'notary response is malformed'
submission_id="$(printf '%s' "$result_json" | /usr/bin/plutil -extract id raw -o - - 2>/dev/null)" || \
  fail 'notary response is malformed'
[[ "$result_status" == Accepted &&
  "$submission_id" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[1-5][0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$ ]] || \
  fail 'notary submission was not accepted'

if [[ "$KIND" == app || "$KIND" == dmg ]]; then
  "$XCRUN_BIN" stapler staple "$working_artifact"
  "$XCRUN_BIN" stapler validate "$working_artifact"
fi
if [[ "$KIND" == app ]]; then
  "$CODESIGN_BIN" --verify --deep --strict --check-notarization -R=notarized --verbose=2 "$working_artifact"
  assert_no_xattrs "$working_artifact"
  /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$working_artifact" > "$WORK_DIR/final-tree.json"
  final_sha256="$(/usr/bin/shasum -a 256 "$WORK_DIR/final-tree.json" | /usr/bin/awk '{print $1}')"
  final_size="$(/usr/bin/stat -f%z "$WORK_DIR/final-tree.json")"
  final_kind=tree
elif [[ "$KIND" == controller-tree || "$KIND" == cli-tree ]]; then
  if [[ "$KIND" == controller-tree ]]; then
    verify_controller_tree_identities true || fail 'qualification tree post-notary identity mismatch'
  else
    verify_cli_tree_identities true || fail 'CLI tree post-notary identity mismatch'
  fi
  assert_no_xattrs "$working_artifact"
  /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$working_artifact" > "$WORK_DIR/final-tree.json"
  final_sha256="$(/usr/bin/shasum -a 256 "$WORK_DIR/final-tree.json" | /usr/bin/awk '{print $1}')"
  final_size="$(/usr/bin/stat -f%z "$WORK_DIR/final-tree.json")"
  final_kind=tree
else
  "$CODESIGN_BIN" --verify --strict --check-notarization -R=notarized --verbose=2 "$working_artifact"
  assert_no_xattrs "$working_artifact"
  final_sha256="$(/usr/bin/shasum -a 256 "$working_artifact" | /usr/bin/awk '{print $1}')"
  final_size="$(/usr/bin/stat -f%z "$working_artifact")"
  final_kind=sha256
fi

receipt_tmp="$WORK_DIR/receipt.json"
/usr/bin/plutil -create xml1 "$receipt_tmp"
/usr/bin/plutil -insert version -integer 2 "$receipt_tmp"
/usr/bin/plutil -insert kind -string "$RECEIPT_KIND" "$receipt_tmp"
/usr/bin/plutil -insert id -string "$submission_id" "$receipt_tmp"
/usr/bin/plutil -insert status -string "$result_status" "$receipt_tmp"
/usr/bin/plutil -insert submission -dictionary "$receipt_tmp"
/usr/bin/plutil -insert submission.path -string "notary/submissions/$submission_sha256" "$receipt_tmp"
/usr/bin/plutil -insert submission.sha256 -string "$submission_sha256" "$receipt_tmp"
/usr/bin/plutil -insert submission.size -integer "$submission_size" "$receipt_tmp"
/usr/bin/plutil -insert code_identity -dictionary "$receipt_tmp"
/usr/bin/plutil -insert code_identity.authority -string "$code_authority" "$receipt_tmp"
/usr/bin/plutil -insert code_identity.identifier -string "$code_identifier" "$receipt_tmp"
/usr/bin/plutil -insert code_identity.team_id -string "$code_team_id" "$receipt_tmp"
/usr/bin/plutil -insert code_identity.cdhash -string "$code_cdhash" "$receipt_tmp"
/usr/bin/plutil -insert code_identity.architectures -json "$code_architectures_json" "$receipt_tmp"
/usr/bin/plutil -insert code_identity.cdhashes -json "$code_cdhashes_json" "$receipt_tmp"
/usr/bin/plutil -insert final_artifact -dictionary "$receipt_tmp"
if [[ "$final_kind" == tree ]]; then
  /usr/bin/plutil -insert final_artifact.tree_manifest_sha256 -string "$final_sha256" "$receipt_tmp"
  /usr/bin/plutil -insert final_artifact.tree_manifest_size -integer "$final_size" "$receipt_tmp"
else
  /usr/bin/plutil -insert final_artifact.sha256 -string "$final_sha256" "$receipt_tmp"
  /usr/bin/plutil -insert final_artifact.size -integer "$final_size" "$receipt_tmp"
fi
/usr/bin/plutil -convert json "$receipt_tmp"
publish_dir="$(mktemp -d "$(dirname "$TRANSACTION_DIR")/.notary-publish.XXXXXX")"
mkdir -p "$(dirname "$TRANSACTION_DIR")"
chmod 444 "$receipt_tmp"
mv "$receipt_tmp" "$publish_dir/receipt.json"
if [[ "$KIND" == app || "$KIND" == dmg ]]; then
  mv "$working_artifact" "$publish_dir/$(basename "$working_artifact")"
fi
if [[ "$KIND" == app || "$KIND" == controller-tree || "$KIND" == cli-tree ]]; then
  mv "$WORK_DIR/final-tree.json" "$publish_dir/tree.json"
  chmod 444 "$publish_dir/tree.json"
fi
mv "$retained_submission" "$publish_dir/submission.bin"
"$ROOT_DIR/scripts/atomic-rename-exclusive.rb" "$publish_dir" "$TRANSACTION_DIR"
publish_dir=""
printf 'Notarization accepted: %s\n' "$submission_id"
