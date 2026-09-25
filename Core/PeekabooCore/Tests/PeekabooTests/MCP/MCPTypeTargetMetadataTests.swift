import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKitTestSupport
import PeekabooBridgeTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct MCPTypeTargetMetadataTests {
    @Test(arguments: [false, true])
    func `ordinary and pixel typing preserve exact target metadata`(pixelFocus: Bool) async throws {
        let fixture = try await TypeMetadataFixture.make(exactWindow: true)
        var arguments: [String: Any] = ["snapshot": fixture.snapshotID, "text": "hello"]
        if pixelFocus {
            arguments["coords"] = "150,150"
        }

        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: arguments))

        #expect(!response.isError)
        try Self.expectTarget(fixture.targetIdentity, in: response)
        #expect(response.meta?.objectValue?["target_pid"] == .int(333))
        #expect(response.meta?.objectValue?["target_window_id"] == .int(999_999))
        #expect(fixture.automation.pixelCalls == (pixelFocus ? 1 : 0))
        #expect(fixture.automation.exactKeyboardEvents == (pixelFocus ? [] : ["type-start", "type-end"]))
        #expect(fixture.automation.lastTypeActions == nil)
        #expect(fixture.unused.calls == 0)
    }

    @Test
    func `process typing preserves lossless target identity without inventing a window`() async throws {
        let fixture = try await TypeMetadataFixture.make(exactWindow: false)
        fixture.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background))

        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "pid": 333,
            "text": "hello",
        ]))

        #expect(!response.isError)
        try Self.expectTarget(fixture.targetIdentity, in: response)
        let identity = try #require(response.meta?.objectValue?["target_identity"]?.objectValue)
        #expect(identity["kind"] == .string("process"))
        #expect(identity["process_start_identity_decimal"] == .string("9007199254740993"))
        #expect(identity["window_id"] == nil)
        #expect(response.meta?.objectValue?["target_pid"] == .int(333))
        #expect(response.meta?.objectValue?["target_window_id"] == nil)
        #expect(fixture.automation.lastProcessTargetedTypeIdentity == fixture.targetIdentity.processIdentity)
        #expect(fixture.automation.lastTypeActions == nil)
        #expect(fixture.unused.calls == 0)
    }

    @Test
    func `foreground typing does not synthesize missing target metadata`() async throws {
        let fixture = try await TypeMetadataFixture.make(exactWindow: false)
        fixture.automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .globalEvents, mode: .foreground))

        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "text": "hello",
            "foreground": true,
        ]))

        #expect(!response.isError)
        try Self.expectTarget(nil, in: response)
        #expect(response.meta?.objectValue?["target_pid"] == nil)
        #expect(response.meta?.objectValue?["target_window_id"] == nil)
        #expect(fixture.automation.lastTypeActions != nil)
        #expect(fixture.automation.lastProcessTargetedTypeIdentity == nil)
        #expect(fixture.unused.calls == 0)
    }

    @Test(arguments: [false, true])
    func `pixel typing still rejects missing or mismatched result identity`(mismatched: Bool) async throws {
        let fixture = try await TypeMetadataFixture.make(exactWindow: true)
        fixture.automation.pixelTargetIdentity = mismatched
            ? try DesktopTargetIdentity(processIdentity: .init(processIdentifier: 444, processStartIdentity: 44))
            : nil

        let response = try await TypeTool(context: fixture.context).execute(arguments: ToolArguments(raw: [
            "snapshot": fixture.snapshotID,
            "coords": "150,150",
            "text": "hello",
        ]))

        #expect(response.isError)
        let wire = try Self.wireMetadata(response)
        for metadata in try [#require(response.meta?.objectValue), wire] {
            #expect(metadata["state"] == .string("indeterminate"))
            #expect(metadata["mutation_dispatched"] == .bool(true))
            #expect(metadata["retry_safe"] == .bool(false))
            #expect(metadata["target_identity"] == nil)
            #expect(try metadata["target_receipt"] == Value(fixture.targetIdentity.actionTargetReceipt))
        }
        #expect(fixture.automation.pixelCalls == 1)
        #expect(fixture.automation.exactKeyboardEvents.isEmpty)
        #expect(fixture.automation.lastTypeActions == nil)
        #expect(fixture.unused.calls == 0)
    }

    private static func expectTarget(_ identity: DesktopTargetIdentity?, in response: ToolResponse) throws {
        let projectedIdentity = try identity.map { try Value($0.projection) }
        let projectedReceipt = try identity.map { try Value($0.actionTargetReceipt) }
        let wire = try self.wireMetadata(response)
        for metadata in try [#require(response.meta?.objectValue), wire] {
            #expect(metadata["target_identity"] == projectedIdentity)
            #expect(metadata["target_receipt"] == projectedReceipt)
        }
        #expect(wire["target_pid"] == nil)
        #expect(wire["target_window_id"] == nil)
    }

    private static func wireMetadata(_ response: ToolResponse) throws -> [String: Value] {
        let wire = PeekabooMCPServer.callToolResult(from: response, toolName: "type")
        let decoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(wire))
        return decoded.objectValue?["_meta"]?.objectValue ?? [:]
    }
}

@MainActor
private struct TypeMetadataFixture {
    let context: MCPToolContext
    let automation: TypeMetadataAutomation
    let targetIdentity: DesktopTargetIdentity
    let snapshotID: String
    let unused: TypeMetadataUnusedServices

    static func make(exactWindow: Bool) async throws -> Self {
        let linked = AutomationTestFixtures.linkedSnapshotTarget(
            snapshotID: SnapshotReference.generate().rawValue,
            processIdentity: .init(processIdentifier: 333, processStartIdentity: 9_007_199_254_740_993),
            windowID: 999_999,
            bounds: CGRect(x: 100, y: 50, width: 500, height: 400))
        let target = linked.desktopTarget
        let application = exactWindow ? target.application : AutomationTestFixtures.application(
            processIdentifier: target.processIdentity.processIdentifier,
            processStartIdentity: target.processIdentity.processStartIdentity,
            bundleIdentifier: target.application.bundleIdentifier,
            name: target.application.name,
            windowCount: 0,
            windowIDs: [])
        let graph = try LinkedApplicationInventoryGraph(nodes: [
            .init(application: application, windows: exactWindow ? [target.window] : []),
        ])
        let storage = if exactWindow {
            try await InMemorySnapshotManager.containing(linked.detectionResult)
        } else {
            InMemorySnapshotManager()
        }
        let automation = TypeMetadataAutomation()
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background))
        automation.pixelTargetIdentity = try linked.targetIdentity
        let services = StubServices(
            applications: ScriptedApplicationInventoryService(graph: graph),
            automation: automation,
            windows: ScriptedWindowInventoryService(graph: graph),
            snapshots: storage)
        let unused = TypeMetadataUnusedServices()
        let context = MCPToolContext(
            automation: automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: storage,
            screens: MockScreenService(screens: []),
            agent: nil,
            permissions: services.permissions,
            clipboard: unused,
            browser: unused,
            permissionsStatusProvider: unused,
            snapshotOwner: MCPToolSnapshotOwner(),
            executionPolicy: .unrestricted)
        if exactWindow {
            let snapshot = await context.uiSnapshots.createSnapshot(id: linked.snapshotID)
            await snapshot.setScreenshot(
                path: linked.detectionResult.screenshotPath,
                metadata: CaptureMetadata(
                    size: target.window.bounds.size,
                    mode: .window,
                    applicationInfo: target.application,
                    windowInfo: target.window),
                context: target.windowContext)
        }
        return try Self(
            context: context,
            automation: automation,
            targetIdentity: exactWindow ? linked.targetIdentity : DesktopTargetIdentity(
                processIdentity: target.processIdentity),
            snapshotID: linked.snapshotID,
            unused: unused)
    }
}

@MainActor
private final class TypeMetadataAutomation: StubAutomationService, ExactWindowPixelFocusTypingServiceProtocol {
    let supportsExactWindowPixelFocusTyping = true
    let exactWindowPixelFocusTypingUnavailableReason: String? = nil
    var pixelTargetIdentity: DesktopTargetIdentity?
    private(set) var pixelCalls = 0

    func typeActionsByFocusingPixelWithOutcome(
        _ request: ExactWindowPixelFocusTypeRequest) async throws -> UIAutomationActionResult<TypeResult>
    {
        self.pixelCalls += 1
        return UIAutomationActionResult(
            payload: BridgeTestFixtures.typeResult(for: request.actions),
            outcome: .confirmedChange(delivery: .init(mechanism: .composite, mode: .background)),
            targetIdentity: self.pixelTargetIdentity)
    }
}

@MainActor
private final class TypeMetadataUnusedServices: ClipboardServiceProtocol, BrowserMCPClientProviding,
    PermissionsStatusProviding
{
    private(set) var calls = 0

    private func unexpected() -> PeekabooError {
        self.calls += 1
        return .notImplemented("Typing metadata must not access ambient services")
    }

    func permissionsStatus() async throws -> PermissionsStatus {
        throw self.unexpected()
    }

    func get(prefer _: UTType?) throws -> ClipboardReadResult? {
        throw self.unexpected()
    }

    func set(_: ClipboardWriteRequest) throws -> ClipboardReadResult {
        throw self.unexpected()
    }

    func clear() {
        _ = self.unexpected()
    }

    func save(slot _: String) throws {
        throw self.unexpected()
    }

    func restore(slot _: String) throws -> ClipboardReadResult {
        throw self.unexpected()
    }

    func status(channel _: BrowserMCPChannel?) async -> BrowserMCPStatus {
        _ = self.unexpected()
        return BrowserMCPStatus(isConnected: false, toolCount: 0, detectedBrowsers: [])
    }

    func connect(channel _: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        throw self.unexpected()
    }

    func disconnect() async {
        _ = self.unexpected()
    }

    func execute(
        toolName _: String,
        arguments _: [String: Any],
        channel _: BrowserMCPChannel?) async throws -> ToolResponse
    {
        throw self.unexpected()
    }
}
