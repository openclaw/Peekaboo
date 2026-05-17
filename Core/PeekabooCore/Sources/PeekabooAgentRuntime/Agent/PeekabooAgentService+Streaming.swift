//
//  PeekabooAgentService+Streaming.swift
//  PeekabooCore
//

import Foundation
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
                eventHandler: configuration.eventHandler,
                stepIndex: stepIndex)

            state.content += output.text
            if let usage = output.usage {
                state.usage = usage
            }

            if case .anthropic = configuration.model {
                for block in output.reasoningBlocks {
                    state.messages.append(ModelMessage(
                        role: .assistant,
                        content: [.text(block.text)],
                        channel: .thinking,
                        metadata: .init(customData: [
                            "anthropic.thinking.signature": block.signature,
                            "anthropic.thinking.type": block.type,
                        ])))
                }
            }

            if output.toolCalls.isEmpty {
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
        stepIndex: Int)
    {
        if !text.isEmpty {
            messages.append(ModelMessage.assistant(text))
        }

        steps.append(GenerationStep(
            stepIndex: stepIndex,
            text: text,
            toolCalls: [],
            toolResults: []))
    }

    func handleToolCalls(
        stepText: String,
        toolCalls: [AgentToolCall],
        context: ToolHandlingContext,
        currentMessages: inout [ModelMessage],
        stepIndex: Int) async throws -> GenerationStep
    {
        self.appendAssistantMessage(
            stepText: stepText,
            toolCalls: toolCalls,
            to: &currentMessages)

        var toolResults: [AgentToolResult] = []

        for (index, toolCall) in toolCalls.enumerated() {
            guard let tool = context.tool(named: toolCall.name) else {
                let unavailableResult = self.makeUnavailableToolResult(for: toolCall)
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
                messages: currentMessages,
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
