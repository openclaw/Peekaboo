import Foundation
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

struct ToolRegistryTests {
    // MARK: - Tool Retrieval Tests

    @Test
    @MainActor
    func `Registry contains expected tools`() {
        let fixture = makeToolRegistryFixture()
        let allTools = fixture.tools

        // Verify registry is not empty
        #expect(!allTools.isEmpty)
    }

    @Test
    @MainActor
    func `Tool retrieval by name`() {
        _ = makeToolRegistryFixture()

        // Test exact name match
        let clickTool = ToolRegistry.tool(named: "click")
        #expect(clickTool != nil)
        #expect(clickTool?.name == "click")

        // Test command name match (if different from tool name)
        let appTool = ToolRegistry.tool(named: "app")
        #expect(appTool != nil)

        // Test non-existent tool
        let nonExistentTool = ToolRegistry.tool(named: "non_existent_tool")
        #expect(nonExistentTool == nil)
    }

    @Test
    @MainActor
    func `Tool retrieval by command name`() {
        let fixture = makeToolRegistryFixture()

        // Find a tool with a different command name
        let toolWithCommandName = fixture.tools.first { $0.commandName != nil }

        if let tool = toolWithCommandName, let cmdName = tool.commandName {
            let retrievedTool = ToolRegistry.tool(named: cmdName)
            #expect(retrievedTool != nil)
            #expect(retrievedTool?.name == tool.name)
        }
    }

    // MARK: - Category Tests

    @Test
    @MainActor
    func `Tools organized by category`() {
        _ = makeToolRegistryFixture()
        let toolsByCategory = ToolRegistry.toolsByCategory()

        // Verify categories are populated
        #expect(!toolsByCategory.isEmpty)

        // Verify each grouped tool retains its category assignment
        for (category, tools) in toolsByCategory {
            for tool in tools {
                #expect(tool.category == category)
            }
        }
    }

    @Test
    func `Category icons`() {
        // Verify all categories have icons
        for category in ToolCategory.allCases {
            let icon = category.icon
            #expect(!icon.isEmpty)
        }

        // Check specific icons
        #expect(ToolCategory.vision.icon == "[see]️")
        #expect(ToolCategory.automation.icon == "👻")
        #expect(ToolCategory.window.icon == "[win]")
        #expect(ToolCategory.app.icon == "[apps]")
        #expect(ToolCategory.menu.icon == "[menu]")
        #expect(ToolCategory.system.icon == "⚙️")
        #expect(ToolCategory.element.icon == "🔍")
    }

    // MARK: - Parameter Tests

    @Test
    @MainActor
    func `Parameter retrieval`() {
        let fixture = makeToolRegistryFixture()

        // Get a tool with parameters
        guard let clickTool = ToolRegistry.tool(named: "click") ?? fixture.tools.first(where: { $0.name == "click" })
        else {
            Issue.record("Click tool not found")
            return
        }

        // Check for expected parameters
        let queryParam = ToolRegistry.parameter(named: "query", from: clickTool)
        #expect(queryParam != nil)
        #expect(queryParam?.type == .string)

        let onParam = ToolRegistry.parameter(named: "on", from: clickTool)
        #expect(onParam != nil)

        // Test non-existent parameter
        let nonExistentParam = ToolRegistry.parameter(named: "non_existent", from: clickTool)
        #expect(nonExistentParam == nil)
    }

    // MARK: - Tool Definition Tests

    @Test
    func `Tool definition properties`() {
        // Create a test tool definition
        let testTool = PeekabooToolDefinition(
            name: "test_tool",
            commandName: "test-cmd",
            abstract: "Test tool abstract",
            discussion: "Detailed test tool discussion",
            category: .system,
            parameters: [
                ParameterDefinition(
                    name: "input",
                    type: .string,
                    description: "Input parameter",
                    required: true),
                ParameterDefinition(
                    name: "count",
                    type: .integer,
                    description: "Count parameter",
                    defaultValue: "1"),
            ],
            examples: ["test-cmd --input hello", "test-cmd --input world --count 5"],
            agentGuidance: "Special guidance for agents")

        // Verify properties
        #expect(testTool.name == "test_tool")
        #expect(testTool.commandName == "test-cmd")
        #expect(testTool.abstract == "Test tool abstract")
        #expect(testTool.category == .system)
        #expect(testTool.parameters.count == 2)
        #expect(testTool.examples.count == 2)
        #expect(testTool.agentGuidance == "Special guidance for agents")

        // Test command configuration
        let config = testTool.commandConfiguration
        #expect(config.commandName == "test-cmd")
        #expect(config.abstract == "Test tool abstract")
        #expect(config.discussion == "Detailed test tool discussion")

        // Test agent description
        let agentDesc = testTool.agentDescription
        #expect(agentDesc.contains("Test tool abstract"))
        #expect(agentDesc.contains("Special guidance for agents"))
    }

    @Test
    func `Tool definition without agent guidance`() {
        let tool = PeekabooToolDefinition(
            name: "simple_tool",
            abstract: "Simple tool",
            discussion: "Simple tool discussion",
            category: .system)

        let agentDesc = tool.agentDescription
        #expect(agentDesc == "Simple tool")
    }

    // MARK: - Parameter Definition Tests

    @Test
    func `Parameter types`() {
        let params = [
            ParameterDefinition(name: "str", type: .string, description: "String param"),
            ParameterDefinition(name: "int", type: .integer, description: "Integer param"),
            ParameterDefinition(name: "bool", type: .boolean, description: "Boolean param"),
            ParameterDefinition(name: "enum", type: .enumeration, description: "Enum param", options: ["a", "b", "c"]),
            ParameterDefinition(name: "obj", type: .object, description: "Object param"),
            ParameterDefinition(name: "arr", type: .array, description: "Array param"),
        ]

        #expect(params[0].type == .string)
        #expect(params[1].type == .integer)
        #expect(params[2].type == .boolean)
        #expect(params[3].type == .enumeration)
        #expect(params[4].type == .object)
        #expect(params[5].type == .array)

        // Check enum options
        #expect(params[3].options == ["a", "b", "c"])
    }

    @Test
    func `CLI options`() {
        let param = ParameterDefinition(
            name: "verbose",
            type: .boolean,
            description: "Verbose output",
            cliOptions: CLIOptions(
                argumentType: .flag,
                shortName: "v",
                longName: "verbose"))

        #expect(param.cliOptions?.argumentType == .flag)
        #expect(param.cliOptions?.shortName == "v")
        #expect(param.cliOptions?.longName == "verbose")
    }

    // MARK: - Agent Conversion Tests

    @Test
    func `Tool to agent parameters conversion`() {
        let tool = PeekabooToolDefinition(
            name: "test_tool",
            abstract: "Test tool",
            discussion: "Test tool discussion",
            category: .system,
            parameters: [
                ParameterDefinition(
                    name: "input-text",
                    type: .string,
                    description: "Input text",
                    required: true),
                ParameterDefinition(
                    name: "count",
                    type: .integer,
                    description: "Count",
                    defaultValue: "1"),
                ParameterDefinition(
                    name: "enabled",
                    type: .boolean,
                    description: "Enabled flag"),
                ParameterDefinition(
                    name: "mode",
                    type: .enumeration,
                    description: "Mode selection",
                    options: ["fast", "slow", "medium"]),
            ])

        let agentParams = tool.toAgentToolParameters()

        self.assertAgentParameters(agentParams)
        let properties = agentParams.properties

        if let enabledParam = properties["enabled"] {
            #expect(enabledParam.type == Tachikoma.AgentToolParameterProperty.ParameterType.boolean)
        } else {
            Issue.record("enabled parameter not found")
        }

        if let modeParam = properties["mode"] {
            #expect(modeParam.type == Tachikoma.AgentToolParameterProperty.ParameterType.string)
            #expect(modeParam.enumValues == ["fast", "slow", "medium"])
        } else {
            Issue.record("mode parameter not found")
        }
    }

    // MARK: - Registry Integrity Tests

    @Test
    @MainActor
    func `All tools have valid categories`() {
        let fixture = makeToolRegistryFixture()
        let allTools = fixture.tools
        let validCategories = Set(ToolCategory.allCases)

        for tool in allTools {
            #expect(validCategories.contains(tool.category))
        }
    }

    @Test
    @MainActor
    func `No duplicate tool names`() {
        let fixture = makeToolRegistryFixture()
        let allTools = fixture.tools
        let toolNames = allTools.map(\.name)
        let uniqueToolNames = Set(toolNames)

        #expect(toolNames.count == uniqueToolNames.count, "Found duplicate tool names")
    }

    @Test
    @MainActor
    func `All tools have abstracts and discussions`() {
        let fixture = makeToolRegistryFixture()
        let allTools = fixture.tools

        for tool in allTools {
            #expect(!tool.abstract.isEmpty, "Tool \(tool.name) has empty abstract")
            #expect(!tool.discussion.isEmpty, "Tool \(tool.name) has empty discussion")
        }
    }
}

extension ToolRegistryTests {
    private func assertAgentParameters(_ agentParams: AgentToolParameters) {
        #expect(agentParams.type == "object")

        let properties = agentParams.properties
        let required = agentParams.required

        self.assertProperty(
            "input_text",
            expectedType: Tachikoma.AgentToolParameterProperty.ParameterType.string,
            existsIn: properties)
        self.assertProperty(
            "count",
            expectedType: Tachikoma.AgentToolParameterProperty.ParameterType.integer,
            existsIn: properties)
        self.assertProperty(
            "enabled",
            expectedType: Tachikoma.AgentToolParameterProperty.ParameterType.boolean,
            existsIn: properties)
        self.assertProperty(
            "mode",
            expectedType: Tachikoma.AgentToolParameterProperty.ParameterType.string,
            existsIn: properties)

        #expect(required.contains("input_text"))
        #expect(!required.contains("count"))
    }

    private func assertProperty(
        _ name: String,
        expectedType: Tachikoma.AgentToolParameterProperty.ParameterType,
        existsIn properties: [String: Tachikoma.AgentToolParameterProperty])
    {
        if let property = properties[name] {
            #expect(property.type == expectedType)
        } else {
            Issue.record("\(name) parameter not found")
        }
    }
}

@MainActor
private func makeToolRegistryFixture() -> ToolRegistryFixture {
    let services = PeekabooServices()
    ToolRegistry.configureDefaultServices { services }
    let tools = ToolRegistry.allTools(using: services)
    return ToolRegistryFixture(services: services, tools: tools)
}

private struct ToolRegistryFixture {
    let services: PeekabooServices
    let tools: [PeekabooToolDefinition]
}
