#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEST_DIR="$(mktemp -d /tmp/peekaboo-terminal-portability-test.XXXXXX)"
cleanup() {
  [[ "${PEEKABOO_KEEP_PORTABILITY_FIXTURE:-0}" == 1 ]] && return
  chmod -R u+w "$TEST_DIR" 2>/dev/null || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT
SOURCE_COMMIT=0123456789abcdef0123456789abcdef01234567
VERSION=9.9.9
ARM_CDHASH=1111111111111111111111111111111111111111
X64_CDHASH=2222222222222222222222222222222222222222
NODE_BIN="$(command -v node)"
sha() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
size() { /usr/bin/stat -f%z "$1"; }
fail() { printf 'test-terminal-manifest-portability: %s\n' "$*" >&2; exit 1; }
# shellcheck source=scripts/terminal-artifact-policy.sh
source "$ROOT_DIR/scripts/terminal-artifact-policy.sh"

# Exercise metadata-bearing inputs without changing tracked files or sealed payloads.
raw_inputs="$TEST_DIR/copy-inputs"
source_input="$raw_inputs/qualification-source"
mkdir -p "$raw_inputs/tools" "$source_input/src" "$source_input/scripts/support" \
  "$source_input/Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm"
for tool in validate-terminal-artifact-manifest.mjs artifact-tree-manifest.rb \
  terminal-archive-policy.mjs terminal-dmg-payload.mjs qualification-node.entitlements; do
  cp -X "$ROOT_DIR/scripts/$tool" "$raw_inputs/tools/"
  /usr/bin/xattr -w com.openclaw.peekaboo.copy-input benign "$raw_inputs/tools/$tool"
done

candidate="$TEST_DIR/candidate-one"
mkdir -p "$candidate/tools" "$candidate/notary/submissions" "$candidate/qualification"
cp -X "$raw_inputs/tools/validate-terminal-artifact-manifest.mjs" "$candidate/tools/"
cp -X "$raw_inputs/tools/artifact-tree-manifest.rb" "$candidate/tools/"
cp -X "$raw_inputs/tools/terminal-archive-policy.mjs" "$candidate/tools/"
cp -X "$raw_inputs/tools/terminal-dmg-payload.mjs" "$candidate/tools/"

printf 'controller fixture source\n' > "$source_input/src/controller.swift"
controller_source_sha="$(sha "$source_input/src/controller.swift")"
printf 'monitor fixture source\n' > "$source_input/scripts/support/background-computer-use-probe.swift"
monitor_source_sha="$(sha "$source_input/scripts/support/background-computer-use-probe.swift")"
printf '{"pins":[],"version":3}\n' > \
  "$source_input/Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved"
lock_sha="$(sha "$source_input/Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved")"
files_json="$(jq -cn --arg sha "$controller_source_sha" '[{path:"src/controller.swift",sha256:$sha}]')"
jq -n --argjson files "$files_json" '{current_build_source:{controller_source_manifest:$files}}' > \
  "$source_input/scripts/multi-target-certification-catalog.json"
catalog_sha="$(sha "$source_input/scripts/multi-target-certification-catalog.json")"
source_aggregate="$(FILES_JSON="$files_json" "$NODE_BIN" -e '
const crypto=require("crypto");
const canonical=v=>Array.isArray(v)?v.map(canonical):(v&&typeof v==="object"?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):v);
const domain=Buffer.from("peekaboo.multi-target-certification.certification-controller-source-manifest.v2\0");
process.stdout.write(crypto.createHash("sha256").update(Buffer.concat([domain,Buffer.from(JSON.stringify(canonical(JSON.parse(process.env.FILES_JSON))))])).digest("hex"));
')"
jq -n --arg catalogSHA "$catalog_sha" --arg aggregate "$source_aggregate" --argjson files "$files_json" '
  {version:1,catalog_path:"scripts/multi-target-certification-catalog.json",catalog_sha256:$catalogSHA,
   aggregate_sha256:$aggregate,files:$files}' > "$candidate/controller-source-manifest.json"
for input in "$source_input" "$source_input/src" "$source_input/src/controller.swift"; do
  /usr/bin/xattr -w com.openclaw.peekaboo.copy-input benign "$input"
done
cp -RX "$source_input" "$candidate/qualification-source"
terminal_artifact_assert_no_xattrs "$candidate" || fail 'copied fixture inputs contain extended attributes'
# Establish the final modes only after copying; receipts and archives must stay immutable.
find "$candidate/qualification-source" -type d -exec chmod 555 {} +
find "$candidate/qualification-source" -type f -exec chmod 444 {} +
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$candidate/qualification-source" > \
  "$candidate/qualification-source-tree.json"
jq -e 'all(.entries[]; if .type == "directory" then .mode == "0555" else .mode == "0444" end)' \
  "$candidate/qualification-source-tree.json" >/dev/null || fail 'source snapshot modes differ'

cat > "$TEST_DIR/producer.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>PeekabooSourceCommit</key><string>$SOURCE_COMMIT</string>
<key>PeekabooCertificationSourceManifestSHA256</key><string>$source_aggregate</string>
<key>PeekabooCertificationCatalogSHA256</key><string>$catalog_sha</string>
<key>PeekabooQualificationMonitorSourceSHA256</key><string>$monitor_source_sha</string>
</dict></plist>
EOF
printf 'int main(void) { return 0; }\n' > "$TEST_DIR/main.c"
for architecture in arm64 x86_64; do
  /usr/bin/clang -arch "$architecture" "$TEST_DIR/main.c" \
    -Wl,-sectcreate,__TEXT,__info_plist,"$TEST_DIR/producer.plist" -o "$TEST_DIR/producer-$architecture"
  /usr/bin/clang -arch "$architecture" "$TEST_DIR/main.c" -o "$TEST_DIR/runtime-$architecture"
done
/usr/bin/lipo -create "$TEST_DIR/producer-arm64" "$TEST_DIR/producer-x86_64" -output "$TEST_DIR/producer-universal"
/usr/bin/lipo -create "$TEST_DIR/runtime-arm64" "$TEST_DIR/runtime-x86_64" -output "$TEST_DIR/runtime-universal"
for input in "$TEST_DIR/producer-universal" "$TEST_DIR/runtime-arm64" "$TEST_DIR/runtime-universal"; do
  /usr/bin/xattr -w com.openclaw.peekaboo.copy-input benign "$input"
done
cp -X "$TEST_DIR/producer-universal" "$candidate/qualification/peekaboo-certification-controller"
cp -X "$TEST_DIR/producer-universal" "$candidate/qualification/background-computer-use-probe"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$candidate/qualification" > "$candidate/qualification-tree.json"

cli_package="$TEST_DIR/peekaboo-macos-universal"
mkdir -p "$cli_package"
cp -X "$TEST_DIR/producer-universal" "$cli_package/peekaboo"
printf 'fixture license\n' > "$cli_package/LICENSE"
printf '%s\n' "$VERSION" > "$cli_package/VERSION"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$cli_package" > "$candidate/cli-tree.json"
/usr/bin/tar -czf "$candidate/peekaboo-macos-universal.tar.gz" -C "$TEST_DIR" peekaboo-macos-universal
cli_notary="$TEST_DIR/cli-notary"
mkdir -p "$cli_notary"
cp -X "$TEST_DIR/producer-universal" "$cli_notary/peekaboo"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$cli_notary" > "$candidate/cli-notary-tree.json"

make_info_plist() {
  local plist="$1" executable="$2" identifier="$3" source="${4:-}"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$executable</string>
<key>CFBundleIdentifier</key><string>$identifier</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
${source:+<key>PeekabooSourceCommit</key><string>$source</string>}
</dict></plist>
EOF
}

peekaboo_app="$TEST_DIR/Peekaboo.app"
mkdir -p "$peekaboo_app/Contents/MacOS" "$peekaboo_app/Contents/Resources"
cp -X "$TEST_DIR/runtime-arm64" "$peekaboo_app/Contents/MacOS/Peekaboo"
make_info_plist "$peekaboo_app/Contents/Info.plist" Peekaboo boo.peekaboo.mac "$SOURCE_COMMIT"
printf 'icon\n' > "$peekaboo_app/Contents/Resources/AppIcon.icns"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$peekaboo_app" > "$candidate/peekaboo-app-tree.json"
/usr/bin/ditto -c -k --norsrc --keepParent "$peekaboo_app" "$candidate/Peekaboo-$VERSION.app.zip"

playground_app="$TEST_DIR/Playground.app"
mkdir -p "$playground_app/Contents/MacOS" "$playground_app/Contents/Resources"
cp -X "$TEST_DIR/runtime-arm64" "$playground_app/Contents/MacOS/Playground"
make_info_plist "$playground_app/Contents/Info.plist" Playground boo.peekaboo.playground.debug
jq -n --arg source "$SOURCE_COMMIT" --arg lockSHA "$lock_sha" --arg version "$VERSION" '
 {version:2,source_commit:$source,source_tree:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  dependency_lock_path:"Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved",dependency_lock_sha256:$lockSHA,
  workspace:"Apps/Peekaboo.xcworkspace",scheme:"Playground",configuration:"Debug",
  bundle_identifier:"boo.peekaboo.playground.debug",marketing_version:$version,developer_dir:"/Fixture/Xcode",
  xcodebuild_version:"Xcode Fixture",sdk_version:"99.0",swiftc_version:"Swift Fixture"}' > \
  "$playground_app/Contents/Resources/PeekabooPlaygroundSource.json"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$playground_app" > "$candidate/playground-app-tree.json"
/usr/bin/ditto -c -k --norsrc --keepParent "$playground_app" "$candidate/Playground-$VERSION.app.zip"

node_app="$TEST_DIR/PeekabooQualificationNode.app"
mkdir -p "$node_app/Contents/MacOS" "$node_app/Contents/Resources"
cp -X "$TEST_DIR/runtime-universal" "$node_app/Contents/MacOS/node"
make_info_plist "$node_app/Contents/Info.plist" node boo.peekaboo.qualification-node
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 24.15.0' "$node_app/Contents/Info.plist"
printf 'fixture node license\n' > "$node_app/Contents/Resources/LICENSE"
cp -X "$raw_inputs/tools/qualification-node.entitlements" \
  "$node_app/Contents/Resources/qualification-node.entitlements"
node_binary_sha="$(sha "$node_app/Contents/MacOS/node")"; node_binary_size="$(size "$node_app/Contents/MacOS/node")"
node_license_sha="$(sha "$node_app/Contents/Resources/LICENSE")"
node_entitlements_sha="$(sha "$node_app/Contents/Resources/qualification-node.entitlements")"
jq -n --arg binarySHA "$node_binary_sha" --argjson binarySize "$node_binary_size" \
  --arg licenseSHA "$node_license_sha" --arg entitlementsSHA "$node_entitlements_sha" '
 {version:1,runtime_version:"24.15.0",identifier:"boo.peekaboo.qualification-node",
  executable_path:"Contents/MacOS/node",universal_binary_sha256:$binarySHA,universal_binary_size:$binarySize,
  architectures:["arm64","x86_64"],license:{path:"Contents/Resources/LICENSE",sha256:$licenseSHA},
  entitlements:{path:"Contents/Resources/qualification-node.entitlements",sha256:$entitlementsSHA},
  inputs:{arm64:{url:"fixture://arm64",archive_sha256:$binarySHA,binary_sha256:$binarySHA},
  x86_64:{url:"fixture://x86_64",archive_sha256:$binarySHA,binary_sha256:$binarySHA}}}' > \
  "$node_app/Contents/Resources/PeekabooQualificationNodeSource.json"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$node_app" > "$candidate/qualification-node-app-tree.json"
/usr/bin/ditto -c -k --norsrc --keepParent "$node_app" "$candidate/PeekabooQualificationNode-24.15.0.app.zip"

volume="$TEST_DIR/volume"
mkdir -p "$volume/.background"
cp -RX "$peekaboo_app" "$volume/Peekaboo.app"
printf 'finder\n' > "$volume/.DS_Store"; printf 'volume icon\n' > "$volume/.VolumeIcon.icns"
printf 'background\n' > "$volume/.background/background.png"; ln -s /Applications "$volume/Applications"
raw_dmg="$raw_inputs/Peekaboo-$VERSION.dmg"
COPYFILE_DISABLE=1 /usr/bin/hdiutil create -quiet -fs HFS+ -format UDZO -volname 'Peekaboo Fixture' \
  -srcfolder "$volume" "$raw_dmg"
"$NODE_BIN" "$ROOT_DIR/scripts/terminal-dmg-payload.mjs" --dmg "$raw_dmg" \
  --expected-app-tree "$candidate/peekaboo-app-tree.json" --tree-generator "$ROOT_DIR/scripts/artifact-tree-manifest.rb" > \
  "$candidate/peekaboo-dmg-payload.json"
cp -X "$raw_dmg" "$candidate/Peekaboo-$VERSION.dmg"
# Prevent mount-time checksum cache writes before binding this synthetic image to receipts.
chmod 444 "$candidate/Peekaboo-$VERSION.dmg"

submission_bytes="$TEST_DIR/submission"; printf 'retained fixture submission\n' > "$submission_bytes"
submission_sha="$(sha "$submission_bytes")"; cp -X "$submission_bytes" "$candidate/notary/submissions/$submission_sha"
receipt() {
  local output="$1" kind="$2" identifier="$3" final_type="$4" final_path="$5" suffix="$6" arch_kind="$7"
  local architectures cdhashes scalar final_sha final_size
  case "$arch_kind" in
    universal) architectures='["arm64","x86_64"]'; cdhashes="{\"arm64\":\"$ARM_CDHASH\",\"x86_64\":\"$X64_CDHASH\"}"; scalar="$ARM_CDHASH" ;;
    arm64) architectures='["arm64"]'; cdhashes="{\"arm64\":\"$ARM_CDHASH\"}"; scalar="$ARM_CDHASH" ;;
    container) architectures='["container"]'; cdhashes="{\"container\":\"$ARM_CDHASH\"}"; scalar="$ARM_CDHASH" ;;
  esac
  final_sha="$(sha "$final_path")"; final_size="$(size "$final_path")"
  jq -n --arg kind "$kind" --arg id "00000000-0000-4000-8000-0000000000$suffix" \
    --arg submissionSHA "$submission_sha" --argjson submissionSize "$(size "$submission_bytes")" \
    --arg identifier "$identifier" --arg cdhash "$scalar" --argjson architectures "$architectures" \
    --argjson cdhashes "$cdhashes" --arg finalType "$final_type" --arg finalSHA "$final_sha" --argjson finalSize "$final_size" '
    {version:2,kind:$kind,id:$id,status:"Accepted",
     submission:{path:("notary/submissions/"+$submissionSHA),sha256:$submissionSHA,size:$submissionSize},
     code_identity:{authority:"Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)",identifier:$identifier,
      team_id:"FWJYW4S8P8",cdhash:$cdhash,architectures:$architectures,cdhashes:$cdhashes},
     final_artifact:(if $finalType=="tree" then {tree_manifest_sha256:$finalSHA,tree_manifest_size:$finalSize}
      else {sha256:$finalSHA,size:$finalSize} end)}' > "$output"
}
receipt "$candidate/notary/cli.json" cli_tree boo.peekaboo.peekaboo tree "$candidate/cli-notary-tree.json" 01 universal
receipt "$candidate/notary/peekaboo-app.json" app boo.peekaboo.mac tree "$candidate/peekaboo-app-tree.json" 02 arm64
receipt "$candidate/notary/peekaboo-dmg.json" dmg fixture.dmg file "$candidate/Peekaboo-$VERSION.dmg" 03 container
receipt "$candidate/notary/playground-app.json" app boo.peekaboo.playground.debug tree "$candidate/playground-app-tree.json" 04 arm64
receipt "$candidate/notary/qualification-node-app.json" app boo.peekaboo.qualification-node tree \
  "$candidate/qualification-node-app-tree.json" 05 universal
receipt "$candidate/notary/certification-controller.json" controller_tree \
  boo.peekaboo.peekaboo-certification-controller tree "$candidate/qualification-tree.json" 06 universal

fake_tools="$TEST_DIR/fake-tools"
mkdir -p "$fake_tools"
cat > "$fake_tools/codesign" <<EOF
#!/bin/bash
set -euo pipefail
display=false; architecture=arm64; previous=
for argument in "\$@"; do [[ "\$argument" == -dvvv ]] && display=true; [[ "\$previous" == --arch ]] && architecture="\$argument"; previous="\$argument"; done
\$display || exit 0
target="\${!#}"
case "\$(basename "\$target")" in
 peekaboo) identifier=boo.peekaboo.peekaboo;; Peekaboo.app) identifier=boo.peekaboo.mac;;
 Playground.app) identifier=boo.peekaboo.playground.debug;; PeekabooQualificationNode.app|node) identifier=boo.peekaboo.qualification-node;;
 peekaboo-certification-controller) identifier=boo.peekaboo.peekaboo-certification-controller;;
 background-computer-use-probe) identifier=boo.peekaboo.background-computer-use-probe;; *.dmg) identifier=fixture.dmg;;
 *) identifier=com.apple.dt.runtime.swiftCompatibilityFixture;; esac
[[ "\$architecture" == x86_64 ]] && cdhash=$X64_CDHASH || cdhash=$ARM_CDHASH
printf 'Identifier=%s\nCDHash=%s\nAuthority=Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)\nTeamIdentifier=FWJYW4S8P8\n' "\$identifier" "\$cdhash"
EOF
chmod 755 "$fake_tools/codesign"

cli_archive_sha="$(sha "$candidate/peekaboo-macos-universal.tar.gz")"; app_zip_sha="$(sha "$candidate/Peekaboo-$VERSION.app.zip")"
playground_zip_sha="$(sha "$candidate/Playground-$VERSION.app.zip")"; node_zip_sha="$(sha "$candidate/PeekabooQualificationNode-24.15.0.app.zip")"
dmg_sha="$(sha "$candidate/Peekaboo-$VERSION.dmg")"; controller_sha="$(sha "$candidate/qualification/peekaboo-certification-controller")"
monitor_sha="$(sha "$candidate/qualification/background-computer-use-probe")"; cli_executable_sha="$(sha "$cli_package/peekaboo")"
playground_manifest_sha="$(sha "$playground_app/Contents/Resources/PeekabooPlaygroundSource.json")"
node_manifest_sha="$(sha "$node_app/Contents/Resources/PeekabooQualificationNodeSource.json")"

jq -n --arg version "$VERSION" --arg source "$SOURCE_COMMIT" --arg lockSHA "$lock_sha" \
 --arg cliArchiveSHA "$cli_archive_sha" --argjson cliArchiveSize "$(size "$candidate/peekaboo-macos-universal.tar.gz")" \
 --arg cliExecutableSHA "$cli_executable_sha" --arg appSHA "$app_zip_sha" --argjson appSize "$(size "$candidate/Peekaboo-$VERSION.app.zip")" \
 --arg playgroundSHA "$playground_zip_sha" --argjson playgroundSize "$(size "$candidate/Playground-$VERSION.app.zip")" \
 --arg nodeSHA "$node_zip_sha" --argjson nodeSize "$(size "$candidate/PeekabooQualificationNode-24.15.0.app.zip")" \
 --arg dmgSHA "$dmg_sha" --argjson dmgSize "$(size "$candidate/Peekaboo-$VERSION.dmg")" \
 --arg controllerSHA "$controller_sha" --argjson controllerSize "$(size "$candidate/qualification/peekaboo-certification-controller")" \
 --arg monitorSHA "$monitor_sha" --argjson monitorSize "$(size "$candidate/qualification/background-computer-use-probe")" \
 --arg sourceAggregate "$source_aggregate" --arg controllerReceiptSHA "$(sha "$candidate/controller-source-manifest.json")" \
 --arg monitorSourceSHA "$monitor_source_sha" --arg playgroundManifestSHA "$playground_manifest_sha" \
 --arg nodeManifestSHA "$node_manifest_sha" --arg nodeBinarySHA "$node_binary_sha" --argjson nodeBinarySize "$node_binary_size" \
 --arg nodeLicenseSHA "$node_license_sha" --arg nodeEntitlementsSHA "$node_entitlements_sha" \
 --slurpfile cliNotary "$candidate/notary/cli.json" \
 --slurpfile appNotary "$candidate/notary/peekaboo-app.json" --slurpfile dmgNotary "$candidate/notary/peekaboo-dmg.json" \
 --slurpfile playgroundNotary "$candidate/notary/playground-app.json" --slurpfile nodeNotary "$candidate/notary/qualification-node-app.json" \
 --slurpfile controllerNotary "$candidate/notary/certification-controller.json" '
 def bound($path): {path:$path,sha256:""};
 {schema:7,phase:"candidate_verified_not_installed",root:".",version:$version,source_commit:$source,
  dependency_lock_path:"Apps/Peekaboo.xcworkspace/xcshareddata/swiftpm/Package.resolved",dependency_lock_sha256:$lockSHA,
  toolchain:{developer_dir:"/Fixture/Xcode",xcodebuild_version:"Xcode Fixture",sdk_version:"99.0",swiftc_version:"Swift Fixture"},
  signing:{authority:"Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)",team_id:"FWJYW4S8P8",
   release_helper:{commit:"20ab9a5e6bb1107788366726868f1a9b4c16d953",executable_sha256:"e65e06ef89ec90ebfc537d28748a3c4de8ce89bd09b51e4d67ba4bdd95427255",library_sha256:"c29d3c46506c2d0bd2db7ab688bd3108d54e8824074a4fe800de6e3fe17284c9"}},
  notarization:{cli:$cliNotary[0],peekaboo_app:$appNotary[0],peekaboo_dmg:$dmgNotary[0],playground_app:$playgroundNotary[0],qualification_node_app:$nodeNotary[0],certification_controller:$controllerNotary[0]},
  cli:{sha256:$cliExecutableSHA,cdhash:"1111111111111111111111111111111111111111"},app:{source_commit:$source,zip_sha256:$appSHA,cdhash:"1111111111111111111111111111111111111111"},
  playground:{source_commit:$source,zip_sha256:$playgroundSHA,cdhash:"1111111111111111111111111111111111111111"},
  monitor:{source_commit:$source,source_path:"scripts/support/background-computer-use-probe.swift",source_sha256:$monitorSourceSHA,relative_path:"qualification/background-computer-use-probe",executable_sha256:$monitorSHA,cdhash:"1111111111111111111111111111111111111111"},
  controller:{source_commit:$source,source_manifest_sha256:$sourceAggregate,relative_path:"qualification/peekaboo-certification-controller",executable_sha256:$controllerSHA,cdhash:"1111111111111111111111111111111111111111",team_id:"FWJYW4S8P8",authority:"Developer ID Application: OpenClaw Foundation (FWJYW4S8P8)",signing_identifier:"boo.peekaboo.peekaboo-certification-controller",architectures:["arm64","x86_64"]},
  verification:{cli_source:true,cli_native_only:true,monitor_source:true,monitor_native_only:true,controller_source:true,controller_native_only:true,app_source:true,app_native_only:true,playground_native_only:true},
  portable:{validator:bound("tools/validate-terminal-artifact-manifest.mjs"),tree_generator:bound("tools/artifact-tree-manifest.rb"),archive_policy:bound("tools/terminal-archive-policy.mjs"),dmg_policy:bound("tools/terminal-dmg-payload.mjs"),source_tree:{path:"qualification-source",tree_manifest:bound("qualification-source-tree.json")}},
  artifacts:{
   cli:{path:"peekaboo-macos-universal.tar.gz",sha256:$cliArchiveSHA,size:$cliArchiveSize,cdhash:"1111111111111111111111111111111111111111",cdhashes:{arm64:"1111111111111111111111111111111111111111",x86_64:"2222222222222222222222222222222222222222"},source_commit:$source,tree_manifest:bound("cli-tree.json"),notarized_tree_manifest:bound("cli-notary-tree.json")},
   peekaboo_app_zip:{path:("Peekaboo-"+$version+".app.zip"),sha256:$appSHA,size:$appSize,cdhash:"1111111111111111111111111111111111111111",source_commit:$source,tree_manifest:bound("peekaboo-app-tree.json")},
   peekaboo_dmg:{path:("Peekaboo-"+$version+".dmg"),sha256:$dmgSHA,size:$dmgSize,cdhash:"1111111111111111111111111111111111111111",source_commit:$source,payload_receipt:bound("peekaboo-dmg-payload.json")},
   playground_app_zip:{path:("Playground-"+$version+".app.zip"),sha256:$playgroundSHA,size:$playgroundSize,cdhash:"1111111111111111111111111111111111111111",source_commit:$source,embedded_manifest_sha256:$playgroundManifestSHA,tree_manifest:bound("playground-app-tree.json")},
   qualification_node_app_zip:{path:"PeekabooQualificationNode-24.15.0.app.zip",sha256:$nodeSHA,size:$nodeSize,cdhash:"1111111111111111111111111111111111111111",source_commit:$source,embedded_runtime_manifest_sha256:$nodeManifestSHA,tree_manifest:bound("qualification-node-app-tree.json"),runtime:{version:"24.15.0",identifier:"boo.peekaboo.qualification-node",executable_path:"Contents/MacOS/node",architectures:["arm64","x86_64"],unsigned_binary_sha256:$nodeBinarySHA,unsigned_binary_size:$nodeBinarySize,binary_sha256:$nodeBinarySHA,binary_cdhashes:{arm64:"1111111111111111111111111111111111111111",x86_64:"2222222222222222222222222222222222222222"},binary_size:$nodeBinarySize,license:{path:"Contents/Resources/LICENSE",sha256:$nodeLicenseSHA},entitlements:{path:"Contents/Resources/qualification-node.entitlements",sha256:$nodeEntitlementsSHA},inputs:{arm64:{url:"fixture://arm64",archive_sha256:$nodeBinarySHA,binary_sha256:$nodeBinarySHA},x86_64:{url:"fixture://x86_64",archive_sha256:$nodeBinarySHA,binary_sha256:$nodeBinarySHA}}}},
   qualification_monitor:{path:"qualification/background-computer-use-probe",sha256:$monitorSHA,size:$monitorSize,cdhash:"1111111111111111111111111111111111111111",cdhashes:{arm64:"1111111111111111111111111111111111111111",x86_64:"2222222222222222222222222222222222222222"},source_commit:$source,identifier:"boo.peekaboo.background-computer-use-probe",architectures:["arm64","x86_64"],source:{path:"scripts/support/background-computer-use-probe.swift",sha256:$monitorSourceSHA},tree_manifest:bound("qualification-tree.json")},
   certification_controller:{path:"qualification/peekaboo-certification-controller",sha256:$controllerSHA,size:$controllerSize,cdhash:"1111111111111111111111111111111111111111",cdhashes:{arm64:"1111111111111111111111111111111111111111",x86_64:"2222222222222222222222222222222222222222"},source_commit:$source,identifier:"boo.peekaboo.peekaboo-certification-controller",architectures:["arm64","x86_64"],source_manifest:{path:"controller-source-manifest.json",sha256:$controllerReceiptSHA,aggregate_sha256:$sourceAggregate},tree_manifest:bound("qualification-tree.json")}}}
' > "$candidate/terminal-artifacts.partial.json"

jq --arg validator "$(sha "$candidate/tools/validate-terminal-artifact-manifest.mjs")" --arg tree "$(sha "$candidate/tools/artifact-tree-manifest.rb")" \
 --arg archive "$(sha "$candidate/tools/terminal-archive-policy.mjs")" --arg dmgPolicy "$(sha "$candidate/tools/terminal-dmg-payload.mjs")" \
 --arg sourceTree "$(sha "$candidate/qualification-source-tree.json")" --arg cliTree "$(sha "$candidate/cli-tree.json")" \
 --arg cliNotaryTree "$(sha "$candidate/cli-notary-tree.json")" --arg appTree "$(sha "$candidate/peekaboo-app-tree.json")" \
 --arg dmgPayload "$(sha "$candidate/peekaboo-dmg-payload.json")" --arg playgroundTree "$(sha "$candidate/playground-app-tree.json")" \
 --arg nodeTree "$(sha "$candidate/qualification-node-app-tree.json")" --arg qualificationTree "$(sha "$candidate/qualification-tree.json")" '
 .portable.validator.sha256=$validator | .portable.tree_generator.sha256=$tree | .portable.archive_policy.sha256=$archive |
 .portable.dmg_policy.sha256=$dmgPolicy | .portable.source_tree.tree_manifest.sha256=$sourceTree |
 .artifacts.cli.tree_manifest.sha256=$cliTree | .artifacts.cli.notarized_tree_manifest.sha256=$cliNotaryTree |
 .artifacts.peekaboo_app_zip.tree_manifest.sha256=$appTree | .artifacts.peekaboo_dmg.payload_receipt.sha256=$dmgPayload |
 .artifacts.playground_app_zip.tree_manifest.sha256=$playgroundTree | .artifacts.qualification_node_app_zip.tree_manifest.sha256=$nodeTree |
 .artifacts.qualification_monitor.tree_manifest.sha256=$qualificationTree | .artifacts.certification_controller.tree_manifest.sha256=$qualificationTree' \
 "$candidate/terminal-artifacts.partial.json" > "$candidate/terminal-artifacts.json"
rm -f "$candidate/terminal-artifacts.partial.json"

(cd "$candidate" && /usr/bin/shasum -a 256 peekaboo-macos-universal.tar.gz "Peekaboo-$VERSION.app.zip" \
 "Peekaboo-$VERSION.dmg" "Playground-$VERSION.app.zip" PeekabooQualificationNode-24.15.0.app.zip \
 cli-tree.json cli-notary-tree.json peekaboo-app-tree.json peekaboo-dmg-payload.json playground-app-tree.json \
 qualification-node-app-tree.json qualification/peekaboo-certification-controller \
 qualification/background-computer-use-probe qualification-tree.json controller-source-manifest.json \
 qualification-source-tree.json tools/validate-terminal-artifact-manifest.mjs tools/artifact-tree-manifest.rb \
 tools/terminal-archive-policy.mjs tools/terminal-dmg-payload.mjs notary/*.json notary/submissions/* > checksums.txt)

validate_root() {
  local root="$1"
  /usr/bin/env -i PATH=/usr/bin:/bin PEEKABOO_TERMINAL_TEST_MODE=1 \
    PEEKABOO_TERMINAL_VALIDATOR_FIXTURE_TOOLS="$fake_tools" "$NODE_BIN" \
    "$root/tools/validate-terminal-artifact-manifest.mjs" "$root/terminal-artifacts.json"
}
candidate_tree="$TEST_DIR/candidate-tree.json"
/usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$candidate" > "$candidate_tree"
assert_candidate_unchanged() {
  local root="$1"
  terminal_artifact_assert_no_xattrs "$root" || fail 'candidate contains extended attributes'
  /usr/bin/ruby "$ROOT_DIR/scripts/artifact-tree-manifest.rb" "$root" > "$TEST_DIR/observed-candidate-tree.json"
  cmp -s "$candidate_tree" "$TEST_DIR/observed-candidate-tree.json" || fail 'candidate bytes or modes changed'
}
assert_candidate_unchanged "$candidate"
validate_root "$candidate" >/dev/null
assert_candidate_unchanged "$candidate"
printf 'test-terminal-manifest-portability: metadata-free candidate and read-only source receipt validated\n'
relocated="$TEST_DIR/different/absolute/inode-tree"; mkdir -p "$(dirname "$relocated")"
/usr/bin/ditto --norsrc "$candidate" "$relocated"
cmp -s "$candidate/terminal-artifacts.json" "$relocated/terminal-artifacts.json"
assert_candidate_unchanged "$relocated"
validate_root "$relocated" >/dev/null
assert_candidate_unchanged "$relocated"
printf 'test-terminal-manifest-portability: relocated candidate validated\n'

for mutation in byte symlink xattr; do
  mutated="$TEST_DIR/mutated-$mutation"; /usr/bin/ditto --norsrc "$candidate" "$mutated"
  case "$mutation" in
    byte)
      chmod u+w "$mutated/qualification-source/src/controller.swift"
      printf 'tamper\n' >> "$mutated/qualification-source/src/controller.swift"
      expected_error='portable source tree differs'
      ;;
    symlink)
      mv "$mutated/tools/terminal-archive-policy.mjs" "$mutated/tools/terminal-archive-policy.real"
      ln -s terminal-archive-policy.real "$mutated/tools/terminal-archive-policy.mjs"
      expected_error='tools/terminal-archive-policy.mjs is not one regular unsymlinked file'
      ;;
    xattr)
      /usr/bin/xattr -w com.openclaw.peekaboo.fixture value "$mutated/checksums.txt"
      expected_error='artifact root contains unbound xattrs'
      ;;
  esac
  if validate_root "$mutated" >"$TEST_DIR/mutation-$mutation.log" 2>&1; then
    fail "$mutation mutation was accepted"
  fi
  grep -Fq "$expected_error" "$TEST_DIR/mutation-$mutation.log" || fail "$mutation failed for an unexpected reason"
  printf 'test-terminal-manifest-portability: %s mutation rejected (%s)\n' "$mutation" "$expected_error"
done
printf 'test-terminal-manifest-portability: ok\n'
