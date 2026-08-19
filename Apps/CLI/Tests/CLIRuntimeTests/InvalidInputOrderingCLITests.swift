import Darwin
import Foundation
import Subprocess
import Testing

@Suite(.serialized)
struct InvalidInputOrderingCLITests {
    struct MissingSemanticInputCase: Sendable {
        let command: String

        var errorMessage: String {
            "Command 'peekaboo \(self.command)' requires command input; " +
                "run 'peekaboo \(self.command) --help' for usage."
        }
    }

    struct JSONCase: Sendable {
        let arguments: [String]
        let code: String
        let message: String
        let hint: String?
    }

    @Test(arguments: [
        MissingSemanticInputCase(command: "type"),
        MissingSemanticInputCase(command: "press"),
        MissingSemanticInputCase(command: "action"),
        MissingSemanticInputCase(command: "set-value"),
        MissingSemanticInputCase(command: "click"),
    ])
    func `missing semantic input is invalid usage before runtime discovery`(
        _ testCase: MissingSemanticInputCase
    ) async throws {
        let human = try await TestChildProcess.runPeekaboo([testCase.command])

        #expect(human.status == .exited(1))
        #expect(human.standardOutput.contains("Usage\n  peekaboo \(testCase.command)"))
        #expect(human.standardError == "Error: \(testCase.errorMessage)\n")

        let json = try await TestChildProcess.runPeekaboo([testCase.command, "--json"])

        #expect(json.status == .exited(1))
        #expect(json.standardError.isEmpty)
        let envelope = try Self.errorEnvelope(from: json.standardOutput)
        #expect(envelope.code == "INVALID_ARGUMENT")
        #expect(envelope.message == "Command 'peekaboo \(testCase.command)' requires command input.")
        #expect(envelope.hint == "Run 'peekaboo \(testCase.command) --help' for usage.")
        #expect(envelope.debugLogs.isEmpty)

        let unavailableRuntime = try await TestChildProcess.runPeekaboo(
            [testCase.command, "--bridge-socket", "/tmp/peekaboo-missing-semantic-input.sock"],
            isolateFromRemoteHosts: false
        )
        #expect(unavailableRuntime.status == .exited(1))
        #expect(unavailableRuntime.standardOutput.contains("Usage\n  peekaboo \(testCase.command)"))
        #expect(unavailableRuntime.standardError == "Error: \(testCase.errorMessage)\n")
    }

    @Test(arguments: ["type", "press", "action", "set-value", "click"])
    func `explicit help remains successful for semantic input commands`(command: String) async throws {
        let result = try await TestChildProcess.runPeekaboo(
            [command, "--bridge-socket", "/tmp/peekaboo-help-missing.sock", "--help"],
            isolateFromRemoteHosts: false
        )

        #expect(result.status == .exited(0))
        #expect(result.standardError.isEmpty)
        #expect(result.standardOutput.contains("Usage\n  peekaboo \(command)"))
    }

    @Test(arguments: ["type", "press", "action", "set-value", "click"])
    func `unknown options are not hidden by empty invocation help`(command: String) async throws {
        let result = try await TestChildProcess.runPeekaboo([command, "--bogus"])

        #expect(result.status == .exited(1))
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.contains("Unknown option --bogus"))
        #expect(!result.standardError.contains("requires command input"))
    }

    @Test(arguments: [
        JSONCase(
            arguments: ["type", "alpha", "--json"],
            code: "VALIDATION_ERROR",
            message: "Keyboard input requires --app, --pid, --window-id, or --snapshot for background delivery.",
            hint: "Use --foreground for intentional global input."
        ),
        JSONCase(
            arguments: ["browser", "frobnicate", "--json"],
            code: "VALIDATION_ERROR",
            message: "Unsupported browser action 'frobnicate'",
            hint: nil
        ),
        JSONCase(
            arguments: [
                "browser", "connect", "--browser-url", "ftp://127.0.0.1:1", "--json",
            ],
            code: "VALIDATION_ERROR",
            message: "Invalid --browser-url. Expected http://127.0.0.1:<port>, " +
                "http://[::1]:<port>, or http://localhost:<port>.",
            hint: "Run `peekaboo browser connect --browser-url http://127.0.0.1:9222 --foreground`."
        ),
    ])
    func `semantic-invalid JSON requests refuse before runtime discovery`(_ testCase: JSONCase) async throws {
        let startedAt = ContinuousClock.now
        let result = try await TestChildProcess.runPeekaboo(testCase.arguments)
        let elapsed = startedAt.duration(to: .now)

        #expect(result.status == .exited(1))
        #expect(result.standardError.isEmpty)
        let envelope = try Self.errorEnvelope(from: result.standardOutput)
        #expect(envelope.code == testCase.code)
        #expect(envelope.message == testCase.message)
        #expect(envelope.hint == testCase.hint)
        #expect(envelope.debugLogs.isEmpty)
        #expect(elapsed < .seconds(2))
    }

    @Test
    func `video input failures retain exact paths and skip runtime discovery`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-input-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("missing.mp4")
        let missingResult = try await TestChildProcess.runPeekaboo([
            "capture", "video", missing.path, "--json",
        ])
        let missingEnvelope = try Self.errorEnvelope(from: missingResult.standardOutput)
        #expect(missingResult.status == .exited(1))
        #expect(missingResult.standardError.isEmpty)
        #expect(missingEnvelope.code == "INVALID_INPUT")
        #expect(missingEnvelope.message == "Input video file does not exist: \(missing.path)")
        #expect(missingEnvelope.hint == "Check the path and pass an existing readable video file.")
        #expect(missingEnvelope.debugLogs.isEmpty)

        let empty = root.appendingPathComponent("empty.mp4")
        try Data().write(to: empty)
        let cadenceResult = try await TestChildProcess.runPeekaboo([
            "capture", "video", empty.path, "--sample-fps", "-1", "--json",
        ])
        let cadenceEnvelope = try Self.errorEnvelope(from: cadenceResult.standardOutput)
        #expect(cadenceResult.status == .exited(1))
        #expect(cadenceResult.standardError.isEmpty)
        #expect(cadenceEnvelope.code == "INVALID_INPUT")
        #expect(cadenceEnvelope.message == "Invalid input: sample-fps must be a positive finite value")
        #expect(cadenceEnvelope.hint == "Use --sample-fps with a finite value greater than 0.")
        #expect(cadenceEnvelope.debugLogs.isEmpty)

        let fifo = root.appendingPathComponent("stream.mp4")
        #expect(mkfifo(fifo.path, mode_t(S_IRUSR | S_IWUSR)) == 0)
        let fifoResult = try await TestChildProcess.runPeekaboo([
            "capture", "video", fifo.path, "--json",
        ])
        let fifoEnvelope = try Self.errorEnvelope(from: fifoResult.standardOutput)
        #expect(fifoResult.status == .exited(1))
        #expect(fifoResult.standardError.isEmpty)
        #expect(fifoEnvelope.code == "INVALID_INPUT")
        #expect(fifoEnvelope.message == "Input video path is not a regular file: \(fifo.path)")
        #expect(fifoEnvelope.debugLogs.isEmpty)

        let optionCases: [([String], String, String, String?)] = [
            (
                ["--every", "0ms"],
                "INVALID_INPUT",
                "Invalid input: every-ms must be greater than zero",
                "Correct the video sampling options and retry."
            ),
            (
                ["--start=-1ms"],
                "INVALID_ARGUMENT",
                "Invalid value '-1ms' for start: Unable to parse CLIDuration",
                nil
            ),
            (
                ["--end=-1ms"],
                "INVALID_ARGUMENT",
                "Invalid value '-1ms' for end: Unable to parse CLIDuration",
                nil
            ),
            (
                ["--end", "0ms"],
                "INVALID_INPUT",
                "Invalid input: end-ms must exceed start-ms",
                "Correct the video sampling options and retry."
            ),
            (
                ["--start", "2s", "--end", "1s"],
                "INVALID_INPUT",
                "Invalid input: end-ms must exceed start-ms",
                "Correct the video sampling options and retry."
            ),
            (
                ["--resolution-cap", "0"],
                "INVALID_INPUT",
                "Invalid input: resolution-cap must be a positive finite value",
                "Correct the video sampling options and retry."
            ),
            (
                ["--diff-strategy", "slow"],
                "VALIDATION_ERROR",
                "Unsupported diff strategy 'slow'.",
                "Use fast or quality."
            ),
        ]
        for (options, expectedCode, expectedMessage, expectedHint) in optionCases {
            let result = try await TestChildProcess.runPeekaboo(
                ["capture", "video", empty.path] + options + ["--json"]
            )
            let envelope = try Self.errorEnvelope(from: result.standardOutput)
            #expect(result.status == .exited(1))
            #expect(result.standardError.isEmpty)
            #expect(envelope.code == expectedCode)
            #expect(envelope.message == expectedMessage)
            #expect(envelope.hint == expectedHint)
            #expect(envelope.debugLogs.isEmpty)
        }
    }

    @Test
    func `human failures remain concise and CLI native`() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-human-missing-\(UUID().uuidString).mp4")
        let cases: [([String], String)] = [
            (
                ["type", "alpha"],
                "Error: Keyboard input requires --app, --pid, --window-id, or --snapshot for background " +
                    "delivery. Hint: Use --foreground for intentional global input.\n"
            ),
            (
                ["browser", "frobnicate"],
                "Error: Unsupported browser action 'frobnicate'\n"
            ),
            (
                ["browser", "connect", "--browser-url", "ftp://127.0.0.1:1"],
                "Error: Invalid --browser-url. Expected http://127.0.0.1:<port>, http://[::1]:<port>, or " +
                    "http://localhost:<port>. Hint: Run `peekaboo browser connect --browser-url " +
                    "http://127.0.0.1:9222 --foreground`.\n"
            ),
            (
                ["capture", "video", missing.path],
                "Error: Input video file does not exist: \(missing.path) Hint: Check the path and pass an " +
                    "existing readable video file.\n"
            ),
        ]

        for (arguments, expectedError) in cases {
            let result = try await TestChildProcess.runPeekaboo(arguments)
            #expect(result.status == .exited(1))
            #expect(result.standardOutput.isEmpty)
            #expect(result.standardError == expectedError)
            #expect(!result.standardError.contains("Run browser {"))
        }
    }

    private static func errorEnvelope(from output: String) throws -> (
        code: String,
        message: String,
        hint: String?,
        debugLogs: [String]
    ) {
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        #expect(object["success"] as? Bool == false)
        let error = try #require(object["error"] as? [String: Any])
        return try (
            code: #require(error["code"] as? String),
            message: #require(error["message"] as? String),
            hint: error["hint"] as? String,
            debugLogs: #require(object["debug_logs"] as? [String])
        )
    }
}
