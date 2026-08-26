import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct MCPPolicyAwareCatalogTests {
    @Test
    func `Space tool schema advertises only policy reachable actions`() async {
        let backgroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let tool = SpaceTool(context: backgroundContext)
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(action)? = properties["action"],
              case let .array(actions)? = action["enum"]
        else {
            Issue.record("Expected background-only Space schema")
            return
        }

        #expect(properties["to"] != nil)
        #expect(properties["app"] != nil)
        #expect(properties["window_title"] != nil)
        #expect(properties["window_index"] != nil)
        #expect(properties["to_current"] != nil)
        #expect(properties["follow"] == nil)
        #expect(properties["foreground"] == nil)
        #expect(properties["detailed"] != nil)
        #expect(actions == ["list", "move-window"].map(Value.string))
        #expect(tool.description.contains("immutable background-only"))

        let foregroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .foregroundAllowed)
        let foregroundTool = SpaceTool(context: foregroundContext)
        guard case let .object(foregroundSchema) = foregroundTool.inputSchema,
              case let .object(foregroundProperties)? = foregroundSchema["properties"],
              case let .object(foregroundAction)? = foregroundProperties["action"],
              case let .array(foregroundActions)? = foregroundAction["enum"]
        else {
            Issue.record("Expected foreground-capable Space schema")
            return
        }
        #expect(foregroundActions == ["list", "switch", "move-window"].map(Value.string))
        #expect(foregroundProperties["follow"] != nil)
        #expect(foregroundProperties["foreground"] != nil)
        #expect(foregroundTool.description.contains("Switch to space 2"))
    }

    @Test
    func `Dock tool schema advertises only policy reachable actions`() async throws {
        let backgroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let tool = DockTool(context: backgroundContext)
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(action)? = properties["action"],
              case let .array(actions)? = action["enum"]
        else {
            Issue.record("Expected background-only Dock schema")
            return
        }
        #expect(actions == [Value.string("list")])
        #expect(properties["app"] == nil)
        #expect(properties["select"] == nil)
        #expect(properties["foreground"] == nil)
        #expect(properties["include_all"] != nil)
        #expect(tool.description.contains("available action is `list`"))

        let foregroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .foregroundAllowed)
        let foregroundTool = DockTool(context: foregroundContext)
        guard case let .object(foregroundSchema) = foregroundTool.inputSchema,
              case let .object(foregroundProperties)? = foregroundSchema["properties"],
              case let .object(foregroundAction)? = foregroundProperties["action"],
              case let .array(foregroundActions)? = foregroundAction["enum"],
              case let .object(foreground)? = foregroundProperties["foreground"],
              case .bool(false)? = foreground["default"]
        else {
            Issue.record("Expected foreground-capable Dock schema")
            return
        }
        #expect(foregroundActions == ["launch", "right-click", "hide", "show", "list"].map(Value.string))
        #expect(foregroundProperties["app"] != nil)
        #expect(foregroundProperties["select"] != nil)
        #expect(foregroundTool.description.contains("launch and right-click activate global Dock UI"))

        for action in ["launch", "right-click"] {
            let response = try await foregroundTool.execute(arguments: ToolArguments(raw: [
                "action": action,
                "app": "Finder",
            ]))
            #expect(response.isError)
            guard case let .text(text: message, annotations: _, _meta: _) = response.content.first else {
                Issue.record("Expected Dock foreground validation error")
                continue
            }
            #expect(message.contains("foreground=true"))
        }
    }
}
