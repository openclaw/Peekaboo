#!/usr/bin/env bash

# Narrow notarization helper for already-built, already-signed terminal artifacts.
# This script never resolves dependencies or invokes a compiler.

set -euo pipefail
umask 077

KIND=""
ARTIFACT=""
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-${NOTARYTOOL_KEYCHAIN_PROFILE:-}}"
RESULT_PATH=""
XCRUN_BIN="${TERMINAL_NOTARY_XCRUN_BIN:-/usr/bin/xcrun}"
DITTO_BIN="${TERMINAL_NOTARY_DITTO_BIN:-/usr/bin/ditto}"
NODE_BIN="${TERMINAL_NOTARY_NODE_BIN:-$(command -v node || true)}"
CODESIGN_BIN="${TERMINAL_NOTARY_CODESIGN_BIN:-/usr/bin/codesign}"
JQ_BIN="${TERMINAL_NOTARY_JQ_BIN:-$(command -v jq || true)}"

fail() {
  printf 'notarize-terminal-artifact: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: scripts/notarize-terminal-artifact.sh --kind cli|app --artifact PATH [options]

Options:
  --notary-profile NAME  Use an existing notarytool keychain profile.
  --result PATH          Write a sanitized accepted-result receipt.
  --help                 Show this help.

Without a profile, APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, and
APP_STORE_CONNECT_API_KEY_P8 must already be present in this narrow finalizer.
EOF
}

while (($# > 0)); do
  case "$1" in
    --kind)
      [[ "$#" -ge 2 ]] || fail '--kind requires a value'
      KIND="$2"
      shift 2
      ;;
    --artifact)
      [[ "$#" -ge 2 ]] || fail '--artifact requires a path'
      ARTIFACT="$2"
      shift 2
      ;;
    --notary-profile)
      [[ "$#" -ge 2 ]] || fail '--notary-profile requires a value'
      NOTARYTOOL_PROFILE="$2"
      shift 2
      ;;
    --result)
      [[ "$#" -ge 2 ]] || fail '--result requires a path'
      RESULT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      fail "unknown argument: $1"
      ;;
  esac
done

[[ "$KIND" == cli || "$KIND" == app ]] || fail '--kind must be cli or app'
[[ "$ARTIFACT" == /* ]] || ARTIFACT="$(pwd)/$ARTIFACT"
if [[ "$KIND" == cli ]]; then
  [[ -f "$ARTIFACT" && -x "$ARTIFACT" && ! -L "$ARTIFACT" ]] || \
    fail "CLI artifact missing, not executable, or symlinked: $ARTIFACT"
else
  [[ -d "$ARTIFACT" && ! -L "$ARTIFACT" ]] || fail "app artifact missing or symlinked: $ARTIFACT"
fi
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail 'node is required to validate the notary response'
[[ -n "$JQ_BIN" && -x "$JQ_BIN" ]] || fail 'jq is required to write the notary receipt'

WORK_DIR="$(mktemp -d /tmp/peekaboo-terminal-notary.XXXXXX)"
KEY_FILE=""
cleanup() {
  if [[ -n "$KEY_FILE" && -f "$KEY_FILE" ]]; then
    /bin/rm -P "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
  fi
  rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

SUBMISSION_ZIP="$WORK_DIR/submission.zip"
if [[ "$KIND" == cli ]]; then
  "$DITTO_BIN" -c -k --sequesterRsrc "$ARTIFACT" "$SUBMISSION_ZIP"
else
  "$DITTO_BIN" -c -k --sequesterRsrc --keepParent "$ARTIFACT" "$SUBMISSION_ZIP"
fi

if [[ -n "$NOTARYTOOL_PROFILE" ]]; then
  "$XCRUN_BIN" notarytool history \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --output-format json >/dev/null
  RESULT_JSON="$($XCRUN_BIN notarytool submit "$SUBMISSION_ZIP" \
    --keychain-profile "$NOTARYTOOL_PROFILE" \
    --no-s3-acceleration \
    --wait \
    --output-format json)"
else
  [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]] || fail 'APP_STORE_CONNECT_KEY_ID missing'
  [[ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]] || fail 'APP_STORE_CONNECT_ISSUER_ID missing'
  [[ -n "${APP_STORE_CONNECT_API_KEY_P8:-}" ]] || fail 'APP_STORE_CONNECT_API_KEY_P8 missing'
  [[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail 'node is required for API-key materialization'

  KEY_FILE="$WORK_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  APP_STORE_CONNECT_API_KEY_P8="$APP_STORE_CONNECT_API_KEY_P8" "$NODE_BIN" > "$KEY_FILE" <<'EOF'
const raw = process.env.APP_STORE_CONNECT_API_KEY_P8 ?? "";
let pem = raw.replace(/\\n/g, "\n").trim();
if (!pem.includes("\n")) {
  const match = pem.match(/^(-----BEGIN [^-]+-----)\s*(.+?)\s*(-----END [^-]+-----)$/);
  if (match) {
    const body = match[2].replace(/\s+/g, "");
    const wrapped = body.match(/.{1,64}/g)?.join("\n") ?? body;
    pem = `${match[1]}\n${wrapped}\n${match[3]}`;
  }
}
process.stdout.write(`${pem}\n`);
EOF
  chmod 600 "$KEY_FILE"
  "$XCRUN_BIN" notarytool history \
    --key "$KEY_FILE" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --output-format json >/dev/null
  RESULT_JSON="$($XCRUN_BIN notarytool submit "$SUBMISSION_ZIP" \
    --key "$KEY_FILE" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --no-s3-acceleration \
    --wait \
    --output-format json)"
fi

RESULT_STATUS="$(NOTARY_RESULT_JSON="$RESULT_JSON" "$NODE_BIN" -e \
  'const value=JSON.parse(process.env.NOTARY_RESULT_JSON); process.stdout.write(value.status ?? "")')"
SUBMISSION_ID="$(NOTARY_RESULT_JSON="$RESULT_JSON" "$NODE_BIN" -e \
  'const value=JSON.parse(process.env.NOTARY_RESULT_JSON); process.stdout.write(value.id ?? "")')"
[[ "$RESULT_STATUS" == Accepted ]] || fail "submission was not accepted: ${RESULT_STATUS:-missing status}"
[[ -n "$SUBMISSION_ID" ]] || fail 'accepted response omitted the submission ID'

if [[ -n "$RESULT_PATH" ]]; then
  [[ "$RESULT_PATH" == /* ]] || RESULT_PATH="$(pwd)/$RESULT_PATH"
  [[ ! -e "$RESULT_PATH" && ! -L "$RESULT_PATH" ]] || fail "result path already exists: $RESULT_PATH"
  mkdir -p "$(dirname "$RESULT_PATH")"
  # shellcheck disable=SC2016 # jq variables are intentionally expanded by jq.
  "$JQ_BIN" -n \
    --arg kind "$KIND" \
    --arg id "$SUBMISSION_ID" \
    --arg status "$RESULT_STATUS" \
    '{version: 1, kind: $kind, id: $id, status: $status}' > "$RESULT_PATH"
  chmod 444 "$RESULT_PATH"
fi

if [[ "$KIND" == app ]]; then
  "$XCRUN_BIN" stapler staple "$ARTIFACT"
  "$XCRUN_BIN" stapler validate "$ARTIFACT"
  "$CODESIGN_BIN" --verify --deep --strict --check-notarization -R=notarized --verbose=2 "$ARTIFACT"
else
  "$CODESIGN_BIN" --verify --strict --check-notarization -R=notarized --verbose=2 "$ARTIFACT"
fi

printf 'Notarization accepted: %s\n' "$SUBMISSION_ID"
