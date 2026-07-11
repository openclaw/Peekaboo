import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooAgentStepLimitTests {
    @Test
    @MainActor
    func `Nonstreaming step exhaustion saves resumable tool history and throws`() async throws {
        let provider = PerpetualToolProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        let thrownError = await #expect(throws: PeekabooAgentService.AgentStepLimitExceededError.self) {
            _ = try await agentService.executeTask(
                "Keep using tools.",
                maxSteps: 1,
                model: .openai(.gpt55),
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(provider.requestCount == 1)
        #expect(error.maxSteps == 1)
        #expect(error.localizedDescription.contains("can be resumed"))

        let loadedSession = try await agentService.getSessionInfo(sessionId: error.sessionId)
        let session = try #require(loadedSession)
        #expect(session.metadata.customData["status"] == "max_steps_exhausted")
        #expect(session.messages.containsToolCall(id: "tool-call-1"))
        #expect(session.messages.containsToolResult(id: "tool-call-1"))

        try await agentService.deleteSession(id: error.sessionId)
    }

    @Test
    @MainActor
    func `Streaming step exhaustion saves resumable tool history without completion event`() async throws {
        let provider = PerpetualToolProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        let thrownError = await #expect(throws: PeekabooAgentService.AgentStepLimitExceededError.self) {
            _ = try await agentService.executeTask(
                "Keep using tools.",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(provider.requestCount == 1)
        #expect(!delegate.events.contains { event in
            if case .completed = event {
                true
            } else {
                false
            }
        })

        let loadedSession = try await agentService.getSessionInfo(sessionId: error.sessionId)
        let session = try #require(loadedSession)
        #expect(session.metadata.customData["status"] == "max_steps_exhausted")
        #expect(session.messages.containsToolCall(id: "tool-call-1"))
        #expect(session.messages.containsToolResult(id: "tool-call-1"))

        try await agentService.deleteSession(id: error.sessionId)
    }

    @Test(arguments: [TerminalTool.done, .needInfo])
    @MainActor
    func `Terminal tool succeeds on final nonstreaming step`(_ terminalTool: TerminalTool) async throws {
        let provider = TerminalToolProvider(terminalTool: terminalTool)
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let result = try await agentService.executeTask(
            "Finish this turn.",
            maxSteps: 1,
            model: .openai(.gpt55),
            enhancementOptions: nil)

        #expect(result.content == terminalTool.expectedReason)
        let sessionId = try #require(result.sessionId)
        let loadedSession = try await agentService.getSessionInfo(sessionId: sessionId)
        #expect(loadedSession?.metadata.customData["status"] == "completed")
        try await agentService.deleteSession(id: sessionId)
    }

    @Test(arguments: [TerminalTool.done, .needInfo])
    @MainActor
    func `Terminal tool succeeds on final streaming step`(_ terminalTool: TerminalTool) async throws {
        let provider = TerminalToolProvider(terminalTool: terminalTool)
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let result = try await agentService.executeTask(
            "Finish this turn.",
            maxSteps: 1,
            model: .openai(.gpt55),
            eventDelegate: delegate,
            enhancementOptions: nil)

        #expect(result.content == terminalTool.expectedReason)
        #expect(delegate.events.contains { event in
            if case let .completed(summary, _) = event {
                summary == terminalTool.expectedReason
            } else {
                false
            }
        })
        let sessionId = try #require(result.sessionId)
        let loadedSession = try await agentService.getSessionInfo(sessionId: sessionId)
        #expect(loadedSession?.metadata.customData["status"] == "completed")
        try await agentService.deleteSession(id: sessionId)
    }

    @Test(arguments: [FinishReason.length, .error, .cancelled, .other])
    @MainActor
    func `Incomplete tool responses are rejected before execution`(_ finishReason: FinishReason) throws {
        let agentService = try PeekabooAgentService(services: PeekabooServices())

        let thrownError = #expect(throws: TachikomaError.self) {
            try agentService.validateToolContinuationFinishReason(finishReason, hasToolCalls: true)
        }
        let error = try #require(thrownError)

        #expect(error.localizedDescription.contains(finishReason.rawValue))
        #expect(error.localizedDescription.contains("refusing to execute incomplete tool calls"))
    }

    @Test
    @MainActor
    func `Ollama compatible tool finish reasons remain accepted`() throws {
        let agentService = try PeekabooAgentService(services: PeekabooServices())

        #expect(throws: Never.self) {
            try agentService.validateToolContinuationFinishReason(nil, hasToolCalls: true)
        }
        #expect(throws: Never.self) {
            try agentService.validateToolContinuationFinishReason(.toolCalls, hasToolCalls: true)
        }
        #expect(throws: Never.self) {
            try agentService.validateToolContinuationFinishReason(.stop, hasToolCalls: true)
        }
    }

    @Test
    @MainActor
    func `Tool-call finish without decoded calls is rejected`() throws {
        let agentService = try PeekabooAgentService(services: PeekabooServices())

        let thrownError = #expect(throws: TachikomaError.self) {
            try agentService.validateToolContinuationFinishReason(.toolCalls, hasToolCalls: false)
        }
        let error = try #require(thrownError)

        #expect(error.localizedDescription.contains("no tool calls were decoded"))
        #expect(error.localizedDescription.contains("refusing to treat the response as complete"))
    }

    @Test
    @MainActor
    func `Nonstreaming tool-call finish without decoded calls fails before completion`() async throws {
        let provider = MalformedToolResponseProvider(finishReason: .toolCalls, toolCalls: [])
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.fable5))

        let thrownError = await #expect(throws: TachikomaError.self) {
            _ = try await agentService.executeTask(
                "Return a malformed response.",
                maxSteps: 1,
                model: .anthropic(.fable5),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(error.localizedDescription.contains("no tool calls were decoded"))
        #expect(provider.generateRequestCount == 1)
        #expect(provider.streamRequestCount == 0)
        #expect(!delegate.events.containsCompletedEvent)
    }

    @Test
    @MainActor
    func `Streaming tool-call finish without decoded calls fails before completion`() async throws {
        let provider = MalformedToolResponseProvider(finishReason: .toolCalls, toolCalls: [])
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        let thrownError = await #expect(throws: TachikomaError.self) {
            _ = try await agentService.executeTask(
                "Return a malformed response.",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(error.localizedDescription.contains("no tool calls were decoded"))
        #expect(provider.generateRequestCount == 0)
        #expect(provider.streamRequestCount == 1)
        #expect(!delegate.events.containsCompletedEvent)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Empty terminal response after tool use fails instead of completing`(_ streaming: Bool) async throws {
        let provider = EmptyTerminalAfterToolProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        let thrownError = await #expect(throws: TachikomaError.self) {
            _ = try await agentService.executeTask(
                "Use a tool, then return an empty response.",
                maxSteps: 2,
                model: .openai(.gpt55),
                eventDelegate: streaming ? delegate : nil,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(error.localizedDescription.contains("empty terminal response"))
        #expect(provider.generateRequestCount == (streaming ? 0 : 2))
        #expect(provider.streamRequestCount == (streaming ? 2 : 0))
        #expect(!delegate.events.containsCompletedEvent)
    }

    @Test(arguments: [FinishReason.length, .error, .cancelled, .other])
    @MainActor
    func `Nonstreaming incomplete terminal response fails instead of completing`(
        _ finishReason: FinishReason) async throws
    {
        let provider = MalformedToolResponseProvider(
            finishReason: finishReason,
            toolCalls: [],
            text: "Partial response")
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        let thrownError = await #expect(throws: TachikomaError.self) {
            _ = try await agentService.executeTask(
                "Return a truncated terminal response.",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: nil,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(error.localizedDescription.contains(finishReason.rawValue))
        #expect(error.localizedDescription.contains("refusing to mark the task complete"))
        #expect(provider.generateRequestCount == 1)
        #expect(provider.streamRequestCount == 0)
    }

    @Test(arguments: [FinishReason.length, .error, .cancelled, .other])
    @MainActor
    func `Streaming incomplete terminal response fails instead of completing`(
        _ finishReason: FinishReason) async throws
    {
        let provider = MalformedToolResponseProvider(
            finishReason: finishReason,
            toolCalls: [],
            text: "Partial response")
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        let thrownError = await #expect(throws: TachikomaError.self) {
            _ = try await agentService.executeTask(
                "Return a truncated terminal response.",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(error.localizedDescription.contains(finishReason.rawValue))
        #expect(error.localizedDescription.contains("refusing to mark the task complete"))
        #expect(provider.generateRequestCount == 0)
        #expect(provider.streamRequestCount == 1)
        #expect(!delegate.events.containsCompletedEvent)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Provider failure preserves last complete tool batch`(_ streaming: Bool) async throws {
        try await self.assertCheckpointAfterProviderFailure(
            streaming: streaming,
            failure: .error,
            expectedStatus: "failed")
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Provider cancellation preserves last complete tool batch`(_ streaming: Bool) async throws {
        try await self.assertCheckpointAfterProviderFailure(
            streaming: streaming,
            failure: .cancellation,
            expectedStatus: "cancelled")
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Parent cancellation persists a balanced in-flight tool batch`(_ streaming: Bool) async throws {
        let provider = MultiSleepProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let model = LanguageModel.openai(.gpt55)
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model)
        let context = try await agentService.prepareSession(
            task: "Run three sleeps.",
            model: model,
            label: "parent-cancellation-test",
            logBehavior: .verboseOnly)
        let firstCompletion = FirstToolCompletionGate()
        let eventHandler = EventHandler { event in
            if case .toolCallCompleted = event {
                await firstCompletion.signal()
            }
        }

        let task = Task { @MainActor in
            if streaming {
                try await agentService.executeWithStreaming(
                    context: context,
                    model: model,
                    maxSteps: 1,
                    streamingDelegate: StreamingEventDelegate { _ in },
                    eventHandler: eventHandler,
                    enhancementOptions: nil)
            } else {
                try await agentService.executeWithoutStreaming(
                    context: context,
                    model: model,
                    maxSteps: 1,
                    eventHandler: eventHandler,
                    enhancementOptions: nil)
            }
        }

        await firstCompletion.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let session = try #require(try await agentService.getSessionInfo(sessionId: context.id))
        #expect(session.metadata.customData["status"] == "cancelled")
        #expect(session.metadata.toolCallCount == 3)
        let toolResults = session.messages.flatMap { message in
            message.content.compactMap { part -> AgentToolResult? in
                if case let .toolResult(result) = part {
                    result
                } else {
                    nil
                }
            }
        }
        #expect(toolResults.map(\.toolCallId) == ["first-sleep", "second-sleep", "third-sleep"])
        #expect(toolResults.map(\.isError) == [false, true, true])
        #expect(session.messages.containsToolCall(id: "first-sleep"))
        #expect(session.messages.containsToolCall(id: "second-sleep"))
        #expect(session.messages.containsToolCall(id: "third-sleep"))
        try await agentService.deleteSession(id: context.id)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Noncooperative provider cannot complete after parent cancellation`(_ streaming: Bool) async throws {
        let gate = NoncooperativeProviderGate()
        let provider = NoncooperativeCancellationProvider(gate: gate)
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let model = LanguageModel.anthropic(.sonnet45)
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model)
        let context = try await agentService.prepareSession(
            task: "Wait for a provider response.",
            model: model,
            label: "provider-parent-cancellation-test",
            logBehavior: .verboseOnly)
        let eventHandler = EventHandler { event in
            if streaming, case .assistantMessage = event {
                await gate.markStarted()
            }
        }

        let task = Task { @MainActor in
            if streaming {
                try await agentService.executeWithStreaming(
                    context: context,
                    model: model,
                    maxSteps: 1,
                    streamingDelegate: StreamingEventDelegate { _ in },
                    eventHandler: eventHandler,
                    enhancementOptions: nil)
            } else {
                try await agentService.executeWithoutStreaming(
                    context: context,
                    model: model,
                    maxSteps: 1,
                    eventHandler: eventHandler,
                    enhancementOptions: nil)
            }
        }

        await gate.waitForStart()
        task.cancel()
        await gate.release()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let session = try #require(try await agentService.getSessionInfo(sessionId: context.id))
        #expect(session.metadata.customData["status"] == "cancelled")
        #expect(session.metadata.totalTokens == (streaming ? 0 : 5))
        #expect(session.metadata.totalCost == (streaming ? nil : 0))
        #expect(!session.messages.containsText(NoncooperativeCancellationProvider.unsafeText))
        try await agentService.deleteSession(id: context.id)
    }

    @Test
    @MainActor
    func `Streaming usage accumulates across tool turns`() async throws {
        let provider = TwoTurnUsageProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let result = try await agentService.executeTask(
            "Use a tool, then finish.",
            maxSteps: 2,
            model: .openai(.gpt55),
            eventDelegate: delegate,
            enhancementOptions: nil)

        #expect(result.usage?.inputTokens == 8)
        #expect(result.usage?.outputTokens == 10)
        #expect(abs((result.usage?.cost?.input ?? 0) - 0.4) < 0.000_001)
        #expect(abs((result.usage?.cost?.output ?? 0) - 0.6) < 0.000_001)

        let sessionId = try #require(result.sessionId)
        let session = try #require(try await agentService.getSessionInfo(sessionId: sessionId))
        #expect(session.metadata.totalTokens == 18)
        #expect(abs((session.metadata.totalCost ?? 0) - 1.0) < 0.000_001)
        try await agentService.deleteSession(id: sessionId)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Mixed known and unknown turn costs omit the aggregate cost`(_ streaming: Bool) async throws {
        let provider = TwoTurnCostProvider(
            firstCost: nil,
            secondCost: .init(input: 0.3, output: 0.4))
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let result = try await agentService.executeTask(
            "Use a tool, then finish.",
            maxSteps: 2,
            model: .openai(.gpt55),
            eventDelegate: streaming ? delegate : nil,
            enhancementOptions: nil)

        #expect(result.usage?.inputTokens == 8)
        #expect(result.usage?.outputTokens == 10)
        #expect(result.usage?.cost == nil)
        let sessionId = try #require(result.sessionId)
        let session = try #require(try await agentService.getSessionInfo(sessionId: sessionId))
        #expect(session.metadata.totalTokens == 18)
        #expect(session.metadata.totalCost == nil)
        try await agentService.deleteSession(id: sessionId)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Explicit zero turn costs remain known`(_ streaming: Bool) async throws {
        let provider = TwoTurnCostProvider(
            firstCost: .init(input: 0, output: 0),
            secondCost: .init(input: 0, output: 0))
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))
        let result = try await agentService.executeTask(
            "Use a tool, then finish.",
            maxSteps: 2,
            model: .openai(.gpt55),
            eventDelegate: streaming ? delegate : nil,
            enhancementOptions: nil)

        let cost = try #require(result.usage?.cost)
        #expect(cost.input == 0)
        #expect(cost.output == 0)
        #expect(cost.total == 0)
        let sessionId = try #require(result.sessionId)
        let session = try #require(try await agentService.getSessionInfo(sessionId: sessionId))
        #expect(session.metadata.totalCost == 0)
        try await agentService.deleteSession(id: sessionId)
    }

    @Test
    @MainActor
    func `Unknown zero-token cost remains unknown across session continuation`() async throws {
        let model = LanguageModel.openai(.gpt55)
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model)
        let context = try await agentService.prepareSession(
            task: "Start cost coverage test.",
            model: model,
            label: "cost-coverage-test",
            logBehavior: .verboseOnly)

        do {
            try agentService.saveExecutionSession(
                context: context,
                model: model,
                finalMessages: context.messages,
                endTime: Date(),
                toolCallCount: 0,
                usage: Usage(inputTokens: 0, outputTokens: 0, cost: nil),
                status: "failed")

            let firstSession = try #require(try await agentService.getSessionInfo(sessionId: context.id))
            let continuation = agentService.makeContinuationContext(
                from: firstSession,
                userMessage: "Continue.",
                model: model)
            try agentService.saveExecutionSession(
                context: continuation,
                model: model,
                finalMessages: continuation.messages,
                endTime: Date(),
                toolCallCount: 0,
                usage: Usage(
                    inputTokens: 0,
                    outputTokens: 0,
                    cost: .init(input: 0, output: 0)),
                status: "completed")

            let finalSession = try #require(try await agentService.getSessionInfo(sessionId: context.id))
            #expect(finalSession.metadata.totalCost == nil)
            #expect(finalSession.metadata.customData["agent_usage_observed"] == "true")
            #expect(finalSession.metadata.customData["agent_usage_cost_complete"] == "false")
            try await agentService.deleteSession(id: context.id)
        } catch {
            try? await agentService.deleteSession(id: context.id)
            throw error
        }
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Abnormal billed response checkpoints usage without unsafe assistant history`(_ streaming: Bool) async throws {
        let provider = AbnormalBilledResponseProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let model = LanguageModel.openai(.gpt55)
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model)
        let context = try await agentService.prepareSession(
            task: "Return a billed but incomplete response.",
            model: model,
            label: "abnormal-usage-test",
            logBehavior: .verboseOnly)

        do {
            await #expect(throws: TachikomaError.self) {
                if streaming {
                    _ = try await agentService.executeWithStreaming(
                        context: context,
                        model: model,
                        maxSteps: 1,
                        streamingDelegate: StreamingEventDelegate { _ in },
                        enhancementOptions: nil)
                } else {
                    _ = try await agentService.executeWithoutStreaming(
                        context: context,
                        model: model,
                        maxSteps: 1,
                        enhancementOptions: nil)
                }
            }

            let session = try #require(try await agentService.getSessionInfo(sessionId: context.id))
            #expect(session.metadata.customData["status"] == "failed")
            #expect(session.metadata.totalTokens == 13)
            #expect(abs((session.metadata.totalCost ?? 0) - 0.3) < 0.000_001)
            #expect(!session.messages.containsText(AbnormalBilledResponseProvider.unsafeText))
            try await agentService.deleteSession(id: context.id)
        } catch {
            try? await agentService.deleteSession(id: context.id)
            throw error
        }
    }

    @Test(arguments: [FinishReason.length, .error])
    @MainActor
    func `Nonstreaming abnormal tool response fails before tool execution`(_ finishReason: FinishReason) async throws {
        let provider = MalformedToolResponseProvider(
            finishReason: finishReason,
            toolCalls: [TerminalTool.done.call])
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .anthropic(.fable5))

        let thrownError = await #expect(throws: TachikomaError.self) {
            _ = try await agentService.executeTask(
                "Return an incomplete tool response.",
                maxSteps: 1,
                model: .anthropic(.fable5),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(error.localizedDescription.contains(finishReason.rawValue))
        #expect(provider.generateRequestCount == 1)
        #expect(provider.streamRequestCount == 0)
        #expect(!delegate.events.containsToolEvent)
        #expect(!delegate.events.containsCompletedEvent)
    }

    @Test(arguments: [FinishReason.length, .error])
    @MainActor
    func `Streaming abnormal tool response fails before tool execution`(_ finishReason: FinishReason) async throws {
        let provider = MalformedToolResponseProvider(
            finishReason: finishReason,
            toolCalls: [TerminalTool.done.call])
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        let thrownError = await #expect(throws: TachikomaError.self) {
            _ = try await agentService.executeTask(
                "Return an incomplete tool response.",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: delegate,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(error.localizedDescription.contains(finishReason.rawValue))
        #expect(provider.generateRequestCount == 0)
        #expect(provider.streamRequestCount == 1)
        #expect(!delegate.events.containsToolEvent)
        #expect(!delegate.events.containsCompletedEvent)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Successful done after a failed call requires model continuation`(_ streaming: Bool) async throws {
        let provider = ErrorThenDoneProvider()
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let delegate = StepLimitEventDelegate()
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: .openai(.gpt55))

        let thrownError = await #expect(throws: PeekabooAgentService.AgentStepLimitExceededError.self) {
            _ = try await agentService.executeTask(
                "Do not hide a failed tool call.",
                maxSteps: 1,
                model: .openai(.gpt55),
                eventDelegate: streaming ? delegate : nil,
                enhancementOptions: nil)
        }
        let error = try #require(thrownError)

        #expect(provider.generateRequestCount == (streaming ? 0 : 1))
        #expect(provider.streamRequestCount == (streaming ? 1 : 0))
        #expect(!delegate.events.containsCompletedEvent)

        let loadedSession = try await agentService.getSessionInfo(sessionId: error.sessionId)
        let session = try #require(loadedSession)
        #expect(session.metadata.customData["status"] == "max_steps_exhausted")
        let toolResults = session.messages.flatMap { message in
            message.content.compactMap { part -> AgentToolResult? in
                if case let .toolResult(toolResult) = part {
                    toolResult
                } else {
                    nil
                }
            }
        }
        #expect(toolResults.map(\.toolCallId) == ["unknown-call", "done-call"])
        #expect(toolResults.map(\.isError) == [true, false])
        #expect(agentService.turnBoundaryStopReason(from: toolResults) == nil)

        try await agentService.deleteSession(id: error.sessionId)
    }

    @MainActor
    private func assertCheckpointAfterProviderFailure(
        streaming: Bool,
        failure: ProviderFailure,
        expectedStatus: String) async throws
    {
        let provider = ToolThenFailureProvider(failure: failure)
        let configuration = TachikomaConfiguration(loadFromEnvironment: false)
        configuration.setProviderFactoryOverride { _, _ in provider }

        let previousConfiguration = TachikomaConfiguration.default
        TachikomaConfiguration.default = configuration
        defer { TachikomaConfiguration.default = previousConfiguration }

        let model = LanguageModel.openai(.gpt55)
        let agentService = try PeekabooAgentService(
            services: PeekabooServices(),
            defaultModel: model)
        let context = try await agentService.prepareSession(
            task: "Use a tool, then encounter a provider failure.",
            model: model,
            label: "checkpoint-test",
            logBehavior: .verboseOnly)

        do {
            if failure == .cancellation {
                await #expect(throws: CancellationError.self) {
                    if streaming {
                        _ = try await agentService.executeWithStreaming(
                            context: context,
                            model: model,
                            maxSteps: 2,
                            streamingDelegate: StreamingEventDelegate { _ in },
                            enhancementOptions: nil)
                    } else {
                        _ = try await agentService.executeWithoutStreaming(
                            context: context,
                            model: model,
                            maxSteps: 2,
                            enhancementOptions: nil)
                    }
                }
            } else {
                await #expect(throws: TachikomaError.self) {
                    if streaming {
                        _ = try await agentService.executeWithStreaming(
                            context: context,
                            model: model,
                            maxSteps: 2,
                            streamingDelegate: StreamingEventDelegate { _ in },
                            enhancementOptions: nil)
                    } else {
                        _ = try await agentService.executeWithoutStreaming(
                            context: context,
                            model: model,
                            maxSteps: 2,
                            enhancementOptions: nil)
                    }
                }
            }

            let session = try #require(try await agentService.getSessionInfo(sessionId: context.id))
            #expect(session.metadata.customData["status"] == expectedStatus)
            #expect(session.metadata.toolCallCount == 1)
            #expect(session.messages.containsToolCall(id: "checkpoint-tool"))
            #expect(session.messages.containsToolResult(id: "checkpoint-tool"))
            try await agentService.deleteSession(id: context.id)
        } catch {
            try? await agentService.deleteSession(id: context.id)
            throw error
        }
    }
}

enum TerminalTool: CaseIterable, Sendable {
    case done
    case needInfo

    var call: AgentToolCall {
        switch self {
        case .done:
            AgentToolCall(
                id: "done-call",
                name: "done",
                arguments: ["message": AnyAgentToolValue(string: "Finished export")])
        case .needInfo:
            AgentToolCall(
                id: "need-info-call",
                name: "need_info",
                arguments: ["question": AnyAgentToolValue(string: "Which account?")])
        }
    }

    var expectedReason: String {
        switch self {
        case .done: "Finished export"
        case .needInfo: "Need more information: Which account?"
        }
    }
}

private final class TerminalToolProvider: ModelProvider, @unchecked Sendable {
    let modelId = "terminal-tool-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()
    private let terminalTool: TerminalTool

    init(terminalTool: TerminalTool) {
        self.terminalTool = terminalTool
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(
            text: "",
            finishReason: .toolCalls,
            toolCalls: [self.terminalTool.call])
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.tool(self.terminalTool.call))
            continuation.yield(.done(finishReason: .toolCalls))
            continuation.finish()
        }
    }
}

private final class PerpetualToolProvider: ModelProvider, @unchecked Sendable {
    let modelId = "perpetual-tool-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        self.lock.withLock { self.requests }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        let requestNumber = self.nextRequestNumber()
        return ProviderResponse(
            text: "tool step \(requestNumber)",
            finishReason: .toolCalls,
            toolCalls: [self.toolCall(for: requestNumber)])
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let requestNumber = self.nextRequestNumber()
        let toolCall = self.toolCall(for: requestNumber)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("tool step \(requestNumber)"))
            continuation.yield(.tool(toolCall))
            continuation.yield(.done(finishReason: .toolCalls))
            continuation.finish()
        }
    }

    private func nextRequestNumber() -> Int {
        self.lock.withLock {
            self.requests += 1
            return self.requests
        }
    }

    private func toolCall(for requestNumber: Int) -> AgentToolCall {
        AgentToolCall(
            id: "tool-call-\(requestNumber)",
            name: "missing_test_tool",
            arguments: [:])
    }
}

private final class MalformedToolResponseProvider: ModelProvider, @unchecked Sendable {
    let modelId = "malformed-tool-response-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let finishReason: FinishReason
    private let toolCalls: [AgentToolCall]
    private let text: String
    private let lock = NSLock()
    private var generateRequests = 0
    private var streamRequests = 0

    init(finishReason: FinishReason, toolCalls: [AgentToolCall], text: String = "") {
        self.finishReason = finishReason
        self.toolCalls = toolCalls
        self.text = text
    }

    var generateRequestCount: Int {
        self.lock.withLock { self.generateRequests }
    }

    var streamRequestCount: Int {
        self.lock.withLock { self.streamRequests }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        self.lock.withLock {
            self.generateRequests += 1
        }
        return ProviderResponse(
            text: self.text,
            finishReason: self.finishReason,
            toolCalls: self.toolCalls)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        self.lock.withLock {
            self.streamRequests += 1
        }
        return AsyncThrowingStream { continuation in
            if !self.text.isEmpty {
                continuation.yield(.text(self.text))
            }
            for toolCall in self.toolCalls {
                continuation.yield(.tool(toolCall))
            }
            continuation.yield(.done(finishReason: self.finishReason))
            continuation.finish()
        }
    }
}

private final class ErrorThenDoneProvider: ModelProvider, @unchecked Sendable {
    let modelId = "error-then-done-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var generateRequests = 0
    private var streamRequests = 0

    var generateRequestCount: Int {
        self.lock.withLock { self.generateRequests }
    }

    var streamRequestCount: Int {
        self.lock.withLock { self.streamRequests }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        self.lock.withLock {
            self.generateRequests += 1
        }
        return ProviderResponse(
            text: "",
            finishReason: .toolCalls,
            toolCalls: self.toolCalls)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        self.lock.withLock {
            self.streamRequests += 1
        }
        return AsyncThrowingStream { continuation in
            for toolCall in self.toolCalls {
                continuation.yield(.tool(toolCall))
            }
            continuation.yield(.done(finishReason: .toolCalls))
            continuation.finish()
        }
    }

    private var toolCalls: [AgentToolCall] {
        [
            AgentToolCall(
                id: "unknown-call",
                name: "missing_test_tool",
                arguments: [:]),
            TerminalTool.done.call,
        ]
    }
}

private final class EmptyTerminalAfterToolProvider: ModelProvider, @unchecked Sendable {
    let modelId = "empty-terminal-after-tool-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var generateRequests = 0
    private var streamRequests = 0

    var generateRequestCount: Int {
        self.lock.withLock { self.generateRequests }
    }

    var streamRequestCount: Int {
        self.lock.withLock { self.streamRequests }
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        let requestNumber = self.lock.withLock {
            self.generateRequests += 1
            return self.generateRequests
        }
        return self.response(for: requestNumber)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let requestNumber = self.lock.withLock {
            self.streamRequests += 1
            return self.streamRequests
        }
        let response = self.response(for: requestNumber)
        return AsyncThrowingStream { continuation in
            for toolCall in response.toolCalls ?? [] {
                continuation.yield(.tool(toolCall))
            }
            continuation.yield(.done(finishReason: response.finishReason))
            continuation.finish()
        }
    }

    private func response(for requestNumber: Int) -> ProviderResponse {
        if requestNumber == 1 {
            return ProviderResponse(
                text: "",
                finishReason: .toolCalls,
                toolCalls: [AgentToolCall(
                    id: "missing-tool",
                    name: "missing_test_tool",
                    arguments: [:])])
        }

        return ProviderResponse(text: "", finishReason: .stop)
    }
}

private enum ProviderFailure: Equatable, Sendable {
    case error
    case cancellation
}

private final class ToolThenFailureProvider: ModelProvider, @unchecked Sendable {
    let modelId = "tool-then-failure-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let failure: ProviderFailure
    private let lock = NSLock()
    private var generateRequests = 0
    private var streamRequests = 0

    init(failure: ProviderFailure) {
        self.failure = failure
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        let requestNumber = self.lock.withLock {
            self.generateRequests += 1
            return self.generateRequests
        }
        if requestNumber == 1 {
            return self.toolResponse
        }
        return try self.throwFailure()
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let requestNumber = self.lock.withLock {
            self.streamRequests += 1
            return self.streamRequests
        }
        return AsyncThrowingStream { continuation in
            if requestNumber == 1 {
                continuation.yield(.tool(self.toolCall))
                continuation.yield(.done(finishReason: .toolCalls))
                continuation.finish()
            } else {
                switch self.failure {
                case .error:
                    continuation.finish(throwing: TachikomaError.apiError("Synthetic provider failure"))
                case .cancellation:
                    continuation.finish(throwing: CancellationError())
                }
            }
        }
    }

    private var toolCall: AgentToolCall {
        AgentToolCall(id: "checkpoint-tool", name: "missing_checkpoint_tool", arguments: [:])
    }

    private var toolResponse: ProviderResponse {
        ProviderResponse(text: "", finishReason: .toolCalls, toolCalls: [self.toolCall])
    }

    private func throwFailure() throws -> ProviderResponse {
        switch self.failure {
        case .error:
            throw TachikomaError.apiError("Synthetic provider failure")
        case .cancellation:
            throw CancellationError()
        }
    }
}

private final class TwoTurnUsageProvider: ModelProvider, @unchecked Sendable {
    let modelId = "two-turn-usage-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let lock = NSLock()
    private var requests = 0

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        self.response(for: self.nextRequestNumber())
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let response = self.response(for: self.nextRequestNumber())
        return AsyncThrowingStream { continuation in
            if !response.text.isEmpty {
                continuation.yield(.text(response.text))
            }
            for toolCall in response.toolCalls ?? [] {
                continuation.yield(.tool(toolCall))
            }
            continuation.yield(.done(usage: response.usage, finishReason: response.finishReason))
            continuation.finish()
        }
    }

    private func nextRequestNumber() -> Int {
        self.lock.withLock {
            self.requests += 1
            return self.requests
        }
    }

    private func response(for requestNumber: Int) -> ProviderResponse {
        if requestNumber == 1 {
            return ProviderResponse(
                text: "",
                usage: Usage(
                    inputTokens: 3,
                    outputTokens: 4,
                    cost: .init(input: 0.1, output: 0.2)),
                finishReason: .toolCalls,
                toolCalls: [AgentToolCall(
                    id: "usage-tool",
                    name: "missing_usage_tool",
                    arguments: [:])])
        }

        return ProviderResponse(
            text: "Finished",
            usage: Usage(
                inputTokens: 5,
                outputTokens: 6,
                cost: .init(input: 0.3, output: 0.4)),
            finishReason: .stop)
    }
}

private actor FirstToolCompletionGate {
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !self.completed else { return }
        self.completed = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func wait() async {
        if self.completed {
            return
        }
        await withCheckedContinuation { continuation in
            self.waiters.append(continuation)
        }
    }
}

private final class MultiSleepProvider: ModelProvider, @unchecked Sendable {
    let modelId = "multi-sleep-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        ProviderResponse(text: "", finishReason: .toolCalls, toolCalls: self.toolCalls)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            for toolCall in self.toolCalls {
                continuation.yield(.tool(toolCall))
            }
            continuation.yield(.done(finishReason: .toolCalls))
            continuation.finish()
        }
    }

    private var toolCalls: [AgentToolCall] {
        [
            AgentToolCall(
                id: "first-sleep",
                name: "sleep",
                arguments: ["duration": AnyAgentToolValue(double: 1)]),
            AgentToolCall(
                id: "second-sleep",
                name: "sleep",
                arguments: ["duration": AnyAgentToolValue(double: 30000)]),
            AgentToolCall(
                id: "third-sleep",
                name: "sleep",
                arguments: ["duration": AnyAgentToolValue(double: 1)]),
        ]
    }
}

private actor NoncooperativeProviderGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        self.started = true
        let waiters = self.startWaiters
        self.startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForStart() async {
        if self.started {
            return
        }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func waitForRelease() async {
        if self.released {
            return
        }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private final class NoncooperativeCancellationProvider: ModelProvider, @unchecked Sendable {
    static let unsafeText = "response returned after cancellation"

    let modelId = "noncooperative-cancellation-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let gate: NoncooperativeProviderGate

    init(gate: NoncooperativeProviderGate) {
        self.gate = gate
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        await self.gate.markStarted()
        await self.gate.waitForRelease()
        return ProviderResponse(
            text: Self.unsafeText,
            usage: self.usage,
            finishReason: .stop)
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            Task {
                continuation.yield(.text(Self.unsafeText))
                await self.gate.waitForRelease()
                continuation.yield(.done(usage: self.usage, finishReason: .stop))
                continuation.finish()
            }
        }
    }

    private var usage: Usage {
        Usage(
            inputTokens: 2,
            outputTokens: 3,
            cost: .init(input: 0, output: 0))
    }
}

private final class TwoTurnCostProvider: ModelProvider, @unchecked Sendable {
    let modelId = "two-turn-cost-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    private let firstCost: Usage.Cost?
    private let secondCost: Usage.Cost?
    private let lock = NSLock()
    private var requests = 0

    init(firstCost: Usage.Cost?, secondCost: Usage.Cost?) {
        self.firstCost = firstCost
        self.secondCost = secondCost
    }

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        self.response(for: self.nextRequestNumber())
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        let response = self.response(for: self.nextRequestNumber())
        return AsyncThrowingStream { continuation in
            if !response.text.isEmpty {
                continuation.yield(.text(response.text))
            }
            for toolCall in response.toolCalls ?? [] {
                continuation.yield(.tool(toolCall))
            }
            continuation.yield(.done(usage: response.usage, finishReason: response.finishReason))
            continuation.finish()
        }
    }

    private func nextRequestNumber() -> Int {
        self.lock.withLock {
            self.requests += 1
            return self.requests
        }
    }

    private func response(for requestNumber: Int) -> ProviderResponse {
        if requestNumber == 1 {
            return ProviderResponse(
                text: "",
                usage: Usage(inputTokens: 3, outputTokens: 4, cost: self.firstCost),
                finishReason: .toolCalls,
                toolCalls: [AgentToolCall(
                    id: "cost-tool",
                    name: "missing_cost_tool",
                    arguments: [:])])
        }

        return ProviderResponse(
            text: "Finished",
            usage: Usage(inputTokens: 5, outputTokens: 6, cost: self.secondCost),
            finishReason: .stop)
    }
}

private final class AbnormalBilledResponseProvider: ModelProvider, @unchecked Sendable {
    static let unsafeText = "unsafe partial assistant response"

    let modelId = "abnormal-billed-response-provider"
    let baseURL: String? = nil
    let apiKey: String? = nil
    let capabilities = ModelCapabilities()

    func generateText(request _: ProviderRequest) async throws -> ProviderResponse {
        self.response
    }

    func streamText(request _: ProviderRequest) async throws -> AsyncThrowingStream<TextStreamDelta, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.text(Self.unsafeText))
            continuation.yield(.done(usage: self.response.usage, finishReason: .length))
            continuation.finish()
        }
    }

    private var response: ProviderResponse {
        ProviderResponse(
            text: Self.unsafeText,
            usage: Usage(
                inputTokens: 8,
                outputTokens: 5,
                cost: .init(input: 0.2, output: 0.1)),
            finishReason: .length)
    }
}

@MainActor
private final class StepLimitEventDelegate: AgentEventDelegate {
    private(set) var events: [AgentEvent] = []

    func agentDidEmitEvent(_ event: AgentEvent) {
        self.events.append(event)
    }
}

extension [AgentEvent] {
    fileprivate var containsCompletedEvent: Bool {
        self.contains { event in
            if case .completed = event {
                true
            } else {
                false
            }
        }
    }

    fileprivate var containsToolEvent: Bool {
        self.contains { event in
            switch event {
            case .toolCallStarted, .toolCallUpdated, .toolCallCompleted:
                true
            default:
                false
            }
        }
    }
}

extension [ModelMessage] {
    fileprivate func containsText(_ expected: String) -> Bool {
        self.contains { message in
            message.content.contains { part in
                if case let .text(text) = part {
                    text == expected
                } else {
                    false
                }
            }
        }
    }

    fileprivate func containsToolCall(id: String) -> Bool {
        self.contains { message in
            message.content.contains { part in
                if case let .toolCall(toolCall) = part {
                    toolCall.id == id
                } else {
                    false
                }
            }
        }
    }

    fileprivate func containsToolResult(id: String) -> Bool {
        self.contains { message in
            message.content.contains { part in
                if case let .toolResult(toolResult) = part {
                    toolResult.toolCallId == id
                } else {
                    false
                }
            }
        }
    }
}
