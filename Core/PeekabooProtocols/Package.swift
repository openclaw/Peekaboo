// swift-tools-version: 6.2

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .defaultIsolation(MainActor.self),
]

let protocolTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=50",
        "-Xfrontend", "-warn-long-expression-type-checking=50",
    ], .when(configuration: .debug)),
]

let package = Package(
    name: "PeekabooProtocols",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PeekabooProtocols",
            targets: ["PeekabooProtocols"]),
    ],
    dependencies: [
        .package(path: "../PeekabooFoundation"),
    ],
    targets: [
        .target(
            name: "PeekabooProtocols",
            dependencies: [
                "PeekabooFoundation",
            ],
            swiftSettings: protocolTargetSettings),
        .testTarget(
            name: "PeekabooProtocolsTests",
            dependencies: ["PeekabooProtocols"],
            path: "Tests/PeekabooProtocolsTests",
            swiftSettings: approachableConcurrencySettings),
    ],
    swiftLanguageModes: [.v6])
