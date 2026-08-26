import Foundation
import PeekabooAutomation
import PeekabooFoundation

extension TypeTool {
    func buildEventSummary(
        request: TypeRequest,
        targetContext: TargetElementContext?,
        typingDispatched: Bool) -> ToolEventSummary
    {
        let truncatedInput = typingDispatched ? self.truncatedText(request.text) : nil
        return ToolEventSummary(
            targetApp: targetContext?.snapshot.applicationName ?? request.target.appIdentifier,
            windowTitle: targetContext?.snapshot.windowTitle,
            elementRole: targetContext?.element.summaryRole,
            elementLabel: targetContext?.element.summaryLabel,
            elementValue: truncatedInput,
            actionDescription: typingDispatched ? self.describeAction(for: request) : "Type (confirmed no change)",
            notes: typingDispatched ? truncatedInput : "Confirmed no typing change")
    }

    func buildActions(for request: TypeRequest) throws -> [TypeAction] {
        var actions: [TypeAction] = []

        if request.clearField {
            actions.append(.clear)
        }

        if let text = request.text, !text.isEmpty {
            actions.append(.text(text))
        }

        guard !actions.isEmpty else {
            throw TypeToolValidationError("Specify text or clear=true to run the type tool")
        }

        return actions
    }

    func buildSummary(
        request: TypeRequest,
        executionTime: TimeInterval,
        result: TypeResult,
        typingDispatched: Bool) -> String
    {
        let duration = String(format: "%.2f", executionTime) + "s"
        guard typingDispatched else {
            return "\(AgentDisplayTokens.Status.success) Confirmed no typing change in \(duration)"
        }

        var actions: [String] = []

        if request.clearField {
            actions.append("Cleared field")
        }

        if let text = request.text {
            let displayText = text.count > 50 ? String(text.prefix(50)) + "..." : text
            actions.append("Typed: \"\(displayText)\"")
        }

        if let wpm = request.wordsPerMinute {
            actions.append("Human cadence: \(wpm) WPM")
        } else {
            actions.append("Fixed delay: \(request.delay)ms")
        }

        actions.append("Profile: \(request.profile.rawValue)")
        if let wpm = request.wordsPerMinute ?? (request.profile == .human ? TypeRequest.defaultHumanWPM : nil) {
            if request.profile == .human {
                actions.append("WPM: \(wpm)")
            }
        } else {
            actions.append("Delay: \(request.delay)ms")
        }
        actions.append("Chars: \(result.totalCharacters)")
        let specialKeys = result.specialKeyPresses ?? max(result.keyPresses - result.totalCharacters, 0)
        actions.append("Special keys: \(specialKeys)")

        let summary = actions.isEmpty ? "Performed no actions" : actions.joined(separator: ", ")
        return "\(AgentDisplayTokens.Status.success) \(summary) in \(duration)"
    }

    private func truncatedText(_ text: String?, limit: Int = 80) -> String? {
        guard let text, !text.isEmpty else { return nil }
        if text.count <= limit {
            return text
        }
        let endIndex = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<endIndex]) + "…"
    }

    private func describeAction(for request: TypeRequest) -> String {
        if let text = request.text, !text.isEmpty {
            return "Typed"
        }
        return request.clearField ? "Clear Field" : "Type"
    }
}
