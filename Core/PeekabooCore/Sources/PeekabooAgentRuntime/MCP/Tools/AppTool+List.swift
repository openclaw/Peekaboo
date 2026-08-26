import Foundation
import MCP
import PeekabooAutomation
import TachikomaMCP

@MainActor
extension AppToolActions {
    func handleList(request: AppToolRequest) async throws -> ToolResponse {
        typealias InstalledOutput = UnifiedToolOutput<ServiceInstalledApplicationListData>
        let catalog: (any InstalledApplicationCatalogProviding)?
        if request.includeInstalled {
            guard let provider = self.service as? any InstalledApplicationCatalogProviding,
                  provider.supportsInstalledApplicationCatalog
            else {
                return ToolResponse.error("The selected runtime host does not support installed application discovery")
            }
            catalog = provider
        } else {
            catalog = nil
        }
        let appsOutput = try await self.service.listApplications()
        let hasIdentityPoorRunningApplications =
            InstalledApplicationReconciler.hasIdentityPoorRunningApplications(appsOutput.data.applications)
        let installedResultsOmitted = request.includeInstalled && hasIdentityPoorRunningApplications
        let installedOutput: InstalledOutput? = if let catalog, !hasIdentityPoorRunningApplications {
            try await catalog.listInstalledApplications()
        } else {
            nil
        }
        // Preserve the MCP tool's historical app-level inventory. The CLI has explicit
        // --include-background semantics for prohibited helpers; MCP list has no such opt-in.
        let apps = appsOutput.data.applications.filter { $0.activationPolicy != .prohibited }
        var warnings = apps.reduce(into: [String]()) { result, app in
            for warning in app.metadataWarnings ?? [] where !result.contains(warning) {
                result.append(warning)
            }
        }
        warnings.append(contentsOf: installedOutput?.metadata.warnings ?? [])
        if installedResultsOmitted {
            warnings.append(
                "Installed-but-not-running results were omitted because a live application lacked " +
                    "bundle identity metadata")
        }
        warnings = Array(Set(warnings)).sorted()
        let installedApplications: [ServiceInstalledApplicationInfo]? = if request.includeInstalled {
            installedOutput.map { output in
                InstalledApplicationReconciler.installedButNotRunning(
                    catalog: output.data.applications,
                    running: appsOutput.data.applications)
                    .filter { $0.declaredPresentation != .backgroundOnly }
            } ?? []
        } else {
            nil
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

        var baseMeta: [String: Value] = [
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
        var installedContent: [MCP.Tool.Content] = []
        if let installedApplications {
            baseMeta["installed_count"] = .double(Double(installedApplications.count))
            baseMeta["installed_status"] = .string(installedResultsOmitted ? "omitted" : "complete")
            baseMeta["installed_apps"] = .array(installedApplications.map { application in
                .object([
                    "name": .string(application.name),
                    "bundle_id": .string(application.bundleIdentifier),
                    "launch_path": .string(application.launchPath),
                    "declared_presentation": .string(application.declaredPresentation.rawValue),
                ])
            })
            if installedResultsOmitted {
                installedContent = [.text(
                    text: "\(AgentDisplayTokens.Status.warning) Installed application status omitted because " +
                        "live bundle identity was incomplete",
                    annotations: nil,
                    _meta: nil)]
            } else {
                let installedSummary = installedApplications.isEmpty
                    ? "\(AgentDisplayTokens.Status.info) No installed-but-not-running applications found"
                    : installedApplications.map { application in
                        "- \(application.name) [\(application.bundleIdentifier)] " +
                            "(\(application.declaredPresentation.rawValue)) — \(application.launchPath)"
                    }.joined(separator: "\n")
                installedContent = [
                    .text(
                        text: "\(AgentDisplayTokens.Status.info) Installed but not running " +
                            "(\(installedApplications.count)):\n\(installedSummary)",
                        annotations: nil,
                        _meta: nil),
                ]
            }
        }
        let notes = if installedResultsOmitted {
            "Found \(apps.count) running applications; installed status omitted due incomplete live identity"
        } else {
            installedApplications.map {
                "Found \(apps.count) running and \($0.count) installed apps"
            } ?? "Found \(apps.count) apps"
        }
        let summaryMeta = self.makeSummary(for: nil, action: "List Applications", notes: notes)
        return ToolResponse(
            content: [
                .text(text: summary, annotations: nil, _meta: nil),
                .text(text: countLine, annotations: nil, _meta: nil),
            ] + installedContent + warnings.map { warning in
                .text(text: "\(AgentDisplayTokens.Status.warning) \(warning)", annotations: nil, _meta: nil)
            },
            meta: ToolEventSummary.merge(summary: summaryMeta, into: .object(baseMeta)))
    }
}
