//
//  PeekabooAgentService+Streaming.swift
//  PeekabooCore
//

import CryptoKit
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
    }

    struct StreamingLoopConfiguration {
        let model: LanguageModel
        let tools: [AgentTool]
        let sessionId: String
        let eventHandler: EventHandler?
        let enhancementOptions: AgentEnhancementOptions?
    }

    struct ToolHandlingContext {
        let model: LanguageModel
        let tools: [AgentTool]
        let eventHandler: EventHandler?
        let sessionId: String
        let turnBoundary = AgentTurnBoundary()
        let enhancementOptions: AgentEnhancementOptions?

        init(
            model: LanguageModel,
            tools: [AgentTool],
            eventHandler: EventHandler?,
            sessionId: String,
            enhancementOptions: AgentEnhancementOptions? = nil)
        {
            self.model = model
            self.tools = tools
            self.eventHandler = eventHandler
            self.sessionId = sessionId
            self.enhancementOptions = enhancementOptions
        }

        func tool(named name: String) -> AgentTool? {
            self.tools.first { $0.name == name }
        }
    }

    struct StreamingLoopState {
        var messages: [ModelMessage]
        var content: String = ""
        var steps: [GenerationStep] = []
        var usage: Usage?
        var toolCallCount: Int = 0
        var desktopContextState = DesktopContextRefreshState()
    }

    func runStreamingLoop(
        configuration: StreamingLoopConfiguration,
        maxSteps: Int,
        initialMessages: [ModelMessage],
        queueMode: QueueMode = .oneAtATime,
        pendingUserMessages: [ModelMessage] = []) async throws -> StreamingLoopOutcome
    {
        var state = StreamingLoopState(messages: initialMessages)
        let resolvedConfiguration = TachikomaConfiguration.resolve(.current)
        let toolContext = ToolHandlingContext(
            model: configuration.model,
            tools: configuration.tools,
            eventHandler: configuration.eventHandler,
            sessionId: configuration.sessionId,
            enhancementOptions: configuration.enhancementOptions)

        // Queue of pending user messages (set by caller). For now, this is empty
        // and will be injected by higher-level chat loop when we add that support.
        var queuedMessages: [ModelMessage] = pendingUserMessages

        for stepIndex in 0..<maxSteps {
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

            let streamResult = try await streamText(
                model: configuration.model,
                messages: state.messages,
                tools: configuration.tools.isEmpty ? nil : configuration.tools,
                settings: self.generationSettings(for: configuration.model))

            let output = try await self.collectStreamOutput(
                from: streamResult,
                model: configuration.model,
                eventHandler: configuration.eventHandler,
                stepIndex: stepIndex)

            state.content += output.text
            if let usage = output.usage {
                state.usage = usage
            }

            let shouldReplayReasoning = ReasoningReplayTarget(
                model: configuration.model,
                configuration: resolvedConfiguration,
                peekabooConfiguration: self.services.configuration) != nil
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
                        to: &state.messages)
                }
            }

            if output.finishReason == .contentFilter {
                throw TachikomaError.apiError("Model refused to answer")
            }

            if output.toolCalls.isEmpty {
                if shouldReplayReasoning, output.text.isEmpty, !output.reasoningBlocks.isEmpty {
                    self.appendReasoningOnlyBoundary(to: &state.messages)
                }
                self.appendFinalStep(
                    text: output.text,
                    to: &state.messages,
                    steps: &state.steps,
                    stepIndex: stepIndex)
                break
            }

            let step = try await self.handleToolCalls(
                stepText: output.text,
                toolCalls: output.toolCalls,
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

            // If queue mode is one-at-a-time, inject exactly one queued message (if any)
            if queueMode == .oneAtATime, let next = queuedMessages.first {
                state.messages.append(next)
                queuedMessages.removeFirst()
            }
        }

        let totalToolCalls = state.toolCallCount

        return StreamingLoopOutcome(
            content: state.content,
            messages: state.messages,
            steps: state.steps,
            usage: state.usage,
            toolCallCount: totalToolCalls)
    }

    func logStreamingStepStart(_ stepIndex: Int, tools: [AgentTool]) {
        guard self.isVerbose else { return }

        self.logger.debug("Step \(stepIndex): Passing \(tools.count) tools to streamText")
        if tools.isEmpty {
            self.logger.warning("No tools available!")
            return
        }

        let toolNames = tools.map(\.name).joined(separator: ", ")
        self.logger.debug("Available tools: \(toolNames)")
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

    func appendReasoningOnlyBoundary(to messages: inout [ModelMessage]) {
        messages.append(ModelMessage(
            role: .assistant,
            content: [.text("")],
            metadata: .init(customData: ["tachikoma.internal.boundary": "reasoning_only"])))
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
                peekabooConfiguration: peekabooConfiguration))))
    }

    func appendResponseHistory(
        from response: ProviderResponse,
        model: LanguageModel,
        configuration: TachikomaConfiguration,
        peekabooConfiguration: ConfigurationManager? = nil,
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
                    peekabooConfiguration: peekabooConfiguration))))
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
        peekabooConfiguration: ConfigurationManager? = nil)
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
        if let endpointIdentity = self.canonicalReasoningEndpointIdentity(baseURL) {
            metadata["tachikoma.reasoning.base_url"] = endpointIdentity
        }
        return metadata
    }

    private func canonicalReasoningEndpointIdentity(_ rawValue: String?) -> String? {
        guard
            let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        guard let value = components.string, let data = value.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }

    func handleToolCalls(
        stepText: String,
        toolCalls: [AgentToolCall],
        context: ToolHandlingContext,
        currentMessages: inout [ModelMessage],
        stepIndex: Int,
        appendAssistantMessage: Bool = true,
        emitToolStartEvents: Bool = false) async throws -> GenerationStep
    {
        if appendAssistantMessage {
            self.appendAssistantMessage(
                stepText: stepText,
                toolCalls: toolCalls,
                to: &currentMessages)
        }

        var toolResults: [AgentToolResult] = []

        for (index, toolCall) in toolCalls.enumerated() {
            if emitToolStartEvents {
                try await self.sendToolStartEvent(toolCall, eventHandler: context.eventHandler)
            }

            guard let tool = context.tool(named: toolCall.name) else {
                let unavailableResult = self.makeUnavailableToolResult(for: toolCall)
                await self.sendToolCompletionEvent(
                    name: toolCall.name,
                    payload: self.toolResultPayload(from: unavailableResult.result, toolName: toolCall.name),
                    eventHandler: context.eventHandler)
                currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(unavailableResult)]))
                toolResults.append(unavailableResult)
                continue
            }
            let result = try await self.executeToolCall(
                toolCall,
                tool: tool,
                context: context,
                currentMessages: &currentMessages,
                stepIndex: stepIndex)
            toolResults.append(result)
            if let stopReason = self.turnBoundaryStopReason(from: result) {
                let remainingToolCalls = toolCalls.dropFirst(index + 1)
                for skippedToolCall in remainingToolCalls {
                    let skippedResult = self.makeSkippedToolResult(
                        for: skippedToolCall,
                        stopReason: stopReason)
                    currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(skippedResult)]))
                    toolResults.append(skippedResult)
                }
                break
            }
        }

        self.logStepCompletion(stepIndex: stepIndex, stepText: stepText, toolCalls: toolCalls)

        return GenerationStep(
            stepIndex: stepIndex,
            text: stepText,
            toolCalls: toolCalls,
            toolResults: toolResults)
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
        stopReason: String) -> AgentToolResult
    {
        let result = AnyAgentToolValue(object: [
            "skipped": AnyAgentToolValue(bool: true),
            "reason": AnyAgentToolValue(string: stopReason),
            "turn_boundary": AnyAgentToolValue(object: [
                "stop_after_current_step": AnyAgentToolValue(bool: true),
                "reason": AnyAgentToolValue(string: stopReason),
            ]),
        ])
        return AgentToolResult(
            toolCallId: toolCall.id,
            result: result,
            isError: true)
    }

    private func makeUnavailableToolResult(for toolCall: AgentToolCall) -> AgentToolResult {
        AgentToolResult(
            toolCallId: toolCall.id,
            result: AnyAgentToolValue(object: [
                "error": AnyAgentToolValue(string: "Tool '\(toolCall.name)' is not available in this context"),
            ]),
            isError: true)
    }

    private func executeToolCall(
        _ toolCall: AgentToolCall,
        tool: AgentTool,
        context: ToolHandlingContext,
        currentMessages: inout [ModelMessage],
        stepIndex: Int) async throws -> AgentToolResult
    {
        let boundaryDecision = context.turnBoundary.record(toolName: toolCall.name, arguments: toolCall.arguments)

        do {
            let executionContext = ToolExecutionContext(
                messages: currentMessages.sanitizedForToolContext(),
                model: context.model,
                settings: self.generationSettings(for: context.model),
                sessionId: context.sessionId,
                stepIndex: stepIndex)
            let toolArguments = AgentToolArguments(toolCall.arguments)
            let execution = try await self.executeTool(
                tool,
                arguments: toolArguments,
                executionContext: executionContext,
                options: context.enhancementOptions)
            let result = execution.result
            var toolValue = result
            if let verification = execution.verification {
                toolValue = self.addVerification(verification, to: toolValue)
                await context.eventHandler?.send(.verificationCompleted(toolName: toolCall.name, result: verification))
            }
            if case let .stopAfterCurrentStep(reason) = boundaryDecision {
                toolValue = self.addTurnBoundaryStopReason(reason, to: toolValue)
            }
            let toolResult = AgentToolResult.success(toolCallId: toolCall.id, result: toolValue)
            await self.sendToolCompletionEvent(
                name: toolCall.name,
                payload: self.toolResultPayload(from: toolValue, toolName: toolCall.name),
                eventHandler: context.eventHandler)
            currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(toolResult)]))
            return toolResult
        } catch let error as CancellationError {
            throw error
        } catch {
            var errorValue = AnyAgentToolValue(string: error.localizedDescription)
            if case let .stopAfterCurrentStep(reason) = boundaryDecision {
                errorValue = self.addTurnBoundaryStopReason(reason, to: errorValue)
            }
            let errorResult = AgentToolResult(
                toolCallId: toolCall.id,
                result: errorValue,
                isError: true)
            await self.sendToolCompletionEvent(
                name: toolCall.name,
                payload: self.toolErrorPayload(from: error),
                eventHandler: context.eventHandler)
            currentMessages.append(ModelMessage(role: .tool, content: [.toolResult(errorResult)]))
            return errorResult
        }
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

    private func addTurnBoundaryStopReason(
        _ reason: String,
        to result: AnyAgentToolValue) -> AnyAgentToolValue
    {
        do {
            let json = try result.toJSON()
            var payload = json as? [String: Any] ?? ["result": json]
            payload["turn_boundary"] = [
                "stop_after_current_step": true,
                "reason": reason,
            ]
            return try AnyAgentToolValue.fromJSON(payload)
        } catch {
            return AnyAgentToolValue(object: [
                "result": result,
                "turn_boundary": AnyAgentToolValue(object: [
                    "stop_after_current_step": AnyAgentToolValue(bool: true),
                    "reason": AnyAgentToolValue(string: reason),
                ]),
            ])
        }
    }

    func turnBoundaryStopReason(from toolResults: [AgentToolResult]) -> String? {
        for toolResult in toolResults {
            if let reason = self.turnBoundaryStopReason(from: toolResult) {
                return reason
            }
        }
        return nil
    }

    func turnBoundaryStopReason(from toolResult: AgentToolResult) -> String? {
        guard let json = try? toolResult.result.toJSON(),
              let payload = json as? [String: Any],
              let boundary = payload["turn_boundary"] as? [String: Any],
              boundary["stop_after_current_step"] as? Bool == true
        else {
            return nil
        }
        return boundary["reason"] as? String
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
        peekabooConfiguration: ConfigurationManager? = nil)
        -> [ModelMessage]
    {
        let target = ReasoningReplayTarget(
            model: model,
            configuration: configuration,
            peekabooConfiguration: peekabooConfiguration)
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

    init?(
        model: LanguageModel,
        configuration: TachikomaConfiguration,
        peekabooConfiguration: ConfigurationManager? = nil)
    {
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
        guard
            let trimmed = self.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            var components = URLComponents(string: trimmed),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        components.user = nil
        components.password = nil
        components.fragment = nil
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }

        guard let value = components.string, let data = value.data(using: .utf8) else { return nil }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return "sha256:\(digest)"
    }
}
