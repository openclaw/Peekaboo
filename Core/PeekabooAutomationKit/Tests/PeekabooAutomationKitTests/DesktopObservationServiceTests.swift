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

    func testReusedPIDAndWindowIDFailBeforeCapture() async throws {
        let oldApplication = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 100,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let oldWindow = Self.window(
            id: 42,
            title: "Original",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300))
        let applications = RecordingApplicationService(applications: [oldApplication], windows: [oldWindow])
        let capture = RecordingScreenCaptureService(
            result: Self.captureResult(app: oldApplication, window: oldWindow))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: RecordingUIAutomationService(),
            applications: applications,
            exactWindowMetadataProvider: ReusedExactWindowMetadataProvider())

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .pid(123, window: .id(42)),
                detection: DesktopDetectionOptions(mode: .none)))
            XCTFail("Expected reused PID/window ID to fail before capture")
        } catch is DesktopObservationError {
            // Expected.
        }

        XCTAssertTrue(capture.operations.isEmpty)
    }

    func testGenerationlessRemoteExactObservationStaysReadOnly() async throws {
        let legacyApplication = ServiceApplicationInfo(
            processIdentifier: 123,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let legacyWindow = Self.window(
            id: 42,
            title: "Legacy",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300))
        let applications = RecordingApplicationService(
            applications: [legacyApplication],
            windows: [legacyWindow])
        let capture = RecordingScreenCaptureService(
            result: Self.captureResult(app: legacyApplication, window: legacyWindow))
        let automation = RecordingUIAutomationService()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: applications)

        let result = try await service.observe(DesktopObservationRequest(
            target: .pid(123, window: .id(42)),
            detection: DesktopDetectionOptions(mode: .accessibility)))

        XCTAssertEqual(capture.operations, [.windowID(42, .logical1x, .auto)])
        XCTAssertNil(result.target.detectionContext?.windowMutationIdentity)
        XCTAssertNil(automation.lastWindowContext?.windowMutationIdentity)
    }

    func testCaptureWithoutReceiptDropsPreCaptureActionIdentity() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 700,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let window = Self.window(
            id: 42,
            title: "Captured",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300))
        let applications = RecordingApplicationService(applications: [application], windows: [window])
        let replacementApplication = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 800,
            bundleIdentifier: "com.example.replacement",
            name: "Replacement",
            windowCount: 1)
        let capture = RecordingScreenCaptureService(
            result: Self.captureResult(app: replacementApplication, window: window))
        let automation = RecordingUIAutomationService()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: applications,
            exactWindowMetadataProvider: StableExactWindowMetadataProvider())

        let result = try await service.observe(DesktopObservationRequest(
            target: .pid(123, window: .id(42)),
            detection: DesktopDetectionOptions(mode: .accessibility)))

        XCTAssertEqual(capture.operations, [.windowID(42, .logical1x, .auto)])
        XCTAssertEqual(result.target.app?.processStartIdentity, 800)
        XCTAssertNil(result.target.detectionContext?.windowMutationIdentity)
        XCTAssertNil(automation.lastWindowContext?.windowMutationIdentity)
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
            index: 5,
            mutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: app.processIdentifier,
                ownerProcessStartIdentity: 700,
                isMinimized: false))
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
        XCTAssertEqual(result.capture.metadata.windowInfo?.mutationIdentity, capturedWindow.mutationIdentity)
        XCTAssertEqual(result.target.detectionContext?.windowMutationIdentity, capturedWindow.mutationIdentity)
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
            output: DesktopObservationOutputOptions(snapshotID: "snapshot-1"),
            timeout: DesktopObservationTimeouts(detection: 0.75)))

        XCTAssertNotNil(result.elements)
        XCTAssertEqual(automation.detectCalls, 1)
        XCTAssertEqual(automation.lastSnapshotID, "snapshot-1")
        XCTAssertEqual(automation.lastWindowContext?.applicationName, "Fixture")
        XCTAssertEqual(automation.lastWindowContext?.applicationBundleId, "com.example.fixture")
        XCTAssertEqual(automation.lastWindowContext?.windowTitle, "Editor")
        XCTAssertEqual(automation.lastWindowContext?.windowID, 77)
        XCTAssertEqual(automation.lastWindowContext?.shouldFocusWebContent, false)
        XCTAssertEqual(automation.lastWindowContext?.includeMenuBarElements, false)
        XCTAssertEqual(automation.lastWindowContext?.accessibilityTimeoutSeconds, 0.75)
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

    func testObservationOverallTimeoutIsEnforcedLocally() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 104,
            title: "Overall timeout",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: RecordingUIAutomationService(delay: 0.5, ignoresCancellation: true),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        let startedAt = ContinuousClock.now

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .accessibility),
                timeout: DesktopObservationTimeouts(overall: 0.02)))
            XCTFail("Expected overall observation timeout")
        } catch let CaptureError.detectionTimedOut(seconds) {
            XCTAssertEqual(seconds, 0.02, accuracy: 0.001)
        }
        XCTAssertLessThan(startedAt.duration(to: .now), .milliseconds(250))
    }

    func testOCRDeadlineReturnsExplicitIncompleteEvidenceWithoutBlockingMainActor() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 105,
            title: "OCR timeout",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let ocr = NoncooperativeOCRRecognizer()
        defer { ocr.release() }
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [app], windows: [window]),
            ocrRecognizer: ocr)
        let heartbeat = expectation(description: "main actor remained responsive")
        Task { @MainActor in heartbeat.fulfill() }

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .none, preferOCR: true),
            timeout: DesktopObservationTimeouts(ocr: 0.02)))

        await fulfillment(of: [heartbeat], timeout: 0.2)
        XCTAssertEqual(ocr.receivedTimeout, 0.02, accuracy: 0.001)
        XCTAssertEqual(result.ocr?.isComplete, false)
        XCTAssertEqual(result.ocr?.deadlineReached, true)
        XCTAssertEqual(result.elements?.metadata.truncationInfo?.deadlineReached, true)
        XCTAssertTrue(result.diagnostics.warnings
            .contains(where: { $0.contains("missing text does not prove absence") }))
    }

    func testReadOnlySlowDetectionDoesNotBlockAnotherObservationCapture() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 101,
            title: "Concurrent",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let detectionStarted = expectation(description: "first observation started AX detection")
        let allowDetectionToFinish = ObservationDetectionSuspension {
            detectionStarted.fulfill()
        }
        let firstService = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: RecordingUIAutomationService(detectionSuspension: allowDetectionToFinish),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        let secondCaptureStarted = expectation(description: "second observation reached capture")
        let secondService = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(
                result: Self.captureResult(app: app, window: window),
                onCapture: { secondCaptureStarted.fulfill() }),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        defer { allowDetectionToFinish.release() }

        let firstObservation = Task {
            try await firstService.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .accessibility)))
        }
        await fulfillment(of: [detectionStarted], timeout: 2)

        let secondObservation = Task {
            try await secondService.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .none)))
        }
        await fulfillment(of: [secondCaptureStarted], timeout: 2)

        allowDetectionToFinish.release()
        _ = try await firstObservation.value
        _ = try await secondObservation.value
    }

    func testWebFocusDetectionBlocksAnotherObservationCapture() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 102,
            title: "Web Focus",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let detectionStarted = expectation(description: "first observation started web-focus detection")
        let allowDetectionToFinish = ObservationDetectionSuspension {
            detectionStarted.fulfill()
        }
        let firstService = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: RecordingUIAutomationService(detectionSuspension: allowDetectionToFinish),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        let captureBeforeRelease = expectation(description: "second capture stayed behind web-focus detection")
        captureBeforeRelease.isInverted = true
        let captureAfterRelease = expectation(description: "second capture ran after web-focus detection")
        let secondService = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(
                result: Self.captureResult(app: app, window: window),
                onCapture: {
                    if allowDetectionToFinish.isReleased {
                        captureAfterRelease.fulfill()
                    } else {
                        captureBeforeRelease.fulfill()
                    }
                }),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        defer { allowDetectionToFinish.release() }

        let firstObservation = Task {
            try await firstService.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(
                    mode: .accessibility,
                    allowWebFocusFallback: true)))
        }
        await fulfillment(of: [detectionStarted], timeout: 2)

        let secondObservation = Task {
            try await secondService.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .none)))
        }
        await fulfillment(of: [captureBeforeRelease], timeout: 0.2)

        allowDetectionToFinish.release()
        await fulfillment(of: [captureAfterRelease], timeout: 2)
        _ = try await firstObservation.value
        _ = try await secondObservation.value
    }

    func testServiceOwnedCaptureDelegatesDesktopOperationLaneToExecutionHost() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 103,
            title: "Remote capture",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let localDetectionStarted = expectation(description: "local observation holds the caller transaction gate")
        let allowLocalDetectionToFinish = ObservationDetectionSuspension {
            localDetectionStarted.fulfill()
        }
        let localService = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: RecordingUIAutomationService(detectionSuspension: allowLocalDetectionToFinish),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        let remoteCaptureBeforeRelease = expectation(
            description: "service-owned capture delegates the desktop lane to its execution host")
        let remoteService = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(
                result: Self.captureResult(app: app, window: window),
                captureTransactionGateOwner: .service,
                onCapture: {
                    if !allowLocalDetectionToFinish.isReleased {
                        remoteCaptureBeforeRelease.fulfill()
                    }
                }),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        defer { allowLocalDetectionToFinish.release() }

        let localObservation = Task {
            try await localService.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(
                    mode: .accessibility,
                    allowWebFocusFallback: true)))
        }
        await fulfillment(of: [localDetectionStarted], timeout: 2)

        let remoteObservation = Task {
            try await remoteService.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .none)))
        }
        await fulfillment(of: [remoteCaptureBeforeRelease], timeout: 2)

        allowLocalDetectionToFinish.release()
        _ = try await localObservation.value
        _ = try await remoteObservation.value
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
        index: Int = 0,
        mutationIdentity: WindowMutationIdentity? = nil) -> ServiceWindowInfo
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
            isExcludedFromWindowsMenu: false,
            mutationIdentity: mutationIdentity)
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

private struct ReusedExactWindowMetadataProvider: ExactWindowMetadataProviding {
    func metadata(for windowID: CGWindowID) -> ExactWindowObservationMetadata? {
        guard windowID == 42 else { return nil }
        return ExactWindowObservationMetadata(
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 200,
            title: "Replacement",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            applicationName: "Fixture")
    }

    func processStartIdentity(for _: Int32) -> UInt64? {
        200
    }
}

private struct StableExactWindowMetadataProvider: ExactWindowMetadataProviding {
    func metadata(for windowID: CGWindowID) -> ExactWindowObservationMetadata? {
        guard windowID == 42 else { return nil }
        return ExactWindowObservationMetadata(
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 700,
            title: "Captured",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            applicationName: "Fixture")
    }

    func processStartIdentity(for _: Int32) -> UInt64? {
        700
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
    let captureTransactionGateOwner: CaptureTransactionGateOwner
    private let onCapture: @MainActor () -> Void
    private var engine: CaptureEnginePreference = .auto
    var operations: [Operation] = []

    init(
        result: CaptureResult,
        captureTransactionGateOwner: CaptureTransactionGateOwner = .caller,
        onCapture: @escaping @MainActor () -> Void = {})
    {
        self.result = result
        self.captureTransactionGateOwner = captureTransactionGateOwner
        self.onCapture = onCapture
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
        self.onCapture()
        return self.result
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.operations.append(.window(appIdentifier, windowIndex, scale, self.engine))
        self.onCapture()
        return self.result
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.operations.append(.windowID(Int(windowID), scale, self.engine))
        self.onCapture()
        return self.result
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.operations.append(.frontmost(scale, self.engine))
        self.onCapture()
        return self.result
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.operations.append(.area(rect, scale, self.engine))
        self.onCapture()
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
    private let detectionSuspension: ObservationDetectionSuspension?
    var detectCalls = 0
    var lastSnapshotID: String?
    var lastWindowContext: WindowContext?

    init(
        delay: TimeInterval = 0,
        ignoresCancellation: Bool = false,
        elements: DetectedElements = DetectedElements(),
        detectionSuspension: ObservationDetectionSuspension? = nil)
    {
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
        self.elements = elements
        self.detectionSuspension = detectionSuspension
    }

    func detectElements(
        in _: Data,
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        await self.detectionSuspension?.wait()
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
private final class ObservationDetectionSuspension {
    private let onStart: @MainActor () -> Void
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isReleased = false

    init(onStart: @escaping @MainActor () -> Void) {
        self.onStart = onStart
    }

    func wait() async {
        self.onStart()
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        self.isReleased = true
        self.continuation?.resume()
        self.continuation = nil
    }
}

private final class RecordingOCRRecognizer: OCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: OCRTextResult
    var recognizeCalls = 0

    init(result: OCRTextResult) {
        self.result = result
    }

    func recognizeText(in _: Data, timeoutSeconds _: TimeInterval) async throws -> OCRTextResult {
        self.lock.withLock { self.recognizeCalls += 1 }
        return self.result
    }
}

private final class NoncooperativeOCRRecognizer: OCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeout: TimeInterval = 0

    var receivedTimeout: TimeInterval {
        self.lock.withLock { self.timeout }
    }

    func recognizeText(in _: Data, timeoutSeconds: TimeInterval) async throws -> OCRTextResult {
        self.lock.withLock { self.timeout = timeoutSeconds }
        await withCheckedContinuation { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
        return OCRTextResult(observations: [], imageSize: CGSize(width: 1, height: 1))
    }

    func release() {
        let continuation = self.lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
}
