import CoreGraphics
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore

@MainActor
struct MCPSecondaryDisplayPointerTests {
    @Test(arguments: ["-100,200", "100,-200", "-100,-200"])
    func `move accepts signed global coordinates for secondary displays`(_ coordinates: String) async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let response = try await MoveTool(context: context).execute(arguments: ToolArguments(raw: [
            "to": coordinates, "foreground": true,
        ]))
        #expect(!response.isError)
        #expect(automation.lastMoveTarget != nil)
        print("MoveTool signed target=\(coordinates); isError=\(response.isError)")
    }

    @Test
    func `foreground drag accepts endpoints left of and above the primary display`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let response = try await DragTool(context: context).execute(arguments: ToolArguments(raw: [
            "from_coords": "-100,200", "to_coords": "100,-200", "foreground": true,
        ]))
        #expect(!response.isError)
        print("DragTool signed endpoints=-100,200 to100,-200; isError=\(response.isError)")
    }

    @Test(arguments: ["-20001,1", "1,-20001", "20001,1", "nan,1", "inf,1"])
    func `malformed or extreme foreground coordinates are refused`(_ coordinates: String) async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let move = try await MoveTool(context: context).execute(arguments: ToolArguments(raw: [
            "to": coordinates, "foreground": true,
        ]))
        let drag = try await DragTool(context: context).execute(arguments: ToolArguments(raw: [
            "from_coords": "0,0", "to_coords": coordinates, "foreground": true,
        ]))
        #expect(move.isError)
        #expect(drag.isError)
        #expect(automation.lastMoveTarget == nil)
    }
}
