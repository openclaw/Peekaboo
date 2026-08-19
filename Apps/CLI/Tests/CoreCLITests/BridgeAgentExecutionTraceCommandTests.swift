import Commander
import Darwin
import Foundation
import PeekabooBridge
import Testing
@testable import PeekabooCLI

@Suite("Bridge Agent execution trace command", .serialized)
struct BridgeAgentExecutionTraceCommandTests {
    @Test
    @MainActor
    func `Hidden command is routable but absent from help and completions`() throws {
        let descriptors = CommanderRegistryBuilder.buildDescriptors()
        let bridge = try #require(descriptors.first(where: { $0.metadata.name == "bridge" }))
        #expect(bridge.subcommands.contains(where: { $0.metadata.name == "_agent-execution-trace" }))

        let bridgeSummary = try #require(
            CommanderRegistryBuilder.buildCommandSummaries().first(where: { $0.name == "bridge" })
        )
        #expect(!bridgeSummary.subcommands.contains(where: { $0.name == "_agent-execution-trace" }))

        let document = CompletionScriptDocument.make(descriptors: descriptors)
        let bridgeCompletion = try #require(document.commands.first(where: { $0.name == "bridge" }))
        #expect(!bridgeCompletion.subcommands.contains(where: { $0.name == "_agent-execution-trace" }))
        #expect(!document.flattenedPaths.contains(where: {
            $0.path.contains("_agent-execution-trace")
        }))
    }

    @Test
    @MainActor
    func `Parser binds required inputs repeatable trust and defaults`() throws {
        let command = try BridgeCommand.AgentExecutionTraceSubcommand.parse([
            "--task", "Inspect Safari without foreground activation",
            "--run-root", "/private/tmp/peekaboo-run",
            "--bridge-socket", "/private/tmp/peekaboo.sock",
            "--trusted-host-team-id", "FIRSTTEAM",
            "--trusted-host-team-id", "SECONDTEAM",
        ])

        #expect(command.task == "Inspect Safari without foreground activation")
        #expect(command.runRoot == "/private/tmp/peekaboo-run")
        #expect(command.bridgeSocket == "/private/tmp/peekaboo.sock")
        #expect(command.trustedHostTeamIDs == ["FIRSTTEAM", "SECONDTEAM"])
        #expect(command.maxSteps == 40)
        #expect(command.startTimeoutSeconds == 30)
        #expect(command.runTimeoutSeconds == 900)
    }

    @Test
    @MainActor
    func `Request derives exact direct sibling paths and millisecond bounds`() throws {
        let runRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: runRoot) }
        var command = BridgeCommand.AgentExecutionTraceSubcommand()
        command.task = "Inspect Safari without foreground activation"
        command.runRoot = runRoot.path
        command.maxSteps = 40
        command.startTimeoutSeconds = 0.001
        command.runTimeoutSeconds = 7200

        let request = try command.validatedRequest()

        #expect(request.runRootPath == runRoot.path)
        #expect(request.coordinationReceiptPath == runRoot.appendingPathComponent(
            "agent-execution-coordination.json"
        ).path)
        #expect(request.acknowledgementPath == runRoot.appendingPathComponent(
            "agent-execution-ack.json"
        ).path)
        #expect(request.startTimeoutMilliseconds == 1)
        #expect(request.runTimeoutMilliseconds == 7_200_000)
        #expect(!FileManager.default.fileExists(atPath: request.coordinationReceiptPath))
        #expect(!FileManager.default.fileExists(atPath: request.acknowledgementPath))
    }

    @Test
    @MainActor
    func `Invalid inputs fail during request preflight`() throws {
        let runRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: runRoot) }
        var command = BridgeCommand.AgentExecutionTraceSubcommand()
        command.task = "task"
        command.runRoot = runRoot.path

        command.maxSteps = 0
        #expect(throws: ValidationError.self) { try command.validatedRequest() }

        command.maxSteps = 40
        command.startTimeoutSeconds = .infinity
        #expect(throws: ValidationError.self) { try command.validatedRequest() }

        command.startTimeoutSeconds = 30
        command.runRoot = "relative/run-root"
        #expect(throws: ValidationError.self) { try command.validatedRequest() }
    }

    @Test
    @MainActor
    func `Task byte ceiling is the canonical Bridge policy boundary`() throws {
        let runRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: runRoot) }
        var command = BridgeCommand.AgentExecutionTraceSubcommand()
        command.runRoot = runRoot.path
        command.task = String(
            repeating: "x",
            count: PeekabooBridgeAgentExecutionPolicy.maximumTaskBytes
        )

        #expect(try command.validatedRequest().task.utf8.count ==
            PeekabooBridgeAgentExecutionPolicy.maximumTaskBytes)
        command.task.append("x")
        #expect(throws: ValidationError.self) { try command.validatedRequest() }

        command.task = String(
            repeating: "é",
            count: PeekabooBridgeAgentExecutionPolicy.maximumTaskBytes / 2
        )
        #expect(try command.validatedRequest().task.utf8.count ==
            PeekabooBridgeAgentExecutionPolicy.maximumTaskBytes)
        command.task.append("é")
        #expect(throws: ValidationError.self) { try command.validatedRequest() }
    }

    @Test
    func `Anonymous release gate accepts only one exact challenge and EOF`() throws {
        let challenge = String(repeating: "a", count: 64)
        let success = try Self.gatePipe(bytes: Data(challenge.utf8))
        try AgentExecutionReleaseGate.wait(descriptor: success.read, challenge: challenge)

        let short = try Self.gatePipe(bytes: Data(challenge.dropLast().utf8))
        #expect(throws: (any Error).self) {
            try AgentExecutionReleaseGate.wait(descriptor: short.read, challenge: challenge)
        }

        let wrong = try Self.gatePipe(bytes: Data(String(repeating: "b", count: 64).utf8))
        #expect(throws: (any Error).self) {
            try AgentExecutionReleaseGate.wait(descriptor: wrong.read, challenge: challenge)
        }

        let trailing = try Self.gatePipe(bytes: Data((challenge + "x").utf8))
        #expect(throws: (any Error).self) {
            try AgentExecutionReleaseGate.wait(descriptor: trailing.read, challenge: challenge)
        }
    }

    @Test
    func `Invalid configured release gate consumes its private environment`() throws {
        let challenge = String(repeating: "c", count: 64)
        let gate = try Self.gatePipe(bytes: Data(challenge.utf8))
        setenv(AgentExecutionReleaseGate.descriptorEnvironmentKey, String(gate.read), 1)
        setenv(AgentExecutionReleaseGate.challengeEnvironmentKey, challenge, 1)
        setenv(AgentExecutionReleaseGate.lockdownDescriptorEnvironmentKey, String(gate.write), 1)
        setenv(AgentExecutionReleaseGate.processCreationLimitEnvironmentKey, "1", 1)
        defer {
            unsetenv(AgentExecutionReleaseGate.descriptorEnvironmentKey)
            unsetenv(AgentExecutionReleaseGate.challengeEnvironmentKey)
            unsetenv(AgentExecutionReleaseGate.lockdownDescriptorEnvironmentKey)
            unsetenv(AgentExecutionReleaseGate.processCreationLimitEnvironmentKey)
        }

        #expect(throws: (any Error).self) {
            try AgentExecutionReleaseGate.waitIfConfigured()
        }

        #expect(getenv(AgentExecutionReleaseGate.descriptorEnvironmentKey) == nil)
        #expect(getenv(AgentExecutionReleaseGate.challengeEnvironmentKey) == nil)
        #expect(getenv(AgentExecutionReleaseGate.lockdownDescriptorEnvironmentKey) == nil)
        #expect(getenv(AgentExecutionReleaseGate.processCreationLimitEnvironmentKey) == nil)

        setenv(AgentExecutionReleaseGate.challengeEnvironmentKey, challenge, 1)
        #expect(throws: (any Error).self) {
            try AgentExecutionReleaseGate.waitIfConfigured()
        }
        #expect(getenv(AgentExecutionReleaseGate.descriptorEnvironmentKey) == nil)
        #expect(getenv(AgentExecutionReleaseGate.challengeEnvironmentKey) == nil)
    }

    private static func makePrivateRunRoot() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private static func gatePipe(bytes: Data) throws -> (read: Int32, write: Int32) {
        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptors[1], buffer.baseAddress, buffer.count)
        }
        close(descriptors[1])
        guard written == bytes.count else {
            close(descriptors[0])
            throw POSIXError(.EIO)
        }
        return (descriptors[0], descriptors[1])
    }
}
