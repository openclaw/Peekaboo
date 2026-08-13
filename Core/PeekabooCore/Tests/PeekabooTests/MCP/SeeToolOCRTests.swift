import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct SeeToolOCRTests {
    private static let uiSnapshots = MCPToolUISnapshotStore(owner: MCPToolSnapshotOwner())

    @Test
    func `See declares local additive OCR as an opt in boolean`() async {
        let context = await MCPToolTestHelpers.makeContext(snapshotOwner: Self.uiSnapshots.owner)
        let tool = SeeTool(context: context)
        guard case let .object(root) = tool.inputSchema,
              case let .object(properties)? = root["properties"],
              case let .object(ocr)? = properties["ocr"]
        else {
            Issue.record("Expected OCR schema")
            return
        }

        #expect(ocr["type"] == .string("boolean"))
        #expect(ocr["default"] == .bool(false))
        guard case let .string(description)? = ocr["description"] else {
            Issue.record("Expected OCR description")
            return
        }
        #expect(description.contains("locally"))
        #expect(description.contains("non-actionable"))
    }

    @Test
    func `Calendar shaped incomplete AX observation succeeds with exact OCR evidence`() async throws {
        await Self.uiSnapshots.removeAllSnapshots()
        let snapshots = await MainActor.run { InMemorySnapshotManager() }
        let observation = await MainActor.run { CalendarOCRObservationService(snapshots: snapshots) }
        let context = await self.makeContext(desktopObservation: observation, snapshots: snapshots)
        defer {
            Task { await Self.uiSnapshots.removeAllSnapshots() }
        }

        let response = try await SeeTool(context: context).execute(arguments: ToolArguments(raw: [
            "app_target": "PID:858",
            "window_id": 119,
            "ocr": true,
        ]))

        #expect(!response.isError)
        let recordedRequest = await MainActor.run { observation.lastRequest }
        let request = try #require(recordedRequest)
        #expect(request.target == .pid(858, window: .id(119)))
        #expect(request.detection.mode == .accessibilityAndOCR)
        #expect(!request.detection.preferOCR)
        #expect(!request.detection.allowWebFocusFallback)
        #expect(request.capture.focus == .background)

        guard let first = response.content.first,
              case let .text(summary, annotations: _, _meta: _) = first,
              case let .object(meta)? = response.meta,
              case let .string(snapshotID)? = meta["snapshot_id"],
              case let .object(coordinateContext)? = meta["coordinate_context"],
              case let .object(window)? = coordinateContext["window"],
              case let .object(observationMeta)? = meta["observation"],
              case let .array(warnings)? = observationMeta["warnings"]
        else {
            Issue.record("Expected successful OCR response metadata")
            return
        }

        #expect(summary.contains("August 10, 2026"))
        #expect(summary.contains("desc: \"ocr\""))
        #expect(summary.contains("confidence: 93%"))
        #expect(summary.contains("[not actionable]"))
        #expect(summary.contains("AX tree incomplete"))
        #expect(meta["actionable_count"] == .double(0))
        #expect(coordinateContext["reference_id"] == .string(snapshotID))
        #expect(window["window_id"] == .int(119))
        #expect(warnings.contains(.string("ax_incomplete_read")))

        let snapshotValue = await Self.uiSnapshots.getSnapshot(id: snapshotID)
        let snapshot = try #require(snapshotValue)
        let ocrElementValue = await snapshot.getElement(byId: "ocr_1")
        let ocrElement = try #require(ocrElementValue)
        #expect(ocrElement.frame == CGRect(x: 240, y: 340, width: 180, height: 24))
        #expect(ocrElement.confidence == 0.93)
        #expect(ocrElement.description == "ocr")
        #expect(!ocrElement.isActionable)
        #expect(snapshot.applicationProcessId == 858)
        #expect(snapshot.windowID == 119)
        let expectedIdentity = await MainActor.run { CalendarOCRObservationService.identity }
        #expect(snapshot.windowMutationIdentity == expectedIdentity)
        let storedValue = try await context.snapshots.getUIAutomationSnapshot(snapshotId: snapshotID)
        let stored = try #require(storedValue)
        #expect(stored.captureCoordinateContext?.referenceID == snapshotID)
        #expect(stored.windowMutationIdentity == expectedIdentity)

        let clickResponse = try await ClickTool(context: context).execute(arguments: ToolArguments(raw: [
            "on": "ocr_1",
            "snapshot": snapshotID,
        ]))
        #expect(clickResponse.isError)
        guard let errorContent = clickResponse.content.first,
              case let .text(errorText, annotations: _, _meta: _) = errorContent,
              case let .object(clickMeta)? = clickResponse.meta
        else {
            Issue.record("Expected structured OCR interaction refusal")
            return
        }
        #expect(errorText.contains("semantic evidence"))
        #expect(clickMeta["mutation_dispatched"] == .bool(false))
        #expect(clickMeta["retry_safe"] == .bool(true))
    }

    @Test
    func `See request keeps OCR disabled by default`() throws {
        let request = try SeeRequest(arguments: ToolArguments(raw: [:]))

        #expect(!request.ocr)
    }

    @Test
    func `remote MCP See OCR refuses an incapable host before transport`() async throws {
        let snapshots = await MainActor.run { InMemorySnapshotManager() }
        let remoteObservation = await MainActor.run {
            RemotePeekabooServices(
                client: PeekabooBridgeClient(
                    socketPath: "/tmp/nonexistent-mcp-ocr-\(UUID().uuidString).sock",
                    requestTimeoutSec: 1),
                supportsDesktopObservation: true,
                supportsDesktopObservationOCR: false)
                .desktopObservation
        }
        let context = await self.makeContext(
            desktopObservation: remoteObservation,
            snapshots: snapshots)

        let response = try await SeeTool(context: context).execute(arguments: ToolArguments(raw: [
            "ocr": true,
        ]))

        #expect(response.isError)
        guard let first = response.content.first,
              case let .text(message, annotations: _, _meta: _) = first
        else {
            Issue.record("Expected structured remote OCR capability refusal")
            return
        }
        #expect(message.contains(PeekabooBridgeHostCapability.desktopObservationOCR))
        #expect(message.contains("Update and relaunch"))
        #expect(message.contains("--no-remote"))
    }

    private func makeContext(
        desktopObservation: any DesktopObservationServiceProtocol,
        snapshots: any SnapshotManagerProtocol) async -> MCPToolContext
    {
        let base = await MCPToolTestHelpers.makeContext(snapshotOwner: Self.uiSnapshots.owner)
        return await MainActor.run {
            MCPToolContext(
                automation: base.automation,
                menu: base.menu,
                windows: base.windows,
                applications: base.applications,
                dialogs: base.dialogs,
                dock: base.dock,
                screenCapture: base.screenCapture,
                desktopObservation: desktopObservation,
                snapshots: snapshots,
                screens: base.screens,
                agent: base.agent,
                permissions: base.permissions,
                clipboard: base.clipboard,
                browser: base.browser,
                snapshotMutationCoordinator: base.snapshotMutationCoordinator,
                snapshotExecutionGate: base.snapshotExecutionGate,
                snapshotOwner: Self.uiSnapshots.owner)
        }
    }
}

@MainActor
private final class CalendarOCRObservationService: DesktopObservationServiceProtocol {
    static let bounds = CGRect(x: 200, y: 300, width: 800, height: 600)
    static let identity = WindowMutationIdentity(
        windowID: 119,
        ownerProcessIdentifier: 858,
        ownerProcessStartIdentity: 4242,
        capturedBounds: bounds)

    private(set) var lastRequest: DesktopObservationRequest?

    private let snapshots: any SnapshotManagerProtocol

    init(snapshots: any SnapshotManagerProtocol) {
        self.snapshots = snapshots
    }

    func observe(_ request: DesktopObservationRequest) async throws -> DesktopObservationResult {
        self.lastRequest = request
        let path = try #require(request.output.path)
        try Data("calendar-ocr-pixels".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)

        let application = ServiceApplicationInfo(
            processIdentifier: 858,
            processStartIdentity: 4242,
            bundleIdentifier: "com.apple.iCal",
            name: "Calendar",
            windowCount: 1)
        let window = ServiceWindowInfo(
            windowID: 119,
            title: "Calendar",
            bounds: Self.bounds,
            mutationIdentity: Self.identity)
        let context = WindowContext(
            applicationName: "Calendar",
            applicationBundleId: "com.apple.iCal",
            applicationProcessId: 858,
            windowTitle: "Calendar",
            windowID: 119,
            windowBounds: Self.bounds,
            windowMutationIdentity: Self.identity)
        let ocrElement = DetectedElement(
            id: "ocr_1",
            type: .staticText,
            label: "August 10, 2026",
            bounds: CGRect(x: 240, y: 340, width: 180, height: 24),
            isEnabled: true,
            attributes: [
                "description": "ocr",
                "confidence": "0.93",
            ])
        let capture = CaptureResult(
            imageData: Data(),
            savedPath: path,
            metadata: CaptureMetadata(
                size: Self.bounds.size,
                mode: .window,
                applicationInfo: application,
                windowInfo: window,
                diagnostics: CaptureDiagnostics(
                    requestedScale: .logical1x,
                    nativeScale: 2,
                    outputScale: 1,
                    scaleSource: "fixture",
                    finalPixelSize: Self.bounds.size)))

        let detection = ElementDetectionResult(
            snapshotId: request.output.snapshotID ?? "calendar-ocr",
            screenshotPath: path,
            elements: DetectedElements(other: [ocrElement]),
            metadata: DetectionMetadata(
                detectionTime: 0.1,
                elementCount: 1,
                method: "AXorcist+OCR",
                warnings: ["ax_incomplete_read"],
                windowContext: context,
                truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true)))
        if let snapshotID = request.output.snapshotID {
            try await self.snapshots.storeScreenshot(SnapshotScreenshotRequest(
                snapshotId: snapshotID,
                screenshotPath: path,
                applicationBundleId: "com.apple.iCal",
                applicationProcessId: 858,
                applicationName: "Calendar",
                windowTitle: "Calendar",
                windowBounds: Self.bounds,
                windowID: 119,
                windowMutationIdentity: Self.identity,
                captureCoordinateContext: CaptureCoordinateContext(
                    metadata: capture.metadata,
                    referenceID: snapshotID)))
            try await self.snapshots.storeDetectionResult(snapshotId: snapshotID, result: detection)
        }

        return DesktopObservationResult(
            target: ResolvedObservationTarget(
                kind: .windowID(119),
                app: ApplicationIdentity(
                    processIdentifier: 858,
                    processStartIdentity: 4242,
                    bundleIdentifier: "com.apple.iCal",
                    name: "Calendar"),
                window: WindowIdentity(windowID: 119, title: "Calendar", bounds: Self.bounds, index: 0),
                bounds: Self.bounds,
                detectionContext: context),
            capture: capture,
            elements: detection,
            ocr: OCRTextResult(
                observations: [OCRTextObservation(
                    text: "August 10, 2026",
                    confidence: 0.93,
                    boundingBox: CGRect(x: 0.05, y: 0.85, width: 0.225, height: 0.04))],
                imageSize: Self.bounds.size),
            files: DesktopObservationFiles(rawScreenshotPath: path),
            diagnostics: DesktopObservationDiagnostics(warnings: ["ax_incomplete_read"]))
    }
}
