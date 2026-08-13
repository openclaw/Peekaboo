import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

extension DialogTool {
    struct ActionResultContext {
        let verb: String
        let notes: String?
        let windowTitle: String?
        let appHint: String?
    }

    func formatActionResult(
        context: ActionResultContext,
        result: DialogActionResult,
        startTime: Date) -> ToolResponse
    {
        let executionTime = Date().timeIntervalSince(startTime)
        let message = "\(AgentDisplayTokens.Status.success) \(context.verb) in \(Self.formattedDuration(executionTime))"

        let baseMeta: [String: Value] = [
            "action": .string(result.action.rawValue),
            "success": .bool(result.success),
            "execution_time": .double(executionTime),
            "details": .object(result.details.mapValues { .string($0) }),
        ]
        let meta = try? MCPToolResponseMetadataProjector.metadata(
            merging: baseMeta,
            outcome: result.outcome)

        let summary = ToolEventSummary(
            targetApp: context.appHint,
            windowTitle: context.windowTitle,
            actionDescription: "Dialog \(context.verb)",
            notes: context.notes)

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: meta))
    }

    func formatList(
        elements: DialogElements,
        executionTime: TimeInterval,
        windowTitle: String?,
        appHint: String?) -> ToolResponse
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

        let meta: Value = .object([
            "title": .string(dialogTitle),
            "role": .string(elements.dialogInfo.role),
            "buttons": .array(buttonTitles.map(Value.string)),
            "text_fields": .array(textFields.map { .object($0.mapValues(Value.string)) }),
            "text_elements": .array(staticTexts.map(Value.string)),
            "execution_time": .double(executionTime),
        ])

        let summary = ToolEventSummary(
            targetApp: appHint,
            windowTitle: windowTitle,
            actionDescription: "Dialog List",
            notes: dialogTitle)

        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: meta))
    }

    static func formattedDuration(_ duration: TimeInterval) -> String {
        String(format: "%.2fs", duration)
    }
}
