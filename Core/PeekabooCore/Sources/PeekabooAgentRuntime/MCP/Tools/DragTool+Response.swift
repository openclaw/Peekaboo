import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

extension DragTool {
    func buildResponse(
        from: DragPointDescription,
        to: DragPointDescription,
        context: DragResponseContext) throws -> ToolResponse
    {
        let movement = context.movement
        let executionTime = context.executionTime
        let request = context.request
        let deltaX = to.point.x - from.point.x
        let deltaY = to.point.y - from.point.y
        let distance = sqrt(deltaX * deltaX + deltaY * deltaY)

        var message = """
        \(AgentDisplayTokens.Status.success) Performed drag and drop from \(from.description) to \(to.description)
        """
        message += " using \(movement.profileName) profile"
        if let modifiers = request.modifiers, !modifiers.isEmpty {
            message += " with modifiers (\(modifiers))"
        }
        message += " over \(movement.duration)ms with \(movement.steps) steps"
        message += " (distance: \(String(format: "%.1f", distance))px)"
        message += " in \(String(format: "%.2f", executionTime))s"

        var metaData: [String: Value] = [
            "from": .object([
                "x": .double(Double(from.point.x)),
                "y": .double(Double(from.point.y)),
                "description": .string(from.description),
            ]),
            "to": .object([
                "x": .double(Double(to.point.x)),
                "y": .double(Double(to.point.y)),
                "description": .string(to.description),
            ]),
            "duration": .double(Double(movement.duration)),
            "steps": .double(Double(movement.steps)),
            "profile": .string(movement.profileName),
            "distance": .double(distance),
            "execution_time": .double(executionTime),
        ]

        if let modifiers = request.modifiers {
            metaData["modifiers"] = .string(modifiers)
        }

        if let toApp = request.targetApp {
            metaData["target_app"] = .string(toApp)
        }
        if let invalidatedSnapshotID = context.invalidatedSnapshotID {
            metaData["invalidated_snapshot"] = .string(invalidatedSnapshotID)
        }

        let summary = ToolEventSummary(
            targetApp: request.targetApp ?? to.targetApp ?? from.targetApp,
            windowTitle: to.windowTitle ?? from.windowTitle,
            elementRole: to.elementRole ?? from.elementRole,
            elementLabel: to.elementLabel ?? from.elementLabel,
            actionDescription: "Drag",
            coordinates: ToolEventSummary.Coordinates(
                x: Double(to.point.x),
                y: Double(to.point.y)),
            pointerProfile: movement.profileName,
            pointerDistance: Double(distance),
            pointerDirection: pointerDirection(from: from.point, to: to.point),
            pointerDurationMs: Double(movement.duration),
            notes: "from \(from.description) to \(to.description)")

        let meta = try MCPToolResponseMetadataProjector.metadata(
            merging: metaData,
            outcome: context.actionResult.outcome)
        let metaValue = ToolEventSummary.merge(summary: summary, into: meta)

        return ToolResponse(content: [.text(text: message, annotations: nil, _meta: nil)], meta: metaValue)
    }
}
