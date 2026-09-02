#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="${ROOT_DIR}/Package.swift"

if [[ ! -f "${MANIFEST_PATH}" ]]; then
  printf 'Missing public SwiftPM manifest: %s\n' "${MANIFEST_PATH}" >&2
  exit 1
fi

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/peekaboo-swiftpm-consumer.XXXXXX")"
trap 'rm -rf "${fixture_dir}"' EXIT

manifest_json="${fixture_dir}/peekaboo-package.json"
swift package --package-path "${ROOT_DIR}" dump-package >"${manifest_json}"

node - "${manifest_json}" <<'NODE'
const fs = require("node:fs");

const manifest = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const expected = [
  "PeekabooFoundation",
  "PeekabooProtocols",
  "PeekabooAutomationKit",
  "PeekabooBridge",
];
const actual = manifest.products.map(product => product.name).sort();

if (JSON.stringify(actual) !== JSON.stringify([...expected].sort())) {
  console.error(`Public SwiftPM products drifted: expected ${expected.join(", ")}; received ${actual.join(", ")}`);
  process.exit(1);
}

const expectedAXVersion = "0.1.9";
const sourceDependencies = manifest.dependencies.flatMap(dependency => dependency.sourceControl ?? []);
const axorcist = sourceDependencies.find(dependency => dependency.identity === "axorcist");
const actualAXVersion = axorcist?.requirement?.exact?.[0];
if (actualAXVersion !== expectedAXVersion) {
  console.error(`AXorcist version drifted: expected ${expectedAXVersion}; received ${actualAXVersion ?? "none"}`);
  process.exit(1);
}
NODE

package_repo="${fixture_dir}/Peekaboo"
mkdir -p \
  "${package_repo}/Core/PeekabooFoundation/Sources" \
  "${package_repo}/Core/PeekabooProtocols/Sources" \
  "${package_repo}/Core/PeekabooAutomationKit/Sources" \
  "${package_repo}/Core/PeekabooCore/Sources"

cp "${MANIFEST_PATH}" "${package_repo}/Package.swift"
/usr/bin/ditto \
  "${ROOT_DIR}/Core/PeekabooFoundation/Sources/PeekabooFoundation" \
  "${package_repo}/Core/PeekabooFoundation/Sources/PeekabooFoundation"
/usr/bin/ditto \
  "${ROOT_DIR}/Core/PeekabooProtocols/Sources/PeekabooProtocols" \
  "${package_repo}/Core/PeekabooProtocols/Sources/PeekabooProtocols"
/usr/bin/ditto \
  "${ROOT_DIR}/Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit" \
  "${package_repo}/Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit"
/usr/bin/ditto \
  "${ROOT_DIR}/Core/PeekabooCore/Sources/PeekabooBridge" \
  "${package_repo}/Core/PeekabooCore/Sources/PeekabooBridge"

git -C "${package_repo}" init -q
git -C "${package_repo}" add Package.swift Core
git -C "${package_repo}" \
  -c user.name='Peekaboo Consumer Contract' \
  -c user.email='consumer-contract@invalid.example' \
  commit -qm 'fixture: exact public package revision'
git -C "${package_repo}" \
  -c user.name='Peekaboo Consumer Contract' \
  -c user.email='consumer-contract@invalid.example' \
  -c tag.gpgSign=false \
  tag -am 'fixture: semantic package version' 4.1.1

export PEEKABOO_CONSUMER_PACKAGE_URL="file://${package_repo}"
export PEEKABOO_CONSUMER_PACKAGE_VERSION="4.1.1"

consumer_dir="${fixture_dir}/Consumer"
mkdir -p "${consumer_dir}/Sources/Consumer"

cat >"${consumer_dir}/Package.swift" <<'EOF'
// swift-tools-version: 6.2

import Foundation
import PackageDescription

let packageURL = ProcessInfo.processInfo.environment["PEEKABOO_CONSUMER_PACKAGE_URL"]!
let packageVersion = ProcessInfo.processInfo.environment["PEEKABOO_CONSUMER_PACKAGE_VERSION"]!

let package = Package(
    name: "PeekabooConsumer",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: packageURL, exact: Version(packageVersion)!),
    ],
    targets: [
        .executableTarget(
            name: "Consumer",
            dependencies: [
                .product(name: "PeekabooFoundation", package: "Peekaboo"),
                .product(name: "PeekabooProtocols", package: "Peekaboo"),
                .product(name: "PeekabooAutomationKit", package: "Peekaboo"),
                .product(name: "PeekabooBridge", package: "Peekaboo"),
            ]),
    ],
    swiftLanguageModes: [.v6])
EOF

cat >"${consumer_dir}/Sources/Consumer/main.swift" <<'EOF'
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation
import PeekabooProtocols

func pendingReservationDisposition(
    for failure: some PendingSnapshotFailureDispositionProviding) -> Bool
{
    failure.mayCompleteSnapshotWorkAfterFailure
}

let failure = DesktopActionFailure.refused(
    reason: .targetUnavailable,
    message: "Consumer contract probe")
precondition(!pendingReservationDisposition(for: failure))

// Compile the six-label factory shipped in v4.2.2 without constructing services.
func releasedRawEvidenceFactory() -> DesktopTargetIdentity.Evidence {
    DesktopTargetEvidenceAdapter.evidence(
        processIdentifier: 4242,
        processStartIdentity: nil,
        windowID: 7,
        windowIdentity: nil,
        windowBounds: nil,
        focusedElement: nil)
}

_ = releasedRawEvidenceFactory

@MainActor
func makeEmbeddedRuntime() -> PeekabooEmbeddedBridgeRuntime {
    PeekabooEmbeddedBridgeRuntime.make(configuration: .init(
        socketPath: "/tmp/peekaboo-consumer-contract.sock",
        allowlistedTeams: ["TEAMID"],
        allowlistedBundles: ["com.example.PeekabooConsumer"]))
}

_ = makeEmbeddedRuntime
EOF

swift package --package-path "${consumer_dir}" resolve
swift build --package-path "${consumer_dir}" --configuration release

printf 'SwiftPM consumer contract passed for: %s\n' "${ROOT_DIR}"
