import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    static let freshPerceptionTerminalRejection =
        "Completion rejected: call `see` successfully before claiming the result of the last UI mutation."

    static let completionEvidenceTerminalRejectionPrefix = "Completion rejected: "
    static let invalidTurnBoundaryReason =
        "Stopped because tool-result turn-boundary metadata was conflicting or malformed."

    static func blocksTerminalBoundary(_ result: AgentToolResult) -> Bool {
        AgentToolResultSemantics.isFailure(result)
    }

    static func classifiedToolResult(
        callID: String,
        value: AnyAgentToolValue,
        source: AnyAgentToolValue) -> AgentToolResult
    {
        AgentToolResult(
            toolCallId: callID,
            result: value,
            isError: AgentToolResultSemantics.valueEncodesFailure(source))
    }

    static func restoredTurnBoundary(from messages: [ModelMessage]) -> AgentTurnBoundary {
        let boundary = AgentTurnBoundary()
        let toolCalls = messages.flatMap { message in
            message.content.compactMap { part -> AgentToolCall? in
                guard case let .toolCall(toolCall) = part else { return nil }
                return toolCall
            }
        }
        var resultsByID: [String: [AgentToolResult]] = [:]

        for message in messages {
            for part in message.content {
                guard case let .toolResult(toolResult) = part else { continue }
                resultsByID[toolResult.toolCallId, default: []].append(toolResult)
            }
        }

        for toolCall in toolCalls {
            let toolResult = resultsByID[toolCall.id]?.removeFirst()
            if resultsByID[toolCall.id]?.isEmpty == true {
                resultsByID.removeValue(forKey: toolCall.id)
            }
            _ = boundary.record(toolName: toolCall.name, arguments: toolCall.arguments)
            if let toolResult {
                _ = boundary.recordResult(
                    toolName: toolCall.name,
                    result: toolResult.failure?.metadata ?? toolResult.result)
            }
            if let toolResult, !AgentToolResultSemantics.isFailure(toolResult) {
                boundary.recordSuccessfulCompletion(
                    toolName: toolCall.name,
                    arguments: toolCall.arguments,
                    result: toolResult.result)
            }
        }

        for unmatchedResults in resultsByID.values
            where unmatchedResults.contains(where: Self.resultRequiresFreshPerception)
        {
            boundary.restorePerceptionRequired()
            break
        }

        return boundary
    }

    private static func resultRequiresFreshPerception(_ result: AgentToolResult) -> Bool {
        let semanticValue = result.failure?.metadata ?? result.result
        return switch AgentToolResultSemantics.normalizedClaims(from: semanticValue).turnBoundary {
        case .absent:
            false
        case .invalid:
            true
        case let .valid(boundary):
            boundary.disposition == .continueNextStep
        }
    }

    func appendFreshPerceptionTerminalRejection(
        text: String,
        to messages: inout [ModelMessage],
        steps: inout [GenerationStep],
        stepIndex: Int,
        appendAssistantMessage: Bool = true)
    {
        self.appendFinalStep(
            text: text,
            to: &messages,
            steps: &steps,
            stepIndex: stepIndex,
            appendMessage: appendAssistantMessage)
        messages.append(.user(Self.freshPerceptionTerminalRejection))
    }

    func handleTerminalResponse(
        _ text: String,
        boundary: AgentTurnBoundary,
        state: inout StreamingLoopState,
        stepIndex: Int,
        appendAssistantMessage: Bool = true) -> Bool
    {
        if boundary.requiresFreshPerception {
            self.appendFreshPerceptionTerminalRejection(
                text: text,
                to: &state.messages,
                steps: &state.steps,
                stepIndex: stepIndex,
                appendAssistantMessage: appendAssistantMessage)
            return false
        }
        if let evidenceIssue = boundary.completionEvidenceIssue {
            self.appendFinalStep(
                text: text,
                to: &state.messages,
                steps: &state.steps,
                stepIndex: stepIndex,
                appendMessage: appendAssistantMessage)
            state.messages.append(.user(Self.completionEvidenceTerminalRejectionPrefix + evidenceIssue))
            return false
        }
        state.content += text
        self.appendFinalStep(
            text: text,
            to: &state.messages,
            steps: &state.steps,
            stepIndex: stepIndex,
            appendMessage: appendAssistantMessage)
        return true
    }

    func makeCompletionEvidenceRequiredSkippedResult(
        for toolCall: AgentToolCall,
        reason: String) -> AgentToolResult
    {
        AgentToolResult(
            toolCallId: toolCall.id,
            result: AnyAgentToolValue(object: [
                "completion_evidence_required": AnyAgentToolValue(bool: true),
                "error": AnyAgentToolValue(string: reason),
                "mutation_dispatched": AnyAgentToolValue(bool: false),
                "reason": AnyAgentToolValue(string: reason),
                "retry_safe": AnyAgentToolValue(bool: true),
                "skipped": AnyAgentToolValue(bool: true),
                "success": AnyAgentToolValue(bool: false),
            ]),
            isError: true)
    }

    func makeBoundaryRequiredSkippedResult(
        for toolCall: AgentToolCall,
        decision: AgentTurnBoundary.Decision) -> AgentToolResult?
    {
        switch decision {
        case let .skipUntilCompletionEvidence(reason):
            self.makeCompletionEvidenceRequiredSkippedResult(for: toolCall, reason: reason)
        case let .skipUntilPerception(reason):
            self.makePerceptionRequiredSkippedResult(for: toolCall, reason: reason)
        case .continueTurn, .continueNextStep, .stopAgentAfterSuccessfulTool:
            nil
        }
    }

    func makePerceptionRequiredSkippedResult(
        for toolCall: AgentToolCall,
        reason: String) -> AgentToolResult
    {
        AgentToolResult(
            toolCallId: toolCall.id,
            result: AnyAgentToolValue(object: [
                "error": AnyAgentToolValue(string: reason),
                "mutation_dispatched": AnyAgentToolValue(bool: false),
                "perception_required": AnyAgentToolValue(bool: true),
                "reason": AnyAgentToolValue(string: reason),
                "retry_safe": AnyAgentToolValue(bool: true),
                "skipped": AnyAgentToolValue(bool: true),
                "success": AnyAgentToolValue(bool: false),
            ]),
            isError: true)
    }

    func turnBoundarySignal(from toolResults: [AgentToolResult]) -> AgentTurnBoundarySignal? {
        var continuation: AgentTurnBoundarySignal?
        for toolResult in toolResults {
            switch self.turnBoundarySignal(from: toolResult) {
            case let .stopAgent(reason):
                return .stopAgent(reason: reason)
            case let .continueNextStep(reason):
                if continuation == nil {
                    continuation = .continueNextStep(reason: reason)
                }
            case nil:
                continue
            }
        }
        return continuation
    }

    func turnBoundarySignal(from toolResult: AgentToolResult) -> AgentTurnBoundarySignal? {
        switch AgentToolResultSemantics.normalizedClaims(from: toolResult.result).turnBoundary {
        case .absent:
            nil
        case .invalid:
            .stopAgent(reason: Self.invalidTurnBoundaryReason)
        case let .valid(boundary):
            switch boundary.disposition {
            case .continueNextStep: .continueNextStep(reason: boundary.reason)
            case .stopAgent: .stopAgent(reason: boundary.reason)
            }
        }
    }

    func turnBoundaryStopReason(from toolResults: [AgentToolResult]) -> String? {
        guard case let .stopAgent(reason)? = self.turnBoundarySignal(from: toolResults) else { return nil }
        return reason
    }

    func turnBoundaryStopReason(from toolResult: AgentToolResult) -> String? {
        guard case let .stopAgent(reason)? = self.turnBoundarySignal(from: toolResult) else { return nil }
        return reason
    }
}
