import PeekabooAutomationKit
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct ObservationPolicyRequestTests {
    @Test
    func `MCP observations default web focus off`() throws {
        #expect(try !(SeeRequest(arguments: ToolArguments(raw: [:])).webFocus))
        #expect(try !InspectUIRequest(arguments: ToolArguments(raw: [:])).webFocus)
    }

    @Test
    func `MCP observations accept explicit web focus`() throws {
        let arguments = ToolArguments(raw: ["web_focus": true])
        #expect(try SeeRequest(arguments: arguments).webFocus)
        #expect(try InspectUIRequest(arguments: arguments).webFocus)
    }

    @Test
    func `MCP image defaults to background capture`() throws {
        #expect(try ImageRequest(arguments: ToolArguments(raw: [:])).captureFocus == .background)
        #expect(try ImageRequest(arguments: ToolArguments(raw: ["capture_focus": "foreground"])).captureFocus ==
            .foreground)
    }

    @Test
    func `Shared observation models default to background and read only`() {
        #expect(DesktopCaptureOptions().focus == .background)
        #expect(!DesktopDetectionOptions().allowWebFocusFallback)
    }
}
