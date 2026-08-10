import Foundation
import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

private let noToolFilters = ToolFilters(
    allow: [],
    deny: [],
    allowSource: .none,
    denySources: [:])

@MainActor
struct MCPToolRegistryTests {
    @Test
    func `Registry initialization`() {
        let registry = MCPToolRegistry()
        let tools = registry.allTools()

        // Registry should start empty
        #expect(tools.isEmpty)
    }

    @Test
    func `Register single tool`() {
        let registry = MCPToolRegistry()
        let mockTool = MockTool(
            name: "test-tool",
            description: "A test tool",
            inputSchema: .object([:]))

        registry.register(mockTool)

        let tools = registry.allTools()
        #expect(tools.count == 1)

        let registeredTool = registry.tool(named: "test-tool")
        #expect(registeredTool != nil)
        #expect(registeredTool?.name == "test-tool")
    }

    @Test
    func `Register multiple tools`() {
        let registry = MCPToolRegistry()
        let tools = [
            MockTool(name: "tool1", description: "Tool 1", inputSchema: .object([:])),
            MockTool(name: "tool2", description: "Tool 2", inputSchema: .object([:])),
            MockTool(name: "tool3", description: "Tool 3", inputSchema: .object([:])),
        ]

        registry.register(tools)

        let allTools = registry.allTools()
        #expect(allTools.count == 3)

        // Verify each tool can be retrieved
        for tool in tools {
            let retrieved = registry.tool(named: tool.name)
            #expect(retrieved != nil)
            #expect(retrieved?.name == tool.name)
        }
    }

    @Test
    func `Tool overwriting`() {
        let registry = MCPToolRegistry()

        let tool1 = MockTool(
            name: "duplicate",
            description: "Original tool",
            inputSchema: .object([:]))

        let tool2 = MockTool(
            name: "duplicate",
            description: "Replacement tool",
            inputSchema: .object(["newField": .string("test")]))

        registry.register(tool1)
        registry.register(tool2)

        let tools = registry.allTools()
        #expect(tools.count == 1)

        let retrieved = registry.tool(named: "duplicate")
        #expect(retrieved?.description == "Replacement tool")
    }

    @Test
    func `Tool not found`() {
        let registry = MCPToolRegistry()

        let tool = registry.tool(named: "nonexistent")
        #expect(tool == nil)
    }

    @Test
    func `Tool info conversion`() throws {
        let registry = MCPToolRegistry()

        let mockTool = MockTool(
            name: "info-test",
            description: "Tool for testing info conversion",
            inputSchema: SchemaBuilder.object(
                properties: [
                    "param1": SchemaBuilder.string(description: "First parameter"),
                    "param2": SchemaBuilder.number(description: "Second parameter"),
                ],
                required: ["param1"]))

        registry.register(mockTool)

        let toolInfos = registry.toolInfos()
        #expect(toolInfos.count == 1)

        let info = try #require(toolInfos.first)
        #expect(info.name == "info-test")
        #expect(info.description == "Tool for testing info conversion")

        // Verify schema is properly converted
        guard case let .object(schemaDict) = info.inputSchema else {
            Issue.record("Expected object schema")
            return
        }

        if case let .string(type)? = schemaDict["type"] {
            #expect(type == "object")
        } else {
            Issue.record("Expected schema type string")
        }
        #expect(schemaDict["properties"] != nil)
        #expect(schemaDict["required"] != nil)
    }

    @Test
    func `Registry thread safety`() async {
        let registry = MCPToolRegistry()

        // Concurrently register many tools
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let tool = MockTool(
                        name: "concurrent-\(i)",
                        description: "Concurrent tool \(i)",
                        inputSchema: .object([:]))
                    await registry.register(tool)
                }
            }
        }

        let tools = registry.allTools()
        #expect(tools.count == 100)

        // Verify all tools were registered correctly
        for i in 0..<100 {
            let tool = registry.tool(named: "concurrent-\(i)")
            #expect(tool != nil)
        }
    }

    @Test
    func `Empty registry tool infos`() {
        let registry = MCPToolRegistry()
        let infos = registry.toolInfos()

        #expect(infos.isEmpty)
    }
}

@Suite(.tags(.integration))
@MainActor
struct MCPToolRegistryIntegrationTests {
    @Test
    func `MCP tool catalog contains authoritative Peekaboo MCP tools`() {
        let services = PeekabooServices()
        let context = MCPToolContext(services: services)
        let tools = MCPToolCatalog.tools(
            context: context,
            inputPolicy: services.configuration.getUIInputPolicy(),
            filters: noToolFilters)
        let names = Set(tools.map(\.name))

        #expect(tools.count == 26)
        #expect(names.contains("clipboard"))
        #expect(names.contains("paste"))
        #expect(names.contains("set_value"))
        #expect(names.contains("action"))
        #expect(names.contains("press"))
        #expect(!names.contains("hotkey"))
        #expect(!names.contains("swipe"))
        #expect(names.contains("inspect_ui"))
        #expect(names.contains("verify_state"))
        #expect(names.contains("capture"))
        #expect(!names.contains("shell"))
    }

    @Test
    func `Register all Peekaboo tools`() {
        let registry = MCPToolRegistry()
        let services = PeekabooServices()
        let context = MCPToolContext(services: services)

        registry.register(MCPToolCatalog.tools(
            context: context,
            inputPolicy: services.configuration.getUIInputPolicy(),
            filters: noToolFilters))

        let tools = registry.allTools()
        #expect(tools.count == 26)

        // Verify some key tools are present
        let imageToolExists = registry.tool(named: "image") != nil
        let clickToolExists = registry.tool(named: "click") != nil
        let agentToolExists = registry.tool(named: "agent") != nil
        let clipboardToolExists = registry.tool(named: "clipboard") != nil
        let inspectUIToolExists = registry.tool(named: "inspect_ui") != nil
        let captureToolExists = registry.tool(named: "capture") != nil

        #expect(imageToolExists)
        #expect(clickToolExists)
        #expect(agentToolExists)
        #expect(clipboardToolExists)
        #expect(inspectUIToolExists)
        #expect(captureToolExists)
    }

    @Test
    @MainActor
    func `Tool info schema validation`() throws {
        let registry = MCPToolRegistry()

        // Register a complex tool with full schema
        let complexTool = MockTool(
            name: "complex",
            description: "A complex tool with many parameters",
            inputSchema: SchemaBuilder.object(
                properties: [
                    "requiredString": SchemaBuilder.string(description: "A required string"),
                    "optionalNumber": SchemaBuilder.number(description: "An optional number"),
                    "enumValue": SchemaBuilder.string(
                        description: "Choice value",
                        enum: ["option1", "option2", "option3"],
                        default: "option1"),
                    "flagValue": SchemaBuilder.boolean(description: "A boolean flag"),
                    "nestedObject": SchemaBuilder.object(
                        properties: [
                            "innerField": SchemaBuilder.string(description: "Inner field"),
                        ],
                        required: ["innerField"]),
                ],
                required: ["requiredString"],
                description: "Complex tool schema"))

        registry.register(complexTool)

        let infos = registry.toolInfos()
        #expect(infos.count == 1)

        let info = try #require(infos.first)

        // Validate the schema structure is preserved
        guard case let .object(schema) = info.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(props.count == 5)
        #expect(props["requiredString"] != nil)
        #expect(props["optionalNumber"] != nil)
        #expect(props["enumValue"] != nil)
        #expect(props["flagValue"] != nil)
        #expect(props["nestedObject"] != nil)

        // Check required array
        if let required = schema["required"],
           case let .array(requiredArray) = required
        {
            #expect(requiredArray.count == 1)
            #expect(requiredArray.contains(.string("requiredString")))
        }
    }
}
