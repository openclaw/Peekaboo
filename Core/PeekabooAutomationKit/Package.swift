// swift-tools-version: 6.2

import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableExperimentalFeature("SwiftTesting"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let kitTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags(["-parse-as-library"]),
]

let package = Package(
    name: "PeekabooAutomationKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PeekabooAutomationKit",
            targets: ["PeekabooAutomationKit"]),
        // Test-only support product. Production targets do not depend on or link this module.
        .library(
            name: "PeekabooAutomationKitTestSupport",
            targets: ["PeekabooAutomationKitTestSupport"]),
    ],
    dependencies: [
        .package(path: "../PeekabooFoundation"),
        .package(path: "../PeekabooProtocols"),
        .package(path: "../../AXorcist"),
        .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),
    ],
    targets: [
        .target(
            name: "PeekabooAutomationKit",
            dependencies: [
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
                .product(name: "PeekabooProtocols", package: "PeekabooProtocols"),
                .product(name: "AXorcist", package: "AXorcist"),
                .product(name: "Algorithms", package: "swift-algorithms"),
            ],
            exclude: ["Core/README.md"],
            swiftSettings: kitTargetSettings),
        .target(
            name: "PeekabooAutomationKitTestSupport",
            dependencies: [
                "PeekabooAutomationKit",
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
                .product(name: "PeekabooFoundationTestSupport", package: "PeekabooFoundation"),
            ],
            swiftSettings: approachableConcurrencySettings),
        .target(
            name: "DescriptorForkTestSupport",
            path: "Tests/Support/DescriptorForkTestSupport",
            publicHeadersPath: "include"),
        .testTarget(
            name: "PeekabooAutomationKitTests",
            dependencies: [
                "PeekabooAutomationKit",
                "PeekabooAutomationKitTestSupport",
                "DescriptorForkTestSupport",
                .product(name: "PeekabooFoundationTestSupport", package: "PeekabooFoundation"),
            ],
            path: "Tests/PeekabooAutomationKitTests",
            swiftSettings: approachableConcurrencySettings),
    ],
    swiftLanguageModes: [.v6])
