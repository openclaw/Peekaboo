import Foundation
import MCP
import Tachikoma
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooBridge
@testable import PeekabooCore
@testable import PeekabooFoundation

@Suite(.serialized)
struct MCPToolContextTests {
    @Test
    @MainActor
    func `shared resolves the configured services`() async {
        let services = PeekabooServices()

        await MCPToolContext.withDefaultContextFactoryForTesting {
            MainActor.preconditionIsolated()
            return MCPToolContext(services: services)
        } perform: {
            let context = MCPToolContext.shared

            #expect(ObjectIdentifier(context.automation as AnyObject) ==
                ObjectIdentifier(services.automation as AnyObject))
            #expect(ObjectIdentifier(context.menu as AnyObject) ==
                ObjectIdentifier(services.menu as AnyObject))
        }
    }

    @Test
    @MainActor
    func `context uses injected services and defaults to background only`() {
        let services = PeekabooServices()
        let context = MCPToolContext(services: services)

        #expect(ObjectIdentifier(context.menu as AnyObject) ==
            ObjectIdentifier(services.menu as AnyObject))
        #expect(ObjectIdentifier(context.automation as AnyObject) ==
            ObjectIdentifier(services.automation as AnyObject))
        #expect(context.executionPolicy == .backgroundOnly)
        #expect(context.executionHost == .local)
    }

    @Test
    @MainActor
    func `low level context initializer defaults to background only`() {
        let services = PeekabooServices()
        let context = MCPToolContext(
            automation: services.automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: services.snapshots,
            screens: services.screens,
            agent: services.agent,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: services.browser)

        #expect(context.executionPolicy == .backgroundOnly)
    }

    @Test
    @MainActor
    func `Agent tool construction captures task-local immutable policy`() throws {
        let agent = try PeekabooAgentService(services: PeekabooServices())
        let owner = MCPToolSnapshotOwner(sessionID: "durable-agent-session")

        let background = PeekabooAgentService.$toolConstructionSnapshotOwner.withValue(owner) {
            PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.backgroundOnly) {
                agent.makeToolContext()
            }
        }
        let foreground = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(.foregroundAllowed) {
            agent.makeToolContext()
        }

        #expect(background.executionPolicy == .backgroundOnly)
        #expect(background.uiSnapshots.owner == owner)
        #expect(foreground.executionPolicy == .foregroundAllowed)
        #expect(foreground.uiSnapshots.owner != owner)
        #expect(agent.makeToolContext().executionPolicy == .backgroundOnly)
    }

    @Test
    @MainActor
    func `capture preflight blocks pixel tools but permits AX and video ingest`() async throws {
        let services = PeekabooServices()
        let refusal = MCPToolCapturePreflightRefusal(
            message: "Legacy ScreenCaptureKit owner is live. No capture was dispatched.",
            hint: "Relaunch that exact owner before retrying.")
        let context = MCPToolContext(
            services: services,
            executionPolicy: .unrestricted,
            capturePreflightRefusal: refusal)
        let serverContext = context.replacingSnapshotOwner(with: MCPToolSnapshotOwner())
        #expect(serverContext.capturePreflightRefusal == refusal)

        for (name, arguments) in [
            ("see", ToolArguments(value: .object([:]))),
            ("see", ToolArguments(value: .object(["app_target": .string("TextEdit")]))),
            ("image", ToolArguments(value: .object(["capture_focus": .string("background")]))),
            ("capture", ToolArguments(value: .object([:]))),
            ("capture", ToolArguments(value: .object(["source": .string("live")]))),
            ("verify_state", ToolArguments(value: .object(["final_screenshot": .bool(true)]))),
        ] {
            let counter = MCPToolInvocationCounter()
            let response = try await serverContext.execute(
                tool: MCPToolInvocationProbe(name: name, counter: counter),
                arguments: arguments)

            #expect(response.isError)
            #expect(await !counter.wasInvoked)
            let metadata = try #require(response.meta?.objectValue)
            #expect(metadata["error_code"] == .string("CAPTURE_FAILED"))
            #expect(metadata["effect"] == .string("refused"))
            #expect(metadata["mutation_dispatched"] == .bool(false))
            #expect(metadata["retry_safe"] == .bool(true))
            guard case let .text(text, _, _)? = response.content.first else {
                Issue.record("Expected a textual capture refusal for \(name)")
                continue
            }
            #expect(text.contains(refusal.message))
            #expect(try text.contains(#require(refusal.hint)))
        }

        for (name, arguments) in [
            ("inspect_ui", ToolArguments(value: .object([:]))),
            ("see", ToolArguments(value: .object(["capture_engine": .string(" CLASSIC ")]))),
            ("capture", ToolArguments(value: .object(["source": .string(" VIDEO ")]))),
            ("verify_state", ToolArguments(value: .object(["final_screenshot": .bool(false)]))),
        ] {
            let counter = MCPToolInvocationCounter()
            let response = try await serverContext.execute(
                tool: MCPToolInvocationProbe(name: name, counter: counter),
                arguments: arguments)

            #expect(!response.isError)
            #expect(await counter.wasInvoked)
        }

        let unknownCounter = MCPToolInvocationCounter()
        let unknown = try await serverContext.execute(
            tool: MCPToolInvocationProbe(name: "future_pixel_tool", counter: unknownCounter),
            arguments: ToolArguments(value: .object([:])))
        #expect(unknown.isError)
        #expect(await !unknownCounter.wasInvoked)
        #expect(unknown.meta?.objectValue?["error_code"] == .string("CAPTURE_POLICY_UNCLASSIFIED"))
    }

    @Test
    @MainActor
    func `Agent contexts inherit immutable capture preflight`() throws {
        let agent = try PeekabooAgentService(services: PeekabooServices())
        let refusal = MCPToolCapturePreflightRefusal(message: "fixture capture refusal")

        agent.configureCapturePreflightRefusal(refusal)
        let refusedContext = agent.makeToolContext()
        agent.configureCapturePreflightRefusal(nil)

        #expect(refusedContext.capturePreflightRefusal == refusal)
        #expect(agent.makeToolContext().capturePreflightRefusal == nil)
    }

    @Test
    func `Bridge action failure preserves its standardized capture code for MCP metadata`() throws {
        let failure = try #require(DesktopActionFailure(
            outcome: .refused(route: .bridge, reason: .runtimeIncompatible),
            message: "Capture failed before dispatch",
            standardErrorCode: .captureFailed))

        #expect(ObservationActionResultSupport.standardErrorFields(failure) == [
            "error_code": .string("CAPTURE_FAILED"),
        ])
        let roundTrip = try JSONDecoder().decode(
            DesktopActionFailure.self,
            from: JSONEncoder().encode(failure))
        #expect(roundTrip == failure)
    }

    @Test
    @MainActor
    func `legacy contexts share process owner while explicit contexts isolate`() {
        let services = PeekabooServices()
        let first = MCPToolContext(services: services)
        let second = MCPToolContext(services: services)
        let isolated = MCPToolContext(
            services: services,
            snapshotOwner: MCPToolSnapshotOwner())

        #expect(first.uiSnapshots.owner == second.uiSnapshots.owner)
        #expect(first.uiSnapshots.owner != isolated.uiSnapshots.owner)
        #expect(first.executionHost == .local)
        #expect(isolated.executionHost == .local)
    }

    @Test
    @MainActor
    func `remote services mark contexts remote and owner replacement preserves the host`() {
        let services = RemotePeekabooServices(
            client: PeekabooBridgeClient(socketPath: "/tmp/peekaboo-unused-context-test.sock"))
        let context = MCPToolContext(services: services)
        let replacement = context.replacingSnapshotOwner(with: MCPToolSnapshotOwner())

        #expect(services.executionHost == .remote)
        #expect(context.executionHost == .remote)
        #expect(replacement.executionHost == .remote)
    }

    @Test
    @MainActor
    func `remote MCP refuses a browser client without scoped session support`() async {
        let services = RemotePeekabooServices(
            client: PeekabooBridgeClient(socketPath: "/tmp/peekaboo-unused-context-test.sock"))
        let root = UnsupportedBrowserRoot()
        let context = MCPToolContext(services: services, browser: root)

        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await context.openingBrowserSession(named: "mcp:must-not-borrow-root")
        }
        #expect(root.callCount == 0)
    }

    @Test
    @MainActor
    func `local MCP refuses an unsupported browser root but browser filtering skips session opening`() async throws {
        let services = PeekabooServices()
        let root = UnsupportedBrowserRoot()
        let context = MCPToolContext(services: services, browser: root)

        #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try context.scopingBrowserSession(named: "mcp:must-not-borrow-root")
        }
        await #expect(throws: BrowserMCPConnectionError.receiptBindingUnsupported) {
            _ = try await PeekabooMCPServer(
                toolContext: context,
                toolFilters: ToolFilters(
                    allow: ["browser"],
                    deny: [],
                    allowSource: .config,
                    denySources: [:]))
        }
        #expect(root.callCount == 0)

        let filteredServer = try await PeekabooMCPServer(
            toolContext: context,
            toolFilters: ToolFilters(
                allow: ["permissions"],
                deny: [],
                allowSource: .config,
                denySources: [:]))
        #expect(await filteredServer.registeredToolNamesForTesting() == ["permissions"])
        #expect(root.callCount == 0)
        #expect(await filteredServer.stopForTesting())
    }

    @Test
    @MainActor
    func `Agent foreground opt-in cannot execute the real shell tool`() async throws {
        let agent = try PeekabooAgentService(services: PeekabooServices())
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-shell-policy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        for policy in [MCPToolExecutionPolicy.backgroundOnly, .foregroundAllowed] {
            let tools = await agent.buildToolset(for: .anthropic(.sonnet45), executionPolicy: policy)
            #expect(!tools.contains(where: { $0.name == "shell" }))
            let shell = PeekabooAgentService.$toolConstructionExecutionPolicy.withValue(policy) {
                agent.createShellTool()
            }
            do {
                _ = try await shell.execute(
                    AgentToolArguments(["command": "/usr/bin/touch \(marker.path)"]),
                    context: ToolExecutionContext())
                Issue.record("Expected the Agent shell policy to throw a typed failure")
            } catch let failure as AgentToolExecutionFailure {
                let metadata = try #require(failure.metadata?.objectValue)
                #expect(metadata["error_code"]?.stringValue == MCPToolExecutionPolicy.refusalErrorCode)
                #expect(metadata["mutation_dispatched"]?.boolValue == false)
            }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    @Test
    @MainActor
    func `task local override restores shared value`() async {
        let services = PeekabooServices()

        await MCPToolContext.withDefaultContextFactoryForTesting {
            MCPToolContext(services: services)
        } perform: {
            let baselineContext = MCPToolContext.shared
            let overrideContext = MCPToolContext(services: PeekabooServices())

            await MCPToolContext.withContext(overrideContext) {
                let inside = MCPToolContext.shared
                #expect(ObjectIdentifier(inside.automation as AnyObject) ==
                    ObjectIdentifier(overrideContext.automation as AnyObject))
            }

            let after = MCPToolContext.shared
            #expect(ObjectIdentifier(after.automation as AnyObject) ==
                ObjectIdentifier(baselineContext.automation as AnyObject))
        }
    }

    @Test
    func `sharedOnMainActor resolves from a detached task`() async {
        await MCPToolContext.withDefaultContextFactoryForTesting(nil) {
            let services = PeekabooServices()
            MCPToolContext.configureDefaultContext {
                MainActor.preconditionIsolated()
                return MCPToolContext(services: services)
            }

            let context = await Task.detached {
                await MCPToolContext.sharedOnMainActor()
            }.value

            #expect(ObjectIdentifier(context.automation as AnyObject) ==
                ObjectIdentifier(services.automation as AnyObject))
            #expect(ObjectIdentifier(context.menu as AnyObject) ==
                ObjectIdentifier(services.menu as AnyObject))
        }
    }
}

@MainActor
private final class UnsupportedBrowserRoot: BrowserMCPClientProviding, @unchecked Sendable {
    private(set) var callCount = 0

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        self.callCount += 1
        return BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        self.callCount += 1
        return BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func disconnect() async {
        self.callCount += 1
    }

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        self.callCount += 1
        return .text("unexpected root execution")
    }
}

private actor MCPToolInvocationCounter {
    private var invoked = false

    var wasInvoked: Bool {
        self.invoked
    }

    func record() {
        self.invoked = true
    }
}

private struct MCPToolInvocationProbe: MCPTool {
    let name: String
    let counter: MCPToolInvocationCounter
    let description = "MCP tool invocation probe"

    var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "app_target": SchemaBuilder.string(),
                "capture_engine": SchemaBuilder.string(),
                "capture_focus": SchemaBuilder.string(),
                "final_screenshot": SchemaBuilder.boolean(),
                "source": SchemaBuilder.string(),
            ],
            required: [])
    }

    func execute(arguments _: ToolArguments) async throws -> ToolResponse {
        await self.counter.record()
        return ToolResponse.text("invoked")
    }
}
