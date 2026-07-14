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

let protocolTargetSettings = approachableConcurrencySettings + [
    .defaultIsolation(MainActor.self),
    .unsafeFlags([
        "-Xfrontend", "-warn-long-function-bodies=50",
        "-Xfrontend", "-warn-long-expression-type-checking=50",
    ], .when(configuration: .debug)),
]

let kitTargetSettings = approachableConcurrencySettings + [
    .enableExperimentalFeature("SwiftTesting"),
    .unsafeFlags(["-parse-as-library"]),
]

let coreTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags(["-parse-as-library"]),
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
        .package(url: "https://github.com/steipete/AXorcist.git", exact: "0.1.3"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
    ],
    targets: [
        .target(
            name: "PeekabooFoundation",
            dependencies: [],
            path: "Core/PeekabooFoundation/Sources/PeekabooFoundation",
            swiftSettings: foundationTargetSettings),
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
            swiftSettings: kitTargetSettings),
        .target(
            name: "PeekabooBridge",
            dependencies: [
                "PeekabooAutomationKit",
                "PeekabooFoundation",
            ],
            path: "Core/PeekabooCore/Sources/PeekabooBridge",
            swiftSettings: coreTargetSettings),
    ],
    swiftLanguageModes: [.v6])
