import CoreGraphics
import Foundation
import MCP
@_spi(Testing) import PeekabooAutomationKit
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import TachikomaMCP
import Testing
import UniformTypeIdentifiers
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct MCPObservedFocusProjectionTests {
    enum Evidence: String, CaseIterable {
        case known
        case absent
        case ambiguous
        case cached
        case applicationScoped
    }

    @Test(arguments: Evidence.allCases)
    @MainActor
    func `See metadata forwards only validated focus through MCP and Agent`(_ evidence: Evidence) async throws {
        let fixture = try FocusProjectionFixture(evidence: evidence)
        let snapshot = UISnapshot()
        let metadata = try await fixture.seeMetadata(snapshot: snapshot)
        let response = ToolResponse.text("Synthetic observation metadata", meta: metadata)

        try Self.expectProjection(response, toolName: "see", expected: fixture.expectedFocus)
        #expect(snapshot.focusedElement == fixture.expectedFocus)
        #expect(fixture.automation.inspectCalls == 0)
        #expect(fixture.automation.detectCalls == 0)
        #expect(fixture.automation.focusCalls == 0)
        fixture.expectNoAmbientCalls()
    }

    @Test(arguments: Evidence.allCases)
    @MainActor
    func `Inspect UI forwards focus without another observation`(_ evidence: Evidence) async throws {
        let fixture = try FocusProjectionFixture(evidence: evidence)
        let response = try await InspectUITool(context: fixture.context).execute(arguments: ToolArguments(raw: [:]))

        #expect(!response.isError)
        try Self.expectProjection(response, toolName: "inspect_ui", expected: fixture.expectedFocus)
        #expect(fixture.automation.inspectCalls == 1)
        #expect(fixture.automation.detectCalls == 0)
        #expect(fixture.automation.focusCalls == 0)
        fixture.expectNoAmbientCalls()
        await fixture.context.uiSnapshots.removeOwner()
    }

    @Test
    @MainActor
    func `See ROI metadata retains global focus frame when focused row is outside presentation`() async throws {
        let fixture = try FocusProjectionFixture(evidence: .known)
        let source = fixture.target.window.bounds
        let localROI = CGRect(x: 0, y: 0, width: 100, height: 100)
        let viewport = CaptureViewport(
            sourceLogicalBounds: source,
            requestedWindowRelativeBounds: localROI,
            deliveredWindowRelativeBounds: localROI,
            logicalBounds: localROI.offsetBy(dx: source.minX, dy: source.minY),
            sourceImageSize: source.size)
        let metadata = try await fixture.seeMetadata(snapshot: UISnapshot(), viewport: viewport)

        #expect(metadata.objectValue?["element_count"] == .double(0))
        try Self.expectProjection(
            .text("Synthetic ROI metadata", meta: metadata),
            toolName: "see",
            expected: fixture.expectedFocus)
        #expect(try Self.focus(in: metadata.objectValue?["focused_element"])?.frame ==
            CGRect(x: 420, y: 260, width: 180, height: 30))
        fixture.expectNoAmbientCalls()
    }

    @Test
    @MainActor
    func `See metadata does not revive focus from an invalidated snapshot`() async throws {
        let fixture = try FocusProjectionFixture(evidence: .known)
        let snapshot = UISnapshot()
        await snapshot.setTargetMetadata(from: WindowContext(
            applicationProcessId: 999,
            applicationProcessStartIdentity: 1))
        let metadata = try await fixture.seeMetadata(snapshot: snapshot)

        #expect(fixture.detection.metadata.windowContext?.focusedElement != nil)
        #expect(snapshot.targetReceiptInvalidated)
        try Self.expectProjection(
            .text("Synthetic invalidated metadata", meta: metadata),
            toolName: "see",
            expected: nil)
        fixture.expectNoAmbientCalls()
    }

    @Test(arguments: [nil, "", "see", "inspect_ui", "image", "browser", "type"] as [String?])
    func `External focus metadata is allowlisted only for native observation tools`(_ toolName: String?) throws {
        let focused = FocusedElementIdentity(
            processIdentifier: 333,
            windowID: 42,
            role: "AXTextField",
            frame: CGRect(x: 420, y: 260, width: 180, height: 30))
        let value = try Value(focused)
        let metadata: Value = .object([
            "focused_element": value,
            "internal_diagnostics": .string("must remain internal"),
        ])
        let response = ToolResponse.text("Synthetic observation", meta: metadata)
        let wire = try Self.wireMetadata(response, toolName: toolName)
        let allowed = toolName == "see" || toolName == "inspect_ui"

        #expect(try Self.focus(in: wire["focused_element"]) == (allowed ? focused : nil))
        #expect(wire["internal_diagnostics"] == nil)
        #expect(MCPToolResponseMetadataProjector.agentFields(from: metadata)["focused_element"] == nil)
    }

    private static func expectProjection(
        _ response: ToolResponse,
        toolName: String,
        expected: FocusedElementIdentity?) throws
    {
        #expect(try self.focus(in: response.meta?.objectValue?["focused_element"]) == expected)
        #expect(try self.focus(in: self.wireMetadata(response, toolName: toolName)["focused_element"]) == expected)
        let agent = try #require(AgentToolMCPBridge.convert(response).value.objectValue)
        let agentFocus = agent["meta"]?.objectValue?["focused_element"]
        if let expected {
            let encoded = try JSONEncoder().encode(#require(agentFocus))
            #expect(try JSONDecoder().decode(FocusedElementIdentity.self, from: encoded) == expected)
        } else {
            #expect(agentFocus == nil)
        }
        #expect(agent["focused_element"] == nil)
    }

    private static func focus(in value: Value?) throws -> FocusedElementIdentity? {
        guard let value else { return nil }
        return try JSONDecoder().decode(FocusedElementIdentity.self, from: JSONEncoder().encode(value))
    }

    private static func wireMetadata(_ response: ToolResponse, toolName: String?) throws -> [String: Value] {
        let wire = PeekabooMCPServer.callToolResult(from: response, toolName: toolName)
        let decoded = try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(wire))
        return decoded.objectValue?["_meta"]?.objectValue ?? [:]
    }
}

@MainActor
private struct FocusProjectionFixture {
    let target: LinkedDesktopTargetFixture
    let detection: ElementDetectionResult
    let expectedFocus: FocusedElementIdentity?
    let automation: FocusProjectionAutomation
    let screenCapture: MockScreenCaptureService
    let desktopObservation: StubDesktopObservationService
    let context: MCPToolContext
    let unused: FocusProjectionUnusedServices

    init(evidence: MCPObservedFocusProjectionTests.Evidence) throws {
        let focused = FocusedElementIdentity(
            processIdentifier: 333,
            windowID: 42,
            role: "AXTextField",
            title: "Editor",
            identifier: "synthetic.editor",
            frame: CGRect(x: 420, y: 260, width: 180, height: 30))
        let target = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 333, processStartIdentity: 1001),
            windowID: 42,
            bounds: CGRect(x: 100, y: 200, width: 640, height: 480),
            focusedElement: focused)
        var attributes = ["role": focused.role, "title": "Editor", "identifier": "synthetic.editor"]
        if evidence != .absent {
            attributes["isFocused"] = "true"
        }
        var elements = [DetectedElement(
            id: "synthetic-editor",
            type: .textField,
            label: "Editor",
            bounds: focused.frame,
            attributes: attributes)]
        if evidence == .ambiguous {
            elements.append(DetectedElement(
                id: "synthetic-second-editor",
                type: .textField,
                bounds: focused.frame.offsetBy(dx: 10, dy: 0),
                attributes: attributes))
        }
        let windowContext = evidence == .applicationScoped
            ? WindowContext(
                applicationName: target.application.name,
                applicationBundleId: target.application.bundleIdentifier,
                applicationProcessId: target.processIdentity.processIdentifier,
                applicationProcessStartIdentity: target.processIdentity.processStartIdentity)
            : target.windowContext
        let detection = ElementDetectionResultBuilder.makeResult(
            snapshotId: "synthetic-focus-result",
            elements: elements,
            usedCache: evidence == .cached,
            windowContext: windowContext,
            isDialog: false,
            truncationInfo: evidence == .applicationScoped
                ? DetectionTruncationInfo(incompleteAccessibilityRead: true) : nil,
            applicationScopedAccessibilityFallbackOrigin: evidence == .applicationScoped
                ? ApplicationScopedAccessibilityFallbackOrigin(windowIdentity: target.windowIdentity) : nil,
            additionalWarnings: evidence == .applicationScoped
                ? [DetectionMetadata.applicationScopedAccessibilityFallbackWarning] : [])
        let expectedFocus = evidence == .known ? focused : nil
        #expect(detection.metadata.windowContext?.focusedElement == expectedFocus)
        #expect(detection.elements.all.contains(where: { $0.isFocused == true }) == (evidence != .absent))
        if evidence == .applicationScoped {
            #expect(detection.metadata.windowContext?.windowID == nil)
            #expect(detection.metadata.windowContext?.windowMutationIdentity == nil)
        }
        let automation = FocusProjectionAutomation(detectionResult: detection)
        let storage = InMemorySnapshotManager()
        let graph = try LinkedApplicationInventoryGraph(linkedTargets: [target])
        let services = StubServices(
            applications: ScriptedApplicationInventoryService(graph: graph),
            automation: automation,
            windows: ScriptedWindowInventoryService(graph: graph),
            snapshots: storage)
        let unused = FocusProjectionUnusedServices()
        let screenCapture = MockScreenCaptureService(screenRecordingGranted: false)
        self.target = target
        self.detection = detection
        self.expectedFocus = expectedFocus
        self.automation = automation
        self.screenCapture = screenCapture
        self.desktopObservation = services.desktopObservationStub
        self.unused = unused
        self.context = MCPToolContext(
            automation: automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: storage,
            screens: MockScreenService(screens: []),
            agent: nil,
            permissions: services.permissions,
            clipboard: unused,
            browser: unused,
            permissionsStatusProvider: unused,
            snapshotOwner: MCPToolSnapshotOwner())
    }

    func seeMetadata(snapshot: UISnapshot, viewport: CaptureViewport? = nil) async throws -> Value {
        let capture = CaptureMetadata(
            size: viewport?.logicalBounds.size ?? self.target.window.bounds.size,
            mode: .window,
            applicationInfo: self.target.application,
            windowInfo: self.target.window,
            viewport: viewport)
        await snapshot.setScreenshot(
            path: "synthetic.png",
            metadata: capture,
            context: self.detection.metadata.windowContext)
        let observation = DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .appWindow),
            capture: CaptureResult(imageData: Data(), metadata: capture),
            elements: self.detection)
        let elements = DesktopObservationROIProcessor.presentationElements(
            DetectedElementSnapshotConverter.convert(self.detection.elements.all),
            viewport: viewport)
        return try SeeTool(context: self.context).makeMetadata(
            snapshot: snapshot,
            elements: elements,
            observation: observation,
            actionResult: UIAutomationActionResult(payload: observation, outcome: nil))
    }

    func expectNoAmbientCalls() {
        #expect(self.unused.calls == 0)
        #expect(self.screenCapture.captureAttemptCount == 0)
        #expect(self.desktopObservation.lastRequest == nil)
        #expect(self.context.executionPolicy == .backgroundOnly)
    }
}

@MainActor
private final class FocusProjectionAutomation: InspectUITestAutomationService {
    private(set) var inspectCalls = 0
    private(set) var detectCalls = 0
    private(set) var focusCalls = 0

    init(detectionResult: ElementDetectionResult) {
        super.init(accessibilityGranted: false, detectionResult: detectionResult)
    }

    override func inspectAccessibilityTree(windowContext: WindowContext?) async throws -> ElementDetectionResult {
        self.inspectCalls += 1
        return try await super.inspectAccessibilityTree(windowContext: windowContext)
    }

    override func detectElements(in imageData: Data, snapshotId: String?, windowContext: WindowContext?) async throws
        -> ElementDetectionResult
    {
        self.detectCalls += 1
        return try await super.detectElements(in: imageData, snapshotId: snapshotId, windowContext: windowContext)
    }

    override func getFocusedElement() -> UIFocusInfo? {
        self.focusCalls += 1
        return nil
    }
}

@MainActor
private final class FocusProjectionUnusedServices: ClipboardServiceProtocol, BrowserMCPClientProviding,
    PermissionsStatusProviding
{
    private(set) var calls = 0

    private func unexpected() -> PeekabooError {
        self.calls += 1
        return .notImplemented("Focus projection must not access ambient services")
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
