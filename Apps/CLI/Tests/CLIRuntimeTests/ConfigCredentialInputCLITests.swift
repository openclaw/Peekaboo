import Darwin
import Dispatch
import Foundation
import Subprocess
import Testing
@testable import PeekabooCLI
#if canImport(System)
import System
#else
import SystemPackage
#endif

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
    func `explicit stdin with no input never prompts on a TTY`() async throws {
        let result = try await self.runTTYCredentialCommand(
            arguments: [
                "config", "credential", "set", "PEEKABOO_TTY_NO_INPUT_TEST_KEY",
                "--credential-stdin", "--no-input", "--json", "--no-remote",
            ],
            action: .waitForExit
        )

        #expect(result.exitedWithinDeadline)
        #expect(result.terminationStatus == .exited(1))
        #expect(result.echoEnabledAfterExit)
        #expect(result.output.contains("CREDENTIAL_INPUT_ERROR"))
        #expect(!result.output.contains("Credential for"))
    }

    @Test
    func `normal secure prompt input restores terminal echo`() async throws {
        let fixture = "fixture-secret-normal-tty"
        let result = try await self.runTTYCredentialCommand(
            arguments: [
                "config", "credential", "set", "PEEKABOO_TTY_NORMAL_TEST_KEY",
                "--no-remote",
            ],
            action: .submit(fixture + "\n")
        )

        #expect(result.sawPrompt)
        #expect(result.echoDisabledAtPrompt)
        #expect(result.exitedWithinDeadline)
        #expect(result.terminationStatus == .exited(0))
        #expect(result.echoEnabledAfterExit)
        #expect(!result.output.contains(fixture))
    }

    @Test
    func `TTY descriptor without a controlling terminal fails without stdin fallback`() async throws {
        let result = try await self.runTTYCredentialCommand(
            arguments: [
                "config", "credential", "set", "PEEKABOO_DETACHED_TTY_TEST_KEY",
                "--json", "--no-remote",
            ],
            action: .waitForExit,
            topology: .detached
        )

        #expect(!result.sawPrompt)
        #expect(result.exitedWithinDeadline)
        #expect(result.terminationStatus == .exited(1))
        #expect(result.echoEnabledAfterExit)
        #expect(result.output.contains("CREDENTIAL_INPUT_ERROR"))
        #expect(!result.output.contains("Credential for"))
    }

    @Test
    func `background process group fails before prompting or changing echo`() async throws {
        let result = try await self.runTTYCredentialCommand(
            arguments: [
                "config", "credential", "set", "PEEKABOO_BACKGROUND_TTY_TEST_KEY",
                "--json", "--no-remote",
            ],
            action: .waitForExit,
            topology: .background
        )

        #expect(!result.sawPrompt)
        #expect(result.exitedWithinDeadline)
        #expect(result.terminationStatus == .exited(1))
        #expect(result.echoEnabledAfterExit)
        #expect(result.output.contains("CREDENTIAL_INPUT_ERROR"))
        #expect(!result.output.contains("Credential for"))
    }

    @Test
    func `terminating a secure prompt restores terminal echo and signal status`() async throws {
        for signalNumber in [SIGINT, SIGTERM, SIGQUIT, SIGHUP, SIGPIPE] {
            let result = try await self.runTTYCredentialCommand(
                arguments: [
                    "config", "credential", "set", "PEEKABOO_TTY_SIGNAL_TEST_KEY",
                    "--no-remote",
                ],
                action: .terminate(signalNumber),
                launchDisposition: .defaultSignals
            )

            #expect(result.sawPrompt)
            #expect(result.echoDisabledAtPrompt)
            #expect(result.exitedWithinDeadline)
            #expect(result.echoEnabledAfterExit)
            #expect(result.terminationStatus == .signaled(signalNumber))
        }
    }

    @Test
    func `ignored SIGPIPE restores echo and reports interrupted input`() async throws {
        let result = try await self.runTTYCredentialCommand(
            arguments: [
                "config", "credential", "set", "PEEKABOO_TTY_SIGPIPE_TEST_KEY",
                "--no-remote",
            ],
            action: .forwardAndSubmit(signalNumber: SIGPIPE, input: "unused\n"),
            launchDisposition: .ignoreSIGPIPE
        )

        #expect(result.sawPrompt)
        #expect(result.echoDisabledAtPrompt)
        #expect(result.exitedWithinDeadline)
        #expect(result.terminationStatus == .exited(1))
        #expect(result.echoEnabledAfterExit)
        #expect(result.output.contains("Unable to disable terminal echo"))
    }

    @Test
    func `job control stop restores echo and continuation reprotects the prompt`() async throws {
        for signalNumber in [SIGTSTP, SIGTTIN, SIGTTOU] {
            let fixture = "fixture-secret-stop-\(signalNumber)"
            let result = try await self.runTTYCredentialCommand(
                arguments: [
                    "config", "credential", "set", "PEEKABOO_TTY_STOP_TEST_KEY",
                    "--no-remote",
                ],
                action: .stopAndContinue(signalNumber: signalNumber, input: fixture + "\n"),
                launchDisposition: .defaultSignals
            )

            #expect(result.sawPrompt)
            #expect(result.echoDisabledAtPrompt)
            #expect(result.stoppedSignal == signalNumber)
            #expect(result.echoEnabledWhileStopped)
            #expect(result.echoDisabledAfterContinue)
            #expect(result.exitedWithinDeadline)
            #expect(result.terminationStatus == .exited(0))
            #expect(result.echoEnabledAfterExit)
            #expect(!result.output.contains(fixture))
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
}

extension ConfigCredentialInputCLITests {
    fileprivate struct TTYResult {
        let output: String
        let terminationStatus: TerminationStatus
        let sawPrompt: Bool
        let echoDisabledAtPrompt: Bool
        let stoppedSignal: Int32?
        let echoEnabledWhileStopped: Bool
        let echoDisabledAfterContinue: Bool
        let exitedWithinDeadline: Bool
        let echoEnabledAfterExit: Bool
    }

    private struct TTYInteraction: Sendable {
        let output: String
        let sawPrompt: Bool
        let echoDisabledAtPrompt: Bool
        let stoppedSignal: Int32?
        let echoEnabledWhileStopped: Bool
        let echoDisabledAfterContinue: Bool
        let exitedWithinDeadline: Bool
        let echoEnabledAfterExit: Bool
    }

    private nonisolated enum TTYAction: Sendable {
        case waitForExit
        case submit(String)
        case terminate(Int32)
        case forwardAndSubmit(signalNumber: Int32, input: String)
        case stopAndContinue(signalNumber: Int32, input: String)

        var waitsForPrompt: Bool {
            switch self {
            case .waitForExit: false
            case .submit, .terminate, .forwardAndSubmit, .stopAndContinue: true
            }
        }
    }

    private nonisolated enum TTYError: Error {
        case openFailed
    }

    private enum TTYLaunchDisposition {
        case defaultSignals
        case ignoreSIGPIPE
    }

    private enum TTYTopology {
        case controlling
        case background
        case detached
    }

    private func runTTYCredentialCommand(
        arguments: [String],
        action: TTYAction,
        launchDisposition: TTYLaunchDisposition = .defaultSignals,
        topology: TTYTopology = .controlling
    ) async throws -> TTYResult {
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
        let peekabooBinary = try TestChildProcess.peekabooBinaryURL()
        let executablePath: String
        let processArguments: [String]
        switch launchDisposition {
        case .defaultSignals:
            executablePath = peekabooBinary.path
            processArguments = arguments
        case .ignoreSIGPIPE:
            executablePath = "/bin/sh"
            processArguments = [
                "-c", "trap '' 13; exec \"$@\"",
                "peekaboo-signal-wrapper", peekabooBinary.path,
            ] + arguments
        }
        var childEnvironment = ProcessInfo.processInfo.environment.merging(
            self.environment(for: directory),
            uniquingKeysWith: { _, new in new }
        )
        childEnvironment["SWIFT_BACKTRACE"] = "enable=no"
        if topology == .detached {
            childEnvironment["PEEKABOO_TEST_DETACHED_TTY"] = "1"
        } else if topology == .background {
            childEnvironment["PEEKABOO_TEST_BACKGROUND_TTY"] = "1"
        }
        let supervisor = try self.ttyCredentialSupervisorURL()
        var environmentOverrides: [Environment.Key: String?] = [:]
        for (key, value) in childEnvironment {
            if let environmentKey = Environment.Key(rawValue: key) {
                environmentOverrides[environmentKey] = value
            }
        }
        let secondaryDescriptor = FileDescriptor(rawValue: secondaryFD)
        let execution = try await Subprocess.run(
            .path(FilePath(supervisor.path)),
            arguments: Arguments([executablePath] + processArguments),
            environment: .inherit.updating(environmentOverrides),
            input: .fileDescriptor(secondaryDescriptor, closeAfterSpawningProcess: false),
            output: .fileDescriptor(secondaryDescriptor, closeAfterSpawningProcess: false),
            error: .fileDescriptor(secondaryDescriptor, closeAfterSpawningProcess: false)
        ) { execution in
            try? secondary.close()
            return try self.interactWithTTYProcess(
                supervisorIdentifier: execution.processIdentifier.value,
                action: action,
                primaryDescriptor: primaryFD
            )
        }
        let interaction = execution.closureResult
        return TTYResult(
            output: interaction.output,
            terminationStatus: execution.terminationStatus,
            sawPrompt: interaction.sawPrompt,
            echoDisabledAtPrompt: interaction.echoDisabledAtPrompt,
            stoppedSignal: interaction.stoppedSignal,
            echoEnabledWhileStopped: interaction.echoEnabledWhileStopped,
            echoDisabledAfterContinue: interaction.echoDisabledAfterContinue,
            exitedWithinDeadline: interaction.exitedWithinDeadline,
            echoEnabledAfterExit: interaction.echoEnabledAfterExit
        )
    }

    private nonisolated func interactWithTTYProcess(
        supervisorIdentifier: pid_t,
        action: TTYAction,
        primaryDescriptor: Int32
    ) throws -> TTYInteraction {
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        watchdog.schedule(deadline: .now() + 20)
        watchdog.setEventHandler {
            let foregroundProcessGroup = tcgetpgrp(primaryDescriptor)
            if foregroundProcessGroup > 0 {
                _ = kill(-foregroundProcessGroup, SIGKILL)
            }
            _ = kill(supervisorIdentifier, SIGKILL)
        }
        watchdog.activate()
        defer { watchdog.cancel() }

        var output = Data()
        guard let processIdentifier = self.waitForReportedProcessIdentifier(
            supervisorIdentifier: supervisorIdentifier,
            fileDescriptor: primaryDescriptor,
            output: &output,
            timeout: 5
        ) else {
            _ = kill(supervisorIdentifier, SIGKILL)
            return TTYInteraction(
                output: String(data: output, encoding: .utf8) ?? "",
                sawPrompt: false,
                echoDisabledAtPrompt: false,
                stoppedSignal: nil,
                echoEnabledWhileStopped: false,
                echoDisabledAfterContinue: false,
                exitedWithinDeadline: false,
                echoEnabledAfterExit: false
            )
        }

        let promptDeadline = Date().addingTimeInterval(5)
        var sawPrompt = false
        while self.isPIDAlive(processIdentifier), Date() < promptDeadline {
            self.drainTTY(fileDescriptor: primaryDescriptor, into: &output)
            if String(data: output, encoding: .utf8)?.contains("Credential for") == true {
                sawPrompt = true
                break
            }
            if !action.waitsForPrompt {
                break
            }
            usleep(20000)
        }

        var promptTerminal = termios()
        let echoDisabledAtPrompt = sawPrompt &&
            tcgetattr(primaryDescriptor, &promptTerminal) == 0 &&
            promptTerminal.c_lflag & tcflag_t(ECHO | ECHONL) == 0

        var stoppedSignal: Int32?
        var echoEnabledWhileStopped = false
        var echoDisabledAfterContinue = false
        if self.isPIDAlive(processIdentifier) {
            switch action {
            case .waitForExit:
                break
            case let .submit(input):
                try self.writeTTY(input, fileDescriptor: primaryDescriptor)
            case let .terminate(signalNumber):
                _ = kill(processIdentifier, signalNumber)
            case let .forwardAndSubmit(signalNumber, input):
                _ = kill(processIdentifier, signalNumber)
                usleep(100_000)
                echoDisabledAfterContinue = self.isPIDAlive(processIdentifier) &&
                    self.waitForEcho(fileDescriptor: primaryDescriptor, enabled: false, timeout: 1)
                if self.isPIDAlive(processIdentifier) {
                    try self.writeTTY(input, fileDescriptor: primaryDescriptor)
                }
            case let .stopAndContinue(signalNumber, input):
                _ = kill(processIdentifier, signalNumber)
                stoppedSignal = self.waitForStopped(
                    processIdentifier: processIdentifier,
                    fileDescriptor: primaryDescriptor,
                    output: &output,
                    timeout: 2
                )
                echoEnabledWhileStopped = stoppedSignal != nil &&
                    self.waitForEcho(fileDescriptor: primaryDescriptor, enabled: true, timeout: 1)
                if stoppedSignal != nil {
                    _ = kill(processIdentifier, SIGCONT)
                    echoDisabledAfterContinue = self.waitForEcho(
                        fileDescriptor: primaryDescriptor,
                        enabled: false,
                        timeout: 1
                    )
                    try self.writeTTY(input, fileDescriptor: primaryDescriptor)
                }
            }
        }
        let exitedWithinDeadline = self.waitForTTYProcessExit(
            supervisorIdentifier,
            fileDescriptor: primaryDescriptor,
            output: &output,
            timeout: 15
        )
        if !exitedWithinDeadline {
            _ = kill(processIdentifier, SIGTERM)
            if !self.waitForTTYProcessExit(
                supervisorIdentifier,
                fileDescriptor: primaryDescriptor,
                output: &output,
                timeout: 1
            ) {
                _ = kill(supervisorIdentifier, SIGKILL)
            }
        }
        self.drainTTY(fileDescriptor: primaryDescriptor, into: &output)
        var finalTerminal = termios()
        let echoEnabledAfterExit = tcgetattr(primaryDescriptor, &finalTerminal) == 0 &&
            finalTerminal.c_lflag & tcflag_t(ECHO) != 0
        return TTYInteraction(
            output: String(data: output, encoding: .utf8) ?? "",
            sawPrompt: sawPrompt,
            echoDisabledAtPrompt: echoDisabledAtPrompt,
            stoppedSignal: stoppedSignal,
            echoEnabledWhileStopped: echoEnabledWhileStopped,
            echoDisabledAfterContinue: echoDisabledAfterContinue,
            exitedWithinDeadline: exitedWithinDeadline,
            echoEnabledAfterExit: echoEnabledAfterExit
        )
    }

    private func ttyCredentialSupervisorURL() throws -> URL {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-tty-credential-supervisor-\(getpid())")
        if FileManager.default.isExecutableFile(atPath: output.path) {
            return output
        }
        var source = URL(fileURLWithPath: #filePath)
        source.deleteLastPathComponent()
        source.deleteLastPathComponent()
        source.appendPathComponent("Support/TTYCredentialSupervisor.c")

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "clang", "-std=c17", "-Wall", "-Wextra", "-Werror", source.path, "-o", output.path,
        ]
        compiler.standardOutput = Pipe()
        compiler.standardError = Pipe()
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0,
              FileManager.default.isExecutableFile(atPath: output.path)
        else {
            throw TTYError.openFailed
        }
        return output
    }

    private nonisolated func isPIDAlive(_ processIdentifier: pid_t) -> Bool {
        if kill(processIdentifier, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private nonisolated func waitForReportedProcessIdentifier(
        supervisorIdentifier: pid_t,
        fileDescriptor: Int32,
        output: inout Data,
        timeout: TimeInterval
    ) -> pid_t? {
        let marker = "PEEKABOO_CHILD_PID="
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            self.drainTTY(fileDescriptor: fileDescriptor, into: &output)
            if let text = String(data: output, encoding: .utf8),
               let markerRange = text.range(of: marker) {
                let suffix = text[markerRange.upperBound...]
                let digits = suffix.prefix(while: { $0.isNumber })
                if let identifier = pid_t(digits) {
                    return identifier
                }
            }
            if self.waitForDirectChildExit(supervisorIdentifier, timeout: 0) {
                return nil
            }
            usleep(10000)
        }
        return nil
    }

    private nonisolated func waitForDirectChildExit(_ processIdentifier: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            var information = siginfo_t()
            if waitid(P_PID, id_t(processIdentifier), &information, WEXITED | WNOHANG | WNOWAIT) == 0,
               information.si_pid == processIdentifier {
                return true
            }
            if timeout == 0 {
                return false
            }
            usleep(10000)
        } while Date() < deadline
        return false
    }

    private nonisolated func waitForTTYProcessExit(
        _ processIdentifier: pid_t,
        fileDescriptor: Int32,
        output: inout Data,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            self.drainTTY(fileDescriptor: fileDescriptor, into: &output)
            var information = siginfo_t()
            if waitid(P_PID, id_t(processIdentifier), &information, WEXITED | WNOHANG | WNOWAIT) == 0,
               information.si_pid == processIdentifier {
                self.drainTTY(fileDescriptor: fileDescriptor, into: &output)
                return true
            }
            usleep(10000)
        } while Date() < deadline
        return false
    }

    private nonisolated func waitForStopped(
        processIdentifier: pid_t,
        fileDescriptor: Int32,
        output: inout Data,
        timeout: TimeInterval
    ) -> Int32? {
        let marker = "PEEKABOO_CHILD_STOPPED=\(processIdentifier):"
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            self.drainTTY(fileDescriptor: fileDescriptor, into: &output)
            if let text = String(data: output, encoding: .utf8),
               let markerRange = text.range(of: marker),
               let lineEnd = text[markerRange.upperBound...].firstIndex(where: \.isNewline),
               let signalNumber = Int32(text[markerRange.upperBound..<lineEnd]
                   .trimmingCharacters(in: .whitespacesAndNewlines)) {
                return signalNumber
            }
            usleep(10000)
        }
        return nil
    }

    private nonisolated func waitForEcho(fileDescriptor: Int32, enabled: Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var terminal = termios()
            if tcgetattr(fileDescriptor, &terminal) == 0 {
                let isEnabled = terminal.c_lflag & tcflag_t(ECHO) != 0
                if isEnabled == enabled {
                    return true
                }
            }
            usleep(20000)
        }
        return false
    }

    private nonisolated func writeTTY(_ value: String, fileDescriptor: Int32) throws {
        let bytes = Array(value.utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                write(fileDescriptor, buffer.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN {
                usleep(1000)
            } else {
                throw TTYError.openFailed
            }
        }
    }

    private func waitForExit(_ process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20000)
        }
        return !process.isRunning
    }

    private nonisolated func drainTTY(fileDescriptor: Int32, into output: inout Data) {
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
