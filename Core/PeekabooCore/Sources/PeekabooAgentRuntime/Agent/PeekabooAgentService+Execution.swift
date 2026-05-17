//
//  PeekabooAgentService+Execution.swift
//  PeekabooCore
//

import Foundation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    func generationSettings(for model: LanguageModel) -> GenerationSettings {
        switch model {
        case .openai(.gpt55), .openai(.gpt54), .openai(.gpt54Mini), .openai(.gpt54Nano), .openai(.gpt5):
            GenerationSettings(
                maxTokens: 4096,
                providerOptions: .init(openai: .init(verbosity: .medium)))
        case .anthropic:
            GenerationSettings(maxTokens: 4096)
        case .google:
            GenerationSettings(maxTokens: 4096)
        default:
            GenerationSettings(maxTokens: 4096)
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
                modelName: self.defaultLanguageModel.description,
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
            for await event in eventStream {
                delegate.agentDidEmitEvent(event)
            }
        }

        let eventHandler = EventHandler { event in
            eventContinuation.yield(event)
        }

        defer {
            eventContinuation.finish()
            eventTask.cancel()
        }

        let streamingDelegate = await MainActor.run {
            StreamingEventDelegate { chunk in
                await eventHandler.send(.assistantMessage(content: chunk))
            }
        }

        let sessionContext = try await self.prepareSession(
            task: input,
            model: self.defaultLanguageModel,
            label: "audio-stream",
            logBehavior: .always)

        let result = try await self.executeWithStreaming(
            context: sessionContext,
            model: self.defaultLanguageModel,
            maxSteps: maxSteps,
            streamingDelegate: streamingDelegate,
            queueMode: queueMode,
            eventHandler: eventHandler)

        await eventHandler.send(.completed(summary: result.content, usage: result.usage))
        return result
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
        _ = streamingDelegate
        let tools = await self.buildToolset(for: model)
        self.logModelUsage(model, prefix: "Streaming ")

        let configuration = StreamingLoopConfiguration(
            model: model,
            tools: tools,
            sessionId: context.id,
            eventHandler: eventHandler,
            enhancementOptions: enhancementOptions)

        let outcome = try await self.runStreamingLoop(
            configuration: configuration,
            maxSteps: maxSteps,
            initialMessages: context.messages,
            queueMode: queueMode)

        let endTime = Date()
        let executionTime = endTime.timeIntervalSince(context.executionStart)
        let toolCallCount = outcome.toolCallCount

        try self.saveCompletedSession(
            context: context,
            model: model,
            finalMessages: outcome.messages,
            endTime: endTime,
            toolCallCount: toolCallCount,
            usage: outcome.usage)

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
        enhancementOptions: AgentEnhancementOptions? = nil) async throws -> AgentExecutionResult
    {
        let tools = await self.buildToolset(for: model)
        self.logModelUsage(model, prefix: "")

        let configuration = StreamingLoopConfiguration(
            model: model,
            tools: tools,
            sessionId: context.id,
            eventHandler: nil,
            enhancementOptions: enhancementOptions)

        let outcome = try await self.runGenerationLoop(
            configuration: configuration,
            maxSteps: maxSteps,
            initialMessages: context.messages)

        let endTime = Date()
        let executionTime = endTime.timeIntervalSince(context.executionStart)

        try self.saveCompletedSession(
            context: context,
            model: model,
            finalMessages: outcome.messages,
            endTime: endTime,
            toolCallCount: outcome.toolCallCount,
            usage: outcome.usage)

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
        initialMessages: [ModelMessage]) async throws -> StreamingLoopOutcome
    {
        var state = StreamingLoopState(messages: initialMessages)
        let toolContext = ToolHandlingContext(
            model: configuration.model,
            tools: configuration.tools,
            eventHandler: configuration.eventHandler,
            sessionId: configuration.sessionId,
            enhancementOptions: configuration.enhancementOptions)

        let resolvedConfiguration = TachikomaConfiguration.resolve(.current)
        let provider = try resolvedConfiguration.makeProvider(for: configuration.model)
        var totalInputTokens = 0
        var totalOutputTokens = 0
        var totalInputCost = 0.0
        var totalOutputCost = 0.0
        var hasUsage = false

        for stepIndex in 0..<maxSteps {
            self.logStreamingStepStart(stepIndex, tools: configuration.tools)

            if let options = configuration.enhancementOptions {
                _ = await self.refreshDesktopContextIfNeeded(
                    into: &state.messages,
                    options: options,
                    tools: configuration.tools,
                    state: &state.desktopContextState,
                    eventHandler: configuration.eventHandler)
            }

            let request = ProviderRequest(
                messages: state.messages,
                tools: configuration.tools.isEmpty ? nil : configuration.tools,
                settings: self.generationSettings(for: configuration.model))
            let response = try await provider.generateText(request: request)

            state.content += response.text
            if let usage = response.usage {
                hasUsage = true
                totalInputTokens += usage.inputTokens
                totalOutputTokens += usage.outputTokens
                if let cost = usage.cost {
                    totalInputCost += cost.input
                    totalOutputCost += cost.output
                }
                let totalCost = totalInputCost > 0 || totalOutputCost > 0
                    ? Usage.Cost(input: totalInputCost, output: totalOutputCost)
                    : nil
                state.usage = Usage(inputTokens: totalInputTokens, outputTokens: totalOutputTokens, cost: totalCost)
            }

            let toolCalls = response.toolCalls ?? []
            if toolCalls.isEmpty {
                self.appendFinalStep(
                    text: response.text,
                    to: &state.messages,
                    steps: &state.steps,
                    stepIndex: stepIndex)
                break
            }

            let step = try await self.handleToolCalls(
                stepText: response.text,
                toolCalls: toolCalls,
                context: toolContext,
                currentMessages: &state.messages,
                stepIndex: stepIndex)
            state.steps.append(step)
            state.toolCallCount += step.toolResults.count

            if let stopReason = self.turnBoundaryStopReason(from: step.toolResults) {
                if state.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    state.content = stopReason
                }
                break
            }

            if response.finishReason != .toolCalls, response.finishReason != .stop {
                break
            }
        }

        if !hasUsage {
            state.usage = nil
        }

        return StreamingLoopOutcome(
            content: state.content,
            messages: state.messages,
            steps: state.steps,
            usage: state.usage,
            toolCallCount: state.toolCallCount)
    }
}
