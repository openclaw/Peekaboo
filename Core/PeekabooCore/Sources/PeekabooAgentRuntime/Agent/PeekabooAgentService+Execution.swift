//
//  PeekabooAgentService+Execution.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation
import PeekabooFoundation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    func generationSettings(for model: LanguageModel) -> GenerationSettings {
        let maxTokens = self.configuredMaxTokens(for: model)
        let temperature = self.shouldOmitTemperature(for: model) ? nil : self.configuredTemperature(for: model)

        return switch model {
        case .openai(.gpt56Sol), .openai(.gpt56Terra), .openai(.gpt56Luna),
             .openai(.gpt55), .openai(.gpt54), .openai(.gpt54Mini), .openai(.gpt54Nano), .openai(.gpt5):
            GenerationSettings(
                maxTokens: maxTokens,
                temperature: temperature,
                providerOptions: .init(openai: .init(verbosity: .medium)))
        case .anthropic:
            GenerationSettings(maxTokens: maxTokens, temperature: temperature)
        case .google:
            GenerationSettings(maxTokens: maxTokens, temperature: temperature)
        default:
            GenerationSettings(maxTokens: maxTokens, temperature: temperature)
        }
    }

    private func configuredMaxTokens(for model: LanguageModel) -> Int {
        let configuredMaxTokens = self.services.configuration.getAgentMaxTokens()
        let providerMaxTokens = self.maxOutputTokens(for: model)
        return max(1, min(configuredMaxTokens, providerMaxTokens))
    }

    private func configuredTemperature(for model: LanguageModel) -> Double {
        let configuredTemperature = self.services.configuration.getAgentTemperature()
        guard configuredTemperature.isFinite else { return 0.7 }
        let maxTemperature = switch model {
        case .anthropic, .anthropicCompatible:
            1.0
        case let .custom(provider):
            if self.customProviderUsesAnthropicTemperatureLimit(provider) {
                1.0
            } else {
                2.0
            }
        default:
            2.0
        }
        return min(maxTemperature, max(0.0, configuredTemperature))
    }

    private func customProviderUsesAnthropicTemperatureLimit(_ provider: any ModelProvider) -> Bool {
        if provider is AnthropicProvider || provider is AnthropicCompatibleProvider {
            return true
        }

        guard let parsed = ProviderParser.parse(provider.modelId) else {
            return false
        }

        if CustomProviderRegistry.shared.get(parsed.provider)?.kind == .anthropic {
            return true
        }

        return self.services.configuration.getCustomProvider(id: parsed.provider)?.type == .anthropic
    }

    private func shouldOmitTemperature(for model: LanguageModel) -> Bool {
        switch model {
        case let .openRouter(modelId), let .together(modelId), let .openaiCompatible(modelId, _):
            return self.isOpenAIGPT5TemperatureExcludedModel(modelId)
        case let .custom(provider):
            guard let parsed = ProviderParser.parse(provider.modelId) else {
                return false
            }

            let isOpenAICompatible = CustomProviderRegistry.shared.get(parsed.provider)?.kind == .openai ||
                self.services.configuration.getCustomProvider(id: parsed.provider)?.type == .openai
            return isOpenAICompatible && self.isOpenAIGPT5TemperatureExcludedModel(parsed.model)
        default:
            return false
        }
    }

    private func isOpenAIGPT5TemperatureExcludedModel(_ modelId: String) -> Bool {
        if LanguageModel.OpenAI.gpt56Model(for: modelId) != nil {
            return true
        }

        return switch self.normalizedOpenAIModelID(modelId) {
        case "chat-latest",
             "gpt-5.5",
             "gpt-5.4",
             "gpt-5.4-mini",
             "gpt-5.4-nano",
             "gpt-5",
             "gpt-5-pro",
             "gpt-5-mini",
             "gpt-5-nano":
            true
        default:
            false
        }
    }

    private func normalizedOpenAIModelID(_ modelId: String) -> String {
        let normalized = modelId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parsed = ProviderParser.parse(normalized) else {
            return normalized
        }

        switch parsed.provider.lowercased() {
        case "openai", "chatgpt":
            return self.normalizedOpenAIModelID(parsed.model)
        default:
            return normalized
        }
    }

    private func maxOutputTokens(for model: LanguageModel) -> Int {
        switch model {
        case let .openai(openAIModel):
            switch openAIModel {
            case .chatLatest,
                 .gpt56Sol,
                 .gpt56Terra,
                 .gpt56Luna,
                 .gpt55,
                 .gpt54,
                 .gpt54Mini,
                 .gpt54Nano,
                 .gpt5,
                 .gpt5Pro,
                 .gpt5Mini,
                 .gpt5Nano:
                128_000
            case .gpt5ChatLatest:
                16384
            case .custom:
                4096
            }
        case let .anthropic(anthropicModel):
            anthropicModel.maxOutputTokens
        case let .custom(provider):
            provider.capabilities.maxOutputTokens
        case .google:
            8192
        case .minimax, .minimaxCN:
            8192
        case .kimi:
            32768
        case .mistral, .groq, .grok, .ollama, .lmstudio, .azureOpenAI, .replicate:
            4096
        case let .openRouter(modelId), let .together(modelId), let .openaiCompatible(modelId, _):
            if let maxOutputTokens = AnthropicModelCapabilityInference.capabilities(for: modelId)?.maxOutputTokens {
                maxOutputTokens
            } else {
                LanguageModel.OpenAI.gpt56Model(for: modelId) == nil ? 4096 : 128_000
            }
        case let .anthropicCompatible(modelId, _):
            AnthropicModelCapabilityInference.capabilities(for: modelId)?.maxOutputTokens ?? 8192
        }
    }

    func makeAudioDryRunResult(description: String) -> AgentExecutionResult {
        let now = Date()
        return AgentExecutionResult(
            content: "Dry run completed. Audio task: \(description)",
            messages: [],
            sessionId: UUID().uuidString,
            usage: nil,
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 0,
                modelName: self.defaultModelDisplayName,
                startTime: now,
                endTime: now))
    }

    func executeAudioStreamingTask(
        input: String,
        maxSteps: Int,
        queueMode: QueueMode,
        eventDelegate: any AgentEventDelegate) async throws -> AgentExecutionResult
    {
        let unsafeDelegate = UnsafeTransfer<any AgentEventDelegate>(eventDelegate)
        let (eventStream, eventContinuation) = AsyncStream<AgentEvent>.makeStream()

        let eventTask = Task { @MainActor in
            let delegate = unsafeDelegate.wrappedValue
            delegate.agentDidEmitEvent(.started(task: input))
            for await event in eventStream {
                delegate.agentDidEmitEvent(event)
            }
        }

        let eventHandler = EventHandler { event in
            eventContinuation.yield(event)
        }

        let streamingDelegate = await MainActor.run {
            StreamingEventDelegate { chunk in
                await eventHandler.send(.assistantMessage(content: chunk))
            }
        }

        do {
            let sessionContext = try await self.prepareSession(
                task: input,
                model: self.defaultLanguageModel,
                label: "audio-stream",
                logBehavior: .always)

            let result = if self.defaultLanguageModel.supportsStreaming {
                try await self.executeWithStreaming(
                    context: sessionContext,
                    model: self.defaultLanguageModel,
                    maxSteps: maxSteps,
                    streamingDelegate: streamingDelegate,
                    queueMode: queueMode,
                    eventHandler: eventHandler)
            } else {
                try await self.executeWithoutStreaming(
                    context: sessionContext,
                    model: self.defaultLanguageModel,
                    maxSteps: maxSteps,
                    eventHandler: eventHandler)
            }

            await eventHandler.send(.completed(summary: result.content, usage: result.usage))
            eventContinuation.finish()
            await eventTask.value
            return result
        } catch let error as CancellationError {
            eventContinuation.finish()
            await eventTask.value
            throw error
        } catch {
            await eventHandler.send(.error(message: error.localizedDescription))
            eventContinuation.finish()
            await eventTask.value
            throw error
        }
    }
}

// MARK: - Event Handler

actor EventHandler {
    private let handler: @Sendable (AgentEvent) async -> Void

    init(handler: @escaping @Sendable (AgentEvent) async -> Void) {
        self.handler = handler
    }

    func send(_ event: AgentEvent) async {
        await self.handler(event)
    }
}

// MARK: - Unsafe Transfer

/// Safely transfer non-Sendable values across isolation boundaries
struct UnsafeTransfer<T>: @unchecked Sendable {
    let wrappedValue: T

    init(_ value: T) {
        self.wrappedValue = value
    }
}

@available(macOS 14.0, *)
extension PeekabooAgentService {
    // MARK: - Helper Functions

    /// Parse a model string and return a mock model object for compatibility
    func parseModelString(_ modelString: String) async throws -> Any {
        // This is a compatibility stub - in the new API we use LanguageModel enum directly
        modelString
    }

    /// Execute task using direct streamText calls with event streaming
    func executeWithStreaming(
        context: SessionContext,
        model: LanguageModel,
        maxSteps: Int = 20,
        streamingDelegate: StreamingEventDelegate,
        queueMode: QueueMode = .oneAtATime,
        eventHandler: EventHandler? = nil,
        enhancementOptions: AgentEnhancementOptions? = nil) async throws -> AgentExecutionResult
    {
        let maxSteps = try AgentStepBudget.validate(maxSteps)
        _ = streamingDelegate
        let tools = await self.buildToolset(for: model)
        self.logModelUsage(model, prefix: "Streaming ")
        guard let provider = context.provider else {
            throw PeekabooError.invalidInput("The session has no verified model provider; refusing to execute it.")
        }

        let configuration = StreamingLoopConfiguration(
            model: model,
            provider: provider,
            tools: tools,
            sessionId: context.id,
            eventHandler: eventHandler,
            enhancementOptions: enhancementOptions)

        var latestCheckpoint = self.makeLoopOutcome(
            state: StreamingLoopState(messages: context.messages),
            reachedStepLimit: false)
        let outcome: StreamingLoopOutcome
        do {
            outcome = try await self.runStreamingLoop(
                configuration: configuration,
                maxSteps: maxSteps,
                initialMessages: context.messages,
                queueMode: queueMode)
            { latestCheckpoint = $0 }
        } catch {
            let wasCancelled = self.isAgentCancellation(error)
            self.preserveExecutionCheckpoint(
                context: context,
                model: model,
                checkpoint: latestCheckpoint,
                status: wasCancelled ? "cancelled" : "failed")
            if wasCancelled {
                throw CancellationError()
            }
            throw error
        }

        let endTime = Date()
        let executionTime = endTime.timeIntervalSince(context.executionStart)
        let toolCallCount = outcome.toolCallCount

        try self.saveExecutionSession(
            context: context,
            model: model,
            finalMessages: outcome.messages,
            endTime: endTime,
            toolCallCount: toolCallCount,
            usage: outcome.usage,
            status: outcome.reachedStepLimit ? "max_steps_exhausted" : "completed")

        if outcome.reachedStepLimit {
            throw AgentStepLimitExceededError(maxSteps: maxSteps, sessionId: context.id)
        }

        return AgentExecutionResult(
            content: outcome.content,
            messages: outcome.messages,
            sessionId: context.id,
            usage: outcome.usage,
            metadata: self.makeExecutionMetadata(
                model: model,
                executionTime: executionTime,
                toolCallCount: toolCallCount,
                startTime: context.executionStart,
                endTime: endTime))
    }

    /// Execute task using direct generateText calls without streaming
    func executeWithoutStreaming(
        context: SessionContext,
        model: LanguageModel,
        maxSteps: Int = 20,
        eventHandler: EventHandler? = nil,
        enhancementOptions: AgentEnhancementOptions? = nil) async throws -> AgentExecutionResult
    {
        let maxSteps = try AgentStepBudget.validate(maxSteps)
        let tools = await self.buildToolset(for: model)
        self.logModelUsage(model, prefix: "")
        guard let provider = context.provider else {
            throw PeekabooError.invalidInput("The session has no verified model provider; refusing to execute it.")
        }

        let configuration = StreamingLoopConfiguration(
            model: model,
            provider: provider,
            tools: tools,
            sessionId: context.id,
            eventHandler: eventHandler,
            enhancementOptions: enhancementOptions)

        var latestCheckpoint = self.makeLoopOutcome(
            state: StreamingLoopState(messages: context.messages),
            reachedStepLimit: false)
        let outcome: StreamingLoopOutcome
        do {
            outcome = try await self.runGenerationLoop(
                configuration: configuration,
                maxSteps: maxSteps,
                initialMessages: context.messages)
            { latestCheckpoint = $0 }
        } catch {
            let wasCancelled = self.isAgentCancellation(error)
            self.preserveExecutionCheckpoint(
                context: context,
                model: model,
                checkpoint: latestCheckpoint,
                status: wasCancelled ? "cancelled" : "failed")
            if wasCancelled {
                throw CancellationError()
            }
            throw error
        }

        let endTime = Date()
        let executionTime = endTime.timeIntervalSince(context.executionStart)

        try self.saveExecutionSession(
            context: context,
            model: model,
            finalMessages: outcome.messages,
            endTime: endTime,
            toolCallCount: outcome.toolCallCount,
            usage: outcome.usage,
            status: outcome.reachedStepLimit ? "max_steps_exhausted" : "completed")

        if outcome.reachedStepLimit {
            throw AgentStepLimitExceededError(maxSteps: maxSteps, sessionId: context.id)
        }

        return AgentExecutionResult(
            content: outcome.content,
            messages: outcome.messages,
            sessionId: context.id,
            usage: outcome.usage,
            metadata: self.makeExecutionMetadata(
                model: model,
                executionTime: executionTime,
                toolCallCount: outcome.toolCallCount,
                startTime: context.executionStart,
                endTime: endTime))
    }

    func runGenerationLoop(
        configuration: StreamingLoopConfiguration,
        maxSteps: Int,
        initialMessages: [ModelMessage],
        onCheckpoint: ((StreamingLoopOutcome) -> Void)? = nil) async throws -> StreamingLoopOutcome
    {
        var state = StreamingLoopState(messages: initialMessages)
        let toolContext = ToolHandlingContext(
            model: configuration.model,
            tools: configuration.tools,
            eventHandler: configuration.eventHandler,
            sessionId: configuration.sessionId,
            enhancementOptions: configuration.enhancementOptions)

        let resolvedConfiguration = TachikomaConfiguration.resolve(.current)
        let provider = configuration.provider
        var usageAccumulator = AgentUsageAccumulator()
        var reachedStepLimit = false

        for stepIndex in 0..<maxSteps {
            try Task.checkCancellation()
            self.logStreamingStepStart(stepIndex, tools: configuration.tools)

            if let options = configuration.enhancementOptions {
                _ = await self.refreshDesktopContextIfNeeded(
                    into: &state.messages,
                    options: options,
                    tools: configuration.tools,
                    state: &state.desktopContextState,
                    eventHandler: configuration.eventHandler)
            }
            try Task.checkCancellation()

            let request = ProviderRequest(
                messages: state.messages.sanitizedForProviderContext(
                    model: configuration.model,
                    configuration: resolvedConfiguration,
                    peekabooConfiguration: self.services.configuration,
                    provider: provider),
                tools: configuration.tools.isEmpty ? nil : configuration.tools,
                settings: self.generationSettings(for: configuration.model))
            let response = try await provider.generateText(request: request)

            if let usage = response.usage {
                state.usage = usageAccumulator.record(usage)
                onCheckpoint?(self.makeLoopOutcome(state: state, reachedStepLimit: false))
            }
            try Task.checkCancellation()

            let toolCalls = response.toolCalls ?? []
            try self.validateToolContinuationFinishReason(
                response.finishReason,
                hasToolCalls: !toolCalls.isEmpty)
            if toolCalls.isEmpty {
                try self.validateTerminalResponse(text: response.text)
            }

            state.content += response.text
            if !response.text.isEmpty {
                await configuration.eventHandler?.send(.assistantMessage(content: response.text))
            }
            try Task.checkCancellation()

            let recordedAssistantTurn = self.appendResponseHistory(
                from: response,
                model: configuration.model,
                configuration: resolvedConfiguration,
                peekabooConfiguration: self.services.configuration,
                provider: provider,
                to: &state.messages)

            if toolCalls.isEmpty {
                self.appendFinalStep(
                    text: response.text,
                    to: &state.messages,
                    steps: &state.steps,
                    stepIndex: stepIndex,
                    appendMessage: !recordedAssistantTurn)
                break
            }

            var cancellationStep: GenerationStep?
            let step: GenerationStep
            do {
                step = try await self.handleToolCalls(
                    stepText: response.text,
                    toolCalls: toolCalls,
                    context: toolContext,
                    currentMessages: &state.messages,
                    stepIndex: stepIndex,
                    appendAssistantMessage: !recordedAssistantTurn,
                    emitToolStartEvents: true,
                    onCancellationCheckpoint: { cancellationStep = $0 })
            } catch {
                if self.isAgentCancellation(error), let cancellationStep {
                    state.steps.append(cancellationStep)
                    state.toolCallCount += cancellationStep.toolResults.count
                    onCheckpoint?(self.makeLoopOutcome(state: state, reachedStepLimit: false))
                    throw CancellationError()
                }
                throw error
            }
            state.steps.append(step)
            state.toolCallCount += step.toolResults.count
            onCheckpoint?(self.makeLoopOutcome(state: state, reachedStepLimit: false))

            if let stopReason = self.turnBoundaryStopReason(from: step.toolResults) {
                state.content = self.contentByAppendingTurnBoundaryReason(
                    stopReason,
                    to: state.content)
                break
            }

            if stepIndex == maxSteps - 1 {
                reachedStepLimit = true
            }
        }

        return self.makeLoopOutcome(state: state, reachedStepLimit: reachedStepLimit)
    }
}
