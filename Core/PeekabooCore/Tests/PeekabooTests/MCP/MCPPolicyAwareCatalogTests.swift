import MCP
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct MCPPolicyAwareCatalogTests {
    @Test
    func `Paste tool advertises only direct targeted text under background authority`() async throws {
        let backgroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let tool = PasteTool(context: backgroundContext)
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .array(required)? = schema["required"],
              case let .array(targetAlternatives)? = schema["anyOf"]
        else {
            Issue.record("Expected background-only Paste schema")
            return
        }
        #expect(required == [Value.string("text")])
        let requiredTargets = targetAlternatives.compactMap { alternative -> Set<String>? in
            guard case let .object(fields) = alternative,
                  case let .array(required)? = fields["required"]
            else { return nil }
            return Set(required.compactMap(\.stringValue))
        }
        #expect(Set(requiredTargets) == Set([
            Set(["app"]),
            Set(["pid"]),
            Set(["app", "window_id"]),
            Set(["pid", "window_id"]),
            Set(["app", "window_title"]),
            Set(["pid", "window_title"]),
            Set(["app", "window_index"]),
            Set(["pid", "window_index"]),
        ]))
        for alternative in targetAlternatives {
            let required = try #require(Self.requiredFields(alternative))
            #expect(Self.excludedTargetFields(alternative) ==
                Set(["app", "pid", "window_id", "window_title", "window_index"]).subtracting(required))
        }
        #expect(properties["text"] != nil)
        #expect(properties["app"] != nil)
        #expect(properties["pid"] != nil)
        #expect(properties["window_id"] != nil)
        #expect(properties["window_id"]?.objectValue?["description"]?.stringValue?.contains("requires app/pid") == true)
        #expect(properties["window_title"]?.objectValue?["description"]?.stringValue?
            .contains("requires app/pid") == true)
        #expect(properties["filePath"] == nil)
        #expect(properties["imagePath"] == nil)
        #expect(properties["dataBase64"] == nil)
        #expect(properties["uti"] == nil)
        #expect(properties["alsoText"] == nil)
        #expect(properties["allowLarge"] == nil)
        #expect(properties["restore_delay_ms"] == nil)
        #expect(properties["foreground"] == nil)
        let normalizedDescription = tool.description.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(normalizedDescription.contains("explicit app or PID UI target"))
        #expect(normalizedDescription.contains("optionally pinned to one exact window"))
        #expect(tool.description.contains("does not touch the shared clipboard"))
        let targetless = try await backgroundContext.execute(
            tool: tool,
            arguments: ToolArguments(raw: ["text": "must not dispatch"]))
        #expect(targetless.isError)
        #expect(targetless.meta?.objectValue?["refusal_reason"] == .string("foreground_consent_required"))
        #expect(targetless.meta?.objectValue?["mutation_dispatched"] == .bool(false))

        for selector in ["window_title", "window_index"] {
            let value: Value = selector == "window_title" ? .string("Document") : .int(0)
            let invalidStandaloneWindow = try await backgroundContext.execute(
                tool: tool,
                arguments: ToolArguments(value: .object([
                    "text": .string("must not dispatch"),
                    selector: value,
                ])))
            #expect(invalidStandaloneWindow.isError)
            #expect(invalidStandaloneWindow.meta?.objectValue?["refusal_reason"] == .string("invalid_request"))
            #expect(invalidStandaloneWindow.meta?.objectValue?["mutation_dispatched"] == .bool(false))
            #expect(invalidStandaloneWindow.meta?.objectValue?["error_code"] == .string("VALIDATION_ERROR"))
        }

        let foregroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .foregroundAllowed)
        let foregroundTool = PasteTool(context: foregroundContext)
        guard case let .object(foregroundSchema) = foregroundTool.inputSchema,
              case let .object(foregroundProperties)? = foregroundSchema["properties"]
        else {
            Issue.record("Expected foreground-capable Paste schema")
            return
        }
        #expect(foregroundSchema["required"] == nil)
        #expect(foregroundSchema["anyOf"] == nil)
        #expect(foregroundProperties["filePath"] != nil)
        #expect(foregroundProperties["imagePath"] != nil)
        #expect(foregroundProperties["dataBase64"] != nil)
        #expect(foregroundProperties["uti"] != nil)
        #expect(foregroundProperties["alsoText"] != nil)
        #expect(foregroundProperties["allowLarge"] != nil)
        #expect(foregroundProperties["restore_delay_ms"] != nil)
        #expect(foregroundProperties["foreground"] != nil)
        #expect(foregroundProperties["window_id"]?.objectValue?["description"]?.stringValue?
            .contains("foreground focus") == true)
        #expect(foregroundTool.description.contains("Paste the current clipboard"))
    }

    private static func requiredFields(_ schema: Value) -> Set<String>? {
        guard case let .object(fields) = schema,
              case let .array(required)? = fields["required"]
        else { return nil }
        return Set(required.compactMap(\.stringValue))
    }

    private static func excludedTargetFields(_ schema: Value) -> Set<String> {
        guard case let .object(fields) = schema,
              case let .object(notSchema)? = fields["not"],
              case let .array(alternatives)? = notSchema["anyOf"]
        else { return [] }
        return Set(alternatives.compactMap { alternative in
            guard case let .object(fields) = alternative,
                  case let .array(required)? = fields["required"]
            else { return nil }
            return required.compactMap(\.stringValue).first
        })
    }

    @Test
    func `Browser tool hides connection setup under background authority`() async {
        let backgroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .backgroundOnly)
        let tool = BrowserTool(context: backgroundContext)
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(action)? = properties["action"],
              case let .array(actions)? = action["enum"]
        else {
            Issue.record("Expected background-only Browser schema")
            return
        }
        #expect(!actions.contains(.string(BrowserAction.connect.rawValue)))
        #expect(actions.contains(.string(BrowserAction.status.rawValue)))
        #expect(actions.contains(.string(BrowserAction.listPages.rawValue)))
        #expect(properties["browser_url"] == nil)
        #expect(tool.description.contains("Connect is unavailable"))

        let foregroundContext = await MCPToolTestHelpers.makeContext(executionPolicy: .foregroundAllowed)
        let foregroundTool = BrowserTool(context: foregroundContext)
        guard case let .object(foregroundSchema) = foregroundTool.inputSchema,
              case let .object(foregroundProperties)? = foregroundSchema["properties"],
              case let .object(foregroundAction)? = foregroundProperties["action"],
              case let .array(foregroundActions)? = foregroundAction["enum"]
        else {
            Issue.record("Expected foreground-capable Browser schema")
            return
        }
        #expect(foregroundActions.contains(.string(BrowserAction.connect.rawValue)))
        #expect(foregroundProperties["browser_url"] != nil)
        #expect(foregroundTool.description.contains("accept Chrome's remote debugging prompt"))
    }

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
