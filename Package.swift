// swift-tools-version: 6.2

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let protocolTargetSettings = approachableConcurrencySettings + [
    .defaultIsolation(MainActor.self),
]

let automationTargetSettings = approachableConcurrencySettings + [
    .enableExperimentalFeature("SwiftTesting"),
]

let package = Package(
    name: "Peekaboo",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PeekabooFoundation",
            targets: ["PeekabooFoundation"]),
        .library(
            name: "PeekabooProtocols",
            targets: ["PeekabooProtocols"]),
        .library(
            name: "PeekabooAutomationKit",
            targets: ["PeekabooAutomationKit"]),
        .library(
            name: "PeekabooBridge",
            targets: ["PeekabooBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/openclaw/AXorcist.git", exact: "0.1.8"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
    ],
    targets: [
        .target(
            name: "PeekabooFoundation",
            path: "Core/PeekabooFoundation/Sources/PeekabooFoundation",
            swiftSettings: approachableConcurrencySettings),
        .target(
            name: "PeekabooProtocols",
            dependencies: [
                "PeekabooFoundation",
            ],
            path: "Core/PeekabooProtocols/Sources/PeekabooProtocols",
            swiftSettings: protocolTargetSettings),
        .target(
            name: "PeekabooAutomationKit",
            dependencies: [
                "PeekabooFoundation",
                "PeekabooProtocols",
                .product(name: "AXorcist", package: "AXorcist"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ],
            path: "Core/PeekabooAutomationKit/Sources/PeekabooAutomationKit",
            exclude: ["Core/README.md"],
            swiftSettings: automationTargetSettings),
        .target(
            name: "PeekabooBridge",
            dependencies: [
                "PeekabooAutomationKit",
                "PeekabooFoundation",
            ],
            path: "Core/PeekabooCore/Sources/PeekabooBridge",
            swiftSettings: approachableConcurrencySettings,
            linkerSettings: [.linkedLibrary("bsm")]),
    ],
    swiftLanguageModes: [.v6])
