// swift-tools-version: 6.2

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let foundationTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags(["-parse-as-library"]),
]

let package = Package(
    name: "PeekabooFoundation",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PeekabooFoundation",
            targets: ["PeekabooFoundation"]),
        // Test-only support product. Production targets do not depend on or link this module.
        .library(
            name: "PeekabooFoundationTestSupport",
            targets: ["PeekabooFoundationTestSupport"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PeekabooFoundation",
            dependencies: [],
            swiftSettings: foundationTargetSettings),
        .target(
            name: "PeekabooFoundationTestSupport",
            dependencies: ["PeekabooFoundation"],
            swiftSettings: approachableConcurrencySettings),
        .testTarget(
            name: "PeekabooFoundationTests",
            dependencies: ["PeekabooFoundation", "PeekabooFoundationTestSupport"],
            swiftSettings: approachableConcurrencySettings),
    ],
    swiftLanguageModes: [.v6])
