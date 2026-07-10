import Foundation
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif

enum TestChildProcess {
    struct Result: Sendable {
        let standardOutput: String
        let standardError: String
        let status: TerminationStatus
    }

    static func runPeekaboo(
        _ arguments: [String],
        environment extraEnvironment: [String: String] = [:],
        executablePathOverride: String? = nil,
        workingDirectory: URL? = nil,
        timeout: Duration? = nil
    ) async throws -> Result {
        if let timeout {
            return try await withThrowingTaskGroup(of: Result.self) { group in
                group.addTask {
                    try await Self.runPeekabooProcess(
                        arguments,
                        environment: extraEnvironment,
                        executablePathOverride: executablePathOverride,
                        workingDirectory: workingDirectory,
                        isolateProcessGroup: true
                    )
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    throw RuntimeError("Peekaboo child process timed out")
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw RuntimeError("Peekaboo child process produced no result")
                }
                return result
            }
        }

        return try await Self.runPeekabooProcess(
            arguments,
            environment: extraEnvironment,
            executablePathOverride: executablePathOverride,
            workingDirectory: workingDirectory,
            isolateProcessGroup: false
        )
    }

    private static func runPeekabooProcess(
        _ arguments: [String],
        environment extraEnvironment: [String: String],
        executablePathOverride: String?,
        workingDirectory: URL?,
        isolateProcessGroup: Bool
    ) async throws -> Result {
        let binaryURL = try Self.peekabooBinaryURL()
        var environmentOverrides: [Environment.Key: String?] = [:]

        // Keep CLI runtime smoke tests deterministic: avoid opportunistically switching to
        // a remote GUI runtime when a bridge socket happens to exist on the machine.
        if extraEnvironment["PEEKABOO_NO_REMOTE"] == nil,
           let envKey = Environment.Key(rawValue: "PEEKABOO_NO_REMOTE") {
            environmentOverrides[envKey] = "1"
        }

        for (key, value) in extraEnvironment {
            if let envKey = Environment.Key(rawValue: key) {
                environmentOverrides[envKey] = value
            }
        }
        let environment = Environment.inherit.updating(environmentOverrides)
        var platformOptions = PlatformOptions()
        if isolateProcessGroup {
            platformOptions.createSession = true
            platformOptions.teardownSequence = [
                .send(
                    signal: .terminate,
                    toProcessGroup: true,
                    allowedDurationToNextStep: .milliseconds(250)
                ),
            ]
        }
        let collected = try await Subprocess.run(
            .path(FilePath(binaryURL.path)),
            arguments: Arguments(
                executablePathOverride: executablePathOverride,
                remainingValues: arguments
            ),
            environment: environment,
            workingDirectory: workingDirectory.map { FilePath($0.path) },
            platformOptions: platformOptions,
            output: .string(limit: .max),
            error: .string(limit: .max)
        )
        return Result(
            standardOutput: collected.standardOutput ?? "",
            standardError: collected.standardError ?? "",
            status: collected.terminationStatus
        )
    }

    private static func peekabooBinaryURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PEEKABOO_CLI_BINARY"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        let packageRoot = Self.packageRootURL()
        let potentialPaths = [
            packageRoot.appendingPathComponent(Self.currentArchitectureBuildPath),
            packageRoot.appendingPathComponent(".build/debug/peekaboo"),
            packageRoot.appendingPathComponent(Self.fallbackArchitectureBuildPath)
        ]

        if let match = potentialPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return match
        }

        throw RuntimeError(
            "Unable to locate peekaboo binary. Checked: \n\(potentialPaths.map(\.path).joined(separator: "\n"))"
        )
    }

    static func canLocatePeekabooBinary() -> Bool {
        (try? self.peekabooBinaryURL()) != nil
    }

    private static func packageRootURL() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../Apps/CLI/Tests/CLIRuntimeTests/Support/TestChildProcess.swift
        for _ in 0..<4 {
            url.deleteLastPathComponent()
        }
        return url
    }

    private static var currentArchitectureBuildPath: String {
        #if arch(arm64)
        ".build/arm64-apple-macosx/debug/peekaboo"
        #elseif arch(x86_64)
        ".build/x86_64-apple-macosx/debug/peekaboo"
        #else
        ".build/debug/peekaboo"
        #endif
    }

    private static var fallbackArchitectureBuildPath: String {
        #if arch(arm64)
        ".build/x86_64-apple-macosx/debug/peekaboo"
        #else
        ".build/arm64-apple-macosx/debug/peekaboo"
        #endif
    }
}

struct RuntimeError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) {
        self.message = message
    }

    var description: String {
        self.message
    }
}
