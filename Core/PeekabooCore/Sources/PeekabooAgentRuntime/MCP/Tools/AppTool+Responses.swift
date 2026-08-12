import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

@MainActor
extension AppToolActions {
    func buildResponse(
        message: String,
        app: ServiceApplicationInfo,
        startTime: Date,
        extraMeta: [String: Value] = [:]) -> ToolResponse
    {
        var meta: [String: Value] = [
            "app_name": .string(app.name),
            "process_id": .double(Double(app.processIdentifier)),
            "process_start_identity": app.processStartIdentity
                .map { .double(Double($0)) } ?? .null,
            "bundle_id": app.bundleIdentifier != nil ? .string(app.bundleIdentifier!) : .null,
            "execution_time": .double(self.executionTime(since: startTime)),
        ]
        meta.merge(extraMeta) { $1 }

        let summary = self.makeSummary(for: app, action: self.actionDescription(from: message), notes: nil)
        return ToolResponse(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: .object(meta)))
    }

    func focusResponse(app: ServiceApplicationInfo, startTime: Date, verb: String) -> ToolResponse {
        let statusLine = "\(AgentDisplayTokens.Status.success) \(verb) \(app.name) (PID: \(app.processIdentifier))"
        let baseMeta: [String: Value] = [
            "app_name": .string(app.name),
            "process_id": .double(Double(app.processIdentifier)),
            "execution_time": .double(self.executionTime(since: startTime)),
        ]
        let summary = self.makeSummary(for: app, action: verb, notes: nil)
        return ToolResponse(
            content: [.text(text: statusLine, annotations: nil, _meta: nil)],
            meta: ToolEventSummary.merge(summary: summary, into: .object(baseMeta)))
    }

    func executionMeta(from startTime: Date) -> Value {
        let baseMeta: Value = .object(["execution_time": .double(self.executionTime(since: startTime))])
        let summary = self.makeSummary(for: nil, action: "Switch Applications", notes: nil)
        return ToolEventSummary.merge(summary: summary, into: baseMeta)
    }

    func executionTime(since startTime: Date) -> Double {
        Date().timeIntervalSince(startTime)
    }

    func executionTimeString(since startTime: Date) -> String {
        self.executionTimeString(from: self.executionTime(since: startTime))
    }

    func executionTimeString(from interval: Double) -> String {
        "\(String(format: "%.2f", interval))s"
    }

    func makeSummary(for app: ServiceApplicationInfo?, action: String, notes: String?) -> ToolEventSummary {
        var summary = ToolEventSummary(
            targetApp: app?.name,
            actionDescription: action,
            notes: notes)
        summary.elementValue = app?.bundleIdentifier
        return summary
    }

    func actionDescription(from message: String) -> String {
        guard let token = message.split(separator: " ").dropFirst().first else {
            return "App"
        }
        return String(token)
    }
}
