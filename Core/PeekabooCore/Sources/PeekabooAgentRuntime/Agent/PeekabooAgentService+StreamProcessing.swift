//
//  PeekabooAgentService+StreamProcessing.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    struct StreamProcessingOutput {
        let text: String
        let toolCalls: [AgentToolCall]
        let usage: Usage?
        let finishReason: FinishReason?
        let reasoningBlocks: [ReasoningBlock]
    }

    struct ReasoningBlock {
        var text: String
        let signature: String?
        let type: String
    }

    private enum BufferedStreamEvent {
        case event(AgentEvent)
    }

    func collectStreamOutput(
        from streamResult: StreamTextResult,
        model: LanguageModel,
        eventHandler: EventHandler?,
        stepIndex: Int,
        onTerminalUsage: ((Usage?) -> Void)? = nil) async throws -> StreamProcessingOutput
    {
        var stepText = ""
        var reasoningBlocks: [ReasoningBlock] = []
        var activeReasoningIndex: Int?
        var lastSignedReasoningIndex: Int?
        var pendingReasoningText = ""
        var pendingReasoningType = "thinking"
        var stepToolCalls: [AgentToolCall] = []
        var seenToolCallIds = Set<String>()
        var isThinking = false
        var bufferedEvents: [BufferedStreamEvent] = []
        let buffersAssistantTextUntilDone = self.buffersAgentTextStreamUntilDone(for: model)
        var usage: Usage?
        var finishReason: FinishReason?
        var didReceiveDone = false

        if self.isVerbose {
            self.logger.debug("Starting to process stream for step \(stepIndex)")
        }

        try Task.checkCancellation()
        for try await delta in streamResult.stream {
            if delta.type != .done {
                try Task.checkCancellation()
            }
            if self.isVerbose {
                self.logger.debug("Received delta type: \(String(describing: delta.type))")
            }

            switch delta.type {
            case .textDelta:
                self.flushPendingReasoningText(
                    &pendingReasoningText,
                    into: lastSignedReasoningIndex,
                    type: pendingReasoningType,
                    reasoningBlocks: &reasoningBlocks)
                guard let content = delta.content else { continue }
                await self.handleTextDelta(
                    content,
                    stepText: &stepText,
                    isThinking: &isThinking,
                    bufferedEvents: &bufferedEvents,
                    buffersAssistantTextUntilDone: buffersAssistantTextUntilDone,
                    eventHandler: eventHandler)

            case .toolCall:
                self.flushPendingReasoningText(
                    &pendingReasoningText,
                    into: lastSignedReasoningIndex,
                    type: pendingReasoningType,
                    reasoningBlocks: &reasoningBlocks)
                if let toolCall = delta.toolCall {
                    try await self.handleToolCallDelta(
                        toolCall,
                        stepToolCalls: &stepToolCalls,
                        seenToolCallIds: &seenToolCallIds,
                        bufferedEvents: &bufferedEvents,
                        eventHandler: eventHandler)
                }

            case .reasoning:
                let reasoningType = delta.reasoningType ?? "thinking"
                if let signature = delta.reasoningSignature {
                    let signedText = pendingReasoningText + (delta.content ?? "")
                    reasoningBlocks.append(ReasoningBlock(
                        text: signedText,
                        signature: signature,
                        type: reasoningType))
                    activeReasoningIndex = signedText.isEmpty ? reasoningBlocks.count - 1 : nil
                    lastSignedReasoningIndex = reasoningBlocks.count - 1
                    pendingReasoningText = ""
                    pendingReasoningType = "thinking"
                } else if reasoningType == "redacted_thinking", let content = delta.content {
                    reasoningBlocks.append(ReasoningBlock(
                        text: content,
                        signature: nil,
                        type: reasoningType))
                    activeReasoningIndex = nil
                    pendingReasoningText = ""
                    pendingReasoningType = "thinking"
                    await self.handleReasoningDelta(
                        nil,
                        bufferedEvents: &bufferedEvents,
                        buffersEventsUntilDone: buffersAssistantTextUntilDone,
                        eventHandler: eventHandler)
                    continue
                }

                if delta.reasoningSignature == nil, let content = delta.content {
                    if let activeIndex = activeReasoningIndex {
                        reasoningBlocks[activeIndex].text += content
                        activeReasoningIndex = nil
                    } else {
                        pendingReasoningType = reasoningType
                        pendingReasoningText += content
                    }
                }

                let displayContent = delta.content.flatMap { $0.isEmpty ? nil : $0 }
                await self.handleReasoningDelta(
                    displayContent,
                    bufferedEvents: &bufferedEvents,
                    buffersEventsUntilDone: buffersAssistantTextUntilDone,
                    eventHandler: eventHandler)

            case .done:
                let isFirstDone = !didReceiveDone
                didReceiveDone = true
                self.flushPendingReasoningText(
                    &pendingReasoningText,
                    into: lastSignedReasoningIndex,
                    type: pendingReasoningType,
                    reasoningBlocks: &reasoningBlocks)
                usage = delta.usage
                if isFirstDone {
                    onTerminalUsage?(usage)
                }
                finishReason = delta.finishReason
                try Task.checkCancellation()

            default:
                break
            }
        }
        try Task.checkCancellation()

        if buffersAssistantTextUntilDone, !didReceiveDone {
            throw TachikomaError.apiError("Provider stream ended without a terminal event")
        }

        try self.validateToolContinuationFinishReason(
            finishReason,
            hasToolCalls: !stepToolCalls.isEmpty)

        for event in bufferedEvents {
            switch event {
            case let .event(agentEvent):
                await eventHandler?.send(agentEvent)
            }
        }

        return StreamProcessingOutput(
            text: stepText,
            toolCalls: stepToolCalls,
            usage: usage,
            finishReason: finishReason,
            reasoningBlocks: reasoningBlocks)
    }

    private func flushPendingReasoningText(
        _ pendingReasoningText: inout String,
        into reasoningIndex: Int?,
        type: String,
        reasoningBlocks: inout [ReasoningBlock])
    {
        guard !pendingReasoningText.isEmpty else { return }
        if let reasoningIndex, reasoningBlocks.indices.contains(reasoningIndex) {
            reasoningBlocks[reasoningIndex].text += pendingReasoningText
        } else {
            reasoningBlocks.append(ReasoningBlock(
                text: pendingReasoningText,
                signature: nil,
                type: type))
        }
        pendingReasoningText = ""
    }

    // swiftlint:disable:next function_parameter_count
    private func handleTextDelta(
        _ content: String,
        stepText: inout String,
        isThinking: inout Bool,
        bufferedEvents: inout [BufferedStreamEvent],
        buffersAssistantTextUntilDone: Bool,
        eventHandler: EventHandler?) async
    {
        if self.isVerbose {
            self.logger.debug("Text delta content: \(content)")
        }

        stepText += content

        let trimmed = content.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        guard !trimmed.isEmpty, let eventHandler else { return }

        if content.contains("<thinking>") || content.contains("Let me") ||
            content.contains("I need to") || content.contains("I'll")
        {
            isThinking = true
        }

        let event: AgentEvent = if isThinking {
            .thinkingMessage(content: content)
        } else {
            .assistantMessage(content: content)
        }

        if buffersAssistantTextUntilDone {
            bufferedEvents.append(.event(event))
        } else {
            await eventHandler.send(event)
        }
    }

    private func handleToolCallDelta(
        _ toolCall: AgentToolCall,
        stepToolCalls: inout [AgentToolCall],
        seenToolCallIds: inout Set<String>,
        bufferedEvents: inout [BufferedStreamEvent],
        eventHandler: EventHandler?) async throws
    {
        if self.isVerbose {
            self.logger.debug("Received tool call: \(toolCall.name) with ID: \(toolCall.id)")
        }
        let isFirstOccurrence = seenToolCallIds.insert(toolCall.id).inserted

        // Keep the latest version of this tool call so downstream handlers see current args.
        if let existingIndex = stepToolCalls.firstIndex(where: { $0.id == toolCall.id }) {
            stepToolCalls[existingIndex] = toolCall
        } else {
            stepToolCalls.append(toolCall)
        }

        guard eventHandler != nil else { return }

        let argumentsData = try JSONEncoder().encode(toolCall.arguments)
        let argumentsJSON = AgentToolCallArgumentPreview.redacted(from: argumentsData)

        let event: AgentEvent = if isFirstOccurrence {
            .toolCallStarted(name: toolCall.name, arguments: argumentsJSON)
        } else {
            .toolCallUpdated(name: toolCall.name, arguments: argumentsJSON)
        }

        bufferedEvents.append(.event(event))
    }

    private func handleReasoningDelta(
        _ content: String?,
        bufferedEvents: inout [BufferedStreamEvent],
        buffersEventsUntilDone: Bool,
        eventHandler: EventHandler?) async
    {
        guard let content, let eventHandler else { return }
        let event = AgentEvent.thinkingMessage(content: content)
        if buffersEventsUntilDone {
            bufferedEvents.append(.event(event))
        } else {
            await eventHandler.send(event)
        }
    }
}

@available(macOS 14.0, *)
extension PeekabooAgentService {
    func buffersAgentTextStreamUntilDone(for model: LanguageModel) -> Bool {
        switch model {
        case .openai,
             .openaiCompatible,
             .openRouter,
             .together,
             .replicate,
             .google,
             .mistral,
             .groq,
             .grok,
             .azureOpenAI:
            return true
        case let .anthropic(model):
            return AnthropicModelCapabilityInference.hasStreamingRefusalRisk(modelId: model.modelId)
        case let .anthropicCompatible(modelId, _):
            return AnthropicModelCapabilityInference.hasStreamingRefusalRisk(modelId: modelId)
        case let .custom(provider):
            guard let parsed = ProviderParser.parse(provider.modelId) else {
                return AnthropicModelCapabilityInference.hasStreamingRefusalRisk(modelId: provider.modelId)
            }
            if let registeredProvider = CustomProviderRegistry.shared.get(parsed.provider) {
                switch registeredProvider.kind {
                case .openai:
                    return true
                case .anthropic:
                    return AnthropicModelCapabilityInference.hasStreamingRefusalRisk(modelId: parsed.model)
                }
            }
            if let configuredProvider = self.services.configuration.getCustomProvider(id: parsed.provider) {
                switch configuredProvider.type {
                case .openai:
                    return true
                case .anthropic:
                    return AnthropicModelCapabilityInference.hasStreamingRefusalRisk(modelId: parsed.model)
                }
            }
            return AnthropicModelCapabilityInference.hasStreamingRefusalRisk(modelId: parsed.model)
        default:
            return false
        }
    }
}
