import CoreGraphics
import MCP
import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore

@MainActor
struct MCPHumanMoveParameterTests {
    @Test(arguments: [
        ("duration", -1),
        ("duration", 0),
        ("duration", 30001),
        ("duration", Int.max),
        ("steps", -1),
        ("steps", 0),
        ("steps", 101),
        ("steps", Int.max),
    ])
    func `human movement refuses invalid overrides before pointer dispatch`(_ input: (String, Int)) async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let response = try await MoveTool(context: context).execute(arguments: ToolArguments(raw: [
            "to": "50,60", "foreground": true, "profile": "human", input.0: input.1,
        ]))
        #expect(response.isError)
        #expect(automation.lastMoveTarget == nil)
        print(
            "MoveTool human override=\(input.0):\(input.1); refused=\(response.isError); " +
                "dispatched=\(automation.lastMoveTarget != nil)")
    }

    @Test(arguments: ["linear", "human"])
    func `valid smooth overrides still execute for both profiles`(_ profile: String) async throws {
        let automation = MockAutomationService(accessibilityGranted: true)
        let context = await MCPToolTestHelpers.makeLegacyContext(automation: automation)
        let response = try await MoveTool(context: context).execute(arguments: ToolArguments(raw: [
            "to": "50,60", "foreground": true, "smooth": true, "profile": profile, "duration": 1000, "steps": 50,
        ]))
        #expect(!response.isError)
        #expect(automation.lastMoveTarget == CGPoint(x: 50, y: 60))
    }
}
