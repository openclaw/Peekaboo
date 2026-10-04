import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct AgentObservationProviderContextTests {
    @Test(arguments: [false, true], ["see", "inspect_ui"])
    func `Observation projection belongs only to provider requests`(streaming: Bool, toolName: String) async throws {
        let fixture = try ObservationContextFixture(toolName: toolName)
        let provider = ObservationContextProvider(toolName: toolName)
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }
        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }
        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("observation-context-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let sessionManager = try AgentSessionManager(sessionDirectory: sessionDirectory)
        let model = LanguageModel.custom(provider: provider)
        let service = try PeekabooAgentService(
            services: PeekabooServices(), defaultModel: model, sessionManager: sessionManager)
        let initialMessages = fixture.initialMessages()
        let originalHistory = try Self.encoded(initialMessages)
        let originalResponse = try Self.encodedResponse(fixture.response)
        let originalPayload = try Self.encoded(fixture.value)
        let originalCLI = try Self.cliPayload(service, value: fixture.value, toolName: toolName)
        let executions = AutomationTestLockedValue(0)
        let events = AutomationTestLockedValue<[AgentEvent]>([])
        let tool = AgentTool(
            name: toolName,
            description: "Synthetic observation; never calls native services",
            parameters: .init(properties: [:], required: []),
            execute: { _ in
                executions.withValue { $0 += 1 }
                return fixture.value
            })
        let loopConfiguration = PeekabooAgentService.StreamingLoopConfiguration(
            model: model,
            provider: provider,
            tools: [tool],
            sessionId: "observation-provider-context",
            eventHandler: EventHandler { event in events.withValue { $0.append(event) } },
            enhancementOptions: nil,
            executionAuthority: .init(basePolicy: .unrestricted))
        var checkpoints: [PeekabooAgentService.StreamingLoopOutcome] = []
        let outcome: PeekabooAgentService.StreamingLoopOutcome = if streaming {
            try await service.runStreamingLoop(
                configuration: loopConfiguration,
                maxSteps: 2,
                initialMessages: initialMessages,
                onCheckpoint: { checkpoints.append($0) })
        } else {
            try await service.runGenerationLoop(
                configuration: loopConfiguration,
                maxSteps: 2,
                initialMessages: initialMessages,
                onCheckpoint: { checkpoints.append($0) })
        }

        #expect(executions.value == 1)
        #expect(outcome.toolCallCount == 1)
        #expect(outcome.content.contains("Finished."))
        #expect(!outcome.reachedStepLimit)
        #expect(outcome.usage == Usage(inputTokens: 24, outputTokens: 12))
        #expect(provider.requests.value.count == 2)
        #expect(provider.methods.value == Array(repeating: streaming ? "stream" : "generate", count: 2))
        #expect(try Self.encoded(initialMessages) == originalHistory)
        #expect(Array(outcome.messages.prefix(initialMessages.count)) == initialMessages)
        #expect(try Self.encodedResponse(fixture.response) == originalResponse)
        #expect(try Self.encoded(fixture.value) == originalPayload)
        #expect(AgentToolMCPBridge.convert(fixture.response).value == fixture.value)

        for (index, request) in provider.requests.value.enumerated() {
            let originalMessages = Array(outcome.messages.prefix(request.messages.count))
            try self.expectProviderCopy(request.messages, original: originalMessages, fixture: fixture)
            #expect(Self.toolResults(request.messages).count == index + 1)
            #expect(request.tools?.map(\.name) == [toolName])
            #expect(request.settings.stopConditions == nil)
        }
        let storedResults = Self.toolResults(outcome.messages)
        #expect(storedResults.count == 2)
        #expect(storedResults.allSatisfy { $0.result == fixture.value && !$0.isError && $0.failure == nil })
        #expect(outcome.steps.flatMap(\.toolResults) == [
            AgentToolResult.success(toolCallId: provider.call.id, result: fixture.value),
        ])
        #expect(!checkpoints.isEmpty)
        for checkpoint in checkpoints {
            #expect(Array(checkpoint.messages.prefix(initialMessages.count)) == initialMessages)
            #expect(Self.toolResults(checkpoint.messages).allSatisfy { $0.result == fixture.value })
            #expect(checkpoint.steps.flatMap(\.toolResults).allSatisfy { $0.result == fixture.value })
        }

        let completionPayloads = events.value.compactMap { event -> String? in
            guard case let .toolCallCompleted(name, payload) = event, name == toolName else { return nil }
            return payload
        }
        #expect(completionPayloads.count == 1)
        let completion = try JSONDecoder().decode(AnyAgentToolValue.self, from: Data(
            #require(completionPayloads.first).utf8))
        #expect(completion == originalCLI)
        #expect(completion.objectValue?["result"]?.stringValue == fixture.text)
        #expect(completion.objectValue?["summary_text"]?.stringValue == "Captured Synthetic App · Fixture Window")
        #expect(try Self.cliPayload(service, value: fixture.value, toolName: toolName) == originalCLI)

        let retainedHistory = try Self.encoded(outcome.messages)
        let trace = AgentExecutionTrace(messages: outcome.messages)
        _ = AgentToolMCPBridge.providerContextMessages(outcome.messages)
        #expect(try Self.encoded(outcome.messages) == retainedHistory)
        #expect(AgentExecutionTrace(messages: outcome.messages) == trace)
        try await self.expectPersistence(
            service: service, directory: sessionDirectory, model: model, outcome: outcome)
    }

    private func expectProviderCopy(
        _ projected: [ModelMessage],
        original: [ModelMessage],
        fixture: ObservationContextFixture) throws
    {
        #expect(projected.count == original.count)
        #expect(try Self.encoded(projected).count < Self.encoded(original).count)
        for (providerMessage, storedMessage) in zip(projected, original) {
            guard case let .toolResult(providerResult)? = providerMessage.content.first else {
                #expect(providerMessage == storedMessage)
                continue
            }
            let storedResult = try #require(Self.toolResults([storedMessage]).first)
            #expect(providerMessage.id == storedMessage.id)
            #expect(providerMessage.role == storedMessage.role)
            #expect(providerMessage.timestamp == storedMessage.timestamp)
            #expect(providerMessage.channel == storedMessage.channel)
            #expect(providerMessage.metadata == storedMessage.metadata)
            #expect(providerResult.toolCallId == storedResult.toolCallId)
            #expect(providerResult.isError == storedResult.isError)
            #expect(providerResult.failure == storedResult.failure)
            var projectedPayload = try #require(providerResult.result.objectValue)
            let storedPayload = try #require(storedResult.result.objectValue)
            let projectedText = try #require(projectedPayload["result"]?.stringValue)
            #expect(projectedText.hasPrefix(fixture.header))
            #expect(projectedText.hasSuffix(fixture.footer))
            #expect(projectedText.contains("meta.ui_elements"))
            #expect(!projectedText.contains(fixture.row.id))
            #expect(!projectedText.contains("(1 found, 1 actionable):"))
            #expect(projectedPayload["meta"] == storedPayload["meta"])
            #expect(projectedPayload["meta"]?.objectValue?["ui_elements"]?.arrayValue?.count == 1)
            projectedPayload["result"] = storedPayload["result"]
            #expect(AnyAgentToolValue(object: projectedPayload) == storedResult.result)
        }
    }

    private func expectPersistence(
        service: PeekabooAgentService,
        directory: URL,
        model: LanguageModel,
        outcome: PeekabooAgentService.StreamingLoopOutcome) async throws
    {
        let history = try Self.encoded(outcome.messages)
        let trace = AgentExecutionTrace(messages: outcome.messages)
        let now = Date()
        let context = PeekabooAgentService.SessionContext(
            id: "observation-provider-context",
            isPersistent: true,
            messages: [],
            createdAt: now,
            executionStart: now,
            metadata: SessionMetadata(),
            modelIdentity: PeekabooAgentService.PersistedModelIdentity(
                displayName: "synthetic-observation-provider",
                selection: nil,
                endpointIdentity: nil,
                providerIdentity: nil),
            storedToolExecutionAuthority: .backgroundOnly,
            toolExecutionAuthority: .backgroundOnly,
            provider: nil,
            executionGeneration: nil)
        try service.saveExecutionSession(
            context: context,
            model: model,
            finalMessages: outcome.messages,
            endTime: now,
            toolCallCount: outcome.toolCallCount,
            usage: outcome.usage,
            status: "completed")
        let reloadedManager = try AgentSessionManager(sessionDirectory: directory)
        let saved = try #require(try await reloadedManager.loadSession(id: context.id))
        #expect(try Self.encoded(saved.messages) == history)
        #expect(saved.messages == outcome.messages)
        #expect(AgentExecutionTrace(messages: saved.messages) == trace)
    }

    private static func toolResults(_ messages: [ModelMessage]) -> [AgentToolResult] {
        messages.flatMap { message in
            message.content.compactMap { part in
                guard case let .toolResult(result) = part else { return nil }
                return result
            }
        }
    }

    private static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func encodedResponse(_ response: ToolResponse) throws -> Data {
        struct Response: Encodable {
            let content: [MCP.Tool.Content]
            let isError: Bool
            let meta: Value?
            let structuredContent: Value?
        }
        return try self.encoded(Response(
            content: response.content,
            isError: response.isError,
            meta: response.meta,
            structuredContent: response.structuredContent))
    }

    private static func cliPayload(
        _ service: PeekabooAgentService,
        value: AnyAgentToolValue,
        toolName: String) throws -> AnyAgentToolValue
    {
        try JSONDecoder().decode(
            AnyAgentToolValue.self,
            from: Data(service.toolResultPayload(from: value, toolName: toolName).utf8))
    }
}

private struct ObservationContextFixture: Sendable {
    let toolName: String
    let row: UIElementSummary
    let header: String
    let footer: String
    let text: String
    let response: ToolResponse
    let value: AnyAgentToolValue

    init(toolName: String) throws {
        self.toolName = toolName
        let frame = CGRect(x: 12.5, y: -24.25, width: 180.5, height: 22.75)
        self.row = UIElementSummary(
            id: "synthetic-element",
            role: "textField",
            ax_role: "AXTextField",
            title: "Résumé 🦞",
            label: "Synthetic label",
            value: "Line one\nLine two",
            description: "Synthetic description",
            role_description: "Text field",
            help: "Synthetic help",
            identifier: "fixture.identifier",
            confidence: 0.95,
            bounds: UIElementBounds(frame),
            is_actionable: true,
            is_enabled: true,
            is_selected: true,
            is_value_settable: true,
            keyboard_shortcut: "⌘K",
            selected_text_range: TextSelectionRange(location: 2, length: 4))
        let section: [String]
        if toolName == "see" {
            section = SeeElementTextFormatter.section([UIElement(
                id: self.row.id,
                elementId: self.row.id,
                role: "AXTextField",
                title: self.row.title,
                label: self.row.label,
                value: self.row.value,
                description: self.row.description,
                help: self.row.help,
                roleDescription: self.row.role_description,
                identifier: self.row.identifier,
                confidence: self.row.confidence,
                frame: frame,
                isActionable: true,
                isEnabled: true,
                isSelected: true,
                isValueSettable: true,
                keyboardShortcut: self.row.keyboard_shortcut)])
            self.footer = SeeElementTextFormatter.interactionHint
        } else {
            section = InspectUIElementTextFormatter.section([self.row])
            self.footer = InspectUIElementTextFormatter.interactionHint
        }
        self.header = """
        Synthetic observation
        Snapshot ID: fixture-snapshot
        Application: Synthetic App
        Window: Fixture Window
        Elements found: 1
        Text selection: UTF-16 location 2, length 4
        Warning: preserve this nonduplicate diagnostic exactly.
        """
        self.text = self.header + "\n\n" + section.joined(separator: "\n") + "\n\n" + self.footer
        let metadata = try MCPToolResponseMetadataProjector.metadata(
            merging: [
                "ui_elements": Value([self.row]),
                "element_count": .int(1),
                "truncated": .bool(false),
                "snapshot_id": .string("fixture-snapshot"),
                "observed_at": .string("2026-01-02T03:04:05Z"),
                "fresh": .bool(true),
                "coordinate_space": .string("window"),
                "target_identity": .object(["pid": .int(42), "window_id": .int(7)]),
                "verification_receipt": .object(["fixture": .string("synthetic verification evidence")]),
                "extra_native_evidence": .array([.string("untouched"), .bool(false)]),
            ],
            outcome: .confirmedNoChange())
        self.response = ToolResponse(
            content: [.text(text: self.text, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(
                summary: ToolEventSummary(captureApp: "Synthetic App", captureWindow: "Fixture Window"),
                into: metadata))
        self.value = AgentToolMCPBridge.convert(self.response).value
    }

    func initialMessages() -> [ModelMessage] {
        let timestamp = Date(timeIntervalSince1970: 1234)
        let metadata = MessageMetadata(
            conversationId: "fixture-conversation", turnId: "fixture-turn", customData: ["fixture": "preserved"])
        return [
            ModelMessage(id: "system", role: .system, content: [.text("Synthetic fixture")], timestamp: timestamp),
            ModelMessage(id: "user", role: .user, content: [.text("Continue the fixture")], timestamp: timestamp),
            ModelMessage(
                id: "prior-call-message",
                role: .assistant,
                content: [.toolCall(AgentToolCall(id: "prior-call", name: self.toolName, arguments: [:]))],
                timestamp: timestamp,
                channel: .commentary,
                metadata: metadata),
            ModelMessage(
                id: "prior-result-message",
                role: .tool,
                content: [.toolResult(.success(toolCallId: "prior-call", result: self.value))],
                timestamp: timestamp,
                channel: .commentary,
                metadata: metadata),
        ]
    }
}

private final class ObservationContextProvider: ModelProvider, Sendable {
    let modelId = "synthetic-observation-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities(supportsStreaming: true)
    let requests = AutomationTestLockedValue<[ProviderRequest]>([])
    let methods = AutomationTestLockedValue<[String]>([])
    let call: AgentToolCall

    init(toolName: String) {
        self.call = AgentToolCall(id: "fresh-observation-call", name: toolName, arguments: [:])
    }

    func generateText(request: ProviderRequest) async throws -> ProviderResponse {
        self.response(request: request, method: "generate")
    }

    func streamText(request: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let response = self.response(request: request, method: "stream")
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(response.text))
            for call in response.toolCalls ?? [] {
                continuation.yield(.tool(call))
            }
            continuation.yield(.done(usage: response.usage, finishReason: response.finishReason))
            continuation.finish()
        }
    }

    private func response(request: ProviderRequest, method: String) -> ProviderResponse {
        self.methods.withValue { $0.append(method) }
        let index = self.requests.withValue { requests in
            let index = requests.count
            requests.append(request)
            return index
        }
        if index == 0 {
            return ProviderResponse(
                text: "Reading the synthetic observation.",
                usage: Usage(inputTokens: 11, outputTokens: 7),
                finishReason: .toolCalls,
                toolCalls: [self.call])
        }
        return ProviderResponse(text: "Finished.", usage: Usage(inputTokens: 13, outputTokens: 5), finishReason: .stop)
    }
}
