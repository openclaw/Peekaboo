import Tachikoma

/// QueueMode mirrors pi-mono's message queue behavior: send queued user messages
/// either one at a time per turn, or all queued together before the next turn.
public enum QueueMode: String, Sendable {
    case oneAtATime = "one-at-a-time"
    case all
}

@MainActor
final class AgentTurnBoundary {
    enum Decision: Equatable {
        case continueTurn
        case stopAfterCurrentStep(reason: String)
        case stopAfterSuccessfulTool(reason: String)
    }

    private static let perceiveTools: Set<String> = [
        "capture",
        "image",
        "see",
        "watch",
    ]

    private static let actionTools: Set<String> = [
        "app",
        "click",
        "dialog",
        "dock",
        "drag",
        "hotkey",
        "launch_app",
        "menu",
        "move",
        "paste",
        "perform_action",
        "scroll",
        "set_value",
        "space",
        "swipe",
        "type",
        "window",
    ]

    private static let readOnlyActionsByTool: [String: Set<String>] = [
        "app": ["list"],
        "dialog": ["list"],
        "dock": ["list"],
        "menu": ["list", "list_all"],
        "space": ["list"],
    ]

    private var hasPerceived = false

    func record(
        toolName: String,
        arguments: [String: AnyAgentToolValue] = [:]) -> Decision
    {
        let normalizedName = Self.normalized(toolName)

        if normalizedName == "done" {
            let message = arguments["message"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = if let message, !message.isEmpty {
                message
            } else {
                "Task completed successfully."
            }
            return .stopAfterSuccessfulTool(reason: reason)
        }

        if normalizedName == "need_info",
           let question = arguments["question"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !question.isEmpty
        {
            return .stopAfterSuccessfulTool(reason: "Need more information: \(question)")
        }

        if Self.perceiveTools.contains(normalizedName) {
            self.hasPerceived = true
            return .continueTurn
        }

        guard self.hasPerceived, Self.isMutatingActionTool(normalizedName, arguments: arguments) else {
            return .continueTurn
        }

        return .stopAfterCurrentStep(
            reason: "Stopped after \(normalizedName); call `see` again before the next UI action.")
    }

    static func normalized(_ toolName: String) -> String {
        toolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
    }

    private static func isMutatingActionTool(
        _ normalizedName: String,
        arguments: [String: AnyAgentToolValue]) -> Bool
    {
        guard self.actionTools.contains(normalizedName) else {
            return false
        }

        guard let readOnlyActions = self.readOnlyActionsByTool[normalizedName],
              let action = arguments["action"]?.stringValue
        else {
            return true
        }

        return !readOnlyActions.contains(self.normalized(action))
    }
}
