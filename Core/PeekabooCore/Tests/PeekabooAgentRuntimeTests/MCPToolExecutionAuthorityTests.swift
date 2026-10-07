import Foundation
import MCP
import PeekabooAgentRuntimeTestSupport
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(AuthorityTestIsolation())
@MainActor
struct MCPToolExecutionAuthorityTests {
    @Test
    func `only the explicit bounded snapshot payload is added to background policy`() {
        let authority = MCPToolExecutionAuthority(temporaryClipboardPasteGranted: true)
        let permitted: [String: Any] = [
            "dataBase64": "eA==", "uti": "public.data", "snapshot": "exact-snapshot",
            "alsoText": "fallback", "restore_delay_ms": 150,
        ]
        #expect(authority.rejection(toolName: "paste", arguments: .init(raw: permitted)) == nil)
        #expect(MCPToolExecutionAuthority.backgroundOnly.rejection(
            toolName: "paste", arguments: .init(raw: permitted))?.isError == true)
        for key in [
            "app",
            "pid",
            "window_id",
            "window_title",
            "window_index",
            "text",
            "filePath",
            "imagePath",
            "allowLarge",
        ] {
            var competing = permitted
            competing[key] = key == "allowLarge" ? false : "untrusted"
            #expect(authority.rejection(toolName: "paste", arguments: .init(raw: competing))?.isError == true)
        }
        for key in ["dataBase64", "uti", "snapshot"] {
            var missing = permitted
            missing.removeValue(forKey: key)
            #expect(authority.rejection(toolName: "paste", arguments: .init(raw: missing))?.isError == true)
        }
        for (tool, arguments) in [
            ("paste", ["foreground": true]),
            ("clipboard", ["action": "set", "text": "persistent"]),
            ("clipboard", ["action": "restore"]),
            ("window", ["action": "focus"]),
            ("shell", ["command": "ignored"]),
        ] as [(String, [String: Any])] {
            #expect(authority.rejection(toolName: tool, arguments: .init(raw: arguments))?.isError == true)
        }
    }

    @Test
    @MainActor
    func `temporary grant expands only the paste schema and not nested Agent input`() throws {
        let context = MCPToolContext(
            services: AuthorityTestSupport.services(),
            executionAuthority: .init(temporaryClipboardPasteGranted: true))
        let properties = try #require(PasteTool(context: context).inputSchema.objectValue?["properties"]?.objectValue)
        for key in ["dataBase64", "uti", "alsoText", "restore_delay_ms", "snapshot", "text", "app"] {
            #expect(properties[key] != nil)
        }
        for key in ["foreground", "filePath", "imagePath", "allowLarge"] {
            #expect(properties[key] == nil)
        }
        let nested = try #require(MCPAgentTool(context: context).inputSchema.objectValue?["properties"]?.objectValue)
        #expect(nested["allowTemporaryClipboard"] == nil)
        #expect(nested["temporaryClipboardPasteGranted"] == nil)
        #expect(nested["allowForeground"] == nil)
        let clipboard = try #require(ClipboardTool(context: context).inputSchema.objectValue?["properties"]?
            .objectValue)
        #expect(clipboard["action"]?.objectValue?["enum"]?.arrayValue?.contains(.string("set")) == false)
    }

    @Test
    @MainActor
    func `concurrent Agent construction cannot share temporary permission`() async throws {
        let service = try AuthorityTestSupport.agent(services: AuthorityTestSupport.services())
        let grant = MCPToolExecutionAuthority(temporaryClipboardPasteGranted: true)
        let granted = Task { @MainActor in
            await PeekabooAgentService.$toolConstructionExecutionAuthority.withValue(grant) {
                await Task.yield()
                return service.makeToolContext().executionAuthority
            }
        }
        let ordinary = Task { @MainActor in
            await PeekabooAgentService.$toolConstructionExecutionAuthority.withValue(.backgroundOnly) {
                await Task.yield()
                return service.makeToolContext().executionAuthority
            }
        }
        #expect(await granted.value == grant)
        #expect(await ordinary.value == .backgroundOnly)
        #expect(service.makeToolContext().executionAuthority == .backgroundOnly)
    }

    @Test(arguments: [false, true])
    @MainActor
    func `Agent tool catalog and model preflight agree on the invocation grant`(granted: Bool) async throws {
        let service = try AuthorityTestSupport.agent(services: AuthorityTestSupport.services())
        let authority = MCPToolExecutionAuthority(temporaryClipboardPasteGranted: granted)
        let tools = await service.buildToolset(for: .anthropic(.sonnet45), executionAuthority: authority)
        let paste = try #require(tools.first { $0.name == "paste" })
        #expect((paste.parameters.properties["dataBase64"] != nil) == granted)
        #expect((paste.parameters.properties["snapshot"] != nil) == granted)
        #expect(paste.parameters.properties["foreground"] == nil)
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "synthetic-authority",
            executionAuthority: authority)
        let call = AgentToolCall(id: "synthetic-paste", name: "paste", arguments: [
            "dataBase64": AnyAgentToolValue(string: "eA=="),
            "uti": AnyAgentToolValue(string: "public.data"),
            "snapshot": AnyAgentToolValue(string: "synthetic-exact-snapshot"),
        ])
        #expect((service.makeToolPreflightResult(for: call, context: context) == nil) == granted)
    }

    @Test
    func `temporary clipboard permission does not change the UI policy`() {
        let authority = MCPToolExecutionAuthority(temporaryClipboardPasteGranted: true)

        #expect(authority.basePolicy == .backgroundOnly)
        #expect(authority.permitsTemporaryClipboardPaste)
        #expect(authority != .backgroundOnly)
    }

    @Test
    func `ungranted background authority cannot gain clipboard or foreground permission`() {
        let maximum = MCPToolExecutionAuthority.backgroundOnly

        #expect(!maximum.permitsTemporaryClipboardPaste)
        #expect(maximum.permits(.backgroundOnly))
        #expect(!maximum.permits(.init(temporaryClipboardPasteGranted: true)))
        #expect(!maximum.permits(.init(basePolicy: .foregroundAllowed)))
        #expect(!maximum.permits(.init(basePolicy: .unrestricted)))
    }

    @Test
    func `clipboard maximum accepts a smaller invocation without broadening UI`() {
        let maximum = MCPToolExecutionAuthority(temporaryClipboardPasteGranted: true)

        #expect(maximum.permits(.backgroundOnly))
        #expect(maximum.permits(maximum))
        #expect(!maximum.permits(.init(basePolicy: .foregroundAllowed)))
        #expect(!maximum.permits(.init(basePolicy: .unrestricted)))
    }

    @Test
    func `legacy foreground maximum includes the narrower temporary clipboard route`() {
        let maximum = MCPToolExecutionAuthority(basePolicy: .foregroundAllowed)

        #expect(!maximum.temporaryClipboardPasteGranted)
        #expect(maximum.permitsTemporaryClipboardPaste)
        #expect(maximum.permits(.init(temporaryClipboardPasteGranted: true)))
        #expect(maximum.permits(maximum))
        #expect(!maximum.permits(.init(basePolicy: .unrestricted)))
    }

    @Test
    func `legacy policy remains exhaustively switchable with unchanged raw strings`() {
        for policy in [MCPToolExecutionPolicy.backgroundOnly, .foregroundAllowed, .unrestricted] {
            let expected = switch policy {
            case .backgroundOnly: "background_only"
            case .foregroundAllowed: "foreground_allowed"
            case .unrestricted: "unrestricted"
            }
            #expect(policy.rawValue == expected)
            #expect(MCPToolExecutionPolicy(rawValue: expected) == policy)
        }
    }
}
