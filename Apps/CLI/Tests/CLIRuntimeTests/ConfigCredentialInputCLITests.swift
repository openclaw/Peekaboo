import Darwin
import Foundation
import Testing

@Suite(.serialized)
struct ConfigCredentialInputCLITests {
    @Test
    func `piped credential is stored without appearing in output`() async throws {
        let fixture = "fixture-secret-piped-cli"
        let directory = try self.makeTemporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await TestChildProcess.runPeekaboo(
            [
                "config", "credential", "set", "PEEKABOO_PIPE_TEST_KEY",
                "--credential-stdin", "--no-input", "--json", "--no-remote",
            ],
            environment: self.environment(for: directory),
            standardInput: fixture + "\n"
        )

        #expect(result.status == .exited(0))
        #expect(!result.standardOutput.contains(fixture))
        #expect(!result.standardError.contains(fixture))

        let stored = try String(
            contentsOf: directory.appendingPathComponent("credentials"),
            encoding: .utf8
        )
        #expect(stored.contains("PEEKABOO_PIPE_TEST_KEY=\(fixture)"))
    }

    @Test
    func `provider dry run JSON reports only the credential source`() async throws {
        let fixture = "fixture-secret-provider-dry-run"
        let directory = try self.makeTemporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await TestChildProcess.runPeekaboo(
            [
                "config", "provider", "add", "fixture-provider",
                "--type", "openai",
                "--name", "Fixture",
                "--base-url", "https://fixture.invalid/v1",
                "--credential-stdin",
                "--no-input",
                "--dry-run",
                "--json",
                "--no-remote",
            ],
            environment: self.environment(for: directory),
            standardInput: fixture + "\n"
        )

        #expect(result.status == .exited(0))
        #expect(!result.standardOutput.contains(fixture))
        #expect(!result.standardError.contains(fixture))
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any]
        )
        let data = try #require(json["data"] as? [String: Any])
        let provider = try #require(data["provider"] as? [String: Any])
        #expect(provider["credentialSource"] as? String == "stdin")
        #expect(provider["apiKey"] == nil)
    }

    @Test
    func `no input failure is structured and actionable`() async throws {
        let directory = try self.makeTemporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await TestChildProcess.runPeekaboo(
            [
                "config", "credential", "set", "PEEKABOO_EMPTY_TEST_KEY",
                "--no-input", "--json", "--no-remote",
            ],
            environment: self.environment(for: directory),
            standardInput: ""
        )

        #expect(result.status == .exited(1))
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(result.standardOutput.utf8)) as? [String: Any]
        )
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "CREDENTIAL_INPUT_ERROR")
        #expect((error["message"] as? String)?.contains("--credential-stdin") == true)
    }

    @Test
    func `non TTY EOF fails without prompting or hanging`() throws {
        let directory = try self.makeTemporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = Pipe()
        let process = Process()
        process.executableURL = try TestChildProcess.peekabooBinaryURL()
        process.arguments = [
            "config", "credential", "set", "PEEKABOO_EOF_TEST_KEY",
            "--json", "--no-remote",
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            self.environment(for: directory),
            uniquingKeysWith: { _, new in new }
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        #expect(self.waitForExit(process, timeout: 2))
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        let standardOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 1)
        #expect(standardOutput.contains("CREDENTIAL_INPUT_ERROR"))
        #expect(standardOutput.contains("--credential-stdin"))
        #expect(!standardOutput.contains("Credential for"))
    }

    @Test
    func `explicit stdin with no input never prompts on a TTY`() throws {
        let result = try self.runTTYCredentialCommand(
            arguments: [
                "config", "credential", "set", "PEEKABOO_TTY_NO_INPUT_TEST_KEY",
                "--credential-stdin", "--no-input", "--json", "--no-remote",
            ],
            signalNumber: nil
        )

        #expect(result.exitedWithinDeadline)
        #expect(result.terminationStatus == 1)
        #expect(result.echoEnabledAfterExit)
        #expect(result.output.contains("CREDENTIAL_INPUT_ERROR"))
        #expect(!result.output.contains("Credential for"))
    }

    @Test
    func `interrupting a secure prompt restores terminal echo and exits`() throws {
        for signalNumber in [SIGINT, SIGTERM] {
            let result = try self.runTTYCredentialCommand(
                arguments: [
                    "config", "credential", "set", "PEEKABOO_TTY_SIGNAL_TEST_KEY",
                    "--no-remote",
                ],
                signalNumber: signalNumber
            )

            #expect(result.sawPrompt)
            #expect(result.echoDisabledAtPrompt)
            #expect(result.exitedWithinDeadline)
            #expect(result.echoEnabledAfterExit)
        }
    }

    @Test
    func `safe pipe keeps credential out of the live process arguments`() throws {
        let fixture = "fixture-secret-process-list"
        let directory = try self.makeTemporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        let process = Process()
        process.executableURL = try TestChildProcess.peekabooBinaryURL()
        process.arguments = [
            "config", "credential", "set", "PEEKABOO_PROCESS_TEST_KEY",
            "--credential-stdin", "--no-input", "--no-remote",
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            self.environment(for: directory),
            uniquingKeysWith: { _, new in new }
        )
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
            }
        }

        let ps = Process()
        let psOutput = Pipe()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-p", String(process.processIdentifier), "-o", "command="]
        ps.standardOutput = psOutput
        try ps.run()
        ps.waitUntilExit()
        let commandLine = String(
            data: psOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        #expect(commandLine.contains("--credential-stdin"))
        #expect(!commandLine.contains(fixture))

        try input.fileHandleForWriting.write(contentsOf: Data((fixture + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        let standardOutput = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let standardError = String(
            data: error.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0)
        #expect(!standardOutput.contains(fixture))
        #expect(!standardError.contains(fixture))
    }

    @Test
    func `invalid provider metadata fails before reading credential input`() throws {
        let directory = try self.makeTemporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = Pipe()
        let output = Pipe()
        let process = Process()
        process.executableURL = try TestChildProcess.peekabooBinaryURL()
        process.arguments = [
            "config", "provider", "add", "invalid provider id",
            "--type", "openai",
            "--name", "Fixture",
            "--base-url", "https://fixture.invalid/v1",
            "--credential-stdin",
            "--no-input",
            "--json",
            "--no-remote",
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            self.environment(for: directory),
            uniquingKeysWith: { _, new in new }
        )
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            usleep(20000)
        }
        #expect(process.isRunning == false)
        if process.isRunning {
            process.terminate()
        }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()

        #expect(process.terminationStatus == 1)
        let json = try #require(
            JSONSerialization.jsonObject(
                with: output.fileHandleForReading.readDataToEndOfFile()
            ) as? [String: Any]
        )
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "INVALID_ID")
    }

    @Test
    func `writerless FIFO credential file is rejected without blocking`() throws {
        let directory = try self.makeTemporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let fifo = directory.appendingPathComponent("credential.fifo")
        #expect(mkfifo(fifo.path, mode_t(0o600)) == 0)

        let output = Pipe()
        let process = Process()
        process.executableURL = try TestChildProcess.peekabooBinaryURL()
        process.arguments = [
            "config", "credential", "set", "PEEKABOO_FIFO_TEST_KEY",
            "--credential-file", fifo.path,
            "--no-input",
            "--json",
            "--no-remote",
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            self.environment(for: directory),
            uniquingKeysWith: { _, new in new }
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        let exitedWithinDeadline = self.waitForExit(process, timeout: 2)
        if !exitedWithinDeadline, process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()

        #expect(exitedWithinDeadline)
        #expect(process.terminationStatus == 1)
        let json = try #require(
            JSONSerialization.jsonObject(
                with: output.fileHandleForReading.readDataToEndOfFile()
            ) as? [String: Any]
        )
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["code"] as? String == "CREDENTIAL_INPUT_ERROR")
        #expect((error["message"] as? String)?.contains("regular file") == true)
    }

    private func makeTemporaryConfigDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-credential-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func environment(for directory: URL) -> [String: String] {
        [
            "PEEKABOO_CONFIG_DIR": directory.path,
            "PEEKABOO_CONFIG_NONINTERACTIVE": "1",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION": "1",
            "PEEKABOO_NO_REMOTE": "1",
        ]
    }

    private struct TTYResult {
        let output: String
        let terminationStatus: Int32
        let sawPrompt: Bool
        let echoDisabledAtPrompt: Bool
        let exitedWithinDeadline: Bool
        let echoEnabledAfterExit: Bool
    }

    private enum TTYError: Error {
        case openFailed
    }

    private func runTTYCredentialCommand(arguments: [String], signalNumber: Int32?) throws -> TTYResult {
        let directory = try self.makeTemporaryConfigDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var size = winsize(ws_row: 20, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &size) == 0 else {
            throw TTYError.openFailed
        }
        let primary = FileHandle(fileDescriptor: primaryFD, closeOnDealloc: true)
        let secondary = FileHandle(fileDescriptor: secondaryFD, closeOnDealloc: true)
        defer {
            try? primary.close()
            try? secondary.close()
        }
        _ = fcntl(primaryFD, F_SETFL, O_NONBLOCK)

        var initial = termios()
        guard tcgetattr(secondaryFD, &initial) == 0 else {
            throw TTYError.openFailed
        }
        initial.c_lflag |= tcflag_t(ECHO)
        guard tcsetattr(secondaryFD, TCSANOW, &initial) == 0 else {
            throw TTYError.openFailed
        }

        let process = Process()
        process.executableURL = try TestChildProcess.peekabooBinaryURL()
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            self.environment(for: directory),
            uniquingKeysWith: { _, new in new }
        )
        process.standardInput = secondary
        process.standardOutput = secondary
        process.standardError = secondary
        try process.run()
        defer {
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }

        var output = Data()
        let promptDeadline = Date().addingTimeInterval(5)
        var sawPrompt = false
        while process.isRunning, Date() < promptDeadline {
            self.drainTTY(fileDescriptor: primaryFD, into: &output)
            if String(data: output, encoding: .utf8)?.contains("Credential for") == true {
                sawPrompt = true
                break
            }
            if signalNumber == nil {
                break
            }
            usleep(20000)
        }

        var promptTerminal = termios()
        let echoDisabledAtPrompt = sawPrompt &&
            tcgetattr(secondaryFD, &promptTerminal) == 0 &&
            promptTerminal.c_lflag & tcflag_t(ECHO) == 0

        if let signalNumber, process.isRunning {
            _ = kill(process.processIdentifier, signalNumber)
        }
        let exitedWithinDeadline = self.waitForExit(process, timeout: 2)
        if !exitedWithinDeadline, process.isRunning {
            _ = kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
        self.drainTTY(fileDescriptor: primaryFD, into: &output)

        var finalTerminal = termios()
        let echoEnabledAfterExit = tcgetattr(secondaryFD, &finalTerminal) == 0 &&
            finalTerminal.c_lflag & tcflag_t(ECHO) != 0
        return TTYResult(
            output: String(data: output, encoding: .utf8) ?? "",
            terminationStatus: process.terminationStatus,
            sawPrompt: sawPrompt,
            echoDisabledAtPrompt: echoDisabledAtPrompt,
            exitedWithinDeadline: exitedWithinDeadline,
            echoEnabledAfterExit: echoEnabledAfterExit
        )
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20000)
        }
        return !process.isRunning
    }

    private func drainTTY(fileDescriptor: Int32, into output: inout Data) {
        while true {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                output.append(contentsOf: bytes.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
    }
}
