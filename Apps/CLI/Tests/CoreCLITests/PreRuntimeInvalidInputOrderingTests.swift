import Darwin
import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct PreRuntimeInvalidInputOrderingTests {
    @Test(arguments: [
        (
            ["peekaboo", "type", "alpha", "--json"],
            "Keyboard input requires --app, --pid, --window-id, or --snapshot for background delivery."
        ),
        (
            ["peekaboo", "browser", "frobnicate", "--json"],
            "Unsupported browser action 'frobnicate'"
        ),
        (
            [
                "peekaboo", "browser", "connect", "--browser-url", "ftp://127.0.0.1:1", "--json",
            ],
            "Invalid --browser-url. Expected http://127.0.0.1:<port>, " +
                "http://[::1]:<port>, or http://localhost:<port>."
        ),
    ])
    func `semantic-invalid commands refuse before runtime construction`(
        arguments: [String],
        expectedMessage: String
    ) async throws {
        try await Self.requirePreRuntimeRefusal(arguments: arguments, expectedMessage: expectedMessage)
    }

    @Test(arguments: [
        ["peekaboo", "agent", "--dry-run", "--no-remote"],
        ["peekaboo", "agent", "--dry-run", "--json", "--no-remote"],
        ["peekaboo", "agent", "run", "--dry-run", "--no-remote"],
        ["peekaboo", "agent", "run", "--dry-run", "--json", "--no-remote"],
    ])
    func `taskless agent dry run refuses before runtime construction`(arguments: [String]) async throws {
        try await Self.requirePreRuntimeRefusal(
            arguments: arguments,
            expectedMessage: "Invalid input: Task argument is required for --dry-run."
        )
    }

    @Test
    func `invalid video file and cadence refuse before runtime construction`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-pre-runtime-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("missing.mp4")
        try await Self.requirePreRuntimeRefusal(
            arguments: ["peekaboo", "capture", "video", missing.path, "--json"],
            expectedMessage: "Input video file does not exist: \(missing.path)"
        )

        let empty = root.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        try await Self.requirePreRuntimeRefusal(
            arguments: [
                "peekaboo", "capture", "video", empty.path, "--sample-fps", "-1", "--json",
            ],
            expectedMessage: "Invalid input: sample-fps must be a positive finite value"
        )

        let fifo = root.appendingPathComponent("stream.mp4")
        #expect(mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        try await Self.requirePreRuntimeRefusal(
            arguments: ["peekaboo", "capture", "video", fifo.path, "--json"],
            expectedMessage: "Input video path is not a regular file: \(fifo.path)"
        )

        let invalidOptions: [([String], String)] = [
            (
                ["--every", "0ms"],
                "Invalid input: every-ms must be greater than zero"
            ),
            (
                ["--start=-1ms"],
                "Invalid value '-1ms' for start: Unable to parse CLIDuration"
            ),
            (
                ["--end=-1ms"],
                "Invalid value '-1ms' for end: Unable to parse CLIDuration"
            ),
            (
                ["--end", "0ms"],
                "Invalid input: end-ms must exceed start-ms"
            ),
            (
                ["--start", "2s", "--end", "1s"],
                "Invalid input: end-ms must exceed start-ms"
            ),
            (
                ["--resolution-cap", "0"],
                "Invalid input: resolution-cap must be a positive finite value"
            ),
            (
                ["--diff-strategy", "slow"],
                "Unsupported diff strategy 'slow'. Use fast or quality."
            ),
        ]
        for (options, expectedMessage) in invalidOptions {
            try await Self.requirePreRuntimeRefusal(
                arguments: ["peekaboo", "capture", "video", empty.path] + options + ["--json"],
                expectedMessage: expectedMessage
            )
        }
    }

    @Test(arguments: [
        ["peekaboo", "type", "alpha", "--foreground", "--json"],
        ["peekaboo", "browser", "status", "--json"],
    ])
    func `valid request shapes continue to runtime construction`(arguments: [String]) async throws {
        let resolved = try CommanderRuntimeRouter.resolve(argv: arguments)
        var runtimeConstructionCount = 0

        do {
            try await CommanderRuntimeExecutor.run(
                resolved: resolved,
                runtimeFactory: .init { _ in
                    runtimeConstructionCount += 1
                    throw RuntimeConstructionProbe.reached
                }
            )
            Issue.record("Expected the runtime construction probe to stop execution")
        } catch RuntimeConstructionProbe.reached {
            // Expected: request-only validation completed and runtime construction began exactly once.
        }

        #expect(runtimeConstructionCount == 1)
    }

    @Test
    func `valid video request shape continues to runtime construction`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-valid-video-shape-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.mp4")
        let input = root.appendingPathComponent("input.mp4")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: input, withDestinationURL: target)

        let resolved = try CommanderRuntimeRouter.resolve(argv: [
            "peekaboo", "capture", "video", input.path, "--sample-fps", "2", "--json",
        ])
        var runtimeConstructionCount = 0

        do {
            try await CommanderRuntimeExecutor.run(
                resolved: resolved,
                runtimeFactory: .init { _ in
                    runtimeConstructionCount += 1
                    throw RuntimeConstructionProbe.reached
                }
            )
            Issue.record("Expected the runtime construction probe to stop execution")
        } catch RuntimeConstructionProbe.reached {
            // Expected.
        }

        #expect(runtimeConstructionCount == 1)
    }

    private static func requirePreRuntimeRefusal(
        arguments: [String],
        expectedMessage: String
    ) async throws {
        let resolved = try CommanderRuntimeRouter.resolve(argv: arguments)
        var runtimeConstructionCount = 0

        do {
            try await CommanderRuntimeExecutor.run(
                resolved: resolved,
                runtimeFactory: .init { _ in
                    runtimeConstructionCount += 1
                    throw RuntimeConstructionProbe.reached
                }
            )
            Issue.record("Expected request-only validation to refuse the command")
        } catch RuntimeConstructionProbe.reached {
            Issue.record("Runtime construction was reached for malformed request: \(arguments)")
        } catch {
            #expect(error.localizedDescription == expectedMessage)
        }

        #expect(runtimeConstructionCount == 0)
    }
}

private enum RuntimeConstructionProbe: Error {
    case reached
}
