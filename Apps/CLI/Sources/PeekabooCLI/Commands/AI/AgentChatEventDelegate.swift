import Foundation
import PeekabooAgentRuntime

@MainActor
final class AgentChatEventDelegate: AgentEventDelegate {
    private weak var ui: AgentChatUI?
    private var lastToolArguments: [String: [String: Any]] = [:]
    private(set) var hasReceivedError = false

    init(ui: AgentChatUI) {
        self.ui = ui
    }

    func agentDidEmitEvent(_ event: AgentEvent) {
        guard let ui else { return }
        switch event {
        case .started:
            break
        case let .assistantMessage(content):
            ui.appendAssistant(content)
        case let .thinkingMessage(content):
            ui.updateThinking(content)
        case let .toolCallStarted(name, arguments):
            self.handleToolStarted(name: name, arguments: arguments, ui: ui)
        case let .toolCallCompleted(name, result):
            self.handleToolCompleted(name: name, result: result, ui: ui)
        case let .toolCallUpdated(name, arguments):
            self.handleToolUpdated(name: name, arguments: arguments, ui: ui)
        case .verificationCompleted, .desktopContextRefreshed:
            break
        case let .error(message):
            self.hasReceivedError = true
            ui.showError(message)
        case .completed:
            ui.finishStreaming()
        case .queueDrained:
            break
        }
    }

    private func handleToolStarted(name: String, arguments: String, ui: AgentChatUI) {
        let args = self.parseArguments(arguments)
        self.lastToolArguments[name] = args
        let formatter = self.toolFormatter(for: name)
        let toolType = ToolType(rawValue: name)
        let summary = formatter?.formatStarting(arguments: args) ??
            name.replacingOccurrences(of: "_", with: " ")
        ui.showToolStart(
            name: name,
            summary: summary,
            icon: toolType?.icon,
            displayName: toolType?.displayName
        )
    }

    private func handleToolCompleted(name: String, result: String, ui: AgentChatUI) {
        let summary = self.toolResultSummary(name: name, result: result)
        let success = Self.successFlag(from: result)
        let toolType = ToolType(rawValue: name)
        ui.showToolCompletion(
            name: name,
            success: success,
            summary: summary,
            icon: toolType?.icon,
            displayName: toolType?.displayName
        )
    }

    private func handleToolUpdated(name: String, arguments: String, ui: AgentChatUI) {
        let args = self.parseArguments(arguments)
        if let previous = self.lastToolArguments[name], self.dictionariesEqual(previous, args) {
            return
        }
        let formatter = self.toolFormatter(for: name)
        let toolType = ToolType(rawValue: name)
        let summary = self.diffSummary(for: name, newArgs: args)
            ?? formatter?.formatStarting(arguments: args)
            ?? name.replacingOccurrences(of: "_", with: " ")
        ui.showToolUpdate(
            name: name,
            summary: summary,
            icon: toolType?.icon,
            displayName: toolType?.displayName
        )
        self.lastToolArguments[name] = args
    }

    private func toolFormatter(for name: String) -> (any ToolFormatter)? {
        if let type = ToolType(rawValue: name) {
            return ToolFormatterRegistry.shared.formatter(for: type)
        }
        return nil
    }

    private func parseArguments(_ jsonString: String) -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    private func parseResult(_ jsonString: String) -> [String: Any]? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func toolResultSummary(name: String, result: String) -> String? {
        guard let json = self.parseResult(result) else { return nil }
        if let summary = ToolEventSummary.from(resultJSON: json)?.shortDescription(toolName: name) {
            return summary
        }
        let formatter = self.toolFormatter(for: name)
        return formatter?.formatResultSummary(result: json)
    }

    static func successFlag(from result: String) -> Bool {
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return true
        }
        return ToolResultExtractor.isSuccess(json)
    }

    /// Minimal diff between previous and new args for the same tool name.
    private func diffSummary(for toolName: String, newArgs: [String: Any]) -> String? {
        guard let previous = self.lastToolArguments[toolName] else { return nil }

        var changes: [String] = []
        for (key, newValue) in newArgs {
            guard let prevValue = previous[key] else {
                changes.append("+\(key)")
                continue
            }
            if !self.valuesEqual(prevValue, newValue) {
                let rendered = self.renderValue(newValue)
                changes.append("\(key): \(rendered)")
            }
            if changes.count >= 3 {
                break
            }
        }

        if changes.isEmpty {
            return nil
        }
        return changes.joined(separator: ", ")
    }

    private func valuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (l as String, r as String): l == r
        case let (l as Int, r as Int): l == r
        case let (l as Double, r as Double): l == r
        case let (l as Bool, r as Bool): l == r
        default: false
        }
    }

    private func dictionariesEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (key, lval) in lhs {
            guard let rval = rhs[key], self.valuesEqual(lval, rval) else { return false }
        }
        return true
    }

    private func renderValue(_ value: Any) -> String {
        switch value {
        case let str as String:
            let max = 32
            if str.count > max {
                let idx = str.index(str.startIndex, offsetBy: max)
                return String(str[..<idx]) + "…"
            }
            return str
        case let num as Int: return String(num)
        case let num as Double: return String(format: "%.3f", num)
        case let bool as Bool: return bool ? "true" : "false"
        default: return "…"
        }
    }
}
