// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let infoPlistPath = ProcessInfo.processInfo.environment["PEEKABOO_CLI_INFO_PLIST_PATH"] ??
    packageDirectory.appendingPathComponent("Sources/Resources/Info.plist").path

let concurrencyBaseSettings: [SwiftSetting] = [
    .enableExperimentalFeature("StrictConcurrency"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableExperimentalFeature("RetroactiveConformances"),
]

let cliConcurrencySettings = concurrencyBaseSettings + [
    .defaultIsolation(MainActor.self),
]

let swiftTestingSettings = cliConcurrencySettings + [
    .enableExperimentalFeature("SwiftTesting"),
]

let includeAutomationTests = ProcessInfo.processInfo.environment["PEEKABOO_INCLUDE_AUTOMATION_TESTS"] == "true"

var targets: [Target] = [
        .target(
            name: "PeekabooCLI",
            dependencies: [
            .product(name: "Commander", package: "Commander"),
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Spinner", package: "Spinner"),
            .product(name: "TauTUI", package: "TauTUI"),
            .product(name: "PeekabooCore", package: "PeekabooCore"),
            .product(name: "PeekabooBridge", package: "PeekabooCore"),
            .product(name: "PeekabooVisualizer", package: "PeekabooVisualizer"),
            .product(name: "Tachikoma", package: "Tachikoma"),
            .product(name: "TachikomaMCP", package: "Tachikoma"),
            .product(name: "Swiftdansi", package: "Swiftdansi"),
            ],
            path: "Sources/PeekabooCLI",
            swiftSettings: cliConcurrencySettings),
        .executableTarget(
        name: "peekaboo",
        dependencies: [
            "PeekabooCLI",
        ],
        path: "Sources/PeekabooExec",
        swiftSettings: cliConcurrencySettings,
        linkerSettings: [
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", infoPlistPath,
                // Ensure LC_UUID is generated for macOS 26 compatibility
                "-Xlinker", "-random_uuid",
            ]),
        ]),
    .testTarget(
        name: "CoreCLITests",
        dependencies: [
            "PeekabooCLI",
            .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
            .product(name: "PeekabooAutomation", package: "PeekabooCore"),
            .product(name: "PeekabooAgentRuntime", package: "PeekabooCore"),
            .product(name: "PeekabooCore", package: "PeekabooCore"),
        ],
        path: "Tests/CoreCLITests",
        swiftSettings: swiftTestingSettings),
    .testTarget(
        name: "CLIRuntimeTests",
        dependencies: [
            "PeekabooCLI",
            .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
            .product(name: "Subprocess", package: "swift-subprocess"),
        ],
        path: "Tests/CLIRuntimeTests",
        swiftSettings: swiftTestingSettings),
]

if includeAutomationTests {
    targets.append(
        .testTarget(
            name: "CLIAutomationTests",
            dependencies: [
                "PeekabooCLI",
                .product(name: "PeekabooFoundation", package: "PeekabooFoundation"),
                .product(name: "PeekabooCore", package: "PeekabooCore"),
                .product(name: "PeekabooAgentRuntime", package: "PeekabooCore"),
                .product(name: "PeekabooAutomation", package: "PeekabooCore"),
                .product(name: "Subprocess", package: "swift-subprocess"),
            ],
            path: "Tests/CLIAutomationTests",
            resources: [
                .process("__snapshots__"),
            ],
            swiftSettings: swiftTestingSettings)
    )
}



let package = Package(
    name: "peekaboo",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "peekaboo",
            targets: ["peekaboo"]),
    ],
    dependencies: [
        .package(path: "../../Commander"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", "0.12.1" ..< "0.13.0"),
        .package(url: "https://github.com/dominicegginton/Spinner", from: "2.2.0"),
        .package(url: "https://github.com/swiftlang/swift-subprocess.git", from: "0.5.0"),
        .package(path: "../../TauTUI"),
        .package(path: "../../Core/PeekabooFoundation"),
        .package(path: "../../Core/PeekabooVisualizer"),
        .package(path: "../../Core/PeekabooCore"),
        .package(path: "../../Tachikoma"),
        .package(path: "../../Swiftdansi"),
    ],
    targets: targets,
    swiftLanguageModes: [.v6])
