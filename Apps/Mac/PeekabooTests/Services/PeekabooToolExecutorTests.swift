import Foundation
import PeekabooCore
import Testing
@testable import Peekaboo

@Suite(.tags(.tools, .unit))
@MainActor
struct ToolRegistryTests {
    @Test
    func `All expected tools are registered`() {
        let services = self.installDefaults()
        defer { withExtendedLifetime(services) {} }
        let allTools = ToolRegistry.allTools()
        #expect(!allTools.isEmpty)

        let toolNames = Set(allTools.map(\.name))

        let expectedTools: Set = [
            "see",
            "click",
            "type",
            "scroll",
            "press",
            "action",
            "app",
            "window",
            "menu",
            "dialog",
            "dock",
            "done",
            "need_info",
        ]

        #expect(toolNames.isSuperset(of: expectedTools))
        #expect(toolNames.isDisjoint(with: ["hotkey", "launch_app", "list", "drag", "move", "shell"]))
    }

    @Test
    func `Tool definitions are valid`() {
        let services = self.installDefaults()
        defer { withExtendedLifetime(services) {} }
        let allTools = ToolRegistry.allTools()

        for tool in allTools {
            #expect(!tool.name.isEmpty)
            #expect(!tool.abstract.isEmpty)

            for param in tool.parameters {
                #expect(!param.name.isEmpty)
                #expect(!param.description.isEmpty)
            }
        }
    }

    @Test
    func `Can retrieve a tool by name`() {
        let services = self.installDefaults()
        defer { withExtendedLifetime(services) {} }
        let tool = ToolRegistry.tool(named: "see")
        #expect(tool != nil)
        #expect(tool?.name == "see")
    }

    @Test
    func `Tools are grouped by category`() {
        let services = self.installDefaults()
        defer { withExtendedLifetime(services) {} }
        let categorizedTools = ToolRegistry.toolsByCategory()
        #expect(!categorizedTools.isEmpty)
        #expect(categorizedTools[.vision] != nil)
        #expect(categorizedTools[.automation] != nil)
        #expect(categorizedTools[.app] != nil)
    }

    @MainActor
    private func installDefaults() -> PeekabooServices {
        let services = PeekabooServices()
        // The default factories capture this owner unowned; each caller must retain it through its assertions.
        services.installAgentRuntimeDefaults()
        return services
    }
}
