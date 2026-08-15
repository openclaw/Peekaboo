// swift-tools-version: 6.2

import Foundation
import PackageDescription

let approachableConcurrencySettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let coreTargetSettings = approachableConcurrencySettings + [
    .unsafeFlags(["-parse-as-library"]),
]

let includeAutomationTests = ProcessInfo.processInfo.environment["PEEKABOO_INCLUDE_AUTOMATION_TESTS"] == "true"
let testTargetSettings: [SwiftSetting] = {
    var base = approachableConcurrencySettings + [.enableExperimentalFeature("SwiftTesting")]
    if includeAutomationTests {
        base.append(.define("PEEKABOO_INCLUDE_AUTOMATION_TESTS"))
    }
    return base
}()

let package = Package(
    name: "PeekabooCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PeekabooAutomation",
            targets: ["PeekabooAutomation"]),
        .library(
            name: "PeekabooAgentRuntime",
            targets: ["PeekabooAgentRuntime"]),
        .library(
            name: "PeekabooBridge",
            targets: ["PeekabooBridge"]),
        // Test-only support product. Production targets do not depend on or link this module.
        .library(
            name: "PeekabooBridgeTestSupport",
            targets: ["PeekabooBridgeTestSupport"]),
        .library(
            name: "PeekabooCore",
            targets: ["PeekabooCore"]),
    ],
    dependencies: [
        .package(path: "../PeekabooAutomationKit"),
        .package(path: "../PeekabooFoundation"),
        .package(path: "../PeekabooProtocols"),
        .package(path: "../PeekabooExternalDependencies"),
        .package(path: "../PeekabooVisualizer"),
        .package(path: "../../Tachikoma"),
        .package(url: "https://github.com/apple/swift-configuration", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "PeekabooAutomation",
            dependencies: [
                .product(name: "PeekabooVisualizer", package: "PeekabooVisualizer"),
                .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit"),
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
                .product(name: "PeekabooProtocols", package: "PeekabooProtocols"),
                .product(name: "PeekabooExternalDependencies", package: "PeekabooExternalDependencies"),
                .product(name: "Tachikoma", package: "Tachikoma"),
                .product(name: "TachikomaAudio", package: "Tachikoma"),
                .product(name: "TachikomaMCP", package: "Tachikoma"),
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            path: "Sources/PeekabooAutomation",
            exclude: [
                "Services/README.md",
            ],
            swiftSettings: coreTargetSettings),
        .testTarget(
            name: "PeekabooAutomationTests",
            dependencies: [
                "PeekabooAutomation",
                "PeekabooCore",
                .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit"),
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
            ],
            path: "Tests/PeekabooAutomationTests",
            swiftSettings: testTargetSettings),
        .target(
            name: "PeekabooBridge",
            dependencies: [
                .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit"),
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
            ],
            path: "Sources/PeekabooBridge",
            swiftSettings: coreTargetSettings,
            linkerSettings: [.linkedLibrary("bsm")]),
        .testTarget(
            name: "PeekabooBridgeTests",
            dependencies: [
                "PeekabooBridge",
                .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit"),
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
            ],
            path: "Tests/PeekabooBridgeTests",
            swiftSettings: testTargetSettings),
        .target(
            name: "PeekabooBridgeTestSupport",
            dependencies: [
                .target(name: "PeekabooBridge"),
                .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit"),
                .product(name: "PeekabooAutomationKitTestSupport", package: "PeekabooAutomationKit"),
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
            ],
            path: "Sources/PeekabooBridgeTestSupport",
            swiftSettings: approachableConcurrencySettings),
        .target(
            name: "PeekabooAgentRuntime",
            dependencies: [
                .target(name: "PeekabooAutomation"),
                .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit"),
                .product(name: "PeekabooVisualizer", package: "PeekabooVisualizer"),
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
                .product(name: "PeekabooProtocols", package: "PeekabooProtocols"),
                .product(name: "PeekabooExternalDependencies", package: "PeekabooExternalDependencies"),
                .product(name: "Tachikoma", package: "Tachikoma"),
                .product(name: "TachikomaMCP", package: "Tachikoma"),
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            path: "Sources/PeekabooAgentRuntime",
            exclude: [
                "Agent/Tools/README.md",
            ],
            swiftSettings: coreTargetSettings),
        .testTarget(
            name: "PeekabooAgentRuntimeTests",
            dependencies: [
                "PeekabooAgentRuntime",
                "PeekabooCore",
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
            ],
            path: "Tests/PeekabooAgentRuntimeTests",
            swiftSettings: testTargetSettings),
        .target(
            name: "PeekabooCore",
            dependencies: [
                .target(name: "PeekabooAutomation"),
                .target(name: "PeekabooAgentRuntime"),
                .target(name: "PeekabooBridge"),
                .product(name: "PeekabooVisualizer", package: "PeekabooVisualizer"),
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
                .product(name: "PeekabooProtocols", package: "PeekabooProtocols"),
                .product(name: "PeekabooExternalDependencies", package: "PeekabooExternalDependencies"),
                .product(name: "Tachikoma", package: "Tachikoma"),
                .product(name: "TachikomaMCP", package: "Tachikoma"),
                .product(name: "TachikomaAudio", package: "Tachikoma"),
                .product(name: "Configuration", package: "swift-configuration"),
            ],
            exclude: [
                "README.md",
            ],
            swiftSettings: coreTargetSettings),
        .testTarget(
            name: "PeekabooTests",
            dependencies: [
                "PeekabooCore",
                "PeekabooAutomation",
                "PeekabooAgentRuntime",
                .product(name: "PeekabooAutomationKit", package: "PeekabooAutomationKit"),
                .product(name: "PeekabooVisualizer", package: "PeekabooVisualizer"),
                "PeekabooFoundation",
                .product(name: "PeekabooFoundationTestSupport", package: "PeekabooFoundation"),
                "PeekabooProtocols",
                "PeekabooBridgeTestSupport",
                .product(name: "PeekabooAutomationKitTestSupport", package: "PeekabooAutomationKit"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: testTargetSettings),
    ],
    swiftLanguageModes: [.v6])
