//
//  PeekabooAgentService+Toolset.swift
//  PeekabooCore
//

import Foundation
import MCP
import PeekabooAutomation
import Tachikoma

// MARK: - Tool Creation Helpers

extension AgentToolParameters {
    static let empty = AgentToolParameters(properties: [:], required: [])
}

@available(macOS 14.0, *)
extension PeekabooAgentService {
    /// Convert MCP Value schema to AgentToolParameters
    private func convertMCPValueToAgentParameters(_ value: MCP.Value) -> AgentToolParameters {
        guard case let .object(schemaDict) = value else {
            return .empty
        }

        let required = self.parseRequiredFields(in: schemaDict)

        guard let propertiesValue = schemaDict["properties"],
              case let .object(properties) = propertiesValue
        else {
            return AgentToolParameters(properties: [:], required: required)
        }

        let agentProperties = self.convertPropertyMap(properties)
        return AgentToolParameters(properties: agentProperties, required: required)
    }

    private func parseRequiredFields(in schemaDict: [String: MCP.Value]) -> [String] {
        guard let requiredValue = schemaDict["required"],
              case let .array(requiredArray) = requiredValue
        else {
            return []
        }

        return requiredArray.compactMap { value in
            if case let .string(stringValue) = value {
                return stringValue
            }
            return nil
        }
    }

    private func convertPropertyMap(
        _ properties: [String: MCP.Value]) -> [String: AgentToolParameterProperty]
    {
        var agentProperties: [String: AgentToolParameterProperty] = [:]

        for (name, value) in properties {
            guard let property = self.convertProperty(name: name, value: value) else { continue }
            agentProperties[name] = property
        }

        return agentProperties
    }

    private func convertProperty(
        name: String,
        value: MCP.Value) -> AgentToolParameterProperty?
    {
        guard case let .object(propertyDict) = value else { return nil }

        return AgentToolParameterProperty(
            name: name,
            type: self.parameterType(from: propertyDict["type"]),
            description: self.propertyDescription(from: propertyDict["description"], defaultName: name))
    }

    private func parameterType(
        from value: MCP.Value?) -> AgentToolParameterProperty.ParameterType
    {
        guard case let .string(typeString) = value else { return .string }

        switch typeString {
        case "string":
            return .string
        case "number":
            return .number
        case "integer":
            return .integer
        case "boolean":
            return .boolean
        case "array":
            return .array
        case "object":
            return .object
        default:
            return .string
        }
    }

    private func propertyDescription(from value: MCP.Value?, defaultName: String) -> String {
        if case let .string(description) = value {
            return description
        }
        return "Parameter \(defaultName)"
    }

    func buildToolset(for model: LanguageModel) async -> [AgentTool] {
        let tools = self.createAgentTools()

        let filters = ToolFiltering.currentFilters()
        let filtered = ToolFiltering.applyInputStrategyAvailability(
            ToolFiltering.apply(
                tools,
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
