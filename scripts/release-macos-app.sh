#!/usr/bin/env bash
# Build, sign, notarize, staple, package, Sparkle-sign, and optionally upload Peekaboo.app.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${ROOT:-$ROOT_DIR}"
MAC_RELEASE_MANIFEST="${MAC_RELEASE_MANIFEST:-$ROOT_DIR/.mac-release.env}"
MAC_RELEASE_MANIFEST_LOADED=false
if [[ -f "$MAC_RELEASE_MANIFEST" ]]; then
  pushd "$ROOT_DIR" >/dev/null
  # shellcheck source=/Users/steipete/Projects/Peekaboo/.mac-release.env
  source "$MAC_RELEASE_MANIFEST"
  popd >/dev/null
  MAC_RELEASE_MANIFEST_LOADED=true
fi
MAC_RELEASE_HELPER_LOADED=false
for candidate in \
  "${MAC_RELEASE_LIB:-}" \
  "$ROOT_DIR/../agent-scripts/skills/release-mac-app/scripts/lib/mac_release.sh" \
  "$HOME/Projects/agent-scripts/skills/release-mac-app/scripts/lib/mac_release.sh"; do
  if [[ -n "$candidate" && -f "$candidate" ]]; then
    # shellcheck source=/Users/steipete/Projects/agent-scripts/skills/release-mac-app/scripts/lib/mac_release.sh
    source "$candidate"
    MAC_RELEASE_HELPER_LOADED=true
    break
  fi
done
if [[ "$MAC_RELEASE_HELPER_LOADED" == true && "$MAC_RELEASE_MANIFEST_LOADED" == true ]]; then
  mac_release_load
else
  MAC_RELEASE_HELPER_LOADED=false
fi

version_to_build_number() {
  if declare -F mac_release_build_number >/dev/null; then
    mac_release_build_number "$1"
    return
  fi

  local version=${1:?"version required"} core prerelease major minor patch suffix prerelease_label prerelease_number
  core=${version%%-*}
  prerelease=
  if [[ "$version" == *-* ]]; then
    prerelease=${version#*-}
  fi
  IFS=. read -r major minor patch <<<"$core"
  if [[ ! "$major" =~ ^[0-9]+$ || ! "$minor" =~ ^[0-9]+$ || ! "$patch" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Version must be numeric semver: $version" >&2
    exit 1
  fi
  if ((10#$minor > 99 || 10#$patch > 99)); then
    echo "ERROR: Minor and patch versions must be <= 99 for generated build numbers: $version" >&2
    exit 1
  fi

  suffix=99
  if [[ -n "$prerelease" ]]; then
    prerelease_label=${prerelease%%.*}
    prerelease_label=${prerelease_label%%-*}
    prerelease_label=${prerelease_label%%[0-9]*}
    prerelease_label=${prerelease_label,,}
    if [[ "$prerelease" =~ ([0-9]+)$ ]]; then
      prerelease_number=${BASH_REMATCH[1]}
    else
      prerelease_number=1
    fi
    if ((10#$prerelease_number < 1 || 10#$prerelease_number > 29)); then
      echo "ERROR: Prerelease number must be 1..29 for generated build numbers: $version" >&2
      exit 1
    fi
    case "$prerelease_label" in
      alpha | a) suffix=$((10#$prerelease_number)) ;;
      beta | b) suffix=$((30 + 10#$prerelease_number)) ;;
      rc) suffix=$((60 + 10#$prerelease_number)) ;;
      *)
        echo "ERROR: Prerelease label must be alpha, beta, or rc for generated build numbers: $version" >&2
        exit 1
        ;;
    esac
  fi

  printf '%d\n' $((((10#$major * 100 + 10#$minor) * 100 + 10#$patch) * 100 + 10#$suffix))
}

MARKETING_VERSION="${MARKETING_VERSION:-$(node -p "require('$ROOT_DIR/package.json').version")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(version_to_build_number "$MARKETING_VERSION")}"

WORKSPACE="${WORKSPACE:-$ROOT_DIR/Apps/Peekaboo.xcworkspace}"
SCHEME="${SCHEME:-Peekaboo}"
CONFIGURATION="${CONFIGURATION:-Release}"
DESTINATION="${DESTINATION:-platform=macOS,arch=arm64}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-/tmp/peekaboo-macos-app-release}"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/release}"
APP_NAME="${APP_NAME:-${MAC_RELEASE_APP_NAME:-Peekaboo}}"
EXPECTED_SIGN_IDENTITY="Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)"
EXPECTED_TEAM_ID="FWJYW4S8P8"
EXPECTED_SIGN_REQUIREMENT="anchor apple generic and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
SIGN_IDENTITY="${MAC_RELEASE_CODESIGN_IDENTITY:-${SIGN_IDENTITY:-$EXPECTED_SIGN_IDENTITY}}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-${NOTARYTOOL_KEYCHAIN_PROFILE:-}}"
APPCAST="${APPCAST:-${MAC_RELEASE_APPCAST:-appcast.xml}}"
APPCAST_PATH="${APPCAST_PATH:-$ROOT_DIR/$APPCAST}"
MINIMUM_SYSTEM_VERSION="${MINIMUM_SYSTEM_VERSION:-15.0}"
REPOSITORY_SLUG="${REPOSITORY_SLUG:-${MAC_RELEASE_REPO:-openclaw/Peekaboo}}"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$ROOT_DIR/Apps/Mac/Peekaboo/Peekaboo.entitlements}"
DMG_BACKGROUND="${DMG_BACKGROUND:-$ROOT_DIR/assets/dmg-background.png}"

VERSION="${VERSION:-$MARKETING_VERSION}"
TAG="v${VERSION}"
UPDATE_APPCAST=true
UPLOAD=false
UPLOAD_CHECKSUMS=false
NOTARIZE=true
KEEP_DERIVED_DATA=false
DRY_RUN=false
SKIP_BUILD=false
VERIFY_ONLY_ZIP=""
INCLUDE_DMG=true

usage() {
  cat <<EOF
Usage: scripts/release-macos-app.sh [options]

Options:
  --version <version>            Override package.json version.
  --tag <tag>                    Override GitHub release tag (default: v<version>).
  --sparkle-key <path>           Sparkle EdDSA private key file.
  --sign-identity <identity>     Developer ID signing identity.
  --notary-profile <profile>     notarytool keychain profile.
  --dry-run                      Build/sign/package/verify in /tmp; no notarization, appcast, or upload.
  --skip-build                   Reuse the app already in DerivedData.
  --verify-only <zip>            Verify an existing zip's extracted app, then exit.
  --no-notarize                  Build/sign/zip without Apple notarization.
  --no-appcast                   Do not update appcast.xml.
  --skip-dmg                     Do not create the branded DMG.
  --upload                       Upload the app zip and DMG to the GitHub release.
  --upload-checksums             Also upload checksums.txt; requires an existing checksum file.
  --keep-derived-data            Keep Xcode DerivedData after completion.
  --help                         Show this help.

Notarization uses NOTARYTOOL_PROFILE when set, otherwise APP_STORE_CONNECT_KEY_ID,
APP_STORE_CONNECT_ISSUER_ID, and APP_STORE_CONNECT_API_KEY_P8.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --)
      shift
      ;;
    --version)
      VERSION="$2"
      TAG="v${VERSION}"
      BUILD_NUMBER="$(version_to_build_number "$VERSION")"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --sparkle-key)
      SPARKLE_PRIVATE_KEY_FILE="$2"
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
    --dry-run)
      DRY_RUN=true
      NOTARIZE=false
      UPDATE_APPCAST=false
      UPLOAD=false
      shift
      ;;
    --skip-build)
      SKIP_BUILD=true
      shift
      ;;
    --verify-only)
      VERIFY_ONLY_ZIP="$2"
      SKIP_BUILD=true
      UPDATE_APPCAST=false
      UPLOAD=false
      shift 2
      ;;
    --no-notarize)
      NOTARIZE=false
      shift
      ;;
    --no-appcast)
      UPDATE_APPCAST=false
      shift
      ;;
    --skip-dmg)
      INCLUDE_DMG=false
      shift
      ;;
    --upload)
      UPLOAD=true
      shift
      ;;
    --upload-checksums)
      UPLOAD_CHECKSUMS=true
      shift
      ;;
    --keep-derived-data)
      KEEP_DERIVED_DATA=true
      shift
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

if [[ "$DRY_RUN" == true ]]; then
  NOTARIZE=false
  UPDATE_APPCAST=false
  UPLOAD=false
  UPLOAD_CHECKSUMS=false
  RELEASE_DIR="$(mktemp -d /tmp/peekaboo-macos-app-dry-run.XXXXXX)"
fi

if [[ "$UPLOAD_CHECKSUMS" == true && "$UPLOAD" != true ]]; then
  echo "ERROR: --upload-checksums requires --upload" >&2
  exit 1
fi

APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
ZIP_NAME="$APP_NAME-${VERSION}.app.zip"
ZIP_PATH="$RELEASE_DIR/$ZIP_NAME"
DMG_NAME="$APP_NAME-${VERSION}.dmg"
DMG_PATH="$RELEASE_DIR/$DMG_NAME"
RELEASE_URL="https://github.com/$REPOSITORY_SLUG/releases/tag/$TAG"
ASSET_URL="https://github.com/$REPOSITORY_SLUG/releases/download/$TAG/$ZIP_NAME"
NOTARY_DIR="$(mktemp -d /tmp/peekaboo-notary.XXXXXX)"
VERIFY_DIR="$(mktemp -d /tmp/peekaboo-zip-verify.XXXXXX)"

cleanup() {
  rm -rf "$NOTARY_DIR" "$VERIFY_DIR"
  [[ -z "${SPARKLE_KEY_FILE:-}" ]] || rm -f "$SPARKLE_KEY_FILE"
  if [[ "$DRY_RUN" == true ]]; then
    rm -rf "$RELEASE_DIR"
  fi
  if [[ -z "$VERIFY_ONLY_ZIP" && "$KEEP_DERIVED_DATA" != true ]]; then
    rm -rf "$DERIVED_DATA_PATH"
  fi
}
trap cleanup EXIT

log() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
require_command() { command -v "$1" >/dev/null 2>&1 || fail "$1 not found"; }

require_command codesign
require_command ditto
require_command file
require_command realpath
if [[ -z "$VERIFY_ONLY_ZIP" ]]; then
  require_command node
  require_command xcodebuild
  require_command shasum
  require_command sign_update
  if [[ "$INCLUDE_DMG" == true ]]; then
    require_command create-dmg
  fi
fi
if [[ "$NOTARIZE" == true ]]; then
  require_command xcrun
  require_command spctl
fi

assess_app_bundle() {
  local app_path="$1"

  spctl --assess --type open --context context:primary-signature --verbose=4 "$app_path"
}

bundle_executable_name() {
  local app_path="$1"

  /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist" 2>/dev/null ||
    fail "Could not read CFBundleExecutable from $app_path"
}

verify_app_payload() {
  local app_path="$1"
  local executable_name
  executable_name="$(bundle_executable_name "$app_path")"
  local executable_path="$app_path/Contents/MacOS/$executable_name"

  [[ -x "$executable_path" ]] || fail "Main executable missing or not executable: $executable_path"

  local executable_size
  executable_size="$(stat -f%z "$executable_path")"
  (( executable_size > 1000000 )) || fail "Main executable is unexpectedly small: $executable_size bytes"

  file "$executable_path" | grep -q 'Mach-O' ||
    fail "Main executable is not a Mach-O binary: $executable_path"

  local sparkle_binary="$app_path/Contents/Frameworks/Sparkle.framework/Sparkle"
  if [[ -e "$sparkle_binary" ]]; then
    [[ -x "$sparkle_binary" ]] || fail "Sparkle framework binary is not executable: $sparkle_binary"
    local sparkle_payload="$sparkle_binary"
    if [[ -L "$sparkle_binary" ]]; then
      sparkle_payload="$(realpath "$sparkle_binary")"
    fi
    local sparkle_size
    sparkle_size="$(stat -f%z "$sparkle_payload")"
    (( sparkle_size > 100000 )) || fail "Sparkle framework binary is unexpectedly small: $sparkle_size bytes"
  fi
}

verify_app_entitlements() {
  local app_path="$1"
  local entitlements

  entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
  printf '%s\n' "$entitlements" | grep -q 'com.apple.security.automation.apple-events' ||
    fail "Signed app is missing AppleEvents entitlement: $app_path"
}

verify_developer_id_signature() {
  local bundle="$1"
  local authority
  local team_id

  authority="$(codesign -dv --verbose=4 "$bundle" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  team_id="$(codesign -dv --verbose=4 "$bundle" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  [[ "$authority" == "$EXPECTED_SIGN_IDENTITY" ]] ||
    fail "$bundle is signed with '$authority'; expected '$EXPECTED_SIGN_IDENTITY'"
  [[ "$team_id" == "$EXPECTED_TEAM_ID" ]] ||
    fail "$bundle has TeamIdentifier '$team_id'; expected '$EXPECTED_TEAM_ID'"
  codesign --verify --strict -R="$EXPECTED_SIGN_REQUIREMENT" "$bundle"
}

verify_nested_developer_id_signatures() {
  local app_path="$1"
  local candidate
  local count=0

  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q 'Mach-O'; then
      codesign --verify --strict --verbose=2 "$candidate"
      verify_developer_id_signature "$candidate"
      count=$((count + 1))
    fi
  done < <(find "$app_path/Contents" -type f -perm -111 -print0)

  ((count > 0)) || fail "No signed Mach-O payloads found in $app_path"
  log "Verified Foundation authority on $count nested Mach-O payloads"
}

if [[ -z "$VERIFY_ONLY_ZIP" ]]; then
  if [[ "$NOTARIZE" == true && "$SIGN_IDENTITY" != "$EXPECTED_SIGN_IDENTITY" ]]; then
    fail "official releases must use '$EXPECTED_SIGN_IDENTITY'"
  fi
  [[ -d "$WORKSPACE" ]] || fail "Workspace not found: $WORKSPACE"
  mkdir -p "$RELEASE_DIR"
  SPARKLE_KEY_ARGS=()
  SPARKLE_KEY_FILE=""
  if [[ "$MAC_RELEASE_HELPER_LOADED" == true ]]; then
    SAVED_VERSION="$VERSION"
    SAVED_TAG="$TAG"
    SAVED_BUILD_NUMBER="$BUILD_NUMBER"
    mac_release_key_args_and_validate SPARKLE_KEY_ARGS SPARKLE_KEY_FILE
    VERSION="$SAVED_VERSION"
    TAG="$SAVED_TAG"
    BUILD_NUMBER="$SAVED_BUILD_NUMBER"
  else
    if [[ -z "${SPARKLE_PRIVATE_KEY_FILE:-}" && -n "${MAC_RELEASE_SIGNING_KEY_FILE:-}" ]]; then
      SPARKLE_PRIVATE_KEY_FILE="$(eval "printf '%s' \"$MAC_RELEASE_SIGNING_KEY_FILE\"")"
    fi
    [[ -f "${SPARKLE_PRIVATE_KEY_FILE:-}" ]] || fail "Sparkle private key not found; set SPARKLE_PRIVATE_KEY_FILE or install agent-scripts helper."
    SPARKLE_KEY_ARGS=(--ed-key-file "$SPARKLE_PRIVATE_KEY_FILE")
  fi
fi

verify_zip() {
  local zip_path="$1"
  local verify_dir="$2"

  [[ -f "$zip_path" ]] || fail "Zip not found: $zip_path"
  rm -rf "$verify_dir"
  mkdir -p "$verify_dir"
  ditto -x -k "$zip_path" "$verify_dir"
  local extracted_app="$verify_dir/$APP_NAME.app"
  [[ -d "$extracted_app" ]] || fail "Extracted app not found: $extracted_app"
  verify_app_payload "$extracted_app"
  codesign --verify --deep --strict --verbose=2 "$extracted_app"
  verify_app_entitlements "$extracted_app"
  verify_developer_id_signature "$extracted_app"
  verify_nested_developer_id_signatures "$extracted_app"
  if [[ "$NOTARIZE" == true ]]; then
    codesign --verify --deep --strict --check-notarization -R=notarized --verbose=2 "$extracted_app"
    xcrun stapler validate "$extracted_app"
    assess_app_bundle "$extracted_app"
  fi
}

if [[ -n "$VERIFY_ONLY_ZIP" ]]; then
  log "Verifying existing zip"
  verify_zip "$VERIFY_ONLY_ZIP" "$VERIFY_DIR"
  log "Done"
  exit 0
fi

if [[ "$SKIP_BUILD" == true ]]; then
  log "Skipping build; reusing $APP_BUNDLE"
else
  log "Building $APP_NAME.app $VERSION"
  xcodebuild \
    -workspace "$WORKSPACE" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -quiet \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    CODE_SIGNING_ALLOWED=NO \
    build
fi

[[ -d "$APP_BUNDLE" ]] || fail "App bundle not found: $APP_BUNDLE"
[[ -f "$ENTITLEMENTS_PATH" ]] || fail "Entitlements file not found: $ENTITLEMENTS_PATH"
verify_app_payload "$APP_BUNDLE"

log "Developer ID signing"
codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
verify_app_entitlements "$APP_BUNDLE"
verify_developer_id_signature "$APP_BUNDLE"
verify_nested_developer_id_signatures "$APP_BUNDLE"

if [[ "$NOTARIZE" == true ]]; then
  log "Submitting to Apple notarization"
  NOTARY_ZIP="$NOTARY_DIR/$APP_NAME-notary.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$NOTARY_ZIP"

  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARYTOOL_PROFILE" --no-s3-acceleration --wait
  else
    [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]] || fail "APP_STORE_CONNECT_KEY_ID missing"
    [[ -n "${APP_STORE_CONNECT_ISSUER_ID:-}" ]] || fail "APP_STORE_CONNECT_ISSUER_ID missing"
    [[ -n "${APP_STORE_CONNECT_API_KEY_P8:-}" ]] || fail "APP_STORE_CONNECT_API_KEY_P8 missing"

    KEY_FILE="$NOTARY_DIR/AuthKey_${APP_STORE_CONNECT_KEY_ID}.p8"
    APP_STORE_CONNECT_API_KEY_P8="$APP_STORE_CONNECT_API_KEY_P8" node > "$KEY_FILE" <<'EOF'
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
    xcrun notarytool submit "$NOTARY_ZIP" \
      --key "$KEY_FILE" \
      --key-id "$APP_STORE_CONNECT_KEY_ID" \
      --issuer "$APP_STORE_CONNECT_ISSUER_ID" \
      --no-s3-acceleration \
      --wait
    rm -f "$KEY_FILE"
  fi

  log "Stapling notarization ticket"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  codesign --verify --deep --strict --check-notarization -R=notarized --verbose=2 "$APP_BUNDLE"
  assess_app_bundle "$APP_BUNDLE"
fi

log "Creating Sparkle zip"
rm -f "$ZIP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
ZIP_LENGTH="$(stat -f%z "$ZIP_PATH")"
ZIP_SHA256="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"

log "Signing Sparkle update"
if ((${#SPARKLE_KEY_ARGS[@]})); then
  SIGN_OUTPUT="$(sign_update "${SPARKLE_KEY_ARGS[@]}" "$ZIP_PATH" 2>&1)"
else
  SIGN_OUTPUT="$(sign_update "$ZIP_PATH" 2>&1)"
fi
printf '%s\n' "$SIGN_OUTPUT"
ED_SIGNATURE="$(printf '%s\n' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' | tail -1)"
[[ -n "$ED_SIGNATURE" ]] || fail "Could not parse sparkle:edSignature from sign_update output"

log "Verifying zipped app"
verify_zip "$ZIP_PATH" "$VERIFY_DIR"

if [[ "$INCLUDE_DMG" == true ]]; then
  log "Creating branded DMG"
  DMG_ARGS=(
    --version "$VERSION"
    --app-zip "$ZIP_PATH"
    --output "$DMG_PATH"
    --background "$DMG_BACKGROUND"
    --sign-identity "$SIGN_IDENTITY"
  )
  if [[ "$NOTARIZE" != true ]]; then
    DMG_ARGS+=(--no-notarize)
  fi
  if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
    DMG_ARGS+=(--notary-profile "$NOTARYTOOL_PROFILE")
  fi
  "$ROOT_DIR/scripts/create-release-dmg.sh" "${DMG_ARGS[@]}"
fi

CHECKSUMS_PATH="$RELEASE_DIR/checksums.txt"
HAD_CHECKSUMS=false
if [[ -f "$CHECKSUMS_PATH" ]]; then
  HAD_CHECKSUMS=true
  checksum_artifacts=("$ZIP_NAME")
  if [[ "$INCLUDE_DMG" == true ]]; then
    checksum_artifacts+=("$DMG_NAME")
  fi
  for artifact_name in "${checksum_artifacts[@]}"; do
    grep -F -v "  $artifact_name" "$CHECKSUMS_PATH" > "$CHECKSUMS_PATH.tmp" || true
    mv "$CHECKSUMS_PATH.tmp" "$CHECKSUMS_PATH"
  done
fi
printf '%s  %s\n' "$ZIP_SHA256" "$ZIP_NAME" >> "$CHECKSUMS_PATH"
if [[ "$INCLUDE_DMG" == true ]]; then
  DMG_SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  printf '%s  %s\n' "$DMG_SHA256" "$DMG_NAME" >> "$CHECKSUMS_PATH"
fi

if [[ "$UPDATE_APPCAST" == true ]]; then
  log "Updating appcast.xml"
  VERSION="$VERSION" \
  RELEASE_URL="$RELEASE_URL" \
  ASSET_URL="$ASSET_URL" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  ZIP_LENGTH="$ZIP_LENGTH" \
  ED_SIGNATURE="$ED_SIGNATURE" \
  MINIMUM_SYSTEM_VERSION="$MINIMUM_SYSTEM_VERSION" \
  APPCAST_PATH="$APPCAST_PATH" \
  node "$ROOT_DIR/scripts/update-appcast-entry.mjs"
  if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$APPCAST_PATH"
  fi
fi

if [[ "$UPLOAD" == true ]]; then
  require_command gh
  log "Uploading release assets"
  UPLOAD_ASSETS=("$ZIP_PATH")
  if [[ "$INCLUDE_DMG" == true ]]; then
    UPLOAD_ASSETS+=("$DMG_PATH")
  fi
  gh release upload "$TAG" "${UPLOAD_ASSETS[@]}" --clobber
  if [[ "$UPLOAD_CHECKSUMS" == true ]]; then
    [[ "$HAD_CHECKSUMS" == true ]] || fail "--upload-checksums requires an existing $CHECKSUMS_PATH from release-binaries.sh"
    gh release upload "$TAG" "$CHECKSUMS_PATH" --clobber
  fi
fi

log "Done"
if [[ "$DRY_RUN" == true ]]; then
  printf 'Dry run: no notarization, appcast update, or upload performed.\n'
fi
printf 'Zip: %s\n' "$ZIP_PATH"
printf 'SHA256: %s\n' "$ZIP_SHA256"
printf 'Length: %s\n' "$ZIP_LENGTH"
printf 'Appcast asset URL: %s\n' "$ASSET_URL"
if [[ "$INCLUDE_DMG" == true ]]; then
  printf 'DMG: %s\n' "$DMG_PATH"
fi
