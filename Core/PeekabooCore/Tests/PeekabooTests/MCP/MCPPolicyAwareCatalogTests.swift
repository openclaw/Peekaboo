import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct MCPPolicyAwareCatalogTests {
    @Test
    func `Dialog tool omits foreground-only actions and inputs under background authority`() async {
        let backgroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let tool = DialogTool(context: backgroundContext)
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(action)? = properties["action"],
              case let .array(actions)? = action["enum"]
        else {
            Issue.record("Expected background-only Dialog schema")
            return
        }
        #expect(actions == ["list", "click", "input", "dismiss"].map(Value.string))
        #expect(properties["button"] != nil)
        #expect(properties["text"] != nil)
        #expect(properties["field"] != nil)
        #expect(properties["path"] == nil)
        #expect(properties["name"] == nil)
        #expect(properties["select"] == nil)
        #expect(properties["ensure_expanded"] == nil)
        #expect(properties["force"] == nil)
        #expect(properties["foreground"] == nil)
        #expect(tool.description.contains("targeted non-forced `dismiss`"))

        let foregroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .foregroundAllowed)
        let foregroundTool = DialogTool(context: foregroundContext)
        guard case let .object(foregroundSchema) = foregroundTool.inputSchema,
              case let .object(foregroundProperties)? = foregroundSchema["properties"],
              case let .object(foregroundAction)? = foregroundProperties["action"],
              case let .array(foregroundActions)? = foregroundAction["enum"]
        else {
            Issue.record("Expected foreground-capable Dialog schema")
            return
        }
        #expect(foregroundActions == DialogToolAction.allCases.map { Value.string($0.rawValue) })
        #expect(foregroundProperties["path"] != nil)
        #expect(foregroundProperties["name"] != nil)
        #expect(foregroundProperties["select"] != nil)
        #expect(foregroundProperties["ensure_expanded"] != nil)
        #expect(foregroundProperties["force"] != nil)
        #expect(foregroundProperties["foreground"] != nil)
        #expect(foregroundTool.description.contains("targeted input defaults to background AXValue"))
        #expect(foregroundTool.description.contains(#""foreground": true"#))
    }

    @Test
    func `Menu tool omits impossible foreground control under background authority`() async {
        let backgroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let tool = MenuTool(context: backgroundContext)
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(path)? = properties["path"],
              case let .string(pathDescription)? = path["description"]
        else {
            Issue.record("Expected background-only Menu schema")
            return
        }
        #expect(properties["foreground"] == nil)
        #expect(pathDescription.contains(">"))
        #expect(tool.description.contains("Foreground menu expansion is unavailable"))

        let foregroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .foregroundAllowed)
        let foregroundTool = MenuTool(context: foregroundContext)
        guard case let .object(foregroundSchema) = foregroundTool.inputSchema,
              case let .object(foregroundProperties)? = foregroundSchema["properties"]
        else {
            Issue.record("Expected foreground-capable Menu schema")
            return
        }
        #expect(foregroundProperties["foreground"] != nil)
        #expect(foregroundTool.description.contains("foreground-list actions require an exact"))
    }

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
