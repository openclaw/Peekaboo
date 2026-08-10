import Darwin
import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCLI
@testable import PeekabooCore

@Suite(.serialized, .tags(.safe))
struct AgentCommandValidationIntegrationTests {
    private struct FailureCase {
        let name: String
        let arguments: [String]
        let code: PeekabooCLI.ErrorCode
        let message: String
    }

    @Test
    func `No cache session conflicts return one validation JSON object`() async throws {
        let result = try await InProcessCommandRunner.runShared(
            ["agent", "resume", "missing-session", "--no-cache", "--json", "--verbose"],
            allowedExitCodes: [1]
        )

        #expect(result.exitStatus == 1)
        let data = try #require(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8))
        let payload = try JSONDecoder().decode(JSONResponse.self, from: data)
        #expect(payload.success == false)
        #expect(payload.error?.code == ErrorCode.VALIDATION_ERROR.rawValue)
        #expect(payload.error?.message.contains("--no-cache cannot be combined") == true)
    }

    @Test(arguments: [0, 101])
    func `Invalid max steps returns one JSON error`(_ maxSteps: Int) async throws {
        let result = try await InProcessCommandRunner.runShared(
            ["agent", "test task", "--max-steps", String(maxSteps), "--json"],
            allowedExitCodes: [1]
        )

        #expect(result.exitStatus == 1)

        let data = try #require(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8))
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["success"] as? Bool == false)
        // Agent failures use the same envelope as every other command.
        let error = try #require(payload["error"] as? [String: Any])
        #expect(error["code"] as? String == "VALIDATION_ERROR")
        let message = try #require(error["message"] as? String)
        #expect(message.contains("between 1 and 100"))
        #expect(message.contains("received \(maxSteps)"))
    }

    @Test
    @MainActor
    func `Terminal agent failures use raw envelopes and nonzero exits`() async throws {
        try await self.withIsolatedAgentEnvironment { sessionDirectory in
            let services = TestServicesFactory.makePeekabooServices()
            let localModel = "ollama/llama3.3"
            let parsedLocalModel = try #require(LanguageModel.parse(from: localModel))
            let agentService = try PeekabooAgentService(
                services: services,
                defaultModel: parsedLocalModel,
                sessionManager: AgentSessionManager(sessionDirectory: sessionDirectory)
            )
            services.agent = agentService
            let cases: [FailureCase] = [
                .init(
                    name: "missing task",
                    arguments: ["agent", "run", "--model", localModel, "--json"],
                    code: .VALIDATION_ERROR,
                    message: "Task argument is required"
                ),
                .init(
                    name: "no resumable session",
                    arguments: ["agent", "resume", "--model", localModel, "--json"],
                    code: .SESSION_NOT_FOUND,
                    message: "No sessions found to resume"
                ),
                .init(
                    name: "invalid resume session",
                    arguments: ["agent", "resume", "missing-\(UUID().uuidString)", "--model", localModel, "--json"],
                    code: .SESSION_NOT_FOUND,
                    message: "Session not found or expired"
                ),
                .init(
                    name: "audio transcription failure",
                    arguments: [
                        "agent", "run", "--audio-file", "/tmp/peekaboo-missing-audio.wav",
                        "--model", localModel, "--json",
                    ],
                    code: .AGENT_ERROR,
                    message: "Audio processing failed"
                ),
                .init(
                    name: "missing provider key",
                    arguments: ["agent", "run", "task", "--model", "gemini-3.5-flash", "--json"],
                    code: .MISSING_API_KEY,
                    message: "Missing API key"
                ),
                .init(
                    name: "unknown model",
                    arguments: ["agent", "run", "task", "--model", "definitely-not-a-model", "--json"],
                    code: .VALIDATION_ERROR,
                    message: "Unsupported model"
                ),
                .init(
                    name: "invalid queue mode",
                    arguments: [
                        "agent", "run", "task", "--model", localModel,
                        "--queue-mode", "sideways", "--json",
                    ],
                    code: .VALIDATION_ERROR,
                    message: "Invalid queue mode"
                ),
            ]

            for testCase in cases {
                let result = try await InProcessCommandRunner.run(testCase.arguments, services: services)
                try self.requireFailureEnvelope(
                    result,
                    code: testCase.code,
                    messageContains: testCase.message,
                    context: testCase.name
                )
            }
        }
    }

    @Test
    func `Taskless missing resume session returns a failing error`() async throws {
        let result = try await InProcessCommandRunner.runShared(
            [
                "agent",
                "resume",
                "missing-session-\(UUID().uuidString)",
            ],
            allowedExitCodes: [1]
        )

        #expect(result.exitStatus == 1)
        #expect(result.stdout.contains("Session not found or expired"))
    }

    @Test
    @MainActor
    func `Taskless piped resume reports step exhaustion once and fails`() async throws {
        try await self.withIsolatedAgentEnvironment { sessionDirectory in
            let provider = CLIResumableStepLimitProvider()
            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            configuration.setProviderFactoryOverride { _, _ in provider }
            let previousConfiguration = TachikomaConfiguration.default
            TachikomaConfiguration.default = configuration
            defer { TachikomaConfiguration.default = previousConfiguration }

            let customProvider = try Configuration.CustomProvider(
                name: "Step Limit Test",
                type: .openai,
                options: .init(baseURL: #require(provider.baseURL), apiKey: "test-key"),
                models: [provider.resolvedModelID: .init(name: "Step Limit Test", supportsTools: true)]
            )
            try PeekabooCore.ConfigurationManager.shared.addCustomProvider(customProvider, id: provider.providerID)

            let services = TestServicesFactory.makePeekabooServices()
            let sessionManager = try AgentSessionManager(sessionDirectory: sessionDirectory)
            let model = LanguageModel.custom(provider: provider)
            let agentService = try PeekabooAgentService(
                services: services,
                defaultModel: model,
                sessionManager: sessionManager
            )
            services.agent = agentService

            let identity = agentService.persistedModelIdentity(for: model, provider: provider)
            let modelSelection = try #require(identity.selection)
            let modelEndpointIdentity = try #require(identity.endpointIdentity)
            let modelProviderIdentity = try #require(identity.providerIdentity)
            let sessionId = "step-limit-\(UUID().uuidString)"
            let now = Date()
            try sessionManager.saveSession(AgentSession(
                id: sessionId,
                modelName: identity.displayName,
                modelSelection: modelSelection,
                modelEndpointIdentity: modelEndpointIdentity,
                modelProviderIdentity: modelProviderIdentity,
                messages: [.system("Test system prompt"), .user("Start the task")],
                metadata: .init(),
                createdAt: now,
                updatedAt: now
            ))

            let result = try await self.withInteractiveOutput {
                try await InProcessCommandRunner.run(
                    ["agent", "resume", sessionId, "--max-steps", "1"],
                    services: services,
                    standardInput: "Continue the task\n"
                )
            }

            #expect(result.exitStatus == 1)
            let output = result.stdout + result.stderr
            #expect(!output.contains("> "))
            #expect(output.components(separatedBy: "Agent reached the 1-step limit").count == 2)
            #expect(output.split(separator: "\n").count(where: { $0.contains("Error:") }) == 1)
            #expect(provider.requestCount == 1)

            let savedSession = try #require(try await agentService.getSessionInfo(sessionId: sessionId))
            #expect(savedSession.metadata.customData["status"] == "max_steps_exhausted")
        }
    }

    @Test
    @MainActor
    func `Taskless piped resume propagates provider cancellation`() async throws {
        try await self.withIsolatedAgentEnvironment { sessionDirectory in
            let provider = CLICancellingProvider()
            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            configuration.setProviderFactoryOverride { _, _ in provider }
            let previousConfiguration = TachikomaConfiguration.default
            TachikomaConfiguration.default = configuration
            defer { TachikomaConfiguration.default = previousConfiguration }

            let customProvider = try Configuration.CustomProvider(
                name: "Cancellation Test",
                type: .openai,
                options: .init(baseURL: #require(provider.baseURL), apiKey: "test-key"),
                models: [provider.resolvedModelID: .init(name: "Cancellation Test", supportsTools: true)]
            )
            try PeekabooCore.ConfigurationManager.shared.addCustomProvider(customProvider, id: provider.providerID)

            let services = TestServicesFactory.makePeekabooServices()
            let sessionManager = try AgentSessionManager(sessionDirectory: sessionDirectory)
            let model = LanguageModel.custom(provider: provider)
            let agentService = try PeekabooAgentService(
                services: services,
                defaultModel: model,
                sessionManager: sessionManager
            )
            services.agent = agentService

            let identity = agentService.persistedModelIdentity(for: model, provider: provider)
            let modelSelection = try #require(identity.selection)
            let modelEndpointIdentity = try #require(identity.endpointIdentity)
            let modelProviderIdentity = try #require(identity.providerIdentity)
            let sessionId = "cancel-resume-\(UUID().uuidString)"
            let now = Date()
            try sessionManager.saveSession(AgentSession(
                id: sessionId,
                modelName: identity.displayName,
                modelSelection: modelSelection,
                modelEndpointIdentity: modelEndpointIdentity,
                modelProviderIdentity: modelProviderIdentity,
                messages: [.system("Test system prompt"), .user("Start the task")],
                metadata: .init(),
                createdAt: now,
                updatedAt: now
            ))

            let result = try await self.withInteractiveOutput {
                try await InProcessCommandRunner.run(
                    ["agent", "resume", sessionId],
                    services: services,
                    standardInput: "Continue the task\n"
                )
            }

            #expect(result.exitStatus == 1)
            #expect(provider.requestCount == 1)
            #expect(result.combinedOutput.components(separatedBy: "Agent turn was cancelled").count == 2)
            #expect(!result.combinedOutput.contains("Agent execution failed"))

            let savedSession = try #require(try await agentService.getSessionInfo(sessionId: sessionId))
            #expect(savedSession.metadata.customData["status"] == "cancelled")
        }
    }

    @Test
    @MainActor
    func `Fresh line chat treats provider cancellation as a cancelled turn`() async throws {
        try await self.withIsolatedAgentEnvironment { sessionDirectory in
            let provider = CLICancellingProvider()
            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            configuration.setProviderFactoryOverride { _, _ in provider }
            let previousConfiguration = TachikomaConfiguration.default
            TachikomaConfiguration.default = configuration
            defer { TachikomaConfiguration.default = previousConfiguration }

            let customProvider = try Configuration.CustomProvider(
                name: "Cancellation Test",
                type: .openai,
                options: .init(baseURL: #require(provider.baseURL), apiKey: "test-key"),
                models: [provider.resolvedModelID: .init(name: "Cancellation Test", supportsTools: true)]
            )
            try PeekabooCore.ConfigurationManager.shared.addCustomProvider(customProvider, id: provider.providerID)

            let services = TestServicesFactory.makePeekabooServices()
            let sessionManager = try AgentSessionManager(sessionDirectory: sessionDirectory)
            let model = LanguageModel.custom(provider: provider)
            let agentService = try PeekabooAgentService(
                services: services,
                defaultModel: model,
                sessionManager: sessionManager
            )
            services.agent = agentService

            let result = try await InProcessCommandRunner.run(
                ["agent", "chat"],
                services: services,
                standardInput: "Cancel this turn\n"
            )

            #expect(result.exitStatus == 0)
            #expect(provider.requestCount == 1)
            #expect(!result.combinedOutput.contains("Agent execution failed"))
            #expect(!result.combinedOutput.contains("Commander.ExitCode"))

            let savedSession = try #require(sessionManager.listSessions().first)
            let session = try #require(try await sessionManager.loadSession(id: savedSession.id))
            #expect(session.metadata.customData["status"] == "cancelled")
        }
    }

    @Test
    @MainActor
    func `Fresh line chat reports provider failure without opaque exit error`() async throws {
        try await self.withIsolatedAgentEnvironment { sessionDirectory in
            let provider = CLICancellingProvider(mode: .providerFailure)
            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            configuration.setProviderFactoryOverride { _, _ in provider }
            let previousConfiguration = TachikomaConfiguration.default
            TachikomaConfiguration.default = configuration
            defer { TachikomaConfiguration.default = previousConfiguration }

            let customProvider = try Configuration.CustomProvider(
                name: "Failure Test",
                type: .openai,
                options: .init(baseURL: #require(provider.baseURL), apiKey: "test-key"),
                models: [provider.resolvedModelID: .init(name: "Failure Test", supportsTools: true)]
            )
            try PeekabooCore.ConfigurationManager.shared.addCustomProvider(customProvider, id: provider.providerID)

            let services = TestServicesFactory.makePeekabooServices()
            let agentService = try PeekabooAgentService(
                services: services,
                defaultModel: .custom(provider: provider),
                sessionManager: AgentSessionManager(sessionDirectory: sessionDirectory)
            )
            services.agent = agentService

            let result = try await InProcessCommandRunner.run(
                ["agent", "chat"],
                services: services,
                standardInput: "Fail this turn\n"
            )

            #expect(result.exitStatus == 0)
            #expect(provider.requestCount == 1)
            #expect(
                result.combinedOutput.components(
                    separatedBy: CLICancellingProvider.providerFailureMessage
                ).count == 2
            )
            #expect(!result.combinedOutput.contains("Commander.ExitCode"))
            #expect(!result.combinedOutput.contains("Agent execution failed"))
        }
    }

    @Test
    @MainActor
    func `Fresh line chat initial prompt reports provider failure without opaque exit error`() async throws {
        try await self.withIsolatedAgentEnvironment { sessionDirectory in
            let provider = CLICancellingProvider(mode: .providerFailure)
            let configuration = TachikomaConfiguration(loadFromEnvironment: false)
            configuration.setProviderFactoryOverride { _, _ in provider }
            let previousConfiguration = TachikomaConfiguration.default
            TachikomaConfiguration.default = configuration
            defer { TachikomaConfiguration.default = previousConfiguration }

            let customProvider = try Configuration.CustomProvider(
                name: "Failure Test",
                type: .openai,
                options: .init(baseURL: #require(provider.baseURL), apiKey: "test-key"),
                models: [provider.resolvedModelID: .init(name: "Failure Test", supportsTools: true)]
            )
            try PeekabooCore.ConfigurationManager.shared.addCustomProvider(customProvider, id: provider.providerID)

            let services = TestServicesFactory.makePeekabooServices()
            let agentService = try PeekabooAgentService(
                services: services,
                defaultModel: .custom(provider: provider),
                sessionManager: AgentSessionManager(sessionDirectory: sessionDirectory)
            )
            services.agent = agentService

            let result = try await InProcessCommandRunner.run(
                ["agent", "chat", "Fail this turn"],
                services: services,
                standardInput: ""
            )

            #expect(result.exitStatus == 0)
            #expect(provider.requestCount == 1)
            #expect(
                result.combinedOutput.components(
                    separatedBy: CLICancellingProvider.providerFailureMessage
                ).count == 2
            )
            #expect(!result.combinedOutput.contains("Commander.ExitCode"))
            #expect(!result.combinedOutput.contains("Agent execution failed"))
        }
    }

    @Test
    @MainActor
    func `Fresh task execution preserves CancellationError`() async throws {
        try await self.withIsolatedAgentEnvironment { sessionDirectory in
            let provider = CLICancellingProvider()
            let services = TestServicesFactory.makePeekabooServices()
            let agentService = try PeekabooAgentService(
                services: services,
                defaultModel: .custom(provider: provider),
                sessionManager: AgentSessionManager(sessionDirectory: sessionDirectory)
            )
            let command = try AgentCommand.parse(["--quiet"])

            await #expect(throws: CancellationError.self) {
                _ = try await command.executeAgentTask(
                    agentService,
                    task: "Cancel this task",
                    requestedModel: nil,
                    maxSteps: 1,
                    queueMode: .oneAtATime
                )
            }
        }
    }

    @Test
    @MainActor
    func `Chat model labels omit compatible endpoint credentials`() async throws {
        try await self.withIsolatedAgentEnvironment { sessionDirectory in
            let model = LanguageModel.openaiCompatible(
                modelId: "safe-model",
                baseURL: "https://username:password@example.test/v1?token=query-secret"
            )
            let services = TestServicesFactory.makePeekabooServices()
            let agentService = try PeekabooAgentService(
                services: services,
                defaultModel: model,
                sessionManager: AgentSessionManager(sessionDirectory: sessionDirectory)
            )
            let command = try AgentCommand.parse([])

            let defaultLabel = await command.describeChatModel(
                nil,
                sessionId: nil,
                agentService: agentService
            )
            let requestedLabel = await command.describeChatModel(
                model,
                sessionId: nil,
                agentService: agentService
            )

            #expect(defaultLabel == "OpenAI-Compatible/safe-model")
            #expect(requestedLabel == defaultLabel)
            #expect(!defaultLabel.contains("password"))
            #expect(!defaultLabel.contains("query-secret"))
        }
    }

    @MainActor
    private func withIsolatedAgentEnvironment(
        _ body: (URL) async throws -> Void
    ) async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-cli-\(UUID().uuidString)", isDirectory: true)
        let sessionDirectory = tempDirectory.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let environmentKeys = [
            "PEEKABOO_CONFIG_DIR",
            "PEEKABOO_CONFIG_NONINTERACTIVE",
            "PEEKABOO_CONFIG_DISABLE_MIGRATION",
            "GEMINI_API_KEY",
        ]
        let previous = Dictionary(uniqueKeysWithValues: environmentKeys.map { key in
            (key, getenv(key).map { String(cString: $0) })
        })

        setenv("PEEKABOO_CONFIG_DIR", tempDirectory.path, 1)
        setenv("PEEKABOO_CONFIG_NONINTERACTIVE", "1", 1)
        setenv("PEEKABOO_CONFIG_DISABLE_MIGRATION", "1", 1)
        unsetenv("GEMINI_API_KEY")
        ConfigurationManager.shared.resetForTesting()

        defer {
            for key in environmentKeys {
                if case let value?? = previous[key] {
                    setenv(key, value, 1)
                } else {
                    unsetenv(key)
                }
            }
            ConfigurationManager.shared.resetForTesting()
            try? FileManager.default.removeItem(at: tempDirectory)
        }

        try await body(sessionDirectory)
    }

    @MainActor
    private func withInteractiveOutput<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        var controllerFileDescriptor: Int32 = -1
        var terminalFileDescriptor: Int32 = -1
        guard openpty(&controllerFileDescriptor, &terminalFileDescriptor, nil, nil, nil) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(controllerFileDescriptor)
            close(terminalFileDescriptor)
        }

        return try await TerminalDetector.$standardOutputFileDescriptor.withValue(terminalFileDescriptor) {
            try await body()
        }
    }

    private func requireFailureEnvelope(
        _ result: CommandRunResult,
        code: PeekabooCLI.ErrorCode,
        messageContains: String,
        context: String = #function
    ) throws {
        #expect(result.exitStatus == 1, "Wrong exit status for \(context)")
        #expect(result.stderr.isEmpty, "JSON error leaked to stderr for \(context)")

        let data = Data(result.stdout.utf8)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["success"] as? Bool == false, "Missing failure status for \(context)")
        #expect(payload["data"] is NSNull, "Failure data was not null for \(context)")
        #expect(payload["effect"] == nil, "Agent failure unexpectedly gained an action effect for \(context)")

        let error = try #require(payload["error"] as? [String: Any])
        #expect(error["code"] as? String == code.rawValue, "Wrong error code for \(context)")
        let message = try #require(error["message"] as? String)
        #expect(message.contains(messageContains), "Wrong error message for \(context): \(message)")
    }
}

private final class CLIResumableStepLimitProvider: PeekabooCustomProviderIdentityProviding, @unchecked Sendable {
    let providerID = "step-limit-test"
    let resolvedModelID = "perpetual-tool"
    let providerTypeIdentity = "openai"
    let modelId = "step-limit-test/perpetual-tool"
    let baseURL: String? = "http://127.0.0.1:9/v1"
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        self.lock.withLock { self.requests }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        let toolCall = self.nextToolCall()
        return ProviderResponse(text: "Continue", finishReason: .toolCalls, toolCalls: [toolCall])
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let toolCall = self.nextToolCall()
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Continue"))
            continuation.yield(.tool(toolCall))
            continuation.yield(.done(finishReason: .toolCalls))
            continuation.finish()
        }
    }

    private func nextToolCall() -> Tachikoma.AgentToolCall {
        let requestNumber = self.lock.withLock {
            self.requests += 1
            return self.requests
        }
        return Tachikoma.AgentToolCall(
            id: "sleep-\(requestNumber)",
            name: "sleep",
            arguments: ["duration": AnyAgentToolValue(double: 1)]
        )
    }
}

private final class CLICancellingProvider: PeekabooCustomProviderIdentityProviding, @unchecked Sendable {
    enum Mode {
        case cancellation
        case providerFailure
    }

    static let providerFailureMessage = "Synthetic provider failure"

    let providerID = "cancellation-test"
    let resolvedModelID = "cancel"
    let providerTypeIdentity = "openai"
    let modelId = "cancellation-test/cancel"
    let baseURL: String? = "http://127.0.0.1:9/v1"
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private let mode: Mode
    private var requests = 0

    init(mode: Mode = .cancellation) {
        self.mode = mode
    }

    var requestCount: Int {
        self.lock.withLock { self.requests }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        self.recordRequest()
        throw self.failure()
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        self.recordRequest()
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: self.failure())
        }
    }

    private func recordRequest() {
        self.lock.withLock {
            self.requests += 1
        }
    }

    private func failure() -> any Error {
        switch self.mode {
        case .cancellation:
            CancellationError()
        case .providerFailure:
            ProviderFailure()
        }
    }

    private struct ProviderFailure: LocalizedError {
        var errorDescription: String? {
            CLICancellingProvider.providerFailureMessage
        }
    }
}
