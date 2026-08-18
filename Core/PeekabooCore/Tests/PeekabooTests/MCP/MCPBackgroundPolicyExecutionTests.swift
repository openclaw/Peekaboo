import CoreGraphics
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct MCPBackgroundPolicyExecutionTests {
    private static let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    @Test
    func `background-only refuses shared system UI through non-element mutation tools`() async throws {
        let dock = ServiceApplicationInfo(
            processIdentifier: 88,
            processStartIdentity: 880,
            bundleIdentifier: "com.apple.dock",
            name: "Dock")
        let textEdit = ServiceApplicationInfo(
            processIdentifier: 89,
            processStartIdentity: 890,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit")
        let applications = await MainActor.run { MockApplicationService(applications: [dock, textEdit]) }
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner,
            executionPolicy: .backgroundOnly)
        let cases = [
            (toolName: "app", action: "quit", selectorKey: "name"),
            (toolName: "menu", action: "click", selectorKey: "app"),
            (toolName: "window", action: "close", selectorKey: "app"),
            (toolName: "dialog", action: "click", selectorKey: "app"),
        ]

        for item in cases {
            let counter = BackgroundPolicyInvocationCounter()
            let probe = BackgroundPolicyMutationProbe(name: item.toolName, counter: counter)
            let response = try await context.execute(
                tool: probe,
                arguments: ToolArguments(raw: [
                    "action": item.action,
                    item.selectorKey: "Dock",
                ]))

            #expect(response.isError)
            #expect(await counter.invocationCount == 0)
            guard case let .object(meta)? = response.meta else {
                Issue.record("Missing shared-system-UI refusal metadata for \(item.toolName)")
                continue
            }
            #expect(meta["error_code"] == .string(MCPToolExecutionPolicy.refusalErrorCode))
            #expect(meta["mutation_dispatched"] == .bool(false))
        }

        let regularCounter = BackgroundPolicyInvocationCounter()
        let regularResponse = try await context.execute(
            tool: BackgroundPolicyMutationProbe(name: "app", counter: regularCounter),
            arguments: ToolArguments(raw: [
                "action": "quit",
                "name": "TextEdit",
            ]))
        #expect(!regularResponse.isError)
        #expect(await regularCounter.invocationCount == 1)
        #expect(await regularCounter.lastName == "PID:89")

        let pasteCounter = BackgroundPolicyInvocationCounter()
        let pasteResponse = try await context.execute(
            tool: BackgroundPolicyMutationProbe(name: "paste", counter: pasteCounter),
            arguments: ToolArguments(raw: ["app": "TextEdit"]))
        #expect(pasteResponse.isError)
        #expect(await pasteCounter.invocationCount == 0)

        for toolName in ["app", "dialog", "space"] {
            let readCounter = BackgroundPolicyInvocationCounter()
            let readResponse = try await context.execute(
                tool: BackgroundPolicyMutationProbe(name: toolName, counter: readCounter),
                arguments: ToolArguments(raw: ["action": "list"]))
            #expect(!readResponse.isError)
            #expect(await readCounter.invocationCount == 1)
        }
    }

    @Test
    func `background-only refuses cold application launch before dispatch`() async throws {
        let applications = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner,
            executionPolicy: .backgroundOnly)

        let response = try await context.execute(
            tool: AppTool(context: context),
            arguments: ToolArguments(raw: [
                "action": "launch",
                "name": "TextEdit",
            ]))

        #expect(response.isError)
        #expect(await MainActor.run { applications.launchRequests.isEmpty })
        guard case let .text(text, _, _)? = response.content.first,
              case let .object(meta)? = response.meta
        else {
            Issue.record("Expected structured cold-launch policy refusal")
            return
        }
        #expect(text.contains("cold launch requires explicit foreground consent"))
        #expect(meta["error_code"] == .string(MCPToolExecutionPolicy.refusalErrorCode))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
    }

    @Test
    func `background-only process mutation families refuse fuzzy application selectors before dispatch`() async throws {
        let textEdit = ServiceApplicationInfo(
            processIdentifier: 89,
            processStartIdentity: 890,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit",
            isHiddenKnown: true,
            activationPolicy: .regular)
        let applications = await MainActor.run { MockApplicationService(applications: [textEdit]) }
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner,
            executionPolicy: .backgroundOnly)
        let cases: [(tool: String, action: String?, key: String)] = [
            ("app", "quit", "name"),
            ("menu", "click", "app"),
            ("dialog", "click", "app"),
            ("paste", nil, "app"),
        ]

        for item in cases {
            let counter = BackgroundPolicyInvocationCounter()
            var raw: [String: Any] = [item.key: "Text"]
            if let action = item.action {
                raw["action"] = action
            }
            if item.tool == "dialog" {
                raw["button"] = "OK"
            }
            if item.tool == "paste" {
                raw["text"] = "must not dispatch"
            }
            let response = try await context.execute(
                tool: BackgroundPolicyMutationProbe(name: item.tool, counter: counter),
                arguments: ToolArguments(raw: raw))

            #expect(response.isError, "Expected fuzzy \(item.tool) target to fail")
            #expect(await counter.invocationCount == 0)
            guard case let .text(text, _, _)? = response.content.first,
                  case let .object(meta)? = response.meta
            else {
                Issue.record("Missing fuzzy-selector refusal for \(item.tool)")
                continue
            }
            #expect(text.contains("not allowed for mutation"))
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
        }
    }

    @Test
    func `background-only process mutation authorization accepts exact name bundle and PID selectors`() async throws {
        let textEdit = ServiceApplicationInfo(
            processIdentifier: 89,
            processStartIdentity: 890,
            bundleIdentifier: "com.apple.TextEdit",
            name: "TextEdit",
            isHiddenKnown: true,
            activationPolicy: .regular)
        let applications = await MainActor.run { MockApplicationService(applications: [textEdit]) }
        let context = await MCPToolTestHelpers.makeContext(
            applications: applications,
            snapshotOwner: Self.uiSnapshots.owner,
            executionPolicy: .backgroundOnly)

        for (key, value) in [
            ("name", "TextEdit"),
            ("bundleId", "com.apple.TextEdit"),
            ("name", "PID:89"),
        ] {
            let counter = BackgroundPolicyInvocationCounter()
            let response = try await context.execute(
                tool: BackgroundPolicyMutationProbe(name: "app", counter: counter),
                arguments: ToolArguments(raw: [
                    "action": "quit",
                    key: value,
                ]))

            #expect(!response.isError, "Expected exact selector \(value) to pass")
            #expect(await counter.invocationCount == 1)
            #expect(await counter.lastName == "PID:89")
        }
    }

    @Test
    func `App tool lifecycle examples include required foreground consent`() async {
        let context = await MCPToolTestHelpers.makeContext(snapshotOwner: Self.uiSnapshots.owner)
        let description = AppTool(context: context).description
        let newInstanceExample =
            #"{ "action": "launch", "name": "TextEdit", "newInstance": true, "foreground": true }"#
        let openExample =
            #"{ "action": "open", "name": "Safari", "openTargets": ["https://example.com"], "foreground": true }"#

        #expect(description.contains(newInstanceExample))
        #expect(description.contains(openExample))
    }

    @Test
    func `App tool launch defaults to background`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(
            applications: mockApps,
            snapshotOwner: Self.uiSnapshots.owner)
        let tool = AppTool(context: context)
        let args = ToolArguments(raw: [
            "action": "launch",
            "name": "TextEdit",
        ])

        let response = try await tool.execute(arguments: args)

        #expect(response.isError == false)
        let request = try #require(await MainActor.run { mockApps.launchRequests.first })
        #expect(request.applicationIdentifier == "TextEdit")
        #expect(request.activates == false)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected app launch metadata")
            return
        }
        #expect(meta["process_start_identity"] == .double(1000))
    }

    @Test
    func `App tool launch foreground is explicit`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(
            applications: mockApps,
            snapshotOwner: Self.uiSnapshots.owner)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "launch",
            "name": "Calendar",
            "foreground": true,
        ]))

        #expect(response.isError == false)
        #expect(await MainActor.run { mockApps.launchRequests.first?.activates } == true)
    }

    @Test
    func `App lifecycle refusal publishes safe MCP dispatch metadata`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(
            applications: mockApps,
            snapshotOwner: Self.uiSnapshots.owner)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "launch",
            "name": "TextEdit",
            "newInstance": true,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { mockApps.launchRequests.isEmpty })
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected lifecycle refusal metadata")
            return
        }
        #expect(meta["effect"] == .string("refused"))
        #expect(meta["state"] == .string("refused"))
        #expect(meta["dispatch_state"] == .string("none"))
        #expect(meta["evidence"] == .string("request_refused"))
        #expect(meta["refusal_reason"] == .string("foreground_consent_required"))
        #expect(meta["escalation"] == .string("correct_request"))
        #expect(meta["requires_fresh_observation"] == .bool(false))
        #expect(meta["error_code"] == .string("INTERACTION_FAILED"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["hint"] == .string("Retry with --foreground in the CLI or foreground=true in MCP."))
    }

    @Test
    func `Background readiness failure publishes zero-dispatch MCP metadata`() async throws {
        let mockApps = await MainActor.run {
            ReadinessFailureApplicationService()
        }
        let context = await MCPToolTestHelpers.makeContext(
            applications: mockApps,
            snapshotOwner: Self.uiSnapshots.owner)

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: [
            "action": "launch",
            "name": "TextEdit",
            "waitForWindow": true,
        ]))

        #expect(response.isError)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected lifecycle failure metadata")
            return
        }
        #expect(meta["effect"] == .string("unverifiable"))
        #expect(meta["error_code"] == .string("TIMEOUT"))
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(meta["hint"] == nil)
        #expect(meta["state"] == nil)
        #expect(meta["dispatch_state"] == nil)
        #expect(meta["refusal_reason"] == nil)
    }

    @Test(arguments: ["launch", "open", "relaunch", "unhide"])
    func `Lifecycle actions reject conflicting name and bundle selectors before dispatch`(
        _ action: String) async throws
    {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(
            applications: mockApps,
            snapshotOwner: Self.uiSnapshots.owner)
        var raw: [String: Any] = [
            "action": action,
            "name": "TextEdit",
            "bundleId": "com.apple.Safari",
            "foreground": true,
        ]
        if action == "open" {
            raw["openTargets"] = ["https://example.com"]
        }

        let response = try await AppTool(context: context).execute(arguments: ToolArguments(raw: raw))

        #expect(response.isError)
        guard case let .text(text, _, _) = response.content.first else {
            Issue.record("Expected selector validation error text")
            return
        }
        #expect(text.contains("either 'name' or 'bundleId'"))
        #expect(await MainActor.run { mockApps.launchRequests.isEmpty })
        #expect(await MainActor.run { mockApps.relaunchRequests.isEmpty })
    }

    @Test
    func `App tool exposes new-instance launch with foreground consent`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(
            applications: mockApps,
            snapshotOwner: Self.uiSnapshots.owner)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "launch",
            "name": "TextEdit",
            "newInstance": true,
            "waitForWindow": true,
            "foreground": true,
        ]))

        #expect(!response.isError)
        let request = try #require(await MainActor.run { mockApps.launchRequests.first })
        #expect(request.createsNewInstance)
        #expect(request.waitForWindow)
        #expect(request.activates)
    }

    @Test
    func `App tool open sends URL to default handler with foreground consent`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(
            applications: mockApps,
            snapshotOwner: Self.uiSnapshots.owner)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "open",
            "openTargets": ["https://example.com"],
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let request = try #require(await MainActor.run { mockApps.launchRequests.first })
        #expect(request.applicationIdentifier == nil)
        #expect(request.applicationBundleIdentifier == nil)
        #expect(request.openURLs.map(\.absoluteString) == ["https://example.com"])
        #expect(request.activates)
    }

    @Test
    func `Foreground app open resolves files and preserves strict bundle handler`() async throws {
        let mockApps = await MainActor.run { MockApplicationService() }
        let context = await MCPToolTestHelpers.makeContext(
            applications: mockApps,
            snapshotOwner: Self.uiSnapshots.owner)
        let tool = AppTool(context: context)

        let response = try await tool.execute(arguments: ToolArguments(raw: [
            "action": "open",
            "bundleId": "com.apple.TextEdit",
            "openTargets": ["notes.txt", "/tmp/report.txt"],
            "foreground": true,
        ]))

        #expect(response.isError == false)
        let request = try #require(await MainActor.run { mockApps.launchRequests.first })
        #expect(request.applicationIdentifier == nil)
        #expect(request.applicationBundleIdentifier == "com.apple.TextEdit")
        #expect(request.openURLs[0].isFileURL)
        #expect(request.openURLs[0].path.hasSuffix("/notes.txt"))
        #expect(request.openURLs[1].path == "/tmp/report.txt")
        #expect(request.activates)
    }

    @Test
    func `Click tool pins background coordinates to snapshot window`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "Snapshot Window",
            bounds: CGRect(x: 100, y: 50, width: 1000, height: 500),
            index: 0,
            mutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: 111,
                ownerProcessStartIdentity: 1))
        let windows = PointerPolicyWindowService(window: window)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: windows,
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/exact-window-coordinate-snapshot.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 1000, height: 500),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp"),
                windowInfo: window))

        let tool = ClickTool(context: context)
        let arguments = ToolArguments(raw: [
            "coords": "300,200",
            "snapshot": snapshotId,
        ])
        let response = try await tool.execute(arguments: arguments)

        #expect(!response.isError)
        let call = try #require(await MainActor.run { automation.targetedClickCalls.first })
        #expect(call.snapshotId == snapshotId)
        #expect(call.targetProcessIdentifier == 111)
        #expect(call.targetWindowID == 42)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected click metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == nil)
        #expect(meta["invalidated_snapshot"] == .string(snapshotId))
    }

    @Test
    func `Click tool refuses empty or missing background coordinate references before dispatch`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            snapshotOwner: Self.uiSnapshots.owner)
        let retainedSnapshot = await Self.uiSnapshots.createSnapshot()
        let retainedSnapshotID = await retainedSnapshot.id
        let requests: [[String: Any]] = [
            ["coords": "100,200", "pid": 111, "snapshot": "", "coordinate_reference": ""],
            ["coords": "100,200", "pid": 111],
        ]

        for raw in requests {
            let response = try await context.execute(
                tool: ClickTool(context: context),
                arguments: ToolArguments(raw: raw))
            #expect(response.isError)
            guard case let .object(meta) = response.meta else {
                Issue.record("Expected refusal metadata")
                continue
            }
            #expect(meta["mutation_dispatched"] == .bool(false))
            #expect(meta["retry_safe"] == .bool(true))
        }

        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        #expect(await Self.uiSnapshots.getSnapshot(id: nil)?.id == retainedSnapshotID)
    }

    @Test
    func `Click tool rejects same ID replacement generation before automation`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let capturedIdentity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 1)
        let replacementIdentity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 111,
            ownerProcessStartIdentity: 2)
        let bounds = CGRect(x: 100, y: 50, width: 1000, height: 500)
        let capturedWindow = ServiceWindowInfo(
            windowID: 42,
            title: "Captured",
            bounds: bounds,
            index: 0,
            mutationIdentity: capturedIdentity)
        let replacementWindow = ServiceWindowInfo(
            windowID: 42,
            title: "Replacement",
            bounds: bounds,
            index: 0,
            mutationIdentity: replacementIdentity)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: replacementWindow),
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotID = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/replaced-coordinate-window.png",
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp"),
                windowInfo: capturedWindow))

        let response = try await context.execute(
            tool: ClickTool(context: context),
            arguments: ToolArguments(raw: [
                "coords": "300,200",
                "snapshot": snapshotID,
            ]))

        #expect(response.isError)
        guard case let .object(meta) = response.meta else {
            Issue.record("Expected refusal metadata")
            return
        }
        #expect(meta["mutation_dispatched"] == .bool(false))
        #expect(meta["retry_safe"] == .bool(true))
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
        #expect(await Self.uiSnapshots.getSnapshot(id: nil)?.id == snapshotID)
    }

    @Test
    func `Click tool never mints a missing snapshot window receipt at dispatch`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let automation = await MainActor.run { MockAutomationService(accessibilityGranted: true) }
        let window = ServiceWindowInfo(
            windowID: 42,
            title: "Legacy Snapshot Window",
            bounds: CGRect(x: 100, y: 50, width: 1000, height: 500),
            index: 0)
        let context = await MCPToolTestHelpers.makeContext(
            automation: automation,
            windows: PointerPolicyWindowService(window: window),
            snapshotOwner: Self.uiSnapshots.owner)
        let snapshot = await Self.uiSnapshots.createSnapshot()
        let snapshotId = await snapshot.id
        await snapshot.setScreenshot(
            path: "/tmp/missing-window-receipt.png",
            metadata: CaptureMetadata(
                size: CGSize(width: 1000, height: 500),
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 111,
                    bundleIdentifier: "com.example.snapshot",
                    name: "SnapshotApp"),
                windowInfo: window))

        let response = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "coords": "300,200",
            "snapshot": snapshotId,
        ]))

        #expect(response.isError)
        #expect(await MainActor.run { automation.targetedClickCalls.isEmpty })
    }
}

private struct BackgroundPolicyMutationProbe: MCPTool {
    let name: String
    let counter: BackgroundPolicyInvocationCounter
    let description = "Background policy mutation probe"

    var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "action": SchemaBuilder.string(),
                "app": SchemaBuilder.string(),
                "button": SchemaBuilder.string(),
                "bundleId": SchemaBuilder.string(),
                "name": SchemaBuilder.string(),
                "pid": SchemaBuilder.integer(),
                "text": SchemaBuilder.string(),
            ],
            required: [])
    }

    func execute(arguments: ToolArguments) async throws -> ToolResponse {
        await self.counter.record(arguments)
        guard let plan = AuthorizedDesktopTargetPlan.current else {
            return ToolResponse.text("invoked")
        }
        let identity = plan.processIdentity
        let receipt = DesktopActionTargetReceipt(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity)
        return try ToolResponse(
            content: [.text(text: "invoked", annotations: nil, _meta: nil)],
            meta: MCPToolResponseMetadataProjector.metadata(
                merging: ["target_receipt": Value(receipt)],
                outcome: .confirmedChange(
                    delivery: .init(mechanism: .nativeFramework, mode: .background),
                    unitCount: .one)))
    }
}

private actor BackgroundPolicyInvocationCounter {
    private(set) var invocationCount = 0
    private(set) var lastName: String?

    func record(_ arguments: ToolArguments) {
        self.invocationCount += 1
        self.lastName = arguments.getString("name")
    }
}

@MainActor
private final class ReadinessFailureApplicationService: MockApplicationService {
    override func launchApplication(request _: ApplicationLaunchRequest) async throws -> ServiceApplicationInfo {
        throw ApplicationLifecycleReadOnlyFailureError(.timeout("Window readiness timed out"))
    }
}
