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
    @Test(arguments: [
        ("-100,200", CGPoint(x: -100, y: 200)),
        ("100,-200", CGPoint(x: 100, y: -200)),
        ("-100,-200", CGPoint(x: -100, y: -200)),
    ])
    func `move accepts signed global coordinates for secondary displays`(_ input: (String, CGPoint)) async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation, executionPolicy: .foregroundAllowed)
        let response = try await MoveTool(context: context).execute(arguments: ToolArguments(raw: [
            "to": input.0, "foreground": true,
        ]))
        #expect(!response.isError)
        #expect(automation.lastMoveTarget == input.1)
    }

    @Test
    func `foreground drag accepts endpoints left of and above the primary display`() async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation, executionPolicy: .foregroundAllowed)
        let response = try await DragTool(context: context).execute(arguments: ToolArguments(raw: [
            "from_coords": "-100,200", "to_coords": "100,-200", "foreground": true,
        ]))
        #expect(!response.isError)
        #expect(automation.dragRequests.count == 1)
        let request = try #require(automation.dragRequests.first)
        #expect(request.from == CGPoint(x: -100, y: 200))
        #expect(request.to == CGPoint(x: 100, y: -200))
    }

    @Test(arguments: ["-20001,1", "1,-20001", "20001,1", "nan,1", "inf,1"])
    func `malformed or extreme foreground coordinates are refused`(_ coordinates: String) async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation, executionPolicy: .foregroundAllowed)
        let move = try await MoveTool(context: context).execute(arguments: ToolArguments(raw: [
            "to": coordinates, "foreground": true,
        ]))
        let drag = try await DragTool(context: context).execute(arguments: ToolArguments(raw: [
            "from_coords": "0,0", "to_coords": coordinates, "foreground": true,
        ]))
        #expect(move.isError)
        #expect(drag.isError)
        #expect(automation.lastMoveTarget == nil)
        #expect(automation.dragRequests.isEmpty)
    }
}
