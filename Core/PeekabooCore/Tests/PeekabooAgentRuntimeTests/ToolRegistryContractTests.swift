import PeekabooAgentRuntime
import PeekabooAutomation
import PeekabooCore
import Testing

@MainActor
struct ToolRegistryContractTests {
    @Test
    func `Default services expose automation tools`() {
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
        #expect(names.isDisjoint(with: ["hotkey", "launch_app", "list"]))
    }

    @Test
    func `installAgentRuntimeDefaults feeds MCP context`() {
        let services = PeekabooServices()
        services.installAgentRuntimeDefaults()

        let context = MCPToolContext.shared
        #expect(ObjectIdentifier(context.automation as AnyObject) ==
            ObjectIdentifier(services.automation as AnyObject))
    }
}
