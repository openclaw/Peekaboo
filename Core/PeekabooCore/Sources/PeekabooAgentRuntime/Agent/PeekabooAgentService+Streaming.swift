//
//  PeekabooAgentService+Streaming.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    struct StreamingLoopOutcome {
        let content: String
        let messages: [ModelMessage]
        let steps: [GenerationStep]
        let usage: Usage?
        let toolCallCount: Int
        let reachedStepLimit: Bool
    }

    public struct AgentStepLimitExceededError: LocalizedError, Sendable {
        public let maxSteps: Int
        public let sessionId: String
        public let sessionWasPersisted: Bool

        public init(maxSteps: Int, sessionId: String, sessionWasPersisted: Bool = true) {
            self.maxSteps = maxSteps
            self.sessionId = sessionId
            self.sessionWasPersisted = sessionWasPersisted
        }

        public var errorDescription: String? {
            let resumeGuidance = if self.sessionWasPersisted {
                "Session \(self.sessionId) was saved and can be resumed to continue."
            } else {
                "Session caching was disabled, so this run cannot be resumed."
            }
            guard self.maxSteps < AgentStepBudget.supportedRange.upperBound else {
                return "Agent reached the \(self.maxSteps)-step limit after executing tools whose results still " +
                    "require model review. \(resumeGuidance)"
            }
            return "Agent reached the \(self.maxSteps)-step limit after executing tools whose results still " +
                "require model review. \(resumeGuidance) You can also retry with a larger --max-steps value " +
                "(maximum \(AgentStepBudget.supportedRange.upperBound))."
        }
    }

    struct StreamingLoopConfiguration {
        let model: LanguageModel
        let provider: any ModelProvider
        let tools: [AgentTool]
        let sessionId: String
        let eventHandler: EventHandler?
        let enhancementOptions: AgentEnhancementOptions?
        let executionPolicy: MCPToolExecutionPolicy

        init(
            model: LanguageModel,
            provider: any ModelProvider,
            tools: [AgentTool],
            sessionId: String,
            eventHandler: EventHandler?,
            enhancementOptions: AgentEnhancementOptions?,
            executionPolicy: MCPToolExecutionPolicy = .backgroundOnly)
        {
            self.model = model
            self.provider = provider
            self.tools = tools
            self.sessionId = sessionId
            self.eventHandler = eventHandler
            self.enhancementOptions = enhancementOptions
            self.executionPolicy = executionPolicy
        }
    }

    @MainActor
    struct ToolHandlingContext {
        let model: LanguageModel
        let supportsVision: Bool
        let tools: [AgentTool]
        let eventHandler: EventHandler?
        let sessionId: String
        let imageContextID: String
        let turnBoundary: AgentTurnBoundary
        let enhancementOptions: AgentEnhancementOptions?
        let executionPolicy: MCPToolExecutionPolicy

        init(
            model: LanguageModel,
            providerSupportsVision: Bool? = nil,
            tools: [AgentTool],
            eventHandler: EventHandler?,
            sessionId: String,
            imageContextID: String = UUID().uuidString,
            initialMessages: [ModelMessage] = [],
            enhancementOptions: AgentEnhancementOptions? = nil,
            executionPolicy: MCPToolExecutionPolicy = .backgroundOnly)
        {
            self.model = model
            self.supportsVision = model.supportsVision && (providerSupportsVision ?? true)
            self.tools = tools
            self.eventHandler = eventHandler
            self.sessionId = sessionId
            self.imageContextID = imageContextID
            self.turnBoundary = PeekabooAgentService.restoredTurnBoundary(from: initialMessages)
            self.enhancementOptions = enhancementOptions
            self.executionPolicy = executionPolicy
        }

        func tool(named name: String) -> AgentTool? {
            self.tools.first { $0.name == name }
        }
    }

    private struct ToolCallExecutionOptions {
        let stepIndex: Int
        let allowSuccessfulToolBoundary: Bool
    }

    private struct ToolResultCancellationContext {
        let stepIndex: Int
        let stepText: String
        let toolCalls: [AgentToolCall]
        let handlingContext: ToolHandlingContext
        let emitToolStartEvents: Bool
        let checkpoint: ((GenerationStep) -> Void)?
    }

    struct StreamingLoopState {
        var messages: [ModelMessage]
        var content: String = ""
        var steps: [GenerationStep] = []
        var usage: Usage?
        var toolCallCount: Int = 0
        var desktopContextState = DesktopContextRefreshState()
    }

    struct AgentUsageAccumulator {
        private var inputTokens = 0
        private var outputTokens = 0
        private var inputCost = 0.0
        private var outputCost = 0.0
        private var allCostsKnown = true

        mutating func record(_ usage: Usage) -> Usage {
            self.inputTokens += usage.inputTokens
            self.outputTokens += usage.outputTokens
            if let cost = usage.cost {
                self.inputCost += cost.input
                self.outputCost += cost.output
            } else {
                self.allCostsKnown = false
            }

            return Usage(
                inputTokens: self.inputTokens,
                outputTokens: self.outputTokens,
                cost: self.allCostsKnown ? Usage.Cost(input: self.inputCost, output: self.outputCost) : nil)
        }
    }

    func runStreamingLoop(
        configuration: StreamingLoopConfiguration,
        maxSteps: Int,
        initialMessages: [ModelMessage],
        queueMode: QueueMode = .oneAtATime,
        pendingUserMessages: [ModelMessage] = [],
        imageContextID: String = UUID().uuidString,
        imageStore: AgentToolMCPImageStore = .shared,
        onCheckpoint: ((StreamingLoopOutcome) -> Void)? = nil) async throws -> StreamingLoopOutcome
    {
        let toolContext = ToolHandlingContext(
            model: configuration.model,
            providerSupportsVision: configuration.provider.capabilities.supportsVision,
            tools: configuration.tools,
            eventHandler: configuration.eventHandler,
            sessionId: configuration.sessionId,
            imageContextID: imageContextID,
            initialMessages: initialMessages,
            enhancementOptions: configuration.enhancementOptions,
            executionPolicy: configuration.executionPolicy)
        return try await self.withAgentToolImageLifecycle(
            executionID: imageContextID,
            imageStore: imageStore)
        {
            try await self.runStreamingLoopBody(
                configuration: configuration,
                maxSteps: maxSteps,
                initialMessages: initialMessages,
                queueMode: queueMode,
                pendingUserMessages: pendingUserMessages,
                toolContext: toolContext,
                onCheckpoint: onCheckpoint)
        }
    }

    // swiftlint:disable:next function_parameter_count
    private func runStreamingLoopBody(
        configuration: StreamingLoopConfiguration,
        maxSteps: Int,
        initialMessages: [ModelMessage],
        queueMode: QueueMode,
        pendingUserMessages: [ModelMessage],
        toolContext: ToolHandlingContext,
        onCheckpoint: ((StreamingLoopOutcome) -> Void)?) async throws -> StreamingLoopOutcome
    {
        var state = StreamingLoopState(messages: initialMessages)
        let resolvedConfiguration = TachikomaConfiguration.resolve(.current)

        // Queue of pending user messages (set by caller). For now, this is empty
        // and will be injected by higher-level chat loop when we add that support.
        var queuedMessages: [ModelMessage] = pendingUserMessages
        var reachedStepLimit = false
        var usageAccumulator = AgentUsageAccumulator()

        for stepIndex in 0..<maxSteps {
            try Task.checkCancellation()
            self.logStreamingStepStart(stepIndex, tools: configuration.tools)

            // If queue mode is "all" and we have queued messages, inject them
            // before the next turn so the model sees them together.
            if queueMode == .all, !queuedMessages.isEmpty {
                state.messages.append(contentsOf: queuedMessages)
                queuedMessages.removeAll()
            }

            if let options = configuration.enhancementOptions {
                _ = await self.refreshDesktopContextIfNeeded(
                    into: &state.messages,
                    options: options,
                    tools: configuration.tools,
                    state: &state.desktopContextState,
                    eventHandler: configuration.eventHandler)
            }
            try Task.checkCancellation()

            let streamResult = try await streamText(
                model: configuration.model,
                provider: configuration.provider,
                messages: state.messages,
                tools: configuration.tools.isEmpty ? nil : configuration.tools,
                settings: self.generationSettings(for: configuration.model))

            var terminalUsage: Usage?
            let output: StreamProcessingOutput
            do {
                output = try await self.collectStreamOutput(
                    from: streamResult,
                    model: configuration.model,
                    eventHandler: configuration.eventHandler,
                    stepIndex: stepIndex,
                    onTerminalUsage: { terminalUsage = $0 })
            } catch {
                if let terminalUsage {
                    state.usage = usageAccumulator.record(terminalUsage)
                    onCheckpoint?(self.makeLoopOutcome(state: state, reachedStepLimit: false))
                }
                throw error
            }
            state.messages.removeConsumedAgentToolImageContext()
            if let terminalUsage {
                state.usage = usageAccumulator.record(terminalUsage)
                onCheckpoint?(self.makeLoopOutcome(state: state, reachedStepLimit: false))
            }
            if output.toolCalls.isEmpty {
                try Task.checkCancellation()
            }

            let shouldReplayReasoning = ReasoningReplayTarget(
                model: configuration.model,
                configuration: resolvedConfiguration,
                peekabooConfiguration: self.services.configuration,
                provider: configuration.provider) != nil
            if shouldReplayReasoning {
                for block in output.reasoningBlocks {
                    self.appendReasoningBlock(
                        ProviderReasoningBlock(
                            text: block.text,
                            signature: block.signature,
                            type: block.type),
                        model: configuration.model,
                        configuration: resolvedConfiguration,
                        peekabooConfiguration: self.services.configuration,
                        provider: configuration.provider,
                        to: &state.messages)
                }
            }

            try self.validateToolContinuationFinishReason(
                output.finishReason,
                hasToolCalls: !output.toolCalls.isEmpty)

            if output.toolCalls.isEmpty {
                try self.validateTerminalResponse(
                    text: output.text,
                    availableToolNames: Set(configuration.tools.map(\.name)))
                if self.handleTerminalResponse(
                    output.text,
                    boundary: toolContext.turnBoundary,
                    state: &state,
                    stepIndex: stepIndex)
                {
                    break
                }
                reachedStepLimit = stepIndex == maxSteps - 1
                onCheckpoint?(self.makeLoopOutcome(state: state, reachedStepLimit: reachedStepLimit))
                continue
            }

            state.content += output.text

            var cancellationStep: GenerationStep?
            let step: GenerationStep
            do {
                step = try await self.handleToolCalls(
                    stepText: output.text,
                    toolCalls: output.toolCalls,
                    context: toolContext,
                    currentMessages: &state.messages,
                    stepIndex: stepIndex,
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

            if let boundarySignal = self.turnBoundarySignal(from: step.toolResults) {
                switch boundarySignal {
                case .continueNextStep:
                    // Force context-aware runs to refresh after a UI mutation before the next model step.
                    state.desktopContextState.lastFingerprint = nil
                case let .stopAgent(reason):
                    state.content = self.contentByAppendingTurnBoundaryReason(reason, to: state.content)
                }
                if case .stopAgent = boundarySignal {
                    break
                }
            }

            if stepIndex == maxSteps - 1 {
                reachedStepLimit = true
            }

            // If queue mode is one-at-a-time, inject exactly one queued message (if any)
            if queueMode == .oneAtATime, let next = queuedMessages.first {
                state.messages.append(next)
                queuedMessages.removeFirst()
            }
        }

        return self.makeLoopOutcome(state: state, reachedStepLimit: reachedStepLimit)
    }

    func validateToolContinuationFinishReason(
        _ finishReason: FinishReason?,
        hasToolCalls: Bool) throws
    {
        if finishReason == .contentFilter {
            throw TachikomaError.apiError("Model refused to answer")
        }

        if finishReason == .toolCalls, !hasToolCalls {
            throw TachikomaError.apiError(
                "Model reported a tool-call finish reason, but no tool calls were decoded; " +
                    "refusing to treat the response as complete.")
        }

        switch finishReason {
        case nil, .toolCalls, .stop:
            return
        case .contentFilter:
            preconditionFailure("Content-filter responses are rejected before tool-finish validation")
        case let finishReason?:
            if hasToolCalls {
                throw TachikomaError.apiError(
                    "Model returned tool calls with finish reason '\(finishReason.rawValue)'; " +
                        "refusing to execute incomplete tool calls.")
            }
            throw TachikomaError.apiError(
                "Model returned a terminal response with finish reason '\(finishReason.rawValue)'; " +
                    "refusing to mark the task complete.")
        }
    }

    func validateTerminalResponse(text: String, availableToolNames: Set<String>) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TachikomaError.apiError(
                "Model returned an empty terminal response; refusing to mark the task complete.")
        }

        for candidate in Self.terminalJSONCandidates(from: trimmed) {
            let serializedCandidates = [candidate, Self.removingJSONComments(from: candidate)]
            for serialized in serializedCandidates {
                guard let data = serialized.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data)
                else {
                    continue
                }
                if Self.containsUnexecutedToolCall(object, availableToolNames: availableToolNames) {
                    throw TachikomaError.apiError(
                        "Model returned an unexecuted tool call as terminal text; refusing to mark the task complete.")
                }
            }
        }
    }

    private static func terminalJSONCandidates(from text: String) -> [String] {
        var candidates = [text]
        var searchStart = text.startIndex
        while let opening = text.range(of: "```", range: searchStart..<text.endIndex),
              let firstNewline = text[opening.upperBound...].firstIndex(of: "\n"),
              let closing = text.range(of: "```", range: text.index(after: firstNewline)..<text.endIndex)
        {
            let language = text[opening.upperBound..<firstNewline]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if language.isEmpty || language == "json" || language == "jsonc" {
                candidates.append(
                    text[text.index(after: firstNewline)..<closing.lowerBound]
                        .trimmingCharacters(in: .whitespacesAndNewlines))
            }
            searchStart = closing.upperBound
        }
        for fragment in self.balancedJSONFragments(in: text) where !candidates.contains(fragment) {
            candidates.append(fragment)
        }
        return candidates
    }

    private static func balancedJSONFragments(in text: String) -> [String] {
        var fragments: [String] = []
        var start: String.Index?
        var stack: [Character] = []
        var inString = false
        var escaped = false

        for index in text.indices {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            if character == "\"", start != nil {
                inString = true
                continue
            }
            if character == "{" || character == "[" {
                if start == nil {
                    start = index
                }
                stack.append(character)
                continue
            }
            guard let fragmentStart = start, character == "}" || character == "]" else { continue }
            let expectedOpening: Character = character == "}" ? "{" : "["
            guard stack.last == expectedOpening else {
                start = nil
                stack.removeAll(keepingCapacity: true)
                continue
            }
            stack.removeLast()
            if stack.isEmpty {
                fragments.append(String(text[fragmentStart...index]))
                start = nil
            }
        }
        return fragments
    }

    private static func removingJSONComments(from text: String) -> String {
        var result = ""
        var index = text.startIndex
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = next
                continue
            }
            if character == "\"" {
                inString = true
                result.append(character)
                index = next
                continue
            }
            if character == "/", next < text.endIndex {
                let following = text[next]
                if following == "/" {
                    index = text.index(after: next)
                    while index < text.endIndex, text[index] != "\n" {
                        index = text.index(after: index)
                    }
                    continue
                }
                if following == "*" {
                    index = text.index(after: next)
                    while index < text.endIndex {
                        let after = text.index(after: index)
                        if text[index] == "*", after < text.endIndex, text[after] == "/" {
                            index = text.index(after: after)
                            break
                        }
                        index = after
                    }
                    continue
                }
            }
            result.append(character)
            index = next
        }
        return result
    }

    private static func containsUnexecutedToolCall(
        _ value: Any,
        availableToolNames: Set<String>) -> Bool
    {
        if let values = value as? [Any] {
            return values.contains { self.containsUnexecutedToolCall($0, availableToolNames: availableToolNames) }
        }
        guard let object = value as? [String: Any] else { return false }

        if let name = object["name"] as? String,
           availableToolNames.contains(name),
           object["arguments"] != nil
        {
            return true
        }
        if let function = object["function"] as? [String: Any],
           self.containsUnexecutedToolCall(function, availableToolNames: availableToolNames)
        {
            return true
        }
        return object.values.contains {
            self.containsUnexecutedToolCall($0, availableToolNames: availableToolNames)
        }
    }

    func appendFinalStep(
        text: String,
        to messages: inout [ModelMessage],
        steps: inout [GenerationStep],
        stepIndex: Int,
        appendMessage: Bool = true)
    {
        if appendMessage, !text.isEmpty {
            messages.append(ModelMessage.assistant(text))
        }

        steps.append(GenerationStep(
            stepIndex: stepIndex,
            text: text,
            toolCalls: [],
            toolResults: []))
    }

    func appendAnthropicReasoningBlock(
        text: String,
        signature: String?,
        type: String,
        model: LanguageModel? = nil,
        configuration: TachikomaConfiguration,
        peekabooConfiguration: ConfigurationManager? = nil,
        to messages: inout [ModelMessage])
    {
        var customData = ["anthropic.thinking.type": type]
        if let model, let target = ReasoningReplayTarget(
            model: model,
            configuration: configuration,
            peekabooConfiguration: peekabooConfiguration)
        {
            customData["anthropic.thinking.model"] = target.modelId
            customData["tachikoma.reasoning.provider"] = target.provider
            customData["tachikoma.reasoning.model"] = target.modelId
            if let endpointIdentity = target.endpointIdentity {
                customData["tachikoma.reasoning.base_url"] = endpointIdentity
            }
        }
        if let signature, !signature.isEmpty {
            customData["anthropic.thinking.signature"] = signature
        }
        messages.append(ModelMessage(
            role: .assistant,
            content: [.text(text)],
            channel: .thinking,
            metadata: .init(customData: customData)))
    }

    func appendReasoningBlock(
        _ block: ProviderReasoningBlock,
        model: LanguageModel,
        configuration: TachikomaConfiguration,
        peekabooConfiguration: ConfigurationManager? = nil,
        provider: (any ModelProvider)? = nil,
        to messages: inout [ModelMessage])
    {
        messages.append(ModelMessage(
            role: .assistant,
            content: [.text(block.text)],
            channel: .thinking,
            metadata: .init(customData: self.reasoningMetadata(
                for: block,
                model: model,
                configuration: configuration,
                peekabooConfiguration: peekabooConfiguration,
                provider: provider))))
    }

    func appendResponseHistory(
        from response: ProviderResponse,
        model: LanguageModel,
        configuration: TachikomaConfiguration,
        peekabooConfiguration: ConfigurationManager? = nil,
        provider: (any ModelProvider)? = nil,
        to messages: inout [ModelMessage])
        -> Bool
    {
        let historyStart = messages.count
        let nativeMessages = response.assistantMessages
        messages.append(contentsOf: nativeMessages)

        for block in response.reasoning where !nativeMessages.containsReasoningBlock(block) {
            messages.append(ModelMessage(
                role: .assistant,
                content: [.text(block.text)],
                channel: .thinking,
                metadata: .init(customData: self.reasoningMetadata(
                    for: block,
                    model: model,
                    configuration: configuration,
                    peekabooConfiguration: peekabooConfiguration,
                    provider: provider))))
        }

        let toolCalls = response.toolCalls ?? []
        let missingToolCalls = toolCalls.filter { !nativeMessages.containsToolCall(id: $0.id) }
        let isMissingText = !nativeMessages.containsAssistantText(response.text)
        let addedHistory = messages[historyStart...]
        let needsReasoningOnlyBoundary = !addedHistory.isEmpty &&
            addedHistory.allSatisfy { $0.channel == .thinking } &&
            response.text.isEmpty &&
            missingToolCalls.isEmpty
        guard isMissingText || !missingToolCalls.isEmpty || needsReasoningOnlyBoundary else {
            return messages.count > historyStart
        }

        var fallbackContent: [ModelMessage.ContentPart] = []
        if isMissingText || needsReasoningOnlyBoundary {
            fallbackContent.append(.text(response.text))
        }
        fallbackContent.append(contentsOf: missingToolCalls.map { .toolCall($0) })
        let metadata: MessageMetadata? = needsReasoningOnlyBoundary
            ? .init(customData: ["tachikoma.internal.boundary": "reasoning_only"])
            : nil
        messages.append(ModelMessage(role: .assistant, content: fallbackContent, metadata: metadata))
        return true
    }

    private func reasoningMetadata(
        for block: ProviderReasoningBlock,
        model: LanguageModel,
        configuration: TachikomaConfiguration,
        peekabooConfiguration: ConfigurationManager? = nil,
        provider: (any ModelProvider)? = nil)
        -> [String: String]
    {
        if let rawJSON = block.rawJSON,
           let openRouterMetadata = self.openRouterReasoningMetadata(
               key: "openrouter.reasoning_details",
               value: rawJSON,
               type: block.type,
               model: model,
               configuration: configuration)
        {
            return openRouterMetadata
        }

        if block.type == "openrouter_reasoning",
           let openRouterMetadata = self.openRouterReasoningMetadata(
               key: "openrouter.reasoning",
               value: block.text,
               type: block.type,
               model: model,
               configuration: configuration)
        {
            return openRouterMetadata
        }

        if block.type == "kimi_reasoning_content",
           let target = ReasoningReplayTarget(
               model: model,
               configuration: configuration,
               peekabooConfiguration: peekabooConfiguration,
               provider: provider),
           target.provider == "kimi"
        {
            var metadata = [
                "kimi.reasoning_content": block.text,
                "tachikoma.reasoning.type": block.type,
                "tachikoma.reasoning.provider": target.provider,
                "tachikoma.reasoning.model": target.modelId,
            ]
            if let endpointIdentity = target.endpointIdentity {
                metadata["tachikoma.reasoning.base_url"] = endpointIdentity
            }
            return metadata
        }

        if block.type == "ollama_thinking",
           let target = ReasoningReplayTarget(
               model: model,
               configuration: configuration,
               peekabooConfiguration: peekabooConfiguration,
               provider: provider),
           target.provider == "ollama"
        {
            var metadata = [
                "ollama.thinking": block.text,
                "tachikoma.reasoning.type": block.type,
                "tachikoma.reasoning.provider": target.provider,
                "tachikoma.reasoning.model": target.modelId,
            ]
            if let endpointIdentity = target.endpointIdentity {
                metadata["tachikoma.reasoning.base_url"] = endpointIdentity
            }
            return metadata
        }

        var customData: [String: String] = if let target = ReasoningReplayTarget(
            model: model,
            configuration: configuration,
            peekabooConfiguration: peekabooConfiguration)
        {
            {
                var metadata = [
                    "anthropic.thinking.type": block.type,
                    "anthropic.thinking.model": target.modelId,
                    "tachikoma.reasoning.provider": target.provider,
                    "tachikoma.reasoning.model": target.modelId,
                ]
                if let endpointIdentity = target.endpointIdentity {
                    metadata["tachikoma.reasoning.base_url"] = endpointIdentity
                }
                return metadata
            }()
        } else {
            ["tachikoma.reasoning.type": block.type]
        }

        if let signature = block.signature, !signature.isEmpty {
            customData["anthropic.thinking.signature"] = signature
            customData["tachikoma.reasoning.signature"] = signature
        }
        return customData
    }

    private func openRouterReasoningMetadata(
        key: String,
        value: String,
        type: String,
        model: LanguageModel,
        configuration: TachikomaConfiguration)
        -> [String: String]?
    {
        guard case let .openRouter(modelId) = model else { return nil }

        let baseURL = configuration.getBaseURL(for: .custom("openrouter")) ?? "https://openrouter.ai/api/v1"
        var metadata = [
            key: value,
            "tachikoma.reasoning.type": type,
            "tachikoma.reasoning.provider": "openrouter",
            "tachikoma.reasoning.model": modelId,
        ]
        if let endpointIdentity = Self.canonicalEndpointIdentity(baseURL) {
            metadata["tachikoma.reasoning.base_url"] = endpointIdentity
        }
        return metadata
    }

    func handleToolCalls(
        stepText: String,
        toolCalls: [AgentToolCall],
        context: ToolHandlingContext,
        currentMessages: inout [ModelMessage],
        stepIndex: Int,
        appendAssistantMessage: Bool = true,
        emitToolStartEvents: Bool = false,
        onCancellationCheckpoint: ((GenerationStep) -> Void)? = nil) async throws -> GenerationStep
    {
        if appendAssistantMessage {
            self.appendAssistantMessage(
                stepText: stepText,
                toolCalls: toolCalls,
                to: &currentMessages)
        }

        var toolResults: [AgentToolResult] = []

        for (index, toolCall) in toolCalls.enumerated() {
            do {
                try Task.checkCancellation()
            } catch {
                await self.appendCancelledToolResults(
                    toolCalls: toolCalls,
                    startingAt: index,
                    activeToolCallId: nil,
                    context: context,
                    currentMessages: &currentMessages,
                    toolResults: &toolResults,
                    emitToolStartEvents: emitToolStartEvents)
                onCancellationCheckpoint?(GenerationStep(
                    stepIndex: stepIndex,
                    text: stepText,
                    toolCalls: toolCalls,
                    toolResults: toolResults))
                throw CancellationError()
            }

            if emitToolStartEvents {
                try await self.sendToolStartEvent(toolCall, eventHandler: context.eventHandler)
                do {
                    try Task.checkCancellation()
                } catch {
                    await self.appendCancelledToolResults(
                        toolCalls: toolCalls,
                        startingAt: index,
                        activeToolCallId: toolCall.id,
                        context: context,
                        currentMessages: &currentMessages,
                        toolResults: &toolResults,
                        emitToolStartEvents: emitToolStartEvents)
                    onCancellationCheckpoint?(GenerationStep(
                        stepIndex: stepIndex,
                        text: stepText,
                        toolCalls: toolCalls,
                        toolResults: toolResults))
                    throw CancellationError()
                }
            }

            if let preflightResult = self.makeToolPreflightResult(for: toolCall, context: context) {
                await self.sendToolCompletionEvent(
                    name: toolCall.name,
                    payload: self.toolResultPayload(from: preflightResult.result, toolName: toolCall.name),
                    eventHandler: context.eventHandler)
                currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(preflightResult)]))
                toolResults.append(preflightResult)
                try await self.checkCancellationAfterToolResult(
                    nextIndex: index + 1,
                    cancellationContext: ToolResultCancellationContext(
                        stepIndex: stepIndex,
                        stepText: stepText,
                        toolCalls: toolCalls,
                        handlingContext: context,
                        emitToolStartEvents: emitToolStartEvents,
                        checkpoint: onCancellationCheckpoint),
                    currentMessages: &currentMessages,
                    toolResults: &toolResults)
                continue
            }

            guard let tool = context.tool(named: toolCall.name) else {
                preconditionFailure("Tool preflight must handle unavailable tools")
            }
            let result: AgentToolResult
            do {
                result = try await self.executeToolCall(
                    toolCall,
                    tool: tool,
                    context: context,
                    currentMessages: &currentMessages,
                    options: ToolCallExecutionOptions(
                        stepIndex: stepIndex,
                        allowSuccessfulToolBoundary: !toolResults.contains(where: Self.blocksTerminalBoundary)))
            } catch {
                guard self.isAgentCancellation(error) else { throw error }
                await self.appendCancelledToolResults(
                    toolCalls: toolCalls,
                    startingAt: index,
                    activeToolCallId: toolCall.id,
                    context: context,
                    currentMessages: &currentMessages,
                    toolResults: &toolResults,
                    emitToolStartEvents: emitToolStartEvents)
                onCancellationCheckpoint?(GenerationStep(
                    stepIndex: stepIndex,
                    text: stepText,
                    toolCalls: toolCalls,
                    toolResults: toolResults))
                throw CancellationError()
            }
            toolResults.append(result)

            try await self.checkCancellationAfterToolResult(
                nextIndex: index + 1,
                cancellationContext: ToolResultCancellationContext(
                    stepIndex: stepIndex,
                    stepText: stepText,
                    toolCalls: toolCalls,
                    handlingContext: context,
                    emitToolStartEvents: emitToolStartEvents,
                    checkpoint: onCancellationCheckpoint),
                currentMessages: &currentMessages,
                toolResults: &toolResults)

            if let boundarySignal = self.turnBoundarySignal(from: result) {
                let remainingToolCalls = toolCalls.dropFirst(index + 1)
                for skippedToolCall in remainingToolCalls {
                    let skippedResult = self.makeToolPreflightResult(
                        for: skippedToolCall,
                        context: context) ?? self.makeSkippedToolResult(
                        for: skippedToolCall,
                        boundarySignal: boundarySignal)
                    if emitToolStartEvents {
                        try? await self.sendToolStartEvent(
                            skippedToolCall,
                            eventHandler: context.eventHandler)
                    }
                    await self.sendToolCompletionEvent(
                        name: skippedToolCall.name,
                        payload: self.toolResultPayload(
                            from: skippedResult.result,
                            toolName: skippedToolCall.name),
                        eventHandler: context.eventHandler)
                    currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(skippedResult)]))
                    toolResults.append(skippedResult)
                }
                break
            }
        }

        let step = GenerationStep(
            stepIndex: stepIndex,
            text: stepText,
            toolCalls: toolCalls,
            toolResults: toolResults)
        return await self.finishToolCallStep(step, context: context, currentMessages: &currentMessages)
    }

    private func finishToolCallStep(
        _ step: GenerationStep,
        context: ToolHandlingContext,
        currentMessages: inout [ModelMessage]) async -> GenerationStep
    {
        await self.appendAgentToolImageContext(
            toolCalls: step.toolCalls,
            context: context,
            stepIndex: step.stepIndex,
            to: &currentMessages)
        self.logStepCompletion(stepIndex: step.stepIndex, stepText: step.text, toolCalls: step.toolCalls)
        return step
    }

    // swiftlint:disable:next function_parameter_count
    private func appendCancelledToolResults(
        toolCalls: [AgentToolCall],
        startingAt startIndex: Int,
        activeToolCallId: String?,
        context: ToolHandlingContext,
        currentMessages: inout [ModelMessage],
        toolResults: inout [AgentToolResult],
        emitToolStartEvents: Bool) async
    {
        guard startIndex < toolCalls.count else { return }

        for toolCall in toolCalls[startIndex...] {
            let wasActive = toolCall.id == activeToolCallId
            if emitToolStartEvents, !wasActive {
                try? await self.sendToolStartEvent(toolCall, eventHandler: context.eventHandler)
            }

            var payload = [
                "cancelled": AnyAgentToolValue(bool: true),
                "error": AnyAgentToolValue(string: "Agent execution was cancelled"),
                "reason": AnyAgentToolValue(string: "Agent execution was cancelled"),
                "success": AnyAgentToolValue(bool: false),
            ]
            if !wasActive {
                payload["skipped"] = AnyAgentToolValue(bool: true)
            }
            let result = AgentToolResult(
                toolCallId: toolCall.id,
                result: AnyAgentToolValue(object: payload),
                isError: true)
            await self.sendToolCompletionEvent(
                name: toolCall.name,
                payload: self.toolResultPayload(from: result.result, toolName: toolCall.name),
                eventHandler: context.eventHandler)
            currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(result)]))
            toolResults.append(result)
        }
    }

    private func appendAssistantMessage(
        stepText: String,
        toolCalls: [AgentToolCall],
        to messages: inout [ModelMessage])
    {
        var content: [ModelMessage.ContentPart] = []
        if !stepText.isEmpty {
            content.append(.text(stepText))
        }
        content.append(contentsOf: toolCalls.map { .toolCall($0) })
        messages.append(ModelMessage(role: .assistant, content: content))
    }

    private func makeSkippedToolResult(
        for toolCall: AgentToolCall,
        boundarySignal: AgentTurnBoundarySignal) -> AgentToolResult
    {
        let reason = boundarySignal.reason
        let error = "Tool call skipped because the provider step ended: \(reason)"
        let result = AnyAgentToolValue(object: [
            "error": AnyAgentToolValue(string: error),
            "skipped": AnyAgentToolValue(bool: true),
            "reason": AnyAgentToolValue(string: reason),
            "success": AnyAgentToolValue(bool: false),
            "turn_boundary": self.turnBoundaryValue(boundarySignal),
        ])
        return AgentToolResult(
            toolCallId: toolCall.id,
            result: result,
            isError: true)
    }

    func contentByAppendingTurnBoundaryReason(
        _ stopReason: String,
        to content: String) -> String
    {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedReason = stopReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedReason.isEmpty else { return normalizedContent }
        guard !normalizedContent.isEmpty else { return normalizedReason }

        if normalizedContent == normalizedReason || normalizedContent.hasSuffix("\n\(normalizedReason)") {
            return normalizedContent
        }
        return "\(normalizedContent)\n\n\(normalizedReason)"
    }

    private func executeToolCall(
        _ toolCall: AgentToolCall,
        tool: AgentTool,
        context: ToolHandlingContext,
        currentMessages: inout [ModelMessage],
        options: ToolCallExecutionOptions) async throws -> AgentToolResult
    {
        let boundaryDecision = context.turnBoundary.record(toolName: toolCall.name, arguments: toolCall.arguments)

        if let skippedResult = self.makeBoundaryRequiredSkippedResult(for: toolCall, decision: boundaryDecision) {
            await self.sendToolCompletionEvent(
                name: toolCall.name,
                payload: self.toolResultPayload(from: skippedResult.result, toolName: toolCall.name),
                eventHandler: context.eventHandler)
            currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(skippedResult)]))
            return skippedResult
        }

        do {
            let executionContext = ToolExecutionContext(
                messages: currentMessages.sanitizedForToolContext(),
                model: context.model,
                settings: self.generationSettings(for: context.model),
                sessionId: context.sessionId,
                stepIndex: options.stepIndex,
                metadata: [
                    "toolCallId": toolCall.id,
                    "imageContextId": context.imageContextID,
                    "supportsVision": context.supportsVision ? "true" : "false",
                ])
            let toolArguments = AgentToolArguments(toolCall.arguments)
            let execution = try await self.executeTool(
                tool,
                arguments: toolArguments,
                executionContext: executionContext,
                options: context.enhancementOptions)
            let result = execution.result
            let resultBoundaryDecision = context.turnBoundary.recordResult(
                toolName: toolCall.name,
                result: result)
            let effectiveBoundaryDecision = Self.effectiveBoundaryDecision(
                initial: boundaryDecision,
                afterResult: resultBoundaryDecision)
            if !Self.resultEncodesToolFailure(result) {
                context.turnBoundary.recordSuccessfulCompletion(
                    toolName: toolCall.name,
                    arguments: toolCall.arguments,
                    result: result)
            }
            var toolValue = result
            if let verification = execution.verification {
                toolValue = self.addVerification(verification, to: toolValue)
                await context.eventHandler?.send(.verificationCompleted(toolName: toolCall.name, result: verification))
            }
            switch effectiveBoundaryDecision {
            case let .continueNextStep(reason):
                toolValue = self.addTurnBoundarySignal(.continueNextStep(reason: reason), to: toolValue)
            case let .stopAgentAfterSuccessfulTool(reason)
                where options.allowSuccessfulToolBoundary && !Self.resultEncodesToolFailure(result):
                toolValue = self.addTurnBoundarySignal(.stopAgent(reason: reason), to: toolValue)
            case .stopAgentAfterSuccessfulTool:
                break
            case .skipUntilCompletionEvidence:
                preconditionFailure("Completion-evidence-required calls return before execution")
            case .skipUntilPerception:
                preconditionFailure("Perception-required calls return before execution")
            case .continueTurn:
                break
            }
            let toolResult = Self.classifiedToolResult(callID: toolCall.id, value: toolValue, source: result)
            await self.sendToolCompletionEvent(
                name: toolCall.name,
                payload: self.toolResultPayload(from: toolValue, toolName: toolCall.name),
                eventHandler: context.eventHandler)
            currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(toolResult)]))
            return toolResult
        } catch {
            if self.isAgentCancellation(error) {
                throw CancellationError()
            }
            let errorResult: AgentToolResult
            if let failure = error as? AgentToolExecutionFailure {
                let resultBoundaryDecision = context.turnBoundary.recordResult(
                    toolName: toolCall.name,
                    result: failure.metadata)
                let effectiveBoundaryDecision = Self.effectiveBoundaryDecision(
                    initial: boundaryDecision,
                    afterResult: resultBoundaryDecision)
                let decoratedFailure: AgentToolExecutionFailure = if case let .continueNextStep(reason) =
                    effectiveBoundaryDecision
                {
                    self.addTurnBoundarySignal(.continueNextStep(reason: reason), to: failure)
                } else {
                    failure
                }
                errorResult = AgentToolResult(toolCallId: toolCall.id, failure: decoratedFailure)
            } else {
                var errorValue = AnyAgentToolValue(string: error.localizedDescription)
                if case let .continueNextStep(reason) = boundaryDecision {
                    errorValue = self.addTurnBoundarySignal(.continueNextStep(reason: reason), to: errorValue)
                }
                errorResult = AgentToolResult(
                    toolCallId: toolCall.id,
                    result: errorValue,
                    isError: true)
            }
            await self.sendToolCompletionEvent(
                name: toolCall.name,
                payload: self.toolErrorPayload(from: error),
                eventHandler: context.eventHandler)
            currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(errorResult)]))
            return errorResult
        }
    }

    private static func effectiveBoundaryDecision(
        initial: AgentTurnBoundary.Decision,
        afterResult: AgentTurnBoundary.Decision) -> AgentTurnBoundary.Decision
    {
        afterResult == .continueTurn ? initial : afterResult
    }

    private func executeTool(
        _ tool: AgentTool,
        arguments: AgentToolArguments,
        executionContext: ToolExecutionContext,
        options: AgentEnhancementOptions?) async throws
        -> (result: AnyAgentToolValue, verification: VerificationResult?)
    {
        guard let options, options.verifyActions else {
            return try await (tool.execute(arguments, context: executionContext), nil)
        }

        if self.actionVerifier.shouldVerify(
            toolName: tool.name,
            arguments: arguments.stringDictionary,
            options: options)
        {
            return try await self.executeToolWithVerification(
                tool,
                arguments: arguments,
                executionContext: executionContext,
                options: options)
        }
        return try await (tool.execute(arguments, context: executionContext), nil)
    }

    private func addVerification(
        _ verification: VerificationResult,
        to result: AnyAgentToolValue) -> AnyAgentToolValue
    {
        do {
            let json = try result.toJSON()
            var payload = json as? [String: Any] ?? ["result": json]
            payload["verification"] = self.verificationPayload(verification)
            return try AnyAgentToolValue.fromJSON(payload)
        } catch {
            return AnyAgentToolValue(object: [
                "result": result,
                "verification": AnyAgentToolValue.from(self.verificationPayload(verification)),
            ])
        }
    }

    private func verificationPayload(_ verification: VerificationResult) -> [String: Any] {
        [
            "success": verification.success,
            "confidence": Double(verification.confidence),
            "observation": verification.observation,
            "suggestion": verification.suggestion ?? NSNull(),
            "should_retry": verification.shouldRetry,
        ]
    }

    private func addTurnBoundarySignal(
        _ signal: AgentTurnBoundarySignal,
        to result: AnyAgentToolValue) -> AnyAgentToolValue
    {
        do {
            let json = try result.toJSON()
            var payload = json as? [String: Any] ?? ["result": json]
            payload["turn_boundary"] = try self.turnBoundaryValue(signal).toJSON()
            return try AnyAgentToolValue.fromJSON(payload)
        } catch {
            return AnyAgentToolValue(object: [
                "result": result,
                "turn_boundary": self.turnBoundaryValue(signal),
            ])
        }
    }

    private func addTurnBoundarySignal(
        _ signal: AgentTurnBoundarySignal,
        to failure: AgentToolExecutionFailure) -> AgentToolExecutionFailure
    {
        let metadata = self.addTurnBoundarySignal(
            signal,
            to: failure.metadata ?? AnyAgentToolValue(object: [:]))
        return AgentToolExecutionFailure(
            message: failure.message,
            content: failure.content,
            structuredValue: failure.structuredValue,
            metadata: metadata)
    }

    private func turnBoundaryValue(_ signal: AgentTurnBoundarySignal) -> AnyAgentToolValue {
        var payload = [
            "reason": AnyAgentToolValue(string: signal.reason),
            // Keep the legacy marker so persisted/current result readers retain transcript compatibility.
            "stop_after_current_step": AnyAgentToolValue(bool: true),
        ]
        switch signal {
        case .continueNextStep:
            payload["continue_next_step"] = AnyAgentToolValue(bool: true)
            payload["disposition"] = AnyAgentToolValue(string: "continue_next_step")
        case .stopAgent:
            payload["stop_agent"] = AnyAgentToolValue(bool: true)
            payload["disposition"] = AnyAgentToolValue(string: "stop_agent")
        }
        return AnyAgentToolValue(object: payload)
    }

    private func checkCancellationAfterToolResult(
        nextIndex: Int,
        cancellationContext: ToolResultCancellationContext,
        currentMessages: inout [ModelMessage],
        toolResults: inout [AgentToolResult]) async throws
    {
        do {
            try Task.checkCancellation()
        } catch {
            await self.appendCancelledToolResults(
                toolCalls: cancellationContext.toolCalls,
                startingAt: nextIndex,
                activeToolCallId: nil,
                context: cancellationContext.handlingContext,
                currentMessages: &currentMessages,
                toolResults: &toolResults,
                emitToolStartEvents: cancellationContext.emitToolStartEvents)
            cancellationContext.checkpoint?(GenerationStep(
                stepIndex: cancellationContext.stepIndex,
                text: cancellationContext.stepText,
                toolCalls: cancellationContext.toolCalls,
                toolResults: toolResults))
            throw CancellationError()
        }
    }

    private func logStepCompletion(
        stepIndex: Int,
        stepText: String,
        toolCalls: [AgentToolCall])
    {
        guard self.isVerbose else { return }
        self.logger.debug(
            "Step \(stepIndex) completed: collected \(toolCalls.count) tool calls, text length: \(stepText.count)")
    }

    private func sendToolCompletionEvent(
        name: String,
        payload: String,
        eventHandler: EventHandler?) async
    {
        guard let eventHandler else { return }
        await eventHandler.send(.toolCallCompleted(name: name, result: payload))
    }

    private func sendToolStartEvent(_ toolCall: AgentToolCall, eventHandler: EventHandler?) async throws {
        guard let eventHandler else { return }
        let argumentsData = try JSONEncoder().encode(toolCall.arguments)
        let argumentsJSON = AgentToolCallArgumentPreview.redacted(from: argumentsData)
        await eventHandler.send(.toolCallStarted(name: toolCall.name, arguments: argumentsJSON))
    }

    private func toolResultPayload(from result: AnyAgentToolValue, toolName: String) -> String {
        do {
            let jsonObject = try result.toJSON()
            var wrapped: [String: Any] = if let dict = jsonObject as? [String: Any] {
                dict
            } else {
                ["result": jsonObject]
            }

            if let summaryText = self.summaryText(from: wrapped, toolName: toolName) {
                wrapped["summary_text"] = summaryText
            }

            let data = try JSONSerialization.data(withJSONObject: wrapped, options: [])
            return String(data: data, encoding: .utf8) ?? "{}"
        } catch {
            let fallback = result.stringValue ?? String(describing: result)
            let escapedFallback = fallback.replacingOccurrences(of: "\"", with: "\\\"")
            return "{\"result\": \"\(escapedFallback)\"}"
        }
    }

    private func summaryText(from payload: [String: Any], toolName: String) -> String? {
        guard
            let meta = payload["meta"] as? [String: Any],
            let summaryJSON = meta["summary"] as? [String: Any],
            let summary = ToolEventSummary(json: summaryJSON)
        else {
            return nil
        }
        return summary.shortDescription(toolName: toolName)
    }

    private func toolErrorPayload(from error: any Error) -> String {
        let errorDict = ["error": error.localizedDescription]
        guard let data = try? JSONSerialization.data(withJSONObject: errorDict, options: []),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"error\": \"Unknown error\"}"
        }
        return json
    }
}

@available(macOS 14.0, *)
extension [ModelMessage] {
    func sanitizedForProviderContext(
        model: LanguageModel,
        configuration: TachikomaConfiguration,
        peekabooConfiguration: ConfigurationManager? = nil,
        provider: (any ModelProvider)? = nil)
        -> [ModelMessage]
    {
        let target = ReasoningReplayTarget(
            model: model,
            configuration: configuration,
            peekabooConfiguration: peekabooConfiguration,
            provider: provider)
        var previousSourceWasRetainedThinking = false
        var sanitizedMessages: [ModelMessage] = []
        sanitizedMessages.reserveCapacity(self.count)

        for message in self {
            guard message.channel == .thinking ||
                message.metadata?.customData?["tachikoma.internal.boundary"] == "reasoning_only"
            else {
                sanitizedMessages.append(message)
                previousSourceWasRetainedThinking = false
                continue
            }

            guard message.channel == .thinking else {
                if target?.allowsReasoningBoundaries == true, previousSourceWasRetainedThinking {
                    sanitizedMessages.append(message)
                }
                previousSourceWasRetainedThinking = false
                continue
            }
            guard let target else {
                previousSourceWasRetainedThinking = false
                continue
            }
            let customData = message.metadata?.customData ?? [:]
            let shouldKeep = target.matches(customData) ||
                (target.allowsLegacyUnknown &&
                    customData["anthropic.thinking.model"] == nil &&
                    customData["anthropic.thinking.type"] != nil)
            if shouldKeep {
                sanitizedMessages.append(message)
            }
            previousSourceWasRetainedThinking = shouldKeep
        }

        return sanitizedMessages
    }

    fileprivate func sanitizedForToolContext() -> [ModelMessage] {
        self.filter { message in
            message.channel != .thinking &&
                message.metadata?.customData?["tachikoma.internal.boundary"] != "reasoning_only"
        }
    }

    fileprivate func containsAssistantText(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let assistantTexts = self.flatMap { message -> [String] in
            guard message.role == .assistant, message.channel != .thinking else {
                return []
            }
            return message.content.compactMap { part in
                if case let .text(value) = part {
                    return value
                }
                return nil
            }
        }
        return assistantTexts.contains(text) || assistantTexts.joined() == text
    }

    fileprivate func containsReasoningBlock(_ reasoning: ProviderReasoningBlock) -> Bool {
        self.contains { message in
            message.role == .assistant && message.channel == .thinking && message.content.contains { part in
                guard case let .text(value) = part else { return false }
                if let signature = reasoning.signature, !signature.isEmpty {
                    return message.metadata?.customData?["anthropic.thinking.signature"] == signature ||
                        message.metadata?.customData?["tachikoma.reasoning.signature"] == signature
                }
                return value == reasoning.text
            }
        }
    }

    fileprivate func containsToolCall(id: String) -> Bool {
        self.contains { message in
            message.role == .assistant && message.content.contains { part in
                if case let .toolCall(toolCall) = part {
                    return toolCall.id == id
                }
                return false
            }
        }
    }
}

@available(macOS 14.0, *)
private struct ReasoningReplayTarget {
    let provider: String
    let modelId: String
    let baseURL: String?
    let allowsReasoningBoundaries: Bool
    let allowsLegacyUnknown: Bool
    private var verifiedEndpointIdentity: String?

    init?(
        model: LanguageModel,
        configuration: TachikomaConfiguration,
        peekabooConfiguration: ConfigurationManager? = nil,
        provider: (any ModelProvider)? = nil)
    {
        self.verifiedEndpointIdentity = nil
        switch model {
        case let .anthropic(anthropicModel):
            self.provider = "anthropic"
            self.modelId = anthropicModel.modelId
            self.baseURL = configuration.getBaseURL(for: .anthropic) ?? Provider.anthropic.defaultBaseURL
            self.allowsReasoningBoundaries = true
            self.allowsLegacyUnknown = !LanguageModel.Anthropic.isFable(modelId: anthropicModel.modelId)
        case let .anthropicCompatible(modelId, baseURL):
            self.provider = "anthropic-compatible"
            self.modelId = modelId
            self.baseURL = baseURL
            self.allowsReasoningBoundaries = true
            self.allowsLegacyUnknown = !LanguageModel.Anthropic.isFable(modelId: modelId)
        case let .openRouter(modelId):
            self.provider = "openrouter"
            self.modelId = modelId
            self.baseURL = configuration.getBaseURL(for: .custom("openrouter")) ?? "https://openrouter.ai/api/v1"
            self.allowsReasoningBoundaries = true
            self.allowsLegacyUnknown = false
        case let .minimax(model):
            self.provider = "minimax"
            self.modelId = model.modelId
            self.baseURL = configuration.getBaseURL(for: .minimax) ?? Provider.minimax.defaultBaseURL
            self.allowsReasoningBoundaries = true
            self.allowsLegacyUnknown = true
        case let .minimaxCN(model):
            self.provider = "minimax-cn"
            self.modelId = model.modelId
            self.baseURL = configuration.getBaseURL(for: .minimaxCN) ?? Provider.minimaxCN.defaultBaseURL
            self.allowsReasoningBoundaries = true
            self.allowsLegacyUnknown = true
        case let .kimi(model):
            self.provider = "kimi"
            self.modelId = model.modelId
            self.baseURL = configuration.getBaseURL(for: .kimi) ?? Provider.kimi.defaultBaseURL
            self.allowsReasoningBoundaries = true
            self.allowsLegacyUnknown = false
        case let .ollama(model):
            guard
                let ollamaProvider = provider as? OllamaProvider,
                ollamaProvider.modelId == model.modelId,
                let replayIdentity = ollamaProvider.reasoningReplayIdentity
            else {
                return nil
            }
            self.provider = "ollama"
            self.modelId = model.modelId
            self.baseURL = ollamaProvider.baseURL
            self.allowsReasoningBoundaries = true
            self.allowsLegacyUnknown = false
            self.verifiedEndpointIdentity = replayIdentity
        case let .custom(provider):
            if let anthropicProvider = provider as? AnthropicProvider {
                self.provider = "anthropic"
                self.modelId = anthropicProvider.modelId
                self.baseURL = anthropicProvider.baseURL ?? Provider.anthropic.defaultBaseURL
                self.allowsReasoningBoundaries = true
                self.allowsLegacyUnknown = !LanguageModel.Anthropic.isFable(modelId: anthropicProvider.modelId)
                return
            }
            if let compatibleProvider = provider as? AnthropicCompatibleProvider {
                self.provider = "anthropic-compatible"
                self.modelId = compatibleProvider.modelId
                self.baseURL = compatibleProvider.baseURL
                self.allowsReasoningBoundaries = true
                self.allowsLegacyUnknown = !LanguageModel.Anthropic.isFable(modelId: compatibleProvider.modelId)
                return
            }
            guard let parsed = ProviderParser.parse(provider.modelId) else {
                return nil
            }
            if let registeredProvider = CustomProviderRegistry.shared.get(parsed.provider),
               registeredProvider.kind == .anthropic
            {
                self.provider = "custom-anthropic"
                self.modelId = parsed.model
                self.baseURL = registeredProvider.baseURL
                self.allowsReasoningBoundaries = true
                self.allowsLegacyUnknown = !LanguageModel.Anthropic.isFable(modelId: parsed.model)
                return
            }
            guard Self.isAnthropicCustomProvider(
                providerID: parsed.provider,
                peekabooConfiguration: peekabooConfiguration)
            else {
                return nil
            }
            self.provider = "custom-anthropic"
            self.modelId = provider.modelId
            self.baseURL = provider.baseURL
            self.allowsReasoningBoundaries = true
            self.allowsLegacyUnknown = !LanguageModel.Anthropic.isFable(modelId: provider.modelId)
        default:
            return nil
        }
    }

    private static func isAnthropicCustomProvider(
        providerID: String,
        peekabooConfiguration: ConfigurationManager?)
        -> Bool
    {
        if CustomProviderRegistry.shared.get(providerID)?.kind == .anthropic {
            return true
        }
        return peekabooConfiguration?.getCustomProvider(id: providerID)?.type == .anthropic
    }

    func matches(_ customData: [String: String]) -> Bool {
        customData["tachikoma.reasoning.provider"] == self.provider &&
            customData["tachikoma.reasoning.model"] == self.modelId &&
            customData["tachikoma.reasoning.base_url"] == self.endpointIdentity
    }

    var endpointIdentity: String? {
        self.verifiedEndpointIdentity ?? PeekabooAgentService.canonicalEndpointIdentity(self.baseURL)
    }
}
