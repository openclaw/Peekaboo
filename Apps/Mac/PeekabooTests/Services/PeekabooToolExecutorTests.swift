import Foundation
import PeekabooCore
import Testing
@testable import Peekaboo

@Suite(.tags(.tools, .unit))
@MainActor
struct ToolRegistryTests {
    @Test
    func `All expected tools are registered`() {
        self.installDefaults()
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
            "drag",
            "move",
            "app",
            "window",
            "menu",
            "dialog",
            "dock",
            "shell",
            "done",
            "need_info",
        ]

        #expect(toolNames.isSuperset(of: expectedTools))
        #expect(toolNames.isDisjoint(with: ["hotkey", "launch_app", "list"]))
    }

    @Test
    func `Tool definitions are valid`() {
        self.installDefaults()
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
        self.installDefaults()
        let tool = ToolRegistry.tool(named: "see")
        #expect(tool != nil)
        #expect(tool?.name == "see")
    }

    @Test
    func `Tools are grouped by category`() {
        self.installDefaults()
        let categorizedTools = ToolRegistry.toolsByCategory()
        #expect(!categorizedTools.isEmpty)
        #expect(categorizedTools[.vision] != nil)
        #expect(categorizedTools[.automation] != nil)
        #expect(categorizedTools[.app] != nil)
    }

    @MainActor
    private func installDefaults() {
        let services = PeekabooServices()
        services.installAgentRuntimeDefaults()
    }
}
