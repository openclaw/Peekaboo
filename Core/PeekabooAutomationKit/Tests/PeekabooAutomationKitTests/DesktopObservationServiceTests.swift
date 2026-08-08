import AppKit
import CoreGraphics
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class DesktopObservationServiceTests: XCTestCase {
    func testBestWindowPrefersLargestVisibleShareableWindow() {
        let small = Self.window(id: 1, title: "Small", bounds: CGRect(x: 100, y: 100, width: 100, height: 100))
        let minimized = Self.window(
            id: 2,
            title: "Minimized",
            bounds: CGRect(x: 100, y: 100, width: 1000, height: 1000),
            isMinimized: true)
        let large = Self.window(id: 3, title: "Large", bounds: CGRect(x: 100, y: 100, width: 400, height: 300))

        let selected = ObservationTargetResolver.bestWindow(from: [small, minimized, large])

        XCTAssertEqual(selected?.windowID, 3)
    }

    func testBestWindowSkipsAuxiliaryAndOffscreenWindows() {
        let toolbar = Self.window(id: 10, title: "", bounds: CGRect(x: 0, y: 0, width: 2560, height: 30), index: 0)
        let offscreen = Self.window(
            id: 11,
            title: "",
            bounds: CGRect(x: -50000, y: -50000, width: 2560, height: 30),
            index: 1)
        let main = Self.window(
            id: 12,
            title: "Zephyr Agency",
            bounds: CGRect(x: 500, y: 300, width: 1460, height: 945),
            index: 2)

        let selected = ObservationTargetResolver.bestWindow(from: [toolbar, offscreen, main])

        XCTAssertEqual(selected?.windowID, 12)
    }

    func testBestWindowPrefersMainTitledWindowOverLargerUntitledWindow() {
        let auxiliary = Self.window(
            id: 20,
            title: "",
            bounds: CGRect(x: 100, y: 100, width: 1000, height: 700),
            index: 0)
        let main = Self.window(
            id: 21,
            title: "Document",
            bounds: CGRect(x: 200, y: 200, width: 500, height: 360),
            isMainWindow: true,
            index: 1)

        let selected = ObservationTargetResolver.bestWindow(from: [auxiliary, main])

        XCTAssertEqual(selected?.windowID, 21)
    }

    func testObservationWithoutDetectionCapturesResolvedWindowID() async throws {
        let imageData = Data([1, 2, 3])
        let app = Self.app()
        let window = Self.window(id: 42, title: "Main", bounds: CGRect(x: 100, y: 100, width: 400, height: 300))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let capture = RecordingScreenCaptureService(
            result: Self.captureResult(imageData: imageData, app: app, window: window))
        let automation = RecordingUIAutomationService()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: applications)

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(capture.operations, [.windowID(42, .logical1x, .auto)])
        XCTAssertNil(result.elements)
        XCTAssertEqual(result.capture.imageData, imageData)
        XCTAssertEqual(result.target.window?.windowID, 42)
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.window",
            "desktop.observe",
        ])
        XCTAssertEqual(result.diagnostics.stateSnapshot?.runningApplicationCount, 1)
        XCTAssertEqual(automation.detectCalls, 0)
    }

    func testObservationNormalizesCapturedWindowMetadataToResolvedTarget() async throws {
        let app = Self.app()
        let resolvedWindow = Self.window(
            id: 42,
            title: "Document",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            index: 0)
        let capturedWindow = Self.window(
            id: 42,
            title: "Document",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            index: 5)
        let applications = RecordingApplicationService(applications: [app], windows: [resolvedWindow])
        let capture = RecordingScreenCaptureService(
            result: Self.captureResult(app: app, window: capturedWindow))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: RecordingUIAutomationService(),
            applications: applications)

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(result.capture.metadata.windowInfo?.windowID, 42)
        XCTAssertEqual(result.capture.metadata.windowInfo?.index, 0)
        XCTAssertEqual(result.capture.metadata.windowInfo?.title, "Document")
    }

    func testObservationWithDetectionPassesWindowContextAndWebFocusPolicy() async throws {
        let app = Self.app()
        let window = Self.window(id: 77, title: "Editor", bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let capture = RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window))
        let automation = RecordingUIAutomationService()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: applications)

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .title("Edit")),
            detection: DesktopDetectionOptions(
                mode: .accessibility,
                allowWebFocusFallback: false,
                includeMenuBarElements: false),
            output: DesktopObservationOutputOptions(snapshotID: "snapshot-1")))

        XCTAssertNotNil(result.elements)
        XCTAssertEqual(automation.detectCalls, 1)
        XCTAssertEqual(automation.lastSnapshotID, "snapshot-1")
        XCTAssertEqual(automation.lastWindowContext?.applicationName, "Fixture")
        XCTAssertEqual(automation.lastWindowContext?.applicationBundleId, "com.example.fixture")
        XCTAssertEqual(automation.lastWindowContext?.windowTitle, "Editor")
        XCTAssertEqual(automation.lastWindowContext?.windowID, 77)
        XCTAssertEqual(automation.lastWindowContext?.shouldFocusWebContent, false)
        XCTAssertEqual(automation.lastWindowContext?.includeMenuBarElements, false)
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.window",
            "detection.ax",
            "desktop.observe",
        ])
    }

    func testObservationWithAccessibilityAndOCRMergesStaticTextElements() async throws {
        let app = Self.app()
        let window = Self.window(id: 78, title: "OCR", bounds: CGRect(x: 10, y: 20, width: 200, height: 100))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let capture = RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window))
        let automation = RecordingUIAutomationService(elements: DetectedElements(buttons: [
            DetectedElement(id: "B1", type: .button, label: "OK", bounds: CGRect(x: 20, y: 30, width: 40, height: 20)),
        ]))
        let ocr = RecordingOCRRecognizer(result: OCRTextResult(
            observations: [
                OCRTextObservation(
                    text: "Document Title",
                    confidence: 0.9,
                    boundingBox: CGRect(x: 0.1, y: 0.7, width: 0.4, height: 0.2)),
            ],
            imageSize: CGSize(width: 200, height: 100)))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: applications,
            ocrRecognizer: ocr)

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .accessibilityAndOCR)))

        XCTAssertEqual(automation.detectCalls, 1)
        XCTAssertEqual(ocr.recognizeCalls, 1)
        XCTAssertEqual(result.ocr?.observations.first?.text, "Document Title")
        XCTAssertEqual(result.elements?.elements.buttons.map(\.id), ["B1"])
        XCTAssertEqual(result.elements?.elements.other.first?.label, "Document Title")
        XCTAssertEqual(result.elements?.elements.other.first?.type, .staticText)
        XCTAssertEqual(result.elements?.metadata.elementCount, 2)
        XCTAssertEqual(result.elements?.metadata.method, "fake+OCR")
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.window",
            "detection.ax",
            "detection.ocr",
            "desktop.observe",
        ])
    }

    func testObservationPreferOCRCanRunWithoutAccessibilityDetection() async throws {
        let app = Self.app()
        let window = Self.window(id: 79, title: "OCR Only", bounds: CGRect(x: 10, y: 20, width: 200, height: 100))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let capture = RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window))
        let automation = RecordingUIAutomationService()
        let ocr = RecordingOCRRecognizer(result: OCRTextResult(
            observations: [
                OCRTextObservation(
                    text: "Open Menu",
                    confidence: 0.8,
                    boundingBox: CGRect(x: 0.2, y: 0.5, width: 0.3, height: 0.2)),
            ],
            imageSize: CGSize(width: 200, height: 100)))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: applications,
            ocrRecognizer: ocr)

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .none, preferOCR: true),
            output: DesktopObservationOutputOptions(snapshotID: "ocr-only")))

        XCTAssertEqual(automation.detectCalls, 0)
        XCTAssertEqual(ocr.recognizeCalls, 1)
        XCTAssertEqual(result.elements?.snapshotId, "ocr-only")
        XCTAssertEqual(result.elements?.metadata.method, "OCR")
        XCTAssertEqual(result.elements?.elements.other.first?.label, "Open Menu")
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.window",
            "detection.ocr",
            "desktop.observe",
        ])
    }

    func testObservationOutputWriterSavesRawScreenshotWhenRequested() async throws {
        let imageData = Data([1, 2, 3, 4])
        let app = Self.app()
        let window = Self.window(id: 88, title: "Output", bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let capture = RecordingScreenCaptureService(
            result: Self.captureResult(imageData: imageData, app: app, window: window))
        let automation = RecordingUIAutomationService()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: applications)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-observation-test-\(UUID().uuidString).png")

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .none),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveRawScreenshot: true)))

        XCTAssertEqual(result.files.rawScreenshotPath, outputURL.path)
        XCTAssertEqual(try Data(contentsOf: outputURL), imageData)
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.window",
            "output.write",
            "output.raw.write",
            "desktop.observe",
        ])
    }

    func testObservationOutputWriterPlansAnnotatedCompanionPath() {
        XCTAssertEqual(
            ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: "/tmp/screenshot.png"),
            "/tmp/screenshot_annotated.png")
        XCTAssertEqual(
            ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: "/tmp/screenshot.jpg"),
            "/tmp/screenshot_annotated.png")
        XCTAssertEqual(
            ObservationOutputWriter.annotatedScreenshotPath(forRawScreenshotPath: "relative"),
            "relative_annotated.png")
    }

    func testObservationOutputPathResolverTreatsCurrentDirectoryAsDirectory() {
        let url = ObservationOutputPathResolver.resolve(
            path: ".",
            format: .png,
            defaultFileName: "capture.png")

        XCTAssertEqual(url.lastPathComponent, "capture.png")
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL.path,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .standardizedFileURL.path)
    }

    func testObservationOutputPathResolverTreatsExistingDirectoryAsDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-output-path-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = ObservationOutputPathResolver.resolve(
            path: directory.path,
            format: .jpg,
            defaultFileName: "capture.jpg")

        XCTAssertEqual(url.path, directory.appendingPathComponent("capture.jpg").path)
    }

    func testObservationOutputPathResolverCanReplaceExplicitFileExtension() {
        let url = ObservationOutputPathResolver.resolve(
            path: "/tmp/capture.jpg",
            format: .png,
            defaultFileName: "unused.png",
            replacingExistingExtension: true)

        XCTAssertEqual(url.path, "/tmp/capture.png")
    }

    func testObservationOutputWriterSavesAnnotatedScreenshotWhenRequested() async throws {
        let app = Self.app()
        let window = Self.window(id: 88, title: "Output", bounds: CGRect(x: 10, y: 20, width: 160, height: 120))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-annotated-test-\(UUID().uuidString).png")
        let capture = try RecordingScreenCaptureService(
            result: Self.captureResult(
                imageData: Self.testPNGData(size: window.bounds.size),
                app: app,
                window: window))
        let automation = RecordingUIAutomationService(elements: DetectedElements(buttons: [
            DetectedElement(
                id: "B1",
                type: .button,
                label: "OK",
                bounds: CGRect(x: 20, y: 30, width: 40, height: 20),
                isEnabled: true),
        ]))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: applications)

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .accessibility),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveRawScreenshot: true,
                saveAnnotatedScreenshot: true)))

        let annotatedPath = try XCTUnwrap(result.files.annotatedScreenshotPath)
        XCTAssertEqual(annotatedPath, outputURL.deletingPathExtension().path + "_annotated.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: annotatedPath))
        XCTAssertGreaterThan(try (FileManager.default.attributesOfItem(atPath: annotatedPath)[.size] as? Int) ?? 0, 0)
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.window",
            "detection.ax",
            "output.write",
            "output.raw.write",
            "annotation.render",
            "desktop.observe",
        ])

        try? FileManager.default.removeItem(at: outputURL)
        try? FileManager.default.removeItem(atPath: annotatedPath)
    }

    func testObservationOutputWriterRegistersSnapshotWhenRequested() async throws {
        let app = Self.app()
        let window = Self.window(id: 89, title: "Snapshot", bounds: CGRect(x: 10, y: 20, width: 160, height: 120))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-snapshot-test-\(UUID().uuidString).png")
        let snapshotManager = InMemorySnapshotManager()
        let automation = RecordingUIAutomationService(elements: DetectedElements(buttons: [
            DetectedElement(
                id: "B1",
                type: .button,
                label: "Save",
                bounds: CGRect(x: 20, y: 30, width: 40, height: 20),
                isEnabled: true),
        ]))
        let service = try DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(
                result: Self.captureResult(
                    imageData: Self.testPNGData(size: window.bounds.size),
                    app: app,
                    window: window)),
            automation: automation,
            applications: applications,
            snapshotManager: snapshotManager)

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .accessibility),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveSnapshot: true)))

        XCTAssertEqual(result.files.rawScreenshotPath, outputURL.path)
        let snapshotID = try XCTUnwrap(result.elements?.snapshotId)
        let storedDetection = try await snapshotManager.getDetectionResult(snapshotId: snapshotID)
        XCTAssertEqual(storedDetection?.screenshotPath, outputURL.path)
        XCTAssertEqual(storedDetection?.elements.all.first?.id, "B1")

        let storedSnapshot = try await snapshotManager.getUIAutomationSnapshot(snapshotId: snapshotID)
        XCTAssertEqual(storedSnapshot?.screenshotPath, outputURL.path)
        XCTAssertEqual(storedSnapshot?.applicationBundleId, "com.example.fixture")
        XCTAssertEqual(storedSnapshot?.windowTitle, "Snapshot")
        XCTAssertEqual(storedSnapshot?.windowBounds, window.bounds)
        XCTAssertTrue(result.timings.spans.map(\.name).contains("snapshot.write"))

        try? FileManager.default.removeItem(at: outputURL)
    }

    func testObservationForwardsCaptureEnginePreferenceWhenSupported() async throws {
        let app = Self.app()
        let window = Self.window(id: 99, title: "Engine", bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let capture = RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: RecordingUIAutomationService(),
            applications: applications)

        _ = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            capture: DesktopCaptureOptions(engine: .legacy),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(capture.operations, [.windowID(99, .logical1x, .legacy)])
    }

    func testObservationUsesRequestSnapshotForPIDResolution() async throws {
        let app = Self.app()
        let window = Self.window(id: 1234, title: "PID", bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let capture = RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: RecordingUIAutomationService(),
            applications: applications)

        _ = try await service.observe(DesktopObservationRequest(
            target: .pid(app.processIdentifier, window: .automatic),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(applications.listApplicationsCalls, 1)
        XCTAssertEqual(applications.findApplicationCalls, 0)
        XCTAssertEqual(capture.operations, [.windowID(1234, .logical1x, .auto)])
    }

    func testObservationDetectionTimeoutUsesRequestBudget() async throws {
        let app = Self.app()
        let window = Self.window(id: 100, title: "Timeout", bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: RecordingUIAutomationService(delay: 0.5, ignoresCancellation: true),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        let startedAt = Date()

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .accessibility),
                timeout: DesktopObservationTimeouts(detection: 0.01)))
            XCTFail("Expected detection timeout")
        } catch let CaptureError.detectionTimedOut(seconds) {
            XCTAssertEqual(seconds, 0.01, accuracy: 0.001)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.25)
    }

    private static func app() -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 123,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
    }

    private static func window(
        id: Int,
        title: String,
        bounds: CGRect,
        isMinimized: Bool = false,
        isMainWindow: Bool = false,
        index: Int = 0) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: id,
            title: title,
            bounds: bounds,
            isMinimized: isMinimized,
            isMainWindow: isMainWindow,
            windowLevel: 0,
            alpha: 1,
            index: index,
            layer: 0,
            isOnScreen: true,
            sharingState: .readOnly,
            isExcludedFromWindowsMenu: false)
    }

    private static func captureResult(
        imageData: Data = Data([9]),
        app: ServiceApplicationInfo,
        window: ServiceWindowInfo) -> CaptureResult
    {
        CaptureResult(
            imageData: imageData,
            metadata: CaptureMetadata(
                size: window.bounds.size,
                mode: .window,
                applicationInfo: app,
                windowInfo: window))
    }

    private static func testPNGData(size: CGSize) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            throw DesktopObservationError.targetNotFound("test image")
        }
        return png
    }
}

@MainActor
private final class RecordingApplicationService: ApplicationServiceProtocol {
    let applications: [ServiceApplicationInfo]
    let windows: [ServiceWindowInfo]
    var listApplicationsCalls = 0
    var findApplicationCalls = 0
    var frontmostApplicationCalls = 0

    init(applications: [ServiceApplicationInfo], windows: [ServiceWindowInfo]) {
        self.applications = applications
        self.windows = windows
    }

    func listApplications() async throws -> UnifiedToolOutput<ServiceApplicationListData> {
        self.listApplicationsCalls += 1
        return UnifiedToolOutput(
            data: ServiceApplicationListData(applications: self.applications),
            summary: .init(brief: "apps", status: .success),
            metadata: .init(duration: 0))
    }

    func findApplication(identifier: String) async throws -> ServiceApplicationInfo {
        self.findApplicationCalls += 1
        guard let app = self.applications.first(where: {
            $0.name == identifier || $0.bundleIdentifier == identifier
        }) else {
            throw DesktopObservationError.targetNotFound(identifier)
        }
        return app
    }

    func listWindows(for _: String, timeout _: Float?) async throws -> UnifiedToolOutput<ServiceWindowListData> {
        UnifiedToolOutput(
            data: ServiceWindowListData(windows: self.windows, targetApplication: self.applications.first),
            summary: .init(brief: "windows", status: .success),
            metadata: .init(duration: 0))
    }

    func getFrontmostApplication() async throws -> ServiceApplicationInfo {
        self.frontmostApplicationCalls += 1
        guard let app = self.applications.first else {
            throw DesktopObservationError.targetNotFound("frontmost")
        }
        return app
    }

    func isApplicationRunning(identifier _: String) async -> Bool {
        true
    }

    func launchApplication(identifier _: String) async throws -> ServiceApplicationInfo {
        self.applications[0]
    }

    func activateApplication(identifier _: String) async throws {}
    func quitApplication(identifier _: String, force _: Bool) async throws -> Bool {
        true
    }

    func hideApplication(identifier _: String) async throws {}
    func unhideApplication(identifier _: String) async throws {}
    func hideOtherApplications(identifier _: String) async throws {}
    func showAllApplications() async throws {}
}

@MainActor
private final class RecordingScreenCaptureService: ScreenCaptureServiceProtocol,
EngineAwareScreenCaptureServiceProtocol {
    enum Operation: Equatable {
        case screen(Int?, CaptureScalePreference, CaptureEnginePreference)
        case window(String, Int?, CaptureScalePreference, CaptureEnginePreference)
        case windowID(Int, CaptureScalePreference, CaptureEnginePreference)
        case frontmost(CaptureScalePreference, CaptureEnginePreference)
        case area(CGRect, CaptureScalePreference, CaptureEnginePreference)
    }

    private let result: CaptureResult
    private var engine: CaptureEnginePreference = .auto
    var operations: [Operation] = []

    init(result: CaptureResult) {
        self.result = result
    }

    func withCaptureEngine<T: Sendable>(
        _ engine: CaptureEnginePreference,
        operation: @MainActor () async throws -> T) async rethrows -> T
    {
        let previous = self.engine
        self.engine = engine
        defer { self.engine = previous }
        return try await operation()
    }

    func captureScreen(
        displayIndex: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.operations.append(.screen(displayIndex, scale, self.engine))
        return self.result
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.operations.append(.window(appIdentifier, windowIndex, scale, self.engine))
        return self.result
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.operations.append(.windowID(Int(windowID), scale, self.engine))
        return self.result
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.operations.append(.frontmost(scale, self.engine))
        return self.result
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.operations.append(.area(rect, scale, self.engine))
        return self.result
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }
}

@MainActor
private final class RecordingUIAutomationService: UIAutomationServiceProtocol {
    private let delay: TimeInterval
    private let ignoresCancellation: Bool
    private let elements: DetectedElements
    var detectCalls = 0
    var lastSnapshotID: String?
    var lastWindowContext: WindowContext?

    init(
        delay: TimeInterval = 0,
        ignoresCancellation: Bool = false,
        elements: DetectedElements = DetectedElements())
    {
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
        self.elements = elements
    }

    func detectElements(
        in _: Data,
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        if self.delay > 0 {
            if self.ignoresCancellation {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + self.delay) {
                        continuation.resume()
                    }
                }
            } else {
                try await Task.sleep(nanoseconds: UInt64(self.delay * 1_000_000_000))
            }
        }
        self.detectCalls += 1
        self.lastSnapshotID = snapshotId
        self.lastWindowContext = windowContext
        return ElementDetectionResult(
            snapshotId: snapshotId ?? "generated",
            screenshotPath: "/tmp/fake.png",
            elements: self.elements,
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "fake"))
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {}
    func type(
        text _: String,
        target _: String?,
        clearExisting _: Bool,
        typingDelay _: Int,
        snapshotId _: String?) async throws {}
    func typeActions(_: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws -> TypeResult {
        TypeResult(totalCharacters: 0, keyPresses: 0)
    }

    func scroll(_: ScrollRequest) async throws {}
    func hotkey(keys _: String, holdDuration _: Int) async throws {}
    func swipe(
        from _: CGPoint,
        to _: CGPoint,
        duration _: Int,
        steps _: Int,
        profile _: MouseMovementProfile) async throws {}
    func hasAccessibilityPermission() async -> Bool {
        true
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
        -> WaitForElementResult
    {
        WaitForElementResult(found: false, element: nil, waitTime: 0)
    }

    func drag(_: DragOperationRequest) async throws {}
    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}
    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        DetectedElement(id: "B1", type: .button, bounds: .zero)
    }
}

@MainActor
private final class RecordingOCRRecognizer: OCRRecognizing {
    private let result: OCRTextResult
    var recognizeCalls = 0

    init(result: OCRTextResult) {
        self.result = result
    }

    func recognizeText(in _: Data) throws -> OCRTextResult {
        self.recognizeCalls += 1
        return self.result
    }
}
