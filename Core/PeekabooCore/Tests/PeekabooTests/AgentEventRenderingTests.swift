import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct AgentEventRenderingTests {
    private enum Entry: CaseIterable {
        case task, resume, audio
    }

    @Test(arguments: [false, true])
    func `Event interest is sampled once and completion payloads are lazy`(interested: Bool) async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store)
        let delegate = EventRenderingDelegate(interested: interested)
        var renders = 0
        func render() -> String {
            renders += 1
            return "rendered-payload"
        }

        #expect(DefaultEventRenderingDelegate().receivesAgentEvents)
        await service.sendToolCompletionEvent(name: "fixture", payload: render(), eventHandler: nil)
        #expect(renders == 0)
        _ = try await service.withAgentEventDelivery(task: "synthetic", delegate: delegate) { handler in
            #expect((handler != nil) == interested)
            await service.sendToolCompletionEvent(name: "fixture", payload: render(), eventHandler: handler)
            return Self.result()
        }

        #expect(delegate.interestReads == 1)
        #expect(renders == (interested ? 1 : 0))
        #expect(delegate.events
            .map(\.renderingTestKind) == (interested ? ["started", "tool-completed", "completed"] : []))
        if interested {
            guard case let .toolCallCompleted(name, payload) = delegate.events[1] else {
                Issue.record("Missing rendered completion")
                return
            }
            #expect(name == "fixture")
            #expect(payload == "rendered-payload")
        }
    }

    @Test(arguments: [false, true])
    func `Actual task cancellation drains queued events before returning`(interested: Bool) async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store)
        let delegate = EventRenderingDelegate(interested: interested)
        let entered = AsyncTestLatch()
        let task = Task { @MainActor in
            try await service.withAgentEventDelivery(task: "synthetic", delegate: delegate) { handler in
                await handler?.send(.toolCallStarted(name: "fixture", arguments: "{}"))
                await entered.open()
                try await Task.sleep(for: .seconds(60))
                return Self.result()
            }
        }
        #expect(await entered.opensWithin(.seconds(2)))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }

        #expect(delegate.events.map(\.renderingTestKind) == (interested ? ["started", "tool-start"] : []))
        #expect(delegate.interestReads == 1)
    }

    @Test(arguments: [false, true])
    func `Preflight failures do not construct event delivery`(resume: Bool) async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let provider = EventRenderingProvider(usesTool: false)
        let model = LanguageModel.custom(provider: provider)
        let service = try self.service(store, model: model)
        let delegate = EventRenderingDelegate(interested: true)
        await #expect(throws: (any Error).self) {
            if resume {
                _ = try await service.resumeSession(
                    sessionId: "missing-session", model: model, eventDelegate: delegate)
            } else {
                _ = try await service.executeTask(
                    "synthetic", maxSteps: 0, model: model, eventDelegate: delegate)
            }
        }
        #expect(delegate.interestReads == 0)
        #expect(delegate.events.isEmpty)
        #expect(provider.requests.value.isEmpty)
    }

    @Test(arguments: Entry.allCases, [false, true])
    private func `Every entry point preserves provider selection and terminal delivery`(
        entry: Entry, streaming: Bool) async throws
    {
        for terminal in EventRenderingTerminal.allCases {
            for interested in [false, true] {
                let store = try IsolatedAgentSessionStore()
                defer { store.cleanup() }
                let provider = EventRenderingProvider(streaming: streaming, usesTool: false)
                let model = LanguageModel.custom(provider: provider)
                let service = try self.service(store, model: model)
                let delegate = EventRenderingDelegate(interested: interested)
                var sessionID: String?
                if entry == .resume {
                    let seeded = try await service.executeTask(
                        "seed", maxSteps: 1, model: model, enhancementOptions: nil)
                    let seededSessionID: String = try #require(seeded.sessionId)
                    sessionID = seededSessionID
                    provider.requests.withValue { $0.removeAll() }
                }
                provider.terminal.withValue { $0 = terminal }
                do {
                    let result: AgentExecutionResult = switch entry {
                    case .task:
                        try await service.executeTask(
                            "synthetic",
                            maxSteps: 1,
                            model: model,
                            eventDelegate: delegate,
                            enhancementOptions: nil,
                            persistSession: false)
                    case .resume:
                        try await service.resumeSession(
                            sessionId: #require(sessionID),
                            model: model,
                            maxSteps: 1,
                            eventDelegate: delegate,
                            enhancementOptions: nil)
                    case .audio:
                        try await service.executeAudioStreamingTask(
                            input: "synthetic transcript",
                            maxSteps: 1,
                            queueMode: .oneAtATime,
                            eventDelegate: delegate)
                    }
                    #expect(terminal == .success)
                    #expect(result.content == "Finished.")
                    #expect(result.usage?.inputTokens == 13)
                    #expect(result.usage?.outputTokens == 5)
                } catch is CancellationError {
                    #expect(terminal == .cancellation)
                } catch EventRenderingFailure.expected {
                    #expect(terminal == .failure)
                }
                #expect(provider.requests.value.map(\.method) == [streaming ? "stream" : "generate"])
                #expect(delegate.interestReads == 1)
                let kinds = delegate.events.map(\.renderingTestKind)
                if interested {
                    #expect(kinds.first == "started")
                    #expect(kinds.filter { $0 == "completed" }.count == (terminal == .success ? 1 : 0))
                    #expect(kinds.filter { $0 == "error" }.count == (terminal == .failure ? 1 : 0))
                    if terminal != .cancellation {
                        #expect(kinds.last == (terminal == .success ? "completed" : "error"))
                    }
                    if case let .completed(summary, usage)? = delegate.events.last {
                        #expect(summary == "Finished.")
                        #expect(usage?.inputTokens == 13)
                        #expect(usage?.outputTokens == 5)
                    }
                } else {
                    #expect(kinds.isEmpty)
                }
            }
        }
    }

    @Test(arguments: [false, true], [false, true])
    func `Unobserved progress preserves both provider turns and canonical tool history`(
        streaming: Bool, toolFails: Bool) async throws
    {
        let interested = try await self.runToolTranscript(streaming: streaming, toolFails: toolFails, interested: true)
        for useTextCallback in [false, true] {
            let silent = try await self.runToolTranscript(
                streaming: streaming,
                toolFails: toolFails,
                interested: false,
                useTextCallback: useTextCallback)

            #expect(interested.outcome.content == silent.outcome.content)
            #expect(Self.normalized(interested.outcome.messages) == Self.normalized(silent.outcome.messages))
            #expect(interested.outcome.usage == silent.outcome.usage)
            #expect(interested.outcome.toolCallCount == 1)
            #expect(silent.outcome.toolCallCount == 1)
            #expect(!interested.outcome.reachedStepLimit && !silent.outcome.reachedStepLimit)
            #expect(interested.outcome.usage?.inputTokens == 24)
            #expect(interested.outcome.usage?.outputTokens == 12)
            #expect(interested.outcome.steps.count == 2 && silent.outcome.steps.count == 2)
            for (left, right) in zip(interested.outcome.steps, silent.outcome.steps) {
                #expect(left.stepIndex == right.stepIndex)
                #expect(left.text == right.text)
                #expect(left.toolCalls == right.toolCalls)
                #expect(left.toolResults == right.toolResults)
                #expect(left.usage == right.usage)
                #expect(left.finishReason == right.finishReason)
            }
            let leftTrace = AgentExecutionTrace(messages: interested.outcome.messages)
            let rightTrace = AgentExecutionTrace(messages: silent.outcome.messages)
            #expect(leftTrace == rightTrace)
            #expect(leftTrace.entries.first?.actionOutcome != nil)
            #expect(leftTrace.entries.first?.isError == toolFails)
            #expect(interested.requests.count == 2 && silent.requests.count == 2)
            for (left, right) in zip(interested.requests, silent.requests) {
                #expect(left.method == (streaming ? "stream" : "generate"))
                #expect(left.method == right.method)
                #expect(Self.normalized(left.request.messages) == Self.normalized(right.request.messages))
                #expect(try self.encoded(left.request.settings) == self.encoded(right.request.settings))
                #expect(left.request.settings.stopConditions == nil && right.request.settings.stopConditions == nil)
                #expect(try self.toolSchemas(left.request.tools) == self.toolSchemas(right.request.tools))
            }
            #expect(silent.events.isEmpty)
            #expect(silent.textChunks == (streaming && useTextCallback
                    ? ["I'll inspect the synthetic result.", "Finished."] : []))
        }
        let toolEvents = interested.events.filter { $0.renderingTestKind.hasPrefix("tool-") }
        #expect(toolEvents.map(\.renderingTestKind) == (
            streaming ? ["tool-start", "tool-update", "tool-completed"] : ["tool-start", "tool-completed"]))
        for event in toolEvents {
            if case let .toolCallStarted(_, arguments) = event {
                #expect(!arguments.contains("synthetic-preview-secret"))
                #expect(arguments.contains(streaming ? "earlier-value" : "latest-value"))
            } else if case let .toolCallUpdated(_, arguments) = event {
                #expect(!arguments.contains("synthetic-preview-secret"))
                #expect(arguments.contains("latest-value"))
            }
        }
    }

    private struct Transcript {
        let outcome: PeekabooAgentService.StreamingLoopOutcome
        let requests: [EventRenderingRequest]
        let events: [AgentEvent]
        let textChunks: [String]
    }

    private enum BenchmarkMode: String, CaseIterable {
        case eagerDiscard, absent, uninterested, interested
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["PEEKABOO_RUN_EVENT_RENDERING_BENCHMARK"] == "1"))
    func `Synthetic completion rendering benchmark`() async throws {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store)
        for size in [1024, 25600, 102_400] {
            let payload = AnyAgentToolValue(object: ["text": .init(string: String(repeating: "x", count: size))])
            var samples: [BenchmarkMode: [Double]] = [:]
            var lastSamples: [BenchmarkMode: (renders: Int, bytes: Int)] = [:]
            for round in 0..<6 {
                let modes = round.isMultiple(of: 2) ? BenchmarkMode.allCases : Array(BenchmarkMode.allCases.reversed())
                for mode in modes {
                    let sample = try await self.benchmark(service, payload: payload, mode: mode)
                    let renders = mode == .eagerDiscard || mode == .interested
                    #expect(sample.renders == (renders ? 22 : 0))
                    #expect(renders ? sample.bytes >= size * 22 : sample.bytes == 0)
                    lastSamples[mode] = (sample.renders, sample.bytes)
                    if round > 0 {
                        samples[mode, default: []].append(sample.milliseconds)
                    }
                }
            }
            for mode in BenchmarkMode.allCases {
                let values = try #require(samples[mode]).sorted()
                let last = try #require(lastSamples[mode])
                print("EVENT_RENDER_BENCHMARK bytes=\(size) mode=\(mode.rawValue) count=22 " +
                    "renders=\(last.renders) serialized_bytes=\(last.bytes) median_ms=\(values[2])")
            }
        }
    }

    private func benchmark(
        _ service: PeekabooAgentService,
        payload: AnyAgentToolValue,
        mode: BenchmarkMode) async throws -> (milliseconds: Double, renders: Int, bytes: Int)
    {
        var renders = 0
        var bytes = 0
        func render() -> String {
            renders += 1
            let text = service.toolResultPayload(from: payload, toolName: "synthetic")
            bytes += text.utf8.count
            return text
        }
        func emit(_ handler: EventHandler?) async -> AgentExecutionResult {
            for _ in 0..<22 {
                if mode == .eagerDiscard {
                    let rendered = render()
                    await service.sendToolCompletionEvent(name: "synthetic", payload: rendered, eventHandler: handler)
                } else {
                    await service.sendToolCompletionEvent(name: "synthetic", payload: render(), eventHandler: handler)
                }
            }
            return Self.result()
        }

        let start = ContinuousClock.now
        if mode == .interested || mode == .uninterested {
            let delegate = EventRenderingDelegate(interested: mode == .interested)
            _ = try await service.withAgentEventDelivery(task: "synthetic", delegate: delegate) { handler in
                await emit(handler)
            }
            #expect(delegate.events.filter { $0.renderingTestKind == "tool-completed" }.count == (
                mode == .interested ? 22 : 0))
        } else {
            _ = await emit(nil)
        }
        let duration = start.duration(to: .now).components
        return (Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15, renders, bytes)
    }

    private func runToolTranscript(
        streaming: Bool,
        toolFails: Bool,
        interested: Bool,
        useTextCallback: Bool = false) async throws -> Transcript
    {
        let store = try IsolatedAgentSessionStore()
        defer { store.cleanup() }
        let service = try self.service(store)
        let provider = EventRenderingProvider()
        let delegate = EventRenderingDelegate(interested: interested)
        let textChunks = AutomationTestLockedValue<[String]>([])
        let textHandler: PeekabooAgentService.TextStreamHandler? = useTextCallback
            ? { @Sendable text in textChunks.withValue { $0.append(text) } } : nil
        let executions = AutomationTestLockedValue(0)
        let outcome = toolFails
            ? DesktopActionOutcome.refused(reason: .permissionDenied)
            : DesktopActionOutcome.confirmedChange(delivery: .init(mechanism: .accessibilityAction, mode: .background))
        let metadata = try AnyAgentToolValue
            .fromJSON(JSONSerialization.jsonObject(with: JSONEncoder().encode(outcome.projection)))
        let tool = AgentTool(
            name: EventRenderingProvider.call().name,
            description: "Synthetic event rendering fixture",
            parameters: .init(properties: [
                "text": .init(name: "text", type: .string, description: "Synthetic text"),
                "password": .init(name: "password", type: .string, description: "Synthetic test data"),
            ], required: ["text", "password"]),
            execute: { arguments in
                #expect(arguments["text"]?.stringValue == "latest-value")
                #expect(arguments["password"]?.stringValue == "synthetic-preview-secret")
                executions.withValue { $0 += 1 }
                if toolFails {
                    throw AgentToolExecutionFailure(message: "synthetic refusal", metadata: metadata)
                }
                return AnyAgentToolValue(object: ["metadata": metadata, "text": .init(string: "synthetic result")])
            })
        var transcript: PeekabooAgentService.StreamingLoopOutcome?
        _ = try await service.withAgentEventDelivery(task: "synthetic", delegate: delegate) { handler in
            let configuration = PeekabooAgentService.StreamingLoopConfiguration(
                model: .anthropic(.opus47),
                provider: provider,
                tools: [tool],
                sessionId: "event-rendering-session",
                eventHandler: handler,
                textHandler: textHandler,
                enhancementOptions: nil,
                executionPolicy: .unrestricted)
            let messages: [ModelMessage] = [.user("Use the synthetic fixture once.")]
            transcript = if streaming {
                try await service.runStreamingLoop(configuration: configuration, maxSteps: 2, initialMessages: messages)
            } else {
                try await service.runGenerationLoop(
                    configuration: configuration,
                    maxSteps: 2,
                    initialMessages: messages)
            }
            return Self.result()
        }
        #expect(executions.value == 1)
        return try Transcript(
            outcome: #require(transcript),
            requests: provider.requests.value,
            events: delegate.events,
            textChunks: textChunks.value)
    }

    private func service(
        _ store: IsolatedAgentSessionStore,
        model: LanguageModel = .anthropic(.opus47)) throws -> PeekabooAgentService
    {
        try PeekabooAgentService(services: PeekabooServices(), defaultModel: model, sessionManager: store.manager)
    }

    private static func result() -> AgentExecutionResult {
        AgentExecutionResult(content: "Finished.", metadata: AgentMetadata(
            executionTime: 0, toolCallCount: 0, modelName: "fixture", startTime: Date(), endTime: Date()))
    }

    private static func normalized(_ messages: [ModelMessage]) -> [ModelMessage] {
        messages.enumerated().map { index, message in
            ModelMessage(
                id: "\(index)",
                role: message.role,
                content: message.content,
                timestamp: Date(timeIntervalSince1970: 0),
                channel: message.channel,
                metadata: message.metadata)
        }
    }

    private func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func toolSchemas(_ tools: [AgentTool]?) throws -> [Data] {
        try (tools ?? []).map { tool in
            struct Schema: Encodable {
                let name: String
                let description: String
                let namespace: String?
                let recipient: String?
                let parameters: AgentToolParameters
            }
            return try self.encoded(Schema(
                name: tool.name,
                description: tool.description,
                namespace: tool.namespace,
                recipient: tool.recipient,
                parameters: tool.parameters))
        }
    }
}
