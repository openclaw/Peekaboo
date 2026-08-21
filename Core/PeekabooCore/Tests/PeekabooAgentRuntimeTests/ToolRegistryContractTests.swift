import PeekabooAutomation
import PeekabooCore
import Testing
@testable import PeekabooAgentRuntime

@MainActor
struct ToolRegistryContractTests {
    @Test
    func `Default services expose the public background Agent catalog`() async throws {
        let services = PeekabooServices()
        services.installAgentRuntimeDefaults()

        let tools = ToolRegistry.allTools(using: services)
        #expect(!tools.isEmpty)

        let names = Set(tools.map(\.name))
        #expect(names.isSuperset(of: [
            "see",
            "click",
            "type",
            "scroll",
            "press",
            "action",
            "drag",
            "move",
            "app",
            "window",
        ]))
        #expect(!names.contains("shell"))
        #expect(names.isDisjoint(with: ["hotkey", "launch_app", "list"]))

        let agent = try PeekabooAgentService(services: services)
        let sessionNames = await Set(agent.buildToolset(for: .anthropic(.sonnet45)).map(\.name))
        let publicFactoryNames = Set(agent.publicAgentTools().map(\.name))
        #expect(names == sessionNames)
        #expect(names == publicFactoryNames)
    }

    @Test
    func `Final definitions preserve policy-filtered source descriptions without widening`() throws {
        let services = PeekabooServices()
        services.installAgentRuntimeDefaults()

        let sourceTools = try PeekabooAgentService(services: services).publicAgentTools()
        let sourceByName = Dictionary(uniqueKeysWithValues: sourceTools.map { ($0.name, $0) })
        let definitions = ToolRegistry.allTools(using: services)

        for definition in definitions {
            let source = try #require(sourceByName[definition.name])
            #expect(definition.abstract == source.description)
            #expect(definition.discussion == source.description)
            #expect(definition.examples.isEmpty)
        }
    }

    @Test
    func `installAgentRuntimeDefaults feeds MCP context`() {
        let services = PeekabooServices()
        services.installAgentRuntimeDefaults()

        let context = MCPToolContext.shared
        #expect(ObjectIdentifier(context.automation as AnyObject) ==
            ObjectIdentifier(services.automation as AnyObject))
        #expect(context.executionPolicy == .backgroundOnly)
    }

    @Test
    func `Every native MCP tool has an explicit capture profile`() {
        let services = PeekabooServices()
        let context = MCPToolContext(services: services)
        let names = MCPToolCatalog.unfilteredTools(context: context).map(\.name)
        let unclassified = names.filter { MCPToolCaptureRequirement.profile(toolName: $0) == nil }

        #expect(unclassified.isEmpty, "MCP tools missing capture profiles: \(unclassified.sorted())")
    }
}
