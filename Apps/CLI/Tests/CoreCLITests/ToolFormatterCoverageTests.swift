import PeekabooAgentRuntime
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite("Current tool formatter coverage")
@MainActor
struct ToolFormatterCoverageTests {
    @Test
    func `current MCP and agent tools use specialized formatters`() throws {
        let services = PeekabooServices()
        let context = MCPToolContext(services: services)
        let mcpNames = MCPToolCatalog.unfilteredTools(context: context).map(\.name)
        let agentNames = try PeekabooAgentService(services: services).createAgentTools().map(\.name)
        let currentToolNames = Set(mcpNames + agentNames)
        let registry = ToolFormatterRegistry()

        for name in currentToolNames.sorted() {
            let toolType = try #require(ToolType(rawValue: name), "Missing ToolType case for \(name)")
            let formatter = registry.formatter(for: toolType)
            let isSpecialized = formatter is ApplicationToolFormatter ||
                formatter is VisionToolFormatter ||
                formatter is UIAutomationToolFormatter ||
                formatter is MenuSystemToolFormatter ||
                formatter is SystemToolFormatter ||
                formatter is DockToolFormatter ||
                formatter is WindowToolFormatter ||
                formatter is ElementToolFormatter ||
                formatter is CommunicationToolFormatter
            #expect(isSpecialized, "\(name) uses the generic formatter fallback")
        }
    }

    @Test
    func `grouped tools include their action in compact summaries`() {
        let registry = ToolFormatterRegistry()

        #expect(registry.formatter(for: .app).formatCompactSummary(arguments: [
            "action": "focus",
            "name": "Safari",
        ]) == "focus Safari")
        #expect(registry.formatter(for: .window).formatCompactSummary(arguments: [
            "action": "resize",
            "app": "Preview",
            "width": 800,
            "height": 600,
        ]) == "resize · Preview · 800×600")
        #expect(registry.formatter(for: .menu).formatCompactSummary(arguments: [
            "action": "click",
            "path": "File > Export",
        ]) == "click · File → Export")
        #expect(registry.formatter(for: .space).formatCompactSummary(arguments: [
            "action": "switch",
            "to": 2,
        ]) == "switch to 2")
    }

    @Test
    func `agent rejects removed realtime option`() {
        #expect(throws: (any Error).self) {
            _ = try AgentCommand.parse(["--realtime"])
        }
    }
}
