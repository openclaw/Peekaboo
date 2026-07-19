#!/usr/bin/env bash
# Create, sign, notarize, staple, and verify a branded Peekaboo DMG from the release app zip.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_RELEASE_MANIFEST="${MAC_RELEASE_MANIFEST:-$ROOT_DIR/.mac-release.env}"
if [[ -f "$MAC_RELEASE_MANIFEST" ]]; then
  pushd "$ROOT_DIR" >/dev/null
  # shellcheck source=/Users/steipete/Projects/Peekaboo/.mac-release.env
  source "$MAC_RELEASE_MANIFEST"
  popd >/dev/null
fi

APP_NAME="${APP_NAME:-${MAC_RELEASE_APP_NAME:-Peekaboo}}"
VERSION="${VERSION:-$(node -p "require('$ROOT_DIR/package.json').version")}"
EXPECTED_SIGN_IDENTITY="Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)"
EXPECTED_TEAM_ID="FWJYW4S8P8"
EXPECTED_SIGN_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
SIGN_IDENTITY="${MAC_RELEASE_CODESIGN_IDENTITY:-${SIGN_IDENTITY:-$EXPECTED_SIGN_IDENTITY}}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-${NOTARYTOOL_KEYCHAIN_PROFILE:-}}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/build/release}"
APP_ZIP="${APP_ZIP:-}"
DMG_PATH="${DMG_PATH:-}"
BACKGROUND="${DMG_BACKGROUND:-$ROOT_DIR/assets/dmg-background.png}"
NOTARIZE=true
VERIFY_ONLY_DMG=""

usage() {
  cat <<EOF
Usage: scripts/create-release-dmg.sh [options]

Options:
  --version <version>          Release version (default: package.json version).
  --app-zip <path>            Signed app zip to package.
  --output <path>             Output DMG path.
  --background <path>         720x460 PNG background.
  --sign-identity <identity>   Developer ID Application identity.
  --notary-profile <profile>   notarytool keychain profile.
  --no-notarize                Sign and verify without DMG notarization.
  --verify-only <dmg>          Verify an existing DMG, then exit.
  --help                       Show this help.

Notarization uses NOTARYTOOL_PROFILE when set, otherwise APP_STORE_CONNECT_KEY_ID,
APP_STORE_CONNECT_ISSUER_ID, and APP_STORE_CONNECT_API_KEY_P8.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --app-zip)
      APP_ZIP="$2"
      shift 2
      ;;
    --output)
      DMG_PATH="$2"
      shift 2
      ;;
    --background)
      BACKGROUND="$2"
      shift 2
      ;;
    --sign-identity)
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --notary-profile)
      NOTARYTOOL_PROFILE="$2"
      shift 2
      ;;
    --no-notarize)
      NOTARIZE=false
      shift
      ;;
    --verify-only)
      VERIFY_ONLY_DMG="$2"
      DMG_PATH="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

APP_ZIP="${APP_ZIP:-$RELEASE_DIR/$APP_NAME-$VERSION.app.zip}"
DMG_PATH="${DMG_PATH:-$RELEASE_DIR/$APP_NAME-$VERSION.dmg}"

WORK_DIR="$(mktemp -d /tmp/peekaboo-dmg.XXXXXX)"
NOTARY_DIR="$(mktemp -d /tmp/peekaboo-dmg-notary.XXXXXX)"
MOUNT_DIR=""

cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR" "$NOTARY_DIR"
}
trap cleanup EXIT

log() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "$1 not found"; }

require_command codesign
require_command hdiutil
require_command spctl
require_command xcrun

verify_identity() {
  local artifact="$1"
  local authority team_id

  authority="$(codesign -dv --verbose=4 "$artifact" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  team_id="$(codesign -dv --verbose=4 "$artifact" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  [[ "$authority" == "$EXPECTED_SIGN_IDENTITY" ]] ||
    fail "$artifact is signed with '$authority'; expected '$EXPECTED_SIGN_IDENTITY'"
  [[ "$team_id" == "$EXPECTED_TEAM_ID" ]] ||
    fail "$artifact has TeamIdentifier '$team_id'; expected '$EXPECTED_TEAM_ID'"
  codesign --verify --strict -R="$EXPECTED_SIGN_REQUIREMENT" "$artifact"
}

verify_nested_app_identities() {
  local app_path="$1"
  local candidate
  local count=0

  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q 'Mach-O'; then
      codesign --verify --strict --verbose=2 "$candidate"
      verify_identity "$candidate"
      count=$((count + 1))
    fi
  done < <(find "$app_path/Contents" -type f -perm -111 -print0)

  ((count > 0)) || fail "No signed Mach-O payloads found in $app_path"
  log "Verified Foundation authority on $count nested Mach-O payloads"
}

verify_app() {
  local app_path="$1"
  local short_version

  [[ -d "$app_path" ]] || fail "App missing from DMG: $app_path"
  short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
  [[ "$short_version" == "$VERSION" ]] ||
    fail "App version mismatch: expected $VERSION, got $short_version"
  codesign --verify --deep --strict --verbose=2 "$app_path"
  verify_identity "$app_path"
  verify_nested_app_identities "$app_path"
  if [[ "$NOTARIZE" == true ]]; then
    codesign --verify --deep --strict --check-notarization -R=notarized --verbose=2 "$app_path"
    xcrun stapler validate "$app_path"
    spctl --assess --type exec --verbose=4 "$app_path"
  fi
}

detach_mount() {
  local mount_dir="$1"
  local max_attempts=5
  local attempt

  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if hdiutil detach "$mount_dir" -quiet; then
      return 0
    fi
    if ((attempt < max_attempts)); then
      log "DMG mount is busy; retrying detach ($attempt/$max_attempts)"
      sleep 1
    fi
  done

  fail "Could not detach DMG mount after $max_attempts attempts: $mount_dir"
}

verify_dmg() {
  local dmg_path="$1"
  local applications_link background_name

  [[ -f "$dmg_path" ]] || fail "DMG missing: $dmg_path"
  hdiutil verify "$dmg_path" >/dev/null
  codesign --verify --strict --verbose=2 "$dmg_path"
  verify_identity "$dmg_path"
  if [[ "$NOTARIZE" == true ]]; then
    codesign --verify --strict --check-notarization -R=notarized --verbose=2 "$dmg_path"
    xcrun stapler validate "$dmg_path"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
  fi

  MOUNT_DIR="$(mktemp -d /tmp/peekaboo-dmg-mount.XXXXXX)"
  hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$MOUNT_DIR" "$dmg_path" >/dev/null
  verify_app "$MOUNT_DIR/$APP_NAME.app"

  applications_link="$MOUNT_DIR/Applications"
  [[ -L "$applications_link" ]] || fail "Applications link missing from DMG"
  [[ "$(readlink "$applications_link")" == "/Applications" ]] ||
    fail "Applications link has unexpected target: $(readlink "$applications_link")"
  background_name="$(basename "$BACKGROUND")"
  [[ -f "$MOUNT_DIR/.background/$background_name" ]] || fail "DMG background missing"
  [[ -f "$MOUNT_DIR/.DS_Store" ]] || fail "DMG Finder layout missing"
  [[ -f "$MOUNT_DIR/.VolumeIcon.icns" ]] || fail "DMG volume icon missing"

  detach_mount "$MOUNT_DIR"
  rmdir "$MOUNT_DIR"
  MOUNT_DIR=""
}

submit_for_notarization() {
  local artifact="$1"

  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$NOTARYTOOL_PROFILE" \
      --no-s3-acceleration \
      --wait
    return
  fi

  [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]] || fail "APP_STORE_CONNECT_KEY_ID missing"
  [[ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]] || fail "APP_STORE_CONNECT_ISSUER_ID missing"
  [[ -n "${APP_STORE_CONNECT_API_KEY_P8:-}" ]] || fail "APP_STORE_CONNECT_API_KEY_P8 missing"
  require_command node

  local key_file="$NOTARY_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
  APP_STORE_CONNECT_API_KEY_P8="$APP_STORE_CONNECT_API_KEY_P8" node > "$key_file" <<'EOF'
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
  chmod 600 "$key_file"
  xcrun notarytool submit "$artifact" \
    --key "$key_file" \
    --key-id "$APP_STORE_CONNECT_KEY_ID" \
    --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
    --no-s3-acceleration \
    --wait
  rm -f "$key_file"
}

if [[ -n "$VERIFY_ONLY_DMG" ]]; then
  log "Verifying existing DMG"
  verify_dmg "$VERIFY_ONLY_DMG"
  log "Done"
  exit 0
fi

require_command create-dmg
require_command ditto
require_command sips
require_command shasum

[[ "$SIGN_IDENTITY" == "$EXPECTED_SIGN_IDENTITY" ]] ||
  fail "official DMGs must use '$EXPECTED_SIGN_IDENTITY'"
[[ -f "$APP_ZIP" ]] || fail "App zip not found: $APP_ZIP"
[[ -f "$BACKGROUND" ]] || fail "DMG background not found: $BACKGROUND"

background_width="$(sips -g pixelWidth "$BACKGROUND" | awk '/pixelWidth/{print $2}')"
background_height="$(sips -g pixelHeight "$BACKGROUND" | awk '/pixelHeight/{print $2}')"
[[ "$background_width" == "720" && "$background_height" == "460" ]] ||
  fail "DMG background must be 720x460; got ${background_width}x${background_height}"

SOURCE_DIR="$WORK_DIR/source"
mkdir -p "$SOURCE_DIR"
ditto -x -k "$APP_ZIP" "$SOURCE_DIR"
APP_BUNDLE="$SOURCE_DIR/$APP_NAME.app"
verify_app "$APP_BUNDLE"

VOLUME_ICON="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
[[ -f "$VOLUME_ICON" ]] || fail "App volume icon missing: $VOLUME_ICON"
mkdir -p "$(dirname "$DMG_PATH")"
rm -f "$DMG_PATH"

log "Creating branded DMG"
create-dmg \
  --volname "$APP_NAME $VERSION" \
  --volicon "$VOLUME_ICON" \
  --background "$BACKGROUND" \
  --window-pos 200 120 \
  --window-size 720 460 \
  --text-size 13 \
  --icon-size 128 \
  --icon "$APP_NAME.app" 180 230 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 540 230 \
  --no-internet-enable \
  --hdiutil-quiet \
  --overwrite \
  "$DMG_PATH" \
  "$SOURCE_DIR"

log "Developer ID signing DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --strict --verbose=2 "$DMG_PATH"
verify_identity "$DMG_PATH"

if [[ "$NOTARIZE" == true ]]; then
  log "Submitting DMG to Apple notarization"
  submit_for_notarization "$DMG_PATH"
  log "Stapling DMG notarization ticket"
  xcrun stapler staple "$DMG_PATH"
fi

log "Verifying DMG"
verify_dmg "$DMG_PATH"

DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
log "Done"
printf 'DMG: %s\n' "$DMG_PATH"
printf 'SHA256: %s\n' "$DMG_SHA256"
printf 'Length: %s\n' "$(stat -f%z "$DMG_PATH")"
