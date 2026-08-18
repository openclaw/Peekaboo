import Darwin
import Foundation
import MCP
import PeekabooFoundation
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

@MainActor
private func makeTestTool<T>(_ factory: (MCPToolContext) -> T) -> T {
    let services = PeekabooServices()
    return factory(MCPToolContext(services: services))
}

private func makeTestTool<T>(_ builder: () -> T) -> T {
    builder()
}

@MainActor
private func makeTestTool<T>(
    executionPolicy: MCPToolExecutionPolicy,
    _ factory: (MCPToolContext) -> T) -> T
{
    let services = PeekabooServices()
    return factory(MCPToolContext(services: services, executionPolicy: executionPolicy))
}

@MainActor
struct MCPSpecificToolTests {
    @Test
    func `Clipboard schema uses snake case payload names and excludes load`() {
        let tool = makeTestTool(ClipboardTool.init)
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(action)? = properties["action"],
              case let .array(actions)? = action["enum"],
              case let .object(outputPath)? = properties["outputPath"],
              case let .string(outputPathDescription)? = outputPath["description"]
        else {
            Issue.record("Expected clipboard schema properties and action enum")
            return
        }

        #expect(properties["file_path"] != nil)
        #expect(properties["data_base64"] != nil)
        #expect(properties["filePath"] == nil)
        #expect(properties["imagePath"] == nil)
        #expect(properties["dataBase64"] == nil)
        #expect(!actions.contains(.string("load")))
        #expect(actions == ["get", "set", "clear", "save", "restore"].map(Value.string))
        #expect(outputPathDescription.contains("'-' stdout sentinel is not supported"))
        #expect(outputPathDescription.contains("JSON-RPC"))
    }

    @Test
    func `Clipboard rejects stdout output path before reading`() async throws {
        let tool = makeTestTool(ClipboardTool.init)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "get",
            "outputPath": "-",
        ]))

        #expect(response.isError)
        guard case let .text(text, _, _) = response.content.first else {
            Issue.record("Expected actionable clipboard stdout refusal")
            return
        }
        #expect(text.contains("stdout carries JSON-RPC"))
        #expect(text.contains("Omit outputPath"))
        #expect(text.contains("filesystem path"))

        guard case let .object(meta)? = response.meta else {
            Issue.record("Expected structured clipboard stdout refusal metadata")
            return
        }
        #expect(meta["effect"] == .string("refused"))
        #expect(meta["error_code"] == .string("MCP_CLIPBOARD_STDOUT_UNAVAILABLE"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    // MARK: - See Tool Tests

    @Test
    func `See tool schema includes annotation options`() {
        let tool = makeTestTool(SeeTool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        // Verify see tool properties
        #expect(props["annotate"] != nil)
        #expect(props["snapshot"] != nil)
        #expect(props["app_target"] != nil)
        #expect(props["window_id"] != nil)
        #expect(props["path"] != nil)
        #expect(props["web_focus"] != nil)
        #expect(props["roi"] != nil)

        // Check annotate default value
        if let annotateSchema = props["annotate"],
           case let .object(annotateDict) = annotateSchema,
           let defaultValue = annotateDict["default"],
           case let .bool(annotateDefault) = defaultValue
        {
            #expect(annotateDefault == false)
        }
        #expect(Self.booleanDefault(for: "web_focus", in: props) == false)

        let imageTool = makeTestTool(ImageTool.init)
        guard case let .object(imageSchema) = imageTool.inputSchema,
              case let .object(imageProperties)? = imageSchema["properties"]
        else {
            Issue.record("Expected image tool object schema")
            return
        }
        #expect(imageProperties["roi"] == nil)
    }

    @Test
    func `See ROI requires exact window and fresh snapshot`() throws {
        #expect(throws: (any Error).self) {
            _ = try SeeRequest(arguments: ToolArguments(raw: ["roi": "0,0,100,100"]))
        }
        #expect(throws: (any Error).self) {
            _ = try SeeRequest(arguments: ToolArguments(raw: [
                "roi": "0,0,100,100",
                "window_id": 42,
                "snapshot": "existing",
            ]))
        }
        let request = try SeeRequest(arguments: ToolArguments(raw: [
            "roi": "10,20,100,50",
            "window_id": 42,
        ]))
        #expect(request.roi?.bounds == CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(try ObservationTargetArgument.parse(nil, windowIDValue: .int(42)) == .windowID(42))
        #expect(try ObservationTargetArgument.parse("", windowIDValue: .int(42)) == .windowID(42))
    }

    @Test
    func `Inspect UI tool schema has correct properties`() {
        let tool = makeTestTool(InspectUITool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(props["app_target"] != nil)
        #expect(props["window_id"] != nil)
        #expect(props["snapshot"] != nil)
        #expect(props["web_focus"] != nil)
        #expect(props["annotate"] == nil)
        #expect(props["path"] == nil)
        #expect(Self.booleanDefault(for: "web_focus", in: props) == false)
    }

    @Test
    func `Image and capture schemas default focus to background`() {
        let tools: [any MCPTool] = [makeTestTool(ImageTool.init), makeTestTool(CaptureTool.init)]
        for tool in tools {
            guard case let .object(schema) = tool.inputSchema,
                  case let .object(properties)? = schema["properties"],
                  case let .object(focus)? = properties["capture_focus"],
                  case let .string(defaultValue)? = focus["default"]
            else {
                Issue.record("Expected capture_focus default for \(tool.name)")
                continue
            }
            #expect(defaultValue == "background")
        }
    }

    private static func booleanDefault(for key: String, in properties: [String: Value]) -> Bool? {
        guard case let .object(schema)? = properties[key],
              case let .bool(value)? = schema["default"]
        else { return nil }
        return value
    }

    // MARK: - Dialog Tool Tests

    @Test
    func `Dialog tool schema validation`() {
        let tool = makeTestTool(DialogTool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        // Dialog tool should have action and optional parameters
        #expect(props["action"] != nil)
        #expect(props["button"] != nil)
        #expect(props["text"] != nil)
        #expect(props["field"] != nil)
        #expect(props["clear"] != nil)
        #expect(props["path"] != nil)
        #expect(props["select"] != nil)
        #expect(props["window_title"] != nil)
        #expect(props["window_index"] != nil)
        #expect(props["window_id"] != nil)
        #expect(props["name"] != nil)
        #expect(props["force"] != nil)
        #expect(props["field_index"] != nil)
        #expect(props["foreground"] != nil)
        #expect(tool.description.contains("targeted input defaults to background AXValue"))
        #expect(tool.description.contains(#""action": "input""#))
        #expect(tool.description.contains(#""foreground": true"#))

        // Check action enum values
        if let actionSchema = props["action"],
           case let .object(actionDict) = actionSchema,
           let enumValue = actionDict["enum"],
           case let .array(actions) = enumValue
        {
            #expect(actions.contains(.string("list")))
            #expect(actions.contains(.string("click")))
            #expect(actions.contains(.string("input")))
        }
    }

    @Test
    func `Dialog tool requires foreground for global input paths`() async throws {
        let tool = makeTestTool(DialogTool.init)
        let requests: [([String: Any], String)] = [
            (["action": "input", "text": "hello"], "Targetless dialog input"),
            (["action": "file", "path": "/tmp"], "Dialog file"),
            (["action": "dismiss", "force": true], "Forced dialog dismiss"),
        ]

        for (request, expectedPrefix) in requests {
            let response = try await tool.execute(arguments: ToolArguments(raw: request))
            #expect(response.isError)
            guard case let .text(text, _, _) = response.content.first else {
                Issue.record("Expected foreground validation error")
                continue
            }
            #expect(text.contains(expectedPrefix))
            #expect(text.contains("requires foreground=true"))
        }
    }

    @Test
    func `Dialog list rejects foreground mode`() async throws {
        let tool = makeTestTool(DialogTool.init)
        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "list",
            "foreground": true,
        ]))

        #expect(response.isError)
        guard case let .text(text, _, _) = response.content.first else {
            Issue.record("Expected background-only validation error")
            return
        }
        #expect(text.contains("always read-only/background"))
    }

    // MARK: - Menu Tool Tests

    @Test
    func `Menu tool schema includes path format`() {
        let tool = makeTestTool(MenuTool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(props["action"] != nil)
        #expect(props["path"] != nil)
        #expect(props["app"] != nil)
        #expect(props["foreground"] != nil)

        // Verify path description includes format examples
        if let pathSchema = props["path"],
           case let .object(pathDict) = pathSchema,
           let description = pathDict["description"],
           case let .string(desc) = description
        {
            #expect(desc.contains(">") || desc.contains("separator"))
        }
    }

    // MARK: - Space Tool Tests

    @Test
    func `Space tool schema includes Mission Control actions`() {
        let tool = makeTestTool(SpaceTool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(props["action"] != nil)
        #expect(props["to"] != nil)
        #expect(props["app"] != nil)
        #expect(props["window_title"] != nil)
        #expect(props["window_index"] != nil)
        #expect(props["to_current"] != nil)
        #expect(props["follow"] != nil)
        #expect(props["foreground"] != nil)
        #expect(props["detailed"] != nil)

        // Check action types
        if let actionSchema = props["action"],
           case let .object(actionDict) = actionSchema,
           let enumValue = actionDict["enum"],
           case let .array(actions) = enumValue
        {
            #expect(actions.contains(.string("list")))
            #expect(actions.contains(.string("switch")))
            #expect(actions.contains(.string("move-window")))
        }
    }

    // MARK: - Drag Tool Tests

    @Test
    func `Drag tool schema includes coordinate support`() {
        let tool = makeTestTool(DragTool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(props["from"] != nil)
        #expect(props["to"] != nil)
        #expect(props["duration"] != nil)
        #expect(props["modifiers"] != nil)
        #expect(props["foreground"] != nil)
        #expect(props["auto_focus"] == nil)
        #expect(props["bring_to_current_space"] == nil)
        #expect(props["space_switch"] == nil)

        // Required fields
        if let required = schema["required"],
           case let .array(requiredArray) = required
        {
            #expect(requiredArray.contains(.string("foreground")))
        }
    }

    // MARK: - Window Tool Tests

    @Test
    func `Dock tool requires foreground consent for global UI actions`() async throws {
        let tool = makeTestTool(DockTool.init)
        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"],
              case let .object(foreground)? = properties["foreground"],
              case .bool(false)? = foreground["default"]
        else {
            Issue.record("Expected Dock foreground schema default")
            return
        }

        for action in ["launch", "right-click"] {
            let response = try await tool.execute(arguments: ToolArguments(raw: [
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

    @Test
    func `Window tool complex action schema`() {
        let tool = makeTestTool(WindowTool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(props["action"] != nil)
        #expect(props["app"] != nil)
        #expect(props["title"] != nil)
        #expect(props["index"] != nil)
        #expect(props["width"] != nil)
        #expect(props["height"] != nil)
        #expect(props["foreground"] != nil)

        // Check action types include all window operations
        if let actionSchema = props["action"],
           case let .object(actionDict) = actionSchema,
           let enumValue = actionDict["enum"],
           case let .array(actions) = enumValue
        {
            // Check that common actions are present
            #expect(actions.contains(.string("close")))
            #expect(actions.contains(.string("minimize")))
            #expect(actions.contains(.string("maximize")))
            #expect(actions.contains(.string("focus")))
        }
    }

    // MARK: - Move Tool Tests

    @Test
    func `Move tool supports both coordinates and elements`() {
        let tool = makeTestTool(MoveTool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(props["to"] != nil)
        #expect(props["coordinates"] != nil)
        #expect(props["foreground"] != nil)

        if let required = schema["required"], case let .array(requiredArray) = required {
            #expect(requiredArray.contains(.string("foreground")))
        }

        // Check description mentions coordinates
        if let toSchema = props["to"],
           case let .object(toDict) = toSchema,
           let description = toDict["description"],
           case let .string(desc) = description
        {
            #expect(desc.contains("Coordinates") || desc.contains("x,y") || desc.contains("center"))
        }
    }

    @Test
    func `Scroll tool exposes background-safe and foreground modes`() {
        let tool = makeTestTool(ScrollTool.init)

        guard case let .object(schema) = tool.inputSchema,
              case let .object(properties)? = schema["properties"]
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(properties["on"] != nil)
        #expect(properties["foreground"] != nil)
        #expect(properties["smooth"] != nil)
        #expect(properties["delay"] != nil)
    }

    @Test
    func `Physical pointer tools require explicit foreground consent`() async throws {
        let move = try await makeTestTool(MoveTool.init).execute(arguments: ToolArguments(raw: ["center": true]))
        let drag = try await makeTestTool(DragTool.init).execute(arguments: ToolArguments(raw: [
            "from_coords": "10,10",
            "to_coords": "20,20",
        ]))
        let scroll = try await makeTestTool(ScrollTool.init).execute(arguments: ToolArguments(raw: [
            "direction": "down",
        ]))

        for response in [move, drag, scroll] {
            #expect(response.isError)
            guard case let .text(text: message, annotations: _, _meta: _) = response.content.first else {
                Issue.record("Expected text validation error")
                continue
            }
            #expect(message.lowercased().contains("foreground"))
        }
    }

    // MARK: - Analyze Tool Tests

    @Test
    func `Analyze tool supports multiple input formats`() {
        let tool = makeTestTool(AnalyzeTool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(props["image_path"] != nil)
        #expect(props["question"] != nil)
        #expect(props["provider_config"] != nil)

        // Verify required fields - only question is required
        if let required = schema["required"],
           case let .array(requiredArray) = required
        {
            #expect(requiredArray.contains(.string("question")))
            #expect(requiredArray.count == 1) // Only question is required
        }
    }

    @Test
    func `Analyze provider config preserves OpenAI custom model`() throws {
        let arguments = ToolArguments(raw: [
            "provider_config": [
                "type": "openai",
                "model": "doubao-seed-1-8-251228",
            ],
        ])

        let model = try AnalyzeTool.modelOverride(from: arguments)

        #expect(model == LanguageModel.openai(.custom("doubao-seed-1-8-251228")))
    }

    @Test
    func `Analyze provider config parses provider models without hardcoded defaults`() throws {
        #expect(try AnalyzeTool.languageModel(providerType: "openai", modelName: "gpt-5.5") == .openai(.gpt55))
        #expect(try AnalyzeTool
            .languageModel(providerType: "anthropic", modelName: "claude-sonnet-4.5") == .anthropic(.sonnet45))
        #expect(try AnalyzeTool
            .languageModel(providerType: "ollama", modelName: "llava:13b") == .ollama(.custom("llava:13b")))
    }

    @Test
    func `Analyze provider config preserves server-redirected Grok models`() throws {
        for (provider, model) in [
            ("grok", "grok-4-fast"),
            ("xai", "grok-code-fast-1"),
        ] {
            #expect(try AnalyzeTool.languageModel(providerType: provider, modelName: model) == .grok(.custom(model)))
        }
    }

    @Test
    func `Analyze provider config rejects unsupported Grok multi-agent models`() throws {
        for model in ["grok-4.20-multi-agent-0309", "grok420multiagent"] {
            let error = #expect(throws: PeekabooError.self) {
                try AnalyzeTool.languageModel(providerType: "xai", modelName: model)
            }

            if case let .invalidInput(message) = error {
                #expect(message.contains("Unsupported Grok model"))
            } else {
                Issue.record("Expected invalidInput error")
            }
        }
    }

    @Test
    func `Analyze provider config can defer to configured default`() throws {
        let arguments = ToolArguments(raw: [:])

        let model = try AnalyzeTool.modelOverride(from: arguments)

        #expect(model == nil)
    }

    @Test
    func `Agent model override preserves configured default and explicit provider resolution`() throws {
        #expect(try MCPAgentTool.modelOverride(from: nil) { _ in
            Issue.record("Resolver should not run without an explicit model")
            return nil
        } == nil)

        let redirected = LanguageModel.grok(.custom("grok-code-fast-1"))
        var resolvedModelString: String?
        let model = try MCPAgentTool.modelOverride(from: "xai/grok-code-fast-1") { modelString in
            resolvedModelString = modelString
            return redirected
        }
        #expect(resolvedModelString == "xai/grok-code-fast-1")
        #expect(model == redirected)
    }

    @Test
    func `Agent max steps are bounded`() throws {
        #expect(try MCPAgentTool.validatedMaxSteps(nil) == 20)
        #expect(try MCPAgentTool.validatedMaxSteps(1) == 1)
        #expect(try MCPAgentTool.validatedMaxSteps(100) == 100)
        #expect(throws: (any Error).self) {
            try MCPAgentTool.validatedMaxSteps(0)
        }
        #expect(throws: (any Error).self) {
            try MCPAgentTool.validatedMaxSteps(101)
        }
    }

    @Test
    func `Agent no cache rejects session lookup options`() throws {
        let conflictingOptions: [(resume: Bool, resumeSession: String?, listSessions: Bool)] = [
            (true, nil, false),
            (false, "saved", false),
            (false, nil, true),
        ]
        for options in conflictingOptions {
            #expect(throws: (any Error).self) {
                try MCPAgentTool.validateSessionOptions(
                    noCache: true,
                    resume: options.resume,
                    resumeSession: options.resumeSession,
                    listSessions: options.listSessions)
            }
        }
        try MCPAgentTool.validateSessionOptions(
            noCache: true,
            resume: false,
            resumeSession: nil,
            listSessions: false)
    }

    @Test
    func `MCP Agent advertises background-only authority without shell`() {
        let description = makeTestTool(MCPAgentTool.init).description
        #expect(description.contains("always background-only"))
        #expect(description.contains("raw `press` only with a fresh exact non-dialog snapshot receipt"))
        #expect(description.contains("typing requires an explicit fresh exact non-dialog snapshot receipt"))
        #expect(description.contains("input resolves the exact target and uses AXValue"))
        #expect(description.contains("Space listing and unfollowed"))
        #expect(description.contains("Shell-tool access"))
        #expect(description.contains("not a process sandbox"))
        #expect(description.contains("Direct text paste is available only"))
        #expect(description.contains("current-clipboard, and binary paste remain"))
        #expect(!description.contains("shell commands"))
        #expect(!description.contains("Process-targeted keyboard chords"))
        #expect(!description.contains("Open Safari and navigate"))
        #expect(!description.contains("launch, quit, focus"))
    }

    @Test
    func `MCP Agent session listings expose immutable policy`() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mcp-agent-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let services = PeekabooServices()
        let manager = try AgentSessionManager(sessionDirectory: directory)
        let agent = try PeekabooAgentService(services: services, sessionManager: manager)
        services.agent = agent
        let now = Date()
        try manager.saveSession(AgentSession(
            id: "foreground-session",
            modelName: "test-model",
            toolExecutionPolicy: .foregroundAllowed,
            messages: [.system("system"), .user("task")],
            metadata: SessionMetadata(),
            createdAt: now,
            updatedAt: now))

        let tool = MCPAgentTool(context: MCPToolContext(services: services))
        let response = try await tool.execute(arguments: ToolArguments(raw: ["listSessions": true]))

        #expect(!response.isError)
        guard case let .text(text, _, _) = response.content.first,
              case let .object(meta)? = response.meta,
              case let .array(sessions)? = meta["sessions"],
              case let .object(session)? = sessions.first
        else {
            Issue.record("Expected structured Agent session listing")
            return
        }
        #expect(text.contains("Tool Policy: foreground_allowed"))
        #expect(text.contains("Task: task"))
        #expect(text.contains("Status: active"))
        #expect(session["task"] == .string("task"))
        #expect(session["status"] == .string("active"))
        #expect(session["toolExecutionPolicy"] == .string("foreground_allowed"))
    }

    @Test
    func `MCP agent metadata exposes the bounded redacted execution trace`() throws {
        let call = AgentToolCall(
            id: "call-1",
            name: "type",
            arguments: ["text": AnyAgentToolValue(string: "private typed content")])
        let result = AgentExecutionResult(
            content: "done",
            messages: [
                ModelMessage(role: .assistant, content: [.toolCall(call)]),
                ModelMessage(role: .tool, content: [.toolResult(AgentToolResult.success(
                    toolCallId: call.id,
                    result: AnyAgentToolValue(string: "typed")))]),
            ],
            metadata: AgentMetadata(
                executionTime: 0,
                toolCallCount: 1,
                modelName: "test",
                startTime: Date(),
                endTime: Date()))

        let metadata = try #require(MCPAgentTool.executionTraceMetadata(for: result).objectValue)
        let trace = try #require(metadata["executionTrace"]?.objectValue)
        let entries = try #require(trace["entries"]?.arrayValue)
        let firstEntry = try #require(entries.first?.objectValue)
        let arguments = try #require(firstEntry["arguments"]?.objectValue)

        #expect(trace["totalCallCount"]?.intValue == 1)
        #expect(arguments["text"]?.objectValue?["redacted"]?.boolValue == true)
        #expect(String(describing: metadata).contains("private typed content") == false)
    }

    // MARK: - Shell Tool Tests

    @Test(.timeLimit(.minutes(1)))
    func `Shell tool does not deadlock on large output`() async throws {
        let tool = makeTestTool(ShellTool.init)

        // Generate output larger than the macOS pipe buffer (~64 KB)
        // to trigger a deadlock if waitUntilExit() precedes pipe reads.
        let result = try await tool.execute(arguments: ToolArguments(raw: [
            "command": "head -c 131072 /dev/zero | base64",
        ]))

        #expect(result.isError == false)
        if case let .text(text, _, _) = result.content.first {
            #expect(text.count > 100_000)
        } else {
            Issue.record("Expected text content from shell output")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `Shell tool does not deadlock when both pipes exceed their buffers`() async throws {
        let tool = makeTestTool(ShellTool.init)

        let result = try await tool.execute(arguments: ToolArguments(raw: [
            "command": "head -c 131072 /dev/zero >&2; head -c 131072 /dev/zero",
        ]))

        #expect(result.isError == false)
        if case let .text(text, _, _) = result.content.first {
            #expect(text.count == 131_072)
        } else {
            Issue.record("Expected text content from shell output")
        }
    }

    @Test
    func `Shell tool resolveTimeout omits deadline when timeout is absent`() {
        #expect(ShellTool.resolveTimeout(nil) == nil)
        #expect(ShellTool.resolveTimeout(0) == nil)
        #expect(ShellTool.resolveTimeout(-1) == nil)
        #expect(ShellTool.resolveTimeout(.nan) == nil)
        #expect(ShellTool.resolveTimeout(1) == 1)
        #expect(ShellTool.resolveTimeout(9000) == ShellTool.maxTimeoutSeconds)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Shell tool times out hung commands instead of blocking forever`() async throws {
        let tool = makeTestTool(ShellTool.init)
        let started = Date()

        let result = try await tool.execute(arguments: ToolArguments(raw: [
            "command": "sleep 30",
            "timeout": 1,
        ]))

        let elapsed = Date().timeIntervalSince(started)
        #expect(result.isError == true)
        #expect(elapsed < 4.0)
        if case let .text(text, _, _) = result.content.first {
            #expect(text.lowercased().contains("timed out"))
        } else {
            Issue.record("Expected timeout error text from shell tool")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `Shell tool still succeeds for fast commands with an explicit timeout`() async throws {
        let tool = makeTestTool(ShellTool.init)

        let result = try await tool.execute(arguments: ToolArguments(raw: [
            "command": "echo shell-timeout-ok",
            "timeout": 5,
        ]))

        #expect(result.isError == false)
        if case let .text(text, _, _) = result.content.first {
            #expect(text.contains("shell-timeout-ok"))
        } else {
            Issue.record("Expected text content from shell output")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `Shell tool omitted timeout allows commands longer than former default`() async throws {
        let tool = makeTestTool(ShellTool.init)
        let started = Date()

        // Legacy contract: no timeout argument means unlimited. A 2s command must succeed
        // and must not be cut off by a silent 30s (or any) default deadline.
        let result = try await tool.execute(arguments: ToolArguments(raw: [
            "command": "sleep 2; echo omitted-timeout-ok",
        ]))

        let elapsed = Date().timeIntervalSince(started)
        #expect(result.isError == false)
        #expect(elapsed >= 1.5)
        #expect(elapsed < 10.0)
        if case let .text(text, _, _) = result.content.first {
            #expect(text.contains("omitted-timeout-ok"))
        } else {
            Issue.record("Expected text content from shell output")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `Shell tool timeout bounds drain when a descendant holds stdout`() async throws {
        let tool = makeTestTool(ShellTool.init)
        let started = Date()

        // Both the shell and its child ignore SIGTERM, exercising the process group's
        // SIGKILL pass while the child keeps stdout open.
        let result = try await tool.execute(arguments: ToolArguments(raw: [
            "command": "trap '' TERM; sleep 120 & while true; do sleep 1; done",
            "timeout": 1,
        ]))

        let elapsed = Date().timeIntervalSince(started)
        #expect(result.isError == true)
        // Timeout (1s) + TERM grace (0.5s) + drain bound (0.5s) should finish well under 5s.
        #expect(elapsed < 5.0)
        if case let .text(text, _, _) = result.content.first {
            #expect(text.lowercased().contains("timed out"))
        } else {
            Issue.record("Expected timeout error text from shell tool")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `Shell tool timeout terminates recorded descendant pid`() async throws {
        let tool = makeTestTool(ShellTool.init)
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("shell-tool-child-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let result = try await tool.execute(arguments: ToolArguments(raw: [
            "command":
                "trap '' TERM; sleep 120 & echo $! > '\(pidFile.path)'; while true; do sleep 1; done",
            "timeout": 1,
        ]))

        #expect(result.isError == true)

        // Allow reaping after SIGKILL.
        try await Task.sleep(nanoseconds: 300_000_000)

        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let childPid = pid_t(pidText), childPid > 0 else {
            Issue.record("Expected child pid file contents, got \(pidText)")
            return
        }

        // kill(pid, 0) succeeds only if a process with that pid still exists.
        let stillAlive = kill(childPid, 0) == 0
        #expect(stillAlive == false)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Shell tool post-timeout drain stops promptly when the caller is cancelled`() async {
        let stopped = LockedFlag()
        let task = Task {
            await ShellTool.waitForPostTimeoutDrain(
                isFinished: { false },
                stop: { stopped.set() },
                drainSeconds: 5)
        }
        try? await Task.sleep(nanoseconds: 20_000_000)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        await task.value
        #expect(cancelledAt.duration(to: .now) < .seconds(1))
        #expect(stopped.value)
    }

    @Test(.timeLimit(.minutes(1)))
    func `Shell tool background reaper exits when cancelled`() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            child.terminate()
            child.waitUntilExit()
        }

        let task = Task {
            await ShellTool.reapDetachedProcess(
                processIdentifier: child.processIdentifier,
                maxDuration: 30)
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let cancelledAt = ContinuousClock.now
        task.cancel()
        await task.value
        #expect(cancelledAt.duration(to: .now) < .seconds(1))
    }
}

@MainActor
struct MCPKeyboardCapabilitySchemaTests {
    @Test
    func `Action tool explains foreground exposing accessibility actions`() {
        let description = makeTestTool(ActionTool.init).description
        #expect(description.contains("including AXPress and"))
        #expect(description.contains("AXShowMenu"))
        #expect(description.contains("background semantic tool"))
        #expect(description.contains("foreground-capable session"))
    }

    @Test
    func `Press tool schema requires snapshot only for background policy`() {
        let tool = makeTestTool(PressTool.init)

        guard case let .object(schema) = tool.inputSchema,
              let properties = schema["properties"],
              case let .object(props) = properties,
              case let .array(required)? = schema["required"]
        else {
            Issue.record("Expected object schema with properties")
            return
        }

        #expect(props["keys"] != nil)
        #expect(props["key"] != nil)
        #expect(props["modifiers"] != nil)
        #expect(props["hold"] != nil)
        #expect(props["snapshot"] != nil)
        #expect(props["foreground"] == nil)
        #expect(props["app"] == nil)
        #expect(props["window_id"] == nil)
        #expect(required == [.string("snapshot")])
        #expect(tool.description.contains("Raw chords cannot prove semantic intent or effect"))
        #expect(tool.description.contains("explicit fresh exact non-dialog snapshot receipt"))

        let foregroundTool = makeTestTool(executionPolicy: .foregroundAllowed, PressTool.init)
        guard case let .object(foregroundSchema) = foregroundTool.inputSchema,
              case let .object(foregroundProps)? = foregroundSchema["properties"]
        else {
            Issue.record("Expected foreground-capable press schema")
            return
        }
        #expect(foregroundProps["foreground"] != nil)
        #expect(foregroundProps["app"] != nil)
        #expect(foregroundProps["window_id"] != nil)
        if case let .array(foregroundRequired)? = foregroundSchema["required"] {
            #expect(foregroundRequired.isEmpty)
        }
    }

    @Test
    func `Type tool schema requires an explicit background snapshot without competing selectors`() {
        let tool = makeTestTool(TypeTool.init)
        guard case let .object(schema) = tool.inputSchema,
              case let .object(props)? = schema["properties"],
              case let .array(required)? = schema["required"]
        else {
            Issue.record("Expected background type schema")
            return
        }
        #expect(props["snapshot"] != nil)
        #expect(props["on"] != nil)
        #expect(props["foreground"] == nil)
        #expect(props["app"] == nil)
        #expect(props["pid"] == nil)
        #expect(props["window_id"] == nil)
        #expect(required == [.string("snapshot")])
        #expect(tool.description.contains("explicit fresh exact non-dialog snapshot receipt"))
        #expect(tool.description.contains("implicit-latest"))

        let foregroundTool = makeTestTool(executionPolicy: .foregroundAllowed, TypeTool.init)
        guard case let .object(foregroundSchema) = foregroundTool.inputSchema,
              case let .object(foregroundProps)? = foregroundSchema["properties"]
        else {
            Issue.record("Expected foreground-capable type schema")
            return
        }
        #expect(foregroundProps["foreground"] != nil)
        #expect(foregroundProps["app"] != nil)
        #expect(foregroundProps["window_id"] != nil)
        if case let .array(foregroundRequired)? = foregroundSchema["required"] {
            #expect(foregroundRequired.isEmpty)
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.stored
    }

    func set() {
        self.lock.lock()
        self.stored = true
        self.lock.unlock()
    }
}

@MainActor
struct MCPToolDescriptionTests {
    @Test
    func `Tool descriptions include version and capabilities`() {
        let tools: [any MCPTool] = [
            makeTestTool(ImageTool.init),
            makeTestTool(SeeTool.init),
            makeTestTool(InspectUITool.init),
            makeTestTool(ClickTool.init),
            makeTestTool(TypeTool.init),
            makeTestTool(SetValueTool.init),
            makeTestTool(ActionTool.init),
            makeTestTool(MCPAgentTool.init),
        ]

        for tool in tools {
            let description = tool.description

            // All tools should have non-empty descriptions
            #expect(!description.isEmpty)

            // Descriptions should be reasonably detailed
            #expect(description.count > 50)

            // Check for common patterns in descriptions
            #expect(
                description.contains("Peekaboo") ||
                    description.lowercased().contains("capture") ||
                    description.lowercased().contains("click") ||
                    description.lowercased().contains("type") ||
                    description.lowercased().contains("automat"))
        }
    }

    @Test
    func `Tool names follow conventions`() {
        let tools: [any MCPTool] = [
            makeTestTool(ImageTool.init),
            makeTestTool(AnalyzeTool.init),
            makeTestTool(PermissionsTool.init),
            makeTestTool(SleepTool.init),
            makeTestTool(SeeTool.init),
            makeTestTool(InspectUITool.init),
            makeTestTool(ClickTool.init),
            makeTestTool(TypeTool.init),
            makeTestTool(SetValueTool.init),
            makeTestTool(ActionTool.init),
            makeTestTool(ScrollTool.init),
            makeTestTool(PressTool.init),
            makeTestTool(DragTool.init),
            makeTestTool(MoveTool.init),
            makeTestTool(AppTool.init),
            makeTestTool(WindowTool.init),
            makeTestTool(MenuTool.init),
            makeTestTool(MCPAgentTool.init),
            makeTestTool(DockTool.init),
            makeTestTool(DialogTool.init),
            makeTestTool(SpaceTool.init),
        ]

        for tool in tools {
            // Tool names should be lowercase
            #expect(tool.name == tool.name.lowercased())

            // Tool names should be single words or underscored
            #expect(!tool.name.contains(" "))
            #expect(!tool.name.contains("-"))

            // Tool names should be reasonable length
            #expect(tool.name.count > 2)
            #expect(tool.name.count < 20)
        }
    }
}
