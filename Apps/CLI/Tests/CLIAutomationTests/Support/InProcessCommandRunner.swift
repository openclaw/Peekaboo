import Darwin
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

actor InProcessRunGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []

    func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await self.acquire()
        defer { self.release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        guard self.isLocked else {
            self.isLocked = true
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = self.waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func release() {
        guard !self.waiters.isEmpty else {
            self.isLocked = false
            return
        }
        let waiter = self.waiters.removeFirst()
        waiter.continuation.resume()
    }
}

struct CommandRunResult {
    let stdout: String
    let stderr: String
    let exitStatus: Int32

    var combinedOutput: String {
        self.stdout.isEmpty ? self.stderr : self.stdout
    }

    func validateExitStatus(allowedExitCodes: Set<Int32>, arguments: [String]) throws {
        guard allowedExitCodes.contains(self.exitStatus) else {
            throw CommandExecutionError(
                status: self.exitStatus,
                stdout: self.stdout,
                stderr: self.stderr,
                arguments: arguments
            )
        }
    }
}

struct CommandExecutionError: Error, CustomStringConvertible {
    let status: Int32
    let stdout: String
    let stderr: String
    let arguments: [String]

    var description: String {
        "Command \(self.arguments.joined(separator: " ")) failed with exit code \(self.status)." +
            "\nstdout: \(self.stdout)\nstderr: \(self.stderr)"
    }
}

enum InProcessCommandRunner {
    private static let gate = InProcessRunGate()

    static func run(
        _ arguments: [String],
        services: PeekabooServices,
        spaceService: (any SpaceCommandSpaceService)? = nil
    ) async throws -> CommandRunResult {
        try await self.gate.run {
            try await CommandRuntime.withInjectedServices(services) {
                if let spaceService {
                    try await SpaceCommandEnvironment.withSpaceService(spaceService) {
                        try await self.execute(arguments: arguments)
                    }
                } else {
                    try await self.execute(arguments: arguments)
                }
            }
        }
    }

    /// Run the CLI using the default shared services (no overrides).
    static func runWithSharedServices(_ arguments: [String]) async throws -> CommandRunResult {
        // Use stubbed services in tests to avoid driving the real UI while still exercising
        // command wiring and JSON formatting.
        let services = TestServicesFactory.makePeekabooServices()

        return try await self.gate.run {
            try await CommandRuntime.withInjectedServices(services) {
                try await self.execute(arguments: arguments)
            }
        }
    }

    /// Convenience helper for tests that rely on the shared service stack and expect specific exit codes.
    static func runShared(
        _ arguments: [String],
        allowedExitCodes: Set<Int32> = [0]
    ) async throws -> CommandRunResult {
        let result = try await self.runWithSharedServices(arguments)
        try result.validateExitStatus(allowedExitCodes: allowedExitCodes, arguments: arguments)
        return result
    }

    static func withExclusiveProcessOutput<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await self.gate.run(operation)
    }

    private static func execute(arguments: [String]) async throws -> CommandRunResult {
        try await self.captureOutput {
            var exitStatus: Int32 = 0
            var stdoutData = Data()
            var stderrData = Data()

            let result: (Int32, Data, Data) = try await self.redirectOutput {
                await executePeekabooCLI(arguments: ["peekaboo"] + arguments)
            }

            exitStatus = result.0
            stdoutData = result.1
            stderrData = result.2

            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
            let stderr = String(data: stderrData, encoding: .utf8) ?? ""

            return CommandRunResult(stdout: stdout, stderr: stderr, exitStatus: exitStatus)
        }
    }

    private static func captureOutput(
        _ operation: () async throws -> CommandRunResult
    ) async throws -> CommandRunResult {
        try await operation()
    }

    private static func redirectOutput(
        _ body: () async throws -> Int32
    ) async throws -> (Int32, Data, Data) {
        // Prevent writes to closed pipes from crashing the test runner.
        let previousSigpipeHandler = signal(SIGPIPE, SIG_IGN)
        defer { _ = signal(SIGPIPE, previousSigpipeHandler) }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let originalStdout = dup(STDOUT_FILENO)
        let originalStderr = dup(STDERR_FILENO)

        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        do {
            let status = try await body()
            dup2(originalStdout, STDOUT_FILENO)
            dup2(originalStderr, STDERR_FILENO)
            close(originalStdout)
            close(originalStderr)

            let stdoutData = self.drainNonBlocking(stdoutPipe.fileHandleForReading)
            let stderrData = self.drainNonBlocking(stderrPipe.fileHandleForReading)
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            return (status, stdoutData, stderrData)
        } catch {
            dup2(originalStdout, STDOUT_FILENO)
            dup2(originalStderr, STDERR_FILENO)
            close(originalStdout)
            close(originalStderr)

            _ = self.drainNonBlocking(stdoutPipe.fileHandleForReading)
            _ = self.drainNonBlocking(stderrPipe.fileHandleForReading)
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            throw error
        }
    }

    private static func drainNonBlocking(_ handle: FileHandle) -> Data {
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags != -1 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var data = Data()

        while true {
            let bytesRead = read(fd, &buffer, buffer.count)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
                continue
            }
            if bytesRead == 0 {
                break // EOF
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                break // no more data right now
            }
            break // other error; bail out
        }

        return data
    }
}

enum ExternalCommandRunner {
    enum Error: Swift.Error, LocalizedError {
        case executableNotFound(String)
        case peekabooCLIPathMissing
        case jsonPayloadMissing(output: String)

        var errorDescription: String? {
            switch self {
            case let .executableNotFound(path):
                "Unable to find executable at \(path)"
            case .peekabooCLIPathMissing:
                "PEEKABOO_CLI_PATH was not set (unable to run Peekaboo CLI as an external process)."
            case let .jsonPayloadMissing(output):
                "Expected JSON payload was not found in command output:\n\(output)"
            }
        }
    }

    @discardableResult
    static func runPeekabooCLI(
        _ arguments: [String],
        allowedExitCodes: Set<Int32> = [0],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CommandRunResult {
        guard let executablePath = environment["PEEKABOO_CLI_PATH"], !executablePath.isEmpty else {
            throw Error.peekabooCLIPathMissing
        }
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw Error.executableNotFound(executablePath)
        }

        let process = Process()
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        let result = CommandRunResult(
            stdout: stdout,
            stderr: stderr,
            exitStatus: process.terminationStatus
        )
        try result.validateExitStatus(
            allowedExitCodes: allowedExitCodes,
            arguments: ["peekaboo"] + arguments
        )
        return result
    }

    static func decodeJSONResponse<T: Decodable>(
        from result: CommandRunResult,
        as type: T.Type
    ) throws -> T {
        let combinedOutput: String = if result.stdout.isEmpty {
            result.stderr
        } else if result.stderr.isEmpty {
            result.stdout
        } else {
            result.stdout + "\n" + result.stderr
        }

        guard let jsonString = Self.extractFirstJSONObject(from: combinedOutput),
              let data = jsonString.data(using: .utf8)
        else {
            throw Error.jsonPayloadMissing(output: combinedOutput)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }

    private static func extractFirstJSONObject(from output: String) -> String? {
        guard let firstBraceIndex = output.firstIndex(of: "{") else { return nil }
        var depth = 0
        var currentIndex = firstBraceIndex
        while currentIndex < output.endIndex {
            let character = output[currentIndex]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(output[firstBraceIndex...currentIndex])
                }
            }
            output.formIndex(after: &currentIndex)
        }
        return nil
    }
}
