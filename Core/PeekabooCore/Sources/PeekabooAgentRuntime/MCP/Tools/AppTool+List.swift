import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

@MainActor
extension AppToolActions {
    func handleList(request: AppToolRequest) async throws -> ToolResponse {
        let appsOutput = try await self.service.listApplications()
        // Preserve the MCP tool's historical app-level inventory. The CLI has explicit
        // --include-background semantics for prohibited helpers; MCP list has no such opt-in.
        let apps = appsOutput.data.applications.filter { $0.activationPolicy != .prohibited }
        let warnings = apps.reduce(into: [String]()) { result, app in
            for warning in app.metadataWarnings ?? [] where !result.contains(warning) {
                result.append(warning)
            }
        }
        let executionTime = self.executionTime(since: request.startTime)

        let summary = apps
            .sorted { $0.isActive && !$1.isActive }
            .map { app in
                let prefix = app.isActive ? AgentDisplayTokens.Status.success : AgentDisplayTokens.Status.info
                let hiddenState = app.isHiddenKnown == false ? ", hidden state unknown" : ""
                return "\(prefix) \(app.name) (PID: \(app.processIdentifier)\(hiddenState))"
            }
            .joined(separator: "\n")
        let countLine = "\(AgentDisplayTokens.Status.info) Found \(apps.count) running applications "
            + "in \(self.executionTimeString(from: executionTime))"

        let baseMeta: [String: Value] = [
            "apps": .array(
                apps.map { app in
                    .object([
                        "name": .string(app.name),
                        "bundle_id": app.bundleIdentifier != nil ? .string(app.bundleIdentifier!) : .null,
                        "process_id": .double(Double(app.processIdentifier)),
                        "is_active": .bool(app.isActive),
                        "is_hidden": app.isHiddenKnown == false ? .null : .bool(app.isHidden),
                        "metadata_warnings": app.metadataWarnings.map { values in
                            .array(values.map(Value.string))
                        } ?? .null,
                    ])
                }),
            "execution_time": .double(executionTime),
            "warnings": .array(warnings.map(Value.string)),
        ]
        let summaryMeta = self.makeSummary(for: nil, action: "List Applications", notes: "Found \(apps.count) apps")
        return ToolResponse(
            content: [
                .text(text: summary, annotations: nil, _meta: nil),
                .text(text: countLine, annotations: nil, _meta: nil),
            ] + warnings.map { warning in
                .text(text: "\(AgentDisplayTokens.Status.warning) \(warning)", annotations: nil, _meta: nil)
            },
            meta: ToolEventSummary.merge(summary: summaryMeta, into: .object(baseMeta)))
    }
}
