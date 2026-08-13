//
//  PeekabooAgentService+Toolset.swift
//  PeekabooCore
//

import PeekabooAutomation
import Tachikoma

@available(macOS 14.0, *)
extension PeekabooAgentService {
    func buildToolset(
        for model: LanguageModel,
        snapshotOwner: MCPToolSnapshotOwner = MCPToolSnapshotOwner(),
        executionPolicy: MCPToolExecutionPolicy = .backgroundOnly) async -> [AgentTool]
    {
        let tools = Self.$toolConstructionSnapshotOwner.withValue(snapshotOwner) {
            Self.$toolConstructionExecutionPolicy.withValue(executionPolicy) {
                self.createAgentTools()
            }
        }
        let authorityFiltered = executionPolicy == .unrestricted
            ? tools
            : tools.filter { $0.name != "shell" }

        let filters = ToolFiltering.currentFilters()
        let filtered = ToolFiltering.applyInputStrategyAvailability(
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

        self.logToolsetDetails(filtered, model: model)
        return filtered
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
