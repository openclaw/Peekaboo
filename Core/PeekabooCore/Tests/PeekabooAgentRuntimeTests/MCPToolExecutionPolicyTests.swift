import MCP
import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooCore

@Suite(.serialized)
struct MCPToolExecutionPolicyTests {
    @Test
    @MainActor
    func `Tool handling context defaults to background only`() {
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: [],
            eventHandler: nil,
            sessionId: "default-background-policy")

        #expect(context.executionPolicy == .backgroundOnly)
    }

    private struct PolicyCase {
        let tool: String
        let arguments: [String: Any]
    }

    @Test
    func `background-only rejects every foreground activation and shared-desktop route`() {
        let cases: [PolicyCase] = [
            .init(tool: "click", arguments: ["foreground": true]),
            .init(tool: "click", arguments: ["background": false]),
            .init(tool: "see", arguments: ["web_focus": true]),
            .init(tool: "inspect_ui", arguments: ["web_focus": true]),
            .init(tool: "type", arguments: ["foreground": true]),
            .init(tool: "type", arguments: ["foreground": false]),
            .init(tool: "type", arguments: ["app": "TextEdit"]),
            .init(tool: "type", arguments: ["on": "T1"]),
            .init(tool: "type", arguments: ["snapshot": "   "]),
            .init(tool: "scroll", arguments: ["foreground": true]),
            .init(tool: "press", arguments: [:]),
            .init(tool: "press", arguments: ["foreground": false]),
            .init(tool: "press", arguments: ["foreground": true]),
            .init(tool: "press", arguments: ["window_id": 42]),
            .init(tool: "paste", arguments: ["foreground": true]),
            .init(tool: "paste", arguments: ["foreground": false, "window_id": 42]),
            .init(tool: "image", arguments: ["capture_focus": "foreground"]),
            .init(tool: "capture", arguments: ["capture_focus": "auto"]),
            .init(tool: "app", arguments: ["action": "launch", "foreground": true]),
            .init(tool: "app", arguments: ["action": "focus"]),
            .init(tool: "app", arguments: ["action": "switch"]),
            .init(tool: "window", arguments: ["action": "close", "foreground": true]),
            .init(tool: "window", arguments: ["action": "focus"]),
            .init(tool: "menu", arguments: ["action": "click", "foreground": true]),
            .init(tool: "dialog", arguments: ["action": "click", "foreground": true]),
            .init(tool: "dialog", arguments: ["action": "click", "button": "OK"]),
            .init(tool: "dialog", arguments: ["action": "dismiss"]),
            .init(tool: "dialog", arguments: ["action": "input"]),
            .init(tool: "dialog", arguments: ["action": "file"]),
            .init(tool: "dialog", arguments: ["action": "dismiss", "force": true]),
            .init(tool: "dock", arguments: ["action": "launch"]),
            .init(tool: "dock", arguments: ["action": "right-click"]),
            .init(tool: "dock", arguments: ["action": "hide"]),
            .init(tool: "dock", arguments: ["action": "show"]),
            .init(tool: "space", arguments: ["action": "switch"]),
            .init(tool: "space", arguments: ["action": "move-window", "follow": true]),
            .init(tool: "space", arguments: ["action": "move-window", "foreground": true]),
            .init(tool: "browser", arguments: ["action": "select_page", "bring_to_front": true]),
            .init(tool: "browser", arguments: ["action": "new_page", "background": false]),
            .init(tool: "browser", arguments: [
                "action": "call",
                "mcp_tool": "select_page",
                "mcp_args_json": "{}",
            ]),
            .init(tool: "browser", arguments: [
                "action": "call",
                "mcp_tool": "select_page",
                "mcp_args_json": #"{"bringToFront":true}"#,
            ]),
            .init(tool: "browser", arguments: [
                "action": "call",
                "mcp_tool": "new_page",
                "mcp_args_json": "{}",
            ]),
            .init(tool: "browser", arguments: [
                "action": "call",
                "mcp_tool": "new_page",
                "mcp_args_json": #"{"background":false}"#,
            ]),
            .init(tool: "browser", arguments: ["action": "connect"]),
            .init(tool: "clipboard", arguments: ["action": "set", "text": "replacement"]),
            .init(tool: "clipboard", arguments: ["action": "clear"]),
            .init(tool: "clipboard", arguments: ["action": "restore"]),
            .init(tool: "permissions", arguments: ["action": "request"]),
            .init(tool: "action", arguments: ["action": "AXRaise"]),
            .init(tool: "action", arguments: ["action": "AXShowMenu"]),
            .init(tool: "action", arguments: ["action": "AXShowAlternateUI"]),
            .init(tool: "action", arguments: ["action": "AXShowDefaultUI"]),
            .init(tool: "action", arguments: ["action": "AXPress"]),
            .init(tool: "action", arguments: ["action": "press"]),
            .init(tool: "action", arguments: ["action": "AXPick"]),
            .init(tool: "action", arguments: ["action": "pick"]),
            .init(tool: "action", arguments: ["action": "AXCustomAction"]),
            .init(tool: "drag", arguments: ["foreground": true]),
            .init(tool: "move", arguments: ["foreground": true]),
            .init(tool: "shell", arguments: ["command": "/usr/bin/osascript -e ignored"]),
            .init(tool: "future_desktop_tool", arguments: [:]),
        ]

        for item in cases {
            let response = MCPToolExecutionPolicy.backgroundOnly.rejection(
                toolName: item.tool,
                arguments: ToolArguments(raw: item.arguments))
            #expect(response?.isError == true, "Expected background-only refusal for \(item.tool) \(item.arguments)")
            guard case let .object(meta)? = response?.meta else {
                Issue.record("Missing structured refusal metadata for \(item.tool)")
                continue
            }
            #expect(meta["effect"] == .string("refused"))
            #expect(meta["state"] == .string("refused"))
            #expect(meta["dispatch_state"] == .string("none"))
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
            #expect(meta["requires_fresh_observation"] == .bool(false))
            #expect(meta["execution_policy"] == .string("background_only"))
            let expectedReason: DesktopActionOutcome.RefusalReason =
                if item.tool == "future_desktop_tool" {
                    .operationUnsupported
                } else if item.tool == "dialog",
                          ["click", "dismiss"].contains(item.arguments["action"] as? String ?? ""),
                          item.arguments["foreground"] == nil,
                          item.arguments["force"] as? Bool != true
                {
                    .invalidRequest
                } else {
                    .foregroundConsentRequired
                }
            #expect(meta["refusal_reason"] == .string(expectedReason.rawValue))
        }
    }

    @Test
    func `background-only allows classified background and read-only routes`() {
        let cases: [PolicyCase] = [
            .init(tool: "see", arguments: [:]),
            .init(tool: "inspect_ui", arguments: [:]),
            .init(tool: "verify_state", arguments: [:]),
            .init(tool: "click", arguments: ["foreground": false]),
            .init(tool: "type", arguments: ["snapshot": "fresh-exact-non-dialog"]),
            .init(tool: "type", arguments: ["snapshot": "fresh-exact-non-dialog", "on": "T1"]),
            .init(tool: "press", arguments: ["snapshot": "exact-window"]),
            .init(tool: "action", arguments: ["action": "AXIncrement"]),
            .init(tool: "set_value", arguments: [:]),
            .init(tool: "image", arguments: [:]),
            .init(tool: "image", arguments: ["capture_focus": "background"]),
            .init(tool: "capture", arguments: [:]),
            .init(tool: "capture", arguments: ["capture_focus": "background"]),
            .init(tool: "app", arguments: ["action": "launch", "foreground": false]),
            .init(tool: "window", arguments: ["action": "set-bounds"]),
            .init(tool: "menu", arguments: ["action": "click", "foreground": false]),
            .init(tool: "dialog", arguments: ["action": "list", "foreground": false]),
            .init(tool: "dialog", arguments: ["action": "click", "button": "OK", "app": "TextEdit"]),
            .init(tool: "dialog", arguments: ["action": "dismiss", "pid": 42]),
            .init(tool: "dock", arguments: ["action": "list"]),
            .init(tool: "space", arguments: ["action": "list"]),
            .init(tool: "space", arguments: [
                "action": "move-window",
                "app": "Safari",
                "to": 2,
            ]),
            .init(tool: "space", arguments: [
                "action": "move-window",
                "app": "TextEdit",
                "to_current": true,
                "follow": false,
            ]),
            .init(tool: "browser", arguments: [
                "action": "select_page",
                "bring_to_front": false,
            ]),
            .init(tool: "browser", arguments: [
                "action": "new_page",
                "background": true,
            ]),
            .init(tool: "browser", arguments: [
                "action": "new_page",
                "url": "https://example.com",
            ]),
            .init(tool: "browser", arguments: [
                "action": "call",
                "mcp_tool": "select_page",
                "mcp_args_json": #"{"bringToFront":false}"#,
            ]),
            .init(tool: "browser", arguments: [
                "action": "call",
                "mcp_tool": "new_page",
                "mcp_args_json": #"{"background":true}"#,
            ]),
            .init(tool: "clipboard", arguments: ["action": "get"]),
            .init(tool: "clipboard", arguments: ["action": "save"]),
            .init(tool: "browser", arguments: ["action": "status"]),
            .init(tool: "permissions", arguments: [:]),
            .init(tool: "analyze", arguments: [:]),
            .init(tool: "sleep", arguments: [:]),
            .init(tool: "agent", arguments: [:]),
            .init(tool: "done", arguments: [:]),
            .init(tool: "need_info", arguments: [:]),
        ]

        for item in cases {
            #expect(
                MCPToolExecutionPolicy.backgroundOnly.rejection(
                    toolName: item.tool,
                    arguments: ToolArguments(raw: item.arguments)) == nil,
                "Unexpected background-only refusal for \(item.tool) \(item.arguments)")
        }
    }

    @Test
    func `foreground Agent policy still refuses shell nested and unknown tools`() {
        for tool in ["shell", "agent", "future_desktop_tool"] {
            let response = MCPToolExecutionPolicy.foregroundAllowed.rejection(
                toolName: tool,
                arguments: ToolArguments(raw: [:]))
            #expect(response?.isError == true)
            guard case let .object(meta)? = response?.meta else {
                Issue.record("Missing structured refusal metadata for \(tool)")
                continue
            }
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
            #expect(meta["execution_policy"] == .string("foreground_allowed"))
            #expect(meta["state"] == .string("refused"))
            #expect(meta["refusal_reason"] == .string("operation_unsupported"))
            #expect(meta["escalation"] == .string("correct_request"))
        }

        #expect(MCPToolExecutionPolicy.foregroundAllowed.rejection(
            toolName: "move",
            arguments: ToolArguments(raw: ["foreground": true])) == nil)
        #expect(MCPToolExecutionPolicy.unrestricted.rejection(
            toolName: "shell",
            arguments: ToolArguments(raw: [:])) == nil)
        #expect(MCPToolExecutionPolicy.unrestricted.rejection(
            toolName: "press",
            arguments: ToolArguments(raw: ["foreground": true])) == nil)
        #expect(MCPToolExecutionPolicy.unrestricted.rejection(
            toolName: "space",
            arguments: ToolArguments(raw: ["action": "switch"])) == nil)
        #expect(MCPToolExecutionPolicy.unrestricted.rejection(
            toolName: "space",
            arguments: ToolArguments(raw: ["action": "move-window", "follow": true])) == nil)
        #expect(MCPToolExecutionPolicy.backgroundOnly.systemSurfaceRejection(
            toolName: "action",
            applicationBundleIdentifier: "com.example.Dock",
            applicationName: "Dock") == nil)
        #expect(MCPToolExecutionPolicy.backgroundOnly.systemSurfaceRejection(
            toolName: "action",
            applicationBundleIdentifier: nil,
            applicationName: "Dock")?.isError == true)
        #expect(MCPToolExecutionPolicy.backgroundOnly.systemSurfaceRejection(
            toolName: "action",
            applicationBundleIdentifier: nil,
            applicationName: "Passwords")?.isError == true)
        for bundleIdentifier in [
            "com.apple.controlcenter",
            "com.apple.dock",
            "com.apple.notificationcenterui",
            "com.apple.systemuiserver",
        ] {
            #expect(MCPToolExecutionPolicy.backgroundOnly.systemSurfaceRejection(
                toolName: "action",
                applicationBundleIdentifier: bundleIdentifier,
                applicationName: nil)?.isError == true)
        }
    }

    @Test
    func `policy target refusals preserve their canonical recovery reason`() throws {
        let unresolved = try #require(MCPToolExecutionPolicy.backgroundOnly.unresolvedTargetRejection(
            toolName: "click",
            detail: "process generation changed"))
        let unresolvedMeta = try #require(unresolved.meta?.objectValue)
        #expect(unresolvedMeta["refusal_reason"] == .string("target_unavailable"))
        #expect(unresolvedMeta["escalation"] == .string("refresh_target"))

        let systemSurface = try #require(MCPToolExecutionPolicy.backgroundOnly.systemSurfaceRejection(
            toolName: "action",
            applicationBundleIdentifier: "com.apple.dock",
            applicationName: nil))
        let systemMeta = try #require(systemSurface.meta?.objectValue)
        #expect(systemMeta["refusal_reason"] == .string("foreground_consent_required"))
        #expect(systemMeta["escalation"] == .string("correct_request"))
    }

    @Test
    @MainActor
    func `context validates arguments then refuses before mutation gates or tool invocation`() async throws {
        let counter = PolicyInvocationCounter()
        let shell = PolicyProbeTool(name: "shell", counter: counter)
        let arguments = ToolArguments(raw: ["command": "/usr/bin/osascript -e ignored"])

        for policy in [MCPToolExecutionPolicy.backgroundOnly, .foregroundAllowed] {
            let context = MCPToolContext(services: PeekabooServices(), executionPolicy: policy)
            let response = try await context.execute(tool: shell, arguments: arguments)
            #expect(response.isError)
            #expect(await counter.value == 0)
        }

        let directContext = MCPToolContext(services: PeekabooServices(), executionPolicy: .unrestricted)
        let directResponse = try await directContext.execute(tool: shell, arguments: arguments)
        #expect(!directResponse.isError)
        #expect(await counter.value == 1)
    }

    @Test
    @MainActor
    func `public Agent tool factory defaults executable tools to background-only`() async throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tools = service.createAgentTools()
        let shell = try #require(tools.first { $0.name == "shell" })
        let move = try #require(tools.first { $0.name == "move" })
        let sleep = try #require(tools.first { $0.name == "sleep" })

        for (tool, arguments) in [
            (shell, AgentToolArguments(["command": "/usr/bin/true"])),
            (move, AgentToolArguments(["to": "10,10", "foreground": true])),
        ] {
            do {
                _ = try await tool.execute(arguments, context: ToolExecutionContext())
                Issue.record("Expected public Agent tool \(tool.name) to retain background-only authority")
            } catch let failure as AgentToolExecutionFailure {
                let metadata = try #require(failure.metadata?.objectValue)
                #expect(
                    metadata["error_code"]?.stringValue == MCPToolExecutionPolicy.refusalErrorCode,
                    "Unexpected rejection for \(tool.name)")
                #expect(
                    metadata["execution_policy"]?.stringValue == "background_only",
                    "Missing policy metadata for \(tool.name)")
                #expect(metadata["mutation_dispatched"]?.boolValue == false)
                #expect(metadata["retry_safe"]?.boolValue == true)
            }
        }

        let sleepResult = try await sleep.execute(
            AgentToolArguments(["duration": 1]),
            context: ToolExecutionContext())
        #expect(!AgentToolResultSemantics.valueEncodesFailure(sleepResult))

        let sessionTools = await service.buildToolset(for: .anthropic(.sonnet45))
        #expect(!sessionTools.contains(where: { $0.name == "shell" }))
    }

    @Test
    @MainActor
    func `background-only refuses generic AXPress when an exact Dock snapshot lacks its tool mirror`() async throws {
        let snapshotID = SnapshotReference.generate().rawValue
        let processIdentifier = getpid()
        let processStartIdentity: UInt64 = 77
        let bounds = CGRect(x: 0, y: 900, width: 1200, height: 100)
        let windowIdentity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: bounds)
        let windowContext = WindowContext(
            applicationName: "Dock",
            applicationBundleId: "com.apple.dock",
            applicationProcessId: processIdentifier,
            windowTitle: "Dock",
            windowID: 700,
            windowBounds: bounds,
            windowMutationIdentity: windowIdentity)
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/dock-policy.png",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Safari",
                    bounds: CGRect(x: 20, y: 920, width: 64, height: 64)),
            ]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: windowContext))
        let snapshots = try await InMemorySnapshotManager.containing(detectionResult)
        let services = PeekabooServices(snapshotManager: snapshots)
        let context = MCPToolContext(services: services, executionPolicy: .backgroundOnly)
        let pressCapture = PolicySnapshotArgumentCapture()

        let response = try await context.execute(
            tool: ActionTool(context: context),
            arguments: ToolArguments(raw: [
                "on": "B1",
                "action": "AXPress",
                "snapshot": snapshotID,
            ]))
        let pressResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "press", capture: pressCapture),
            arguments: ToolArguments(raw: [
                "keys": ["return"],
                "snapshot": snapshotID,
            ]))

        #expect(response.isError)
        #expect(pressResponse.isError)
        #expect(await pressCapture.callCount == 0)
        guard case let .object(meta)? = response.meta else {
            Issue.record("Missing structured Dock policy refusal metadata")
            return
        }
        #expect(meta["error_code"] == .string(MCPToolExecutionPolicy.refusalErrorCode))
        #expect(meta["effect"] == .string("refused"))
        #expect(meta["execution_policy"] == .string("background_only"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    @MainActor
    func `background-only pins the authorized implicit snapshot into mutation dispatch`() async throws {
        let snapshotID = SnapshotReference.generate().rawValue
        let processIdentifier = getpid()
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 701,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: 78,
            capturedBounds: bounds)
        let desktopTarget = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: identity.processIdentity,
            bundleIdentifier: "com.apple.TextEdit",
            applicationName: "TextEdit",
            windowID: identity.windowID,
            windowTitle: "Untitled",
            bounds: bounds)
        let windowContext = desktopTarget.windowContext
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/implicit-policy.png",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Save",
                    bounds: CGRect(x: 20, y: 20, width: 64, height: 24)),
            ]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: windowContext))
        let snapshots = try await InMemorySnapshotManager.containing(detectionResult)
        let context = try Self.makePolicyContext(snapshots: snapshots, desktopTarget: desktopTarget)
        let toolSnapshot = await UISnapshotManager.shared.createSnapshot(id: snapshotID)
        await toolSnapshot.setTargetMetadata(from: windowContext)
        let capture = PolicySnapshotArgumentCapture()

        let response = try await context.execute(
            tool: PolicySnapshotProbeTool(capture: capture),
            arguments: ToolArguments(raw: [
                "on": "B1",
                "action": "AXIncrement",
            ]))
        await UISnapshotManager.shared.removeSnapshot(id: snapshotID)

        #expect(!response.isError)
        #expect(await capture.snapshotID == snapshotID)
    }

    @Test
    @MainActor
    // swiftlint:disable:next function_body_length
    func `background-only rejects conflicting snapshot selectors before dispatch`() async throws {
        let snapshotID = SnapshotReference.generate().rawValue
        let processIdentifier = getpid()
        let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)
        let identity = WindowMutationIdentity(
            windowID: 702,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: 79,
            capturedBounds: bounds)
        let desktopTarget = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: identity.processIdentity,
            bundleIdentifier: "com.apple.TextEdit",
            applicationName: "TextEdit",
            windowID: identity.windowID,
            windowTitle: "Untitled",
            bounds: bounds)
        let windowContext = desktopTarget.windowContext
        let detectionResult = ElementDetectionResult(
            snapshotId: snapshotID,
            screenshotPath: "/tmp/selector-policy.png",
            elements: DetectedElements(buttons: [
                DetectedElement(
                    id: "B1",
                    type: .button,
                    label: "Save",
                    bounds: CGRect(x: 20, y: 20, width: 64, height: 24)),
            ]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "test",
                windowContext: windowContext))
        let snapshots = try await InMemorySnapshotManager.containing(detectionResult)
        let context = try Self.makePolicyContext(snapshots: snapshots, desktopTarget: desktopTarget)
        let toolSnapshot = await UISnapshotManager.shared.createSnapshot(id: snapshotID)
        await toolSnapshot.setTargetMetadata(from: windowContext)
        let capture = PolicySnapshotArgumentCapture()
        let typeCapture = PolicySnapshotArgumentCapture()
        let pressCapture = PolicySnapshotArgumentCapture()

        let response = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "click", capture: capture),
            arguments: ToolArguments(raw: [
                "coords": "120,120",
                "snapshot": snapshotID,
                "coordinate_reference": "unchecked-target",
            ]))
        let blankResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "click", capture: capture),
            arguments: ToolArguments(raw: [
                "coords": "120,120",
                "snapshot": "",
                "coordinate_reference": snapshotID,
            ]))
        let malformedResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "click", capture: capture),
            arguments: ToolArguments(raw: [
                "coords": "120,120",
                "snapshot": 42,
            ]))
        let missingReceiptResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "click", capture: capture),
            arguments: ToolArguments(raw: ["coords": "120,120"]))
        let mixedTypeResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "type", capture: typeCapture),
            arguments: ToolArguments(raw: [
                "text": "hello",
                "on": "B1",
                "snapshot": snapshotID,
                "app": "TextEdit",
            ]))
        let processTypeResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "type", capture: typeCapture),
            arguments: ToolArguments(raw: [
                "text": "hello",
                "app": "TextEdit",
            ]))
        let elementOnlyTypeResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "type", capture: typeCapture),
            arguments: ToolArguments(raw: [
                "text": "hello",
                "on": "B1",
            ]))
        let exactTypeResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "type", capture: typeCapture),
            arguments: ToolArguments(raw: [
                "text": "hello",
                "on": "B1",
                "snapshot": snapshotID,
            ]))
        let exactPressResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "press", capture: pressCapture),
            arguments: ToolArguments(raw: [
                "keys": ["return"],
                "snapshot": snapshotID,
            ]))
        let mixedPressResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "press", capture: pressCapture),
            arguments: ToolArguments(raw: [
                "keys": ["return"],
                "snapshot": snapshotID,
                "app": "TextEdit",
            ]))
        let windowOnlyPressResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "press", capture: pressCapture),
            arguments: ToolArguments(raw: [
                "keys": ["return"],
                "window_id": 702,
            ]))
        try await snapshots.storeDetectionResult(
            snapshotId: snapshotID,
            result: ElementDetectionResult(
                snapshotId: snapshotID,
                screenshotPath: "/tmp/selector-policy-dialog.png",
                elements: detectionResult.elements,
                metadata: DetectionMetadata(
                    detectionTime: 0.01,
                    elementCount: 1,
                    method: "test",
                    windowContext: windowContext,
                    isDialog: true)))
        let genericDialogResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(capture: capture),
            arguments: ToolArguments(raw: [
                "on": "B1",
                "action": "AXPress",
                "snapshot": snapshotID,
            ]))
        let dialogPressResponse = try await context.execute(
            tool: PolicySnapshotProbeTool(name: "press", capture: pressCapture),
            arguments: ToolArguments(raw: [
                "keys": ["return"],
                "snapshot": snapshotID,
            ]))
        await UISnapshotManager.shared.removeSnapshot(id: snapshotID)

        #expect(response.isError)
        #expect(blankResponse.isError)
        #expect(malformedResponse.isError)
        #expect(missingReceiptResponse.isError)
        #expect(mixedTypeResponse.isError)
        #expect(processTypeResponse.isError)
        #expect(elementOnlyTypeResponse.isError)
        #expect(!exactTypeResponse.isError)
        #expect(!exactPressResponse.isError)
        #expect(mixedPressResponse.isError)
        #expect(windowOnlyPressResponse.isError)
        #expect(genericDialogResponse.isError)
        #expect(dialogPressResponse.isError)
        #expect(await pressCapture.callCount == 1)
        #expect(await typeCapture.callCount == 1)
        #expect(await typeCapture.snapshotID == snapshotID)
        #expect(await capture.snapshotID == nil)
        guard case let .object(meta)? = response.meta else {
            Issue.record("Missing selector-conflict refusal metadata")
            return
        }
        #expect(meta["error_code"] == .string(MCPToolExecutionPolicy.refusalErrorCode))
        #expect(meta["mutation_dispatched"] == .bool(false))
    }

    @MainActor
    private static func makePolicyContext(
        snapshots: any SnapshotManagerProtocol,
        desktopTarget: LinkedDesktopTargetFixture) throws -> MCPToolContext
    {
        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [desktopTarget])
        let base = PeekabooServices(snapshotManager: snapshots)
        return MCPToolContext(
            automation: base.automation,
            menu: base.menu,
            windows: ScriptedWindowInventoryService(graph: graph),
            applications: ScriptedApplicationInventoryService(graph: graph),
            dialogs: base.dialogs,
            dock: base.dock,
            screenCapture: base.screenCapture,
            desktopObservation: base.desktopObservation,
            snapshots: snapshots,
            screens: base.screens,
            agent: base.agent,
            permissions: base.permissions,
            clipboard: base.clipboard,
            browser: base.browser,
            permissionsStatusProvider: base,
            executionPolicy: .backgroundOnly)
    }

    @Test
    @MainActor
    func `Agent loop refuses policy violations before lookup and turn boundary`() async throws {
        let counter = PolicyInvocationCounter()
        let tools = ["see", "click"].map { name in
            AgentTool(
                name: name,
                description: name,
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await counter.record()
                    return AnyAgentToolValue(object: ["success": AnyAgentToolValue(bool: true)])
                })
        }
        let service = try PeekabooAgentService(services: PeekabooServices())
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: nil,
            sessionId: "policy-loop",
            executionPolicy: .backgroundOnly)
        var messages: [ModelMessage] = []

        let step = try await service.handleToolCalls(
            stepText: "",
            toolCalls: [
                AgentToolCall(id: "see", name: "see", arguments: [:]),
                AgentToolCall(id: "click", name: "click", arguments: [:]),
                AgentToolCall(
                    id: "foreground-click",
                    name: "click",
                    arguments: ["foreground": AnyAgentToolValue(bool: true)]),
                AgentToolCall(id: "shell", name: "shell", arguments: [:]),
                AgentToolCall(id: "unknown", name: "future_desktop_tool", arguments: [:]),
            ],
            context: context,
            currentMessages: &messages,
            stepIndex: 0)

        #expect(await counter.value == 2)
        for result in step.toolResults.suffix(3) {
            #expect(result.isError)
            let metadata = try #require(result.failure?.metadata?.objectValue)
            #expect(metadata["effect"]?.stringValue == "refused")
            #expect(metadata["mutation_dispatched"]?.boolValue == false)
            #expect(metadata["retry_safe"]?.boolValue == true)
            #expect(metadata["execution_policy"]?.stringValue == "background_only")
            #expect(metadata["skipped"]?.boolValue == true)
        }
    }

    @Test
    @MainActor
    func `cancellation after policy refusal cancels every remaining call before execution`() async throws {
        let counter = PolicyInvocationCounter()
        let capture = PolicyCancellationCapture()
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tools = [
            AgentTool(
                name: "see",
                description: "see",
                parameters: AgentToolParameters(properties: [:], required: []),
                execute: { _ in
                    await counter.record()
                    return AnyAgentToolValue(object: ["success": AnyAgentToolValue(bool: true)])
                }),
        ]
        let eventHandler = EventHandler { event in
            if case let .toolCallCompleted(name, _) = event, name == "shell" {
                withUnsafeCurrentTask { task in task?.cancel() }
            }
        }
        let context = PeekabooAgentService.ToolHandlingContext(
            model: .anthropic(.sonnet45),
            tools: tools,
            eventHandler: eventHandler,
            sessionId: "policy-cancellation",
            executionPolicy: .backgroundOnly)
        let toolCalls = [
            AgentToolCall(id: "policy-refusal", name: "shell", arguments: [:]),
            AgentToolCall(id: "must-not-run", name: "see", arguments: [:]),
        ]

        let worker = Task { @MainActor in
            var messages: [ModelMessage] = []
            var checkpoint: GenerationStep?
            do {
                _ = try await service.handleToolCalls(
                    stepText: "",
                    toolCalls: toolCalls,
                    context: context,
                    currentMessages: &messages,
                    stepIndex: 0,
                    onCancellationCheckpoint: { checkpoint = $0 })
                await capture.record(cancelled: false, checkpoint: checkpoint, messages: messages)
            } catch {
                await capture.record(
                    cancelled: error is CancellationError,
                    checkpoint: checkpoint,
                    messages: messages)
            }
        }
        await worker.value

        let snapshot = await capture.snapshot()
        #expect(snapshot.cancelled)
        #expect(snapshot.toolCallIDs == ["policy-refusal", "must-not-run"])
        #expect(snapshot.isError == [true, true])
        #expect(snapshot.toolMessageCount == 2)
        #expect(await counter.value == 0)
    }
}

private actor PolicyInvocationCounter {
    private(set) var value = 0

    func record() {
        self.value += 1
    }
}

private actor PolicySnapshotArgumentCapture {
    private(set) var snapshotID: String?
    private(set) var coordinateReference: String?
    private(set) var callCount = 0

    func record(snapshotID: String?, coordinateReference: String?) {
        self.callCount += 1
        self.snapshotID = snapshotID
        self.coordinateReference = coordinateReference
    }
}

private actor PolicyCancellationCapture {
    struct Snapshot: Sendable {
        let cancelled: Bool
        let toolCallIDs: [String]
        let isError: [Bool]
        let toolMessageCount: Int
    }

    private var stored = Snapshot(cancelled: false, toolCallIDs: [], isError: [], toolMessageCount: 0)

    func record(cancelled: Bool, checkpoint: GenerationStep?, messages: [ModelMessage]) {
        self.stored = Snapshot(
            cancelled: cancelled,
            toolCallIDs: checkpoint?.toolResults.map(\.toolCallId) ?? [],
            isError: checkpoint?.toolResults.map(\.isError) ?? [],
            toolMessageCount: messages.count(where: { $0.role == .tool }))
    }

    func snapshot() -> Snapshot {
        self.stored
    }
}

private struct PolicyProbeTool: MCPTool {
    let name: String
    let counter: PolicyInvocationCounter
    let description = "Policy invocation probe"

    var inputSchema: Value {
        SchemaBuilder.object(
            properties: ["command": SchemaBuilder.string()],
            required: [])
    }

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        await self.counter.record()
        return ToolResponse.text("invoked")
    }
}

private struct PolicySnapshotProbeTool: MCPTool {
    let name: String
    let capture: PolicySnapshotArgumentCapture
    let description = "Policy snapshot argument probe"

    init(name: String = "action", capture: PolicySnapshotArgumentCapture) {
        self.name = name
        self.capture = capture
    }

    var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "on": SchemaBuilder.string(),
                "action": SchemaBuilder.string(),
                "app": SchemaBuilder.string(),
                "coords": SchemaBuilder.string(),
                "coordinate_reference": SchemaBuilder.string(),
                "keys": SchemaBuilder.array(items: SchemaBuilder.string()),
                "pid": SchemaBuilder.integer(),
                "snapshot": SchemaBuilder.string(),
                "text": SchemaBuilder.string(),
                "window_id": SchemaBuilder.integer(),
                "window_index": SchemaBuilder.integer(),
                "window_title": SchemaBuilder.string(),
            ],
            required: [])
    }

    func execute(arguments: ToolArguments) async throws -> ToolResponse {
        await self.capture.record(
            snapshotID: arguments.getString("snapshot"),
            coordinateReference: arguments.getString("coordinate_reference"))
        let mechanism: DesktopActionOutcome.Delivery.Mechanism =
            self.name == "press" ? .windowTargetedEvents : .accessibilityAction
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: mechanism, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        return try ToolResponse.text(
            "captured",
            meta: MCPToolResponseMetadataProjector.metadata(outcome: outcome))
    }
}
