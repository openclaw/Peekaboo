import Foundation
import MCP
import PeekabooAutomation
import PeekabooFoundation
import TachikomaMCP

extension DialogTool {
    struct ActionResultContext {
        let verb: String
        let expectedAction: DialogActionType
        let notes: String?
        let windowTitle: String?
        let appHint: String?
    }

    func formatActionResult(
        context: ActionResultContext,
        result: DialogActionResult,
        outcome: DesktopActionOutcome,
        targetIdentity: DesktopTargetIdentity?,
        startTime: Date) throws -> ToolResponse
    {
        try Self.requireSuccessfulActionResult(
            result,
            outcome: outcome,
            operation: "Dialog \(context.verb.lowercased())",
            expectedAction: context.expectedAction)
        let executionTime = Date().timeIntervalSince(startTime)
        let prefix = if outcome.effect == .unverifiable {
            AgentDisplayTokens.Status.warning
        } else {
            AgentDisplayTokens.Status.success
        }
        let suffix = outcome.effect == .unverifiable
            ? "; effect is unverifiable, observe before retrying"
            : ""
        let message = "\(prefix) \(context.verb) in \(Self.formattedDuration(executionTime))\(suffix)"

        let baseMeta: [String: Value] = [
            "action": .string(result.action.rawValue),
            "success": .bool(result.success),
            "execution_time": .double(executionTime),
            "details": .object(result.details.mapValues { .string($0) }),
        ]
        var targetFields = try MCPDesktopTargetMetadataProjector.fields(targetIdentity)
        if let targetReceipt = result.targetReceipt {
            targetFields["target_receipt"] = try Value(targetReceipt)
        }
        let meta = try MCPToolResponseMetadataProjector.metadata(
            merging: baseMeta.merging(targetFields) { _, target in target },
            outcome: outcome)

        let summary = ToolEventSummary(
            targetApp: context.appHint,
            windowTitle: context.windowTitle,
            actionDescription: "Dialog \(context.verb)",
            notes: context.notes)

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: meta))
    }

    static func requireSuccessfulActionResult(
        _ result: DialogActionResult,
        outcome: DesktopActionOutcome,
        operation: String,
        expectedAction: DialogActionType) throws
    {
        if !result.success {
            guard result.outcome != nil else {
                throw DesktopActionFailure.indeterminate(
                    route: outcome.route,
                    evidence: .completionUnknown,
                    message: "\(operation) returned unsuccessful without a canonical outcome.",
                    hint: "Observe the dialog before retrying and update the execution provider.")
                    .attributed(to: result.targetReceipt)
            }
            if let failure = DesktopActionFailure(
                outcome: outcome,
                message: "\(operation) did not complete successfully.",
                hint: "Follow the canonical outcome metadata before retrying.",
                targetReceipt: result.targetReceipt)
            {
                throw failure
            }
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "\(operation) contradicted its confirmed outcome.",
                hint: "Observe the dialog before retrying and update the execution provider.")
                .attributed(to: result.targetReceipt)
        }

        if !outcome.isAccepted(by: .confirmedOrDispatched) {
            guard let failure = DesktopActionFailure(
                outcome: outcome,
                message: "\(operation) did not return a successful outcome.",
                hint: "Follow the canonical outcome metadata before retrying.",
                targetReceipt: result.targetReceipt)
            else {
                throw DesktopActionFailure.indeterminate(
                    route: outcome.route,
                    delivery: outcome.delivery,
                    evidence: .completionUnknown,
                    unitCount: outcome.dispatchState.unitCount,
                    message: "\(operation) returned contradictory failure metadata.",
                    hint: "Observe the dialog before retrying and update the execution provider.")
                    .attributed(to: result.targetReceipt)
            }
            throw failure
        }
        guard result.action == expectedAction else {
            throw DesktopActionFailure.indeterminate(
                route: outcome.route,
                delivery: outcome.delivery,
                evidence: .completionUnknown,
                unitCount: outcome.dispatchState.unitCount,
                message: "\(operation) returned action \(result.action.rawValue) instead of " +
                    "\(expectedAction.rawValue).",
                hint: "Observe the dialog before retrying and update the execution provider.")
                .attributed(to: result.targetReceipt)
        }
    }

    func formatList(
        elements: DialogElements,
        executionTime: TimeInterval,
        windowTitle: String?,
        appHint: String?,
        targetIdentity: DesktopTargetIdentity?) throws -> ToolResponse
    {
        let dialogTitle = elements.dialogInfo.title
        let buttonTitles = elements.buttons.map(\.title)
        let textFields = elements.textFields.map { field in
            [
                "title": field.title ?? "",
                "value": field.value ?? "",
                "placeholder": field.placeholder ?? "",
            ]
        }
        let staticTexts = elements.staticTexts

        let message = "\(AgentDisplayTokens.Status.success) Dialog '\(dialogTitle)' " +
            "(buttons=\(buttonTitles.count), fields=\(textFields.count), text=\(staticTexts.count)) " +
            "in \(Self.formattedDuration(executionTime))"

        var meta: [String: Value] = [
            "title": .string(dialogTitle),
            "role": .string(elements.dialogInfo.role),
            "buttons": .array(buttonTitles.map(Value.string)),
            "text_fields": .array(textFields.map { .object($0.mapValues(Value.string)) }),
            "text_elements": .array(staticTexts.map(Value.string)),
            "execution_time": .double(executionTime),
        ]
        try meta.merge(MCPDesktopTargetMetadataProjector.fields(targetIdentity)) { _, target in target }

        let summary = ToolEventSummary(
            targetApp: appHint,
            windowTitle: windowTitle,
            actionDescription: "Dialog List",
            notes: dialogTitle)

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: .object(meta)))
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.2fs", duration)
    }
}
