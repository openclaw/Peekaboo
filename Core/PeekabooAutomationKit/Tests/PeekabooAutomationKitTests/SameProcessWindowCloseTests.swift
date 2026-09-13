import Foundation
import Testing
@testable import PeekabooAutomationKit

@Suite(
    .serialized,
    .enabled(if: ProcessInfo.processInfo.environment["RUN_AUTOMATION_ACTIONS"]?.lowercased() == "true"))
struct SameProcessWindowCloseTests {
    @Test
    func `background close keeps host callbacks on MainActor and preserves sibling windows`() throws {
        let fixtureURL = Bundle(for: FixtureBundleAnchor.self).bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("HostWindowCloseFixture")
        try #require(FileManager.default.isExecutableFile(atPath: fixtureURL.path))

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-host-window-close-\(UUID().uuidString).log")
        try #require(FileManager.default.createFile(atPath: outputURL.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = fixtureURL
        process.standardOutput = output
        process.standardError = output
        try process.run()
        try DockService.waitForProcessExit(process, timeoutSeconds: 25)

        let diagnostics = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(process.terminationReason == .exit, "\(diagnostics)")
        #expect(process.terminationStatus == 0, "\(diagnostics)")
        #expect(
            diagnostics.split(separator: "\n").contains("HOST_WINDOW_CLOSE_FIXTURE_COMPLETED"),
            "The AppKit child must finish its assertions before exiting. \(diagnostics)")
    }
}

private final class FixtureBundleAnchor: NSObject {}
