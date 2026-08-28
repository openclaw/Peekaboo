//
//  PeekabooAgentService+Toolset.swift
//  PeekabooCore
//

import Foundation
import PeekabooAutomation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    func buildToolset(
        for model: LanguageModel,
        snapshotOwner: MCPToolSnapshotOwner = MCPToolSnapshotOwner(),
        browserClient: (any BrowserMCPClientProviding)? = nil,
        browserCapabilities: BrowserToolCapabilitySession? = nil,
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly) async -> [AgentTool]
    {
        let filtered = self.filteredAgentTools(
            snapshotOwner: snapshotOwner,
            browserClient: browserClient,
            browserCapabilities: browserCapabilities,
            executionPolicy: executionPolicy)

        self.logToolsetDetails(filtered, model: model)
        return filtered
    }

    /// Builds the final Agent catalog before acquiring a remote browser scope.
    ///
    /// When browser survives filtering, only that already-admitted tool is rebuilt with the session-scoped
    /// client. This keeps filter evaluation single-shot and prevents browser-disabled runs from opening a scope.
    func buildExecutionToolset(
        for model: LanguageModel,
        agentSessionID: String,
        agentExecutionGeneration: UUID? = nil,
        snapshotOwner: MCPToolSnapshotOwner,
        executionPolicy: MCPToolExecutionPolicy,
        filters: ToolFilters? = nil,
        onBrowserAcquisitionStarted: (@MainActor () -> Void)? = nil) async throws -> [AgentTool]
    {
        var filtered = self.filteredAgentTools(
            snapshotOwner: snapshotOwner,
            executionPolicy: executionPolicy,
            filters: filters)
        guard let browserIndex = filtered.firstIndex(where: { $0.name == "browser" }) else {
            self.logToolsetDetails(filtered, model: model)
            return filtered
        }

        onBrowserAcquisitionStarted?()
        let browserClient = try await self.browserClient(
            forAgentSessionID: agentSessionID,
            executionGeneration: agentExecutionGeneration)
        let browserCapabilities = self.remoteBrowserCapabilities[agentSessionID]
        let scopedBrowserTool = Self.$toolConstructionSnapshotOwner.withValue(snapshotOwner) {
            Self.$toolConstructionExecutionPolicy.withValue(executionPolicy) {
                Self.$toolConstructionBrowserClient.withValue(browserClient) {
                    AgentToolConstructionContext.$browserCapabilities.withValue(browserCapabilities) {
                        self.createBrowserTool()
                    }
                }
            }
        }
        filtered[browserIndex] = scopedBrowserTool
        self.logToolsetDetails(filtered, model: model)
        return filtered
    }

    /// The exact tool catalog exposed by a normal public Agent session.
    /// Public Agent entry points are background-only by default and never expose Shell.
    public func publicAgentTools(
        snapshotOwner: MCPToolSnapshotOwner = MCPToolSnapshotOwner()) -> [AgentTool]
    {
        self.filteredAgentTools(
            snapshotOwner: snapshotOwner,
            executionPolicy: .backgroundOnly)
    }

    private func filteredAgentTools(
        snapshotOwner: MCPToolSnapshotOwner,
        browserClient: (any BrowserMCPClientProviding)? = nil,
        browserCapabilities: BrowserToolCapabilitySession? = nil,
        executionPolicy: MCPToolExecutionPolicy,
        filters: ToolFilters? = nil) -> [AgentTool]
    {
        let tools = Self.$toolConstructionSnapshotOwner.withValue(snapshotOwner) {
            Self.$toolConstructionExecutionPolicy.withValue(executionPolicy) {
                Self.$toolConstructionBrowserClient.withValue(browserClient) {
                    AgentToolConstructionContext.$browserCapabilities.withValue(browserCapabilities) {
                        self.createAgentTools()
                    }
                }
            }
        }
        let authorityFiltered = tools.filter { executionPolicy.exposesToolInCatalog(named: $0.name) }

        let filters = filters ?? ToolFiltering.currentFilters()
        return ToolFiltering.applyInputStrategyAvailability(
            ToolFiltering.apply(
                authorityFiltered,
                filters: filters,
                log: { [logger] message in
                    logger.notice("\(message, privacy: .public)")
                }),
            policy: self.runtimeInputPolicy(),
            log: { [logger] message in
                logger.notice("\(message, privacy: .public)")
            })
    }

    private func runtimeInputPolicy() -> UIInputPolicy {
        if let automation = self.services.automation as? UIAutomationService {
            return automation.inputPolicy
        }

        return self.services.configuration.getUIInputPolicy()
    }

    private func logToolsetDetails(_ tools: [AgentTool], model: LanguageModel) {
        guard self.isVerbose else { return }
        self.logger.debug("Using model: \(model)")
        self.logger.debug("Model description: \(model.description)")
        self.logger.debug("Passing \(tools.count) tools to generateText")
        for tool in tools {
            let propertyCount = tool.parameters.properties.count
            let requiredCount = tool.parameters.required.count
            self.logger.debug(
                "Tool '\(tool.name)' has \(propertyCount) properties, \(requiredCount) required")
            if tool.name == "see" {
                self.logger.debug("'see' tool required array: \(tool.parameters.required)")
            }
        }
    }

    /// Create AgentTool instances from native Peekaboo tools
    public func createAgentTools() -> [Tachikoma.AgentTool] {
        // Create AgentTool instances from native Peekaboo tools
        var agentTools: [Tachikoma.AgentTool] = []

        // Vision tools
        agentTools.append(createSeeTool())
        agentTools.append(createInspectUITool())
        agentTools.append(createVerifyStateTool())
        agentTools.append(createImageTool())
        agentTools.append(createCaptureTool())
        agentTools.append(createAnalyzeTool())
        agentTools.append(createBrowserTool())

        // UI automation tools
        agentTools.append(createClickTool())
        agentTools.append(createTypeTool())
        agentTools.append(createSetValueTool())
        agentTools.append(createActionTool())
        agentTools.append(createScrollTool())
        agentTools.append(createPressTool())
        agentTools.append(createDragTool())
        agentTools.append(createMoveTool())

        // Window management
        agentTools.append(createWindowTool())

        // Menu interaction
        agentTools.append(createMenuTool())

        // Dialog handling
        agentTools.append(createDialogTool())

        // Dock management
        agentTools.append(createDockTool())

        // Application tools
        agentTools.append(createAppTool()) // Full app management (launch, quit, focus, etc.)

        // Space management
        agentTools.append(createSpaceTool())

        // System tools
        agentTools.append(createPermissionsTool())
        agentTools.append(createSleepTool())
        agentTools.append(createClipboardTool())
        agentTools.append(createPasteTool())

        // Shell tool
        agentTools.append(createShellTool())

        // Completion tools
        agentTools.append(createDoneTool())
        agentTools.append(createNeedInfoTool())

        return agentTools
    }
}
