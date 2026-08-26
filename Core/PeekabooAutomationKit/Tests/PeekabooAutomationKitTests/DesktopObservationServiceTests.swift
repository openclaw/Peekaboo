import AppKit
import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
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
}

@MainActor
extension DesktopObservationServiceTests {
    func testObservationLanePlanNarrowsOnlyPassiveExactTargets() {
        let process = ApplicationProcessIdentity(processIdentifier: 500, processStartIdentity: 70)
        let window = WindowMutationIdentity(
            windowID: 200,
            ownerProcessIdentifier: process.processIdentifier,
            ownerProcessStartIdentity: process.processStartIdentity,
            capturedBounds: CGRect(x: 10, y: 20, width: 300, height: 200))
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(
                app: Self.app(),
                window: Self.window(id: 1, title: "Fixture", bounds: CGRect(x: 0, y: 0, width: 1, height: 1)))),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [], windows: []),
            processStartIdentityProvider: { _ in process.processStartIdentity },
            windowMutationIdentityProvider: { _ in window })
        let passivePID = service.operationLanePlan(for: DesktopObservationRequest(
            target: .pid(process.processIdentifier, window: .automatic),
            detection: DesktopDetectionOptions(mode: .none)))
        let passiveWindow = service.operationLanePlan(for: DesktopObservationRequest(
            target: .windowID(CGWindowID(window.windowID)),
            detection: DesktopDetectionOptions(mode: .none)))
        let screen = service.operationLanePlan(for: DesktopObservationRequest(
            target: .screen(index: 0),
            detection: DesktopDetectionOptions(mode: .none)))
        let webFocus = service.operationLanePlan(for: DesktopObservationRequest(
            target: .pid(process.processIdentifier, window: .automatic),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true)))
        let foreground = service.operationLanePlan(for: DesktopObservationRequest(
            target: .windowID(CGWindowID(window.windowID)),
            capture: DesktopCaptureOptions(focus: .foreground),
            detection: DesktopDetectionOptions(mode: .none)))
        let menuOpening = service.operationLanePlan(for: DesktopObservationRequest(
            target: .menubarPopover(hints: ["Fixture"], openIfNeeded: .init()),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(passivePID.scope, .process(process))
        XCTAssertEqual(passivePID.access, .read)
        XCTAssertEqual(passiveWindow.scope, .window(window))
        XCTAssertEqual(passiveWindow.access, .read)
        for global in [screen, webFocus, foreground, menuOpening] {
            XCTAssertEqual(global.scope, .global)
            XCTAssertEqual(global.access, .write)
        }
    }
}

@MainActor
extension DesktopObservationServiceTests {
    func testBackgroundCaptureSuppressesVisibleVisualizerMode() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 42,
            title: "Fixture",
            bounds: CGRect(x: 10, y: 20, width: 300, height: 200))
        let capture = RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [app], windows: [window]))
        let target = ResolvedObservationTarget(kind: .screen(index: 0))

        _ = try await service.captureResolvedTarget(
            target,
            options: .init(focus: .background, visualizerMode: .screenshotFlash))
        _ = try await service.captureResolvedTarget(
            target,
            options: .init(focus: .foreground, visualizerMode: .screenshotFlash))

        XCTAssertEqual(capture.visualizerModes, [.none, .screenshotFlash])
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

    func testReusedPIDAndWindowIDFailWhenCaptureReceiptDisagrees() async throws {
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
            XCTFail("Expected reused PID/window ID to fail closed")
        } catch is DesktopObservationError {
            // Expected.
        }

        XCTAssertEqual(capture.operations, [
            .windowID(42, .logical1x, .auto),
            .windowID(42, .logical1x, .auto),
        ])
    }

    func testExactPIDObservationBindsCaptureAppMetadataWithoutInventory() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 700,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let window = Self.window(
            id: 42,
            title: "Captured",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            mutationIdentity: WindowMutationIdentity(
                windowID: 42,
                ownerProcessIdentifier: application.processIdentifier,
                ownerProcessStartIdentity: 700,
                capturedBounds: CGRect(x: 100, y: 100, width: 400, height: 300)))
        let applications = RecordingApplicationService(applications: [application], windows: [window])
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(
                result: Self.captureResult(app: application, window: window)),
            automation: RecordingUIAutomationService(),
            applications: applications,
            exactWindowMetadataProvider: StableExactWindowMetadataProvider())

        let result = try await service.observe(DesktopObservationRequest(
            target: .pid(application.processIdentifier, window: .id(42)),
            capture: DesktopCaptureOptions(engine: .legacy),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(applications.listApplicationsCalls, 0)
        XCTAssertEqual(result.diagnostics.stateSnapshot?.runningApplicationCount, 0)
        XCTAssertEqual(result.target.app?.bundleIdentifier, application.bundleIdentifier)
        XCTAssertEqual(result.target.detectionContext?.applicationBundleId, application.bundleIdentifier)
        XCTAssertEqual(result.target.app?.processStartIdentity, application.processStartIdentity)
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

    func testCaptureWithoutMatchingReceiptFailsInsteadOfRetargeting() async throws {
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

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .pid(123, window: .id(42)),
                detection: DesktopDetectionOptions(mode: .accessibility)))
            XCTFail("Expected capture metadata from a replacement process to fail closed")
        } catch let error as DesktopObservationError {
            guard case .targetChanged = error else {
                XCTFail("Expected targetChanged, got \(error)")
                return
            }
        }

        XCTAssertEqual(capture.operations, [
            .windowID(42, .logical1x, .auto),
            .windowID(42, .logical1x, .auto),
        ])
        XCTAssertNil(automation.lastWindowContext?.windowMutationIdentity)
    }

    func testObservationNormalizesCapturedWindowMetadataToResolvedTarget() async throws {
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: 123,
            processStartIdentity: 700)
        let baseApp = ServiceApplicationInfo(
            processIdentifier: processIdentity.processIdentifier,
            processStartIdentity: processIdentity.processStartIdentity,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let appResolution = try XCTUnwrap(ApplicationIdentifierMatcher.resolution(
            for: "Fixture",
            in: [ApplicationIdentifierMatcher.Candidate(baseApp)]))
        let app = baseApp.withSelectorResolutionProofs([
            appResolution.proof(selectedProcessIdentity: processIdentity),
        ])
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)
        let windowIdentity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: processIdentity.processIdentifier,
            ownerProcessStartIdentity: processIdentity.processStartIdentity,
            capturedBounds: bounds,
            isMinimized: false)
        let resolvedWindow = Self.window(
            id: 42,
            title: "Document",
            bounds: bounds,
            index: 0,
            mutationIdentity: windowIdentity)
        let capturedWindow = Self.window(
            id: 42,
            title: "Document",
            bounds: bounds,
            index: 5,
            mutationIdentity: windowIdentity)
        let windowProof = try WindowSelectorResolutionProof.make(
            selection: .automatic,
            candidates: [resolvedWindow],
            selected: resolvedWindow,
            processIdentity: processIdentity)
        let selectorResolutionProofs = (app.selectorResolutionProofs ?? []).map {
            $0.selecting(windowIdentity: windowIdentity)
        } + [windowProof]
        let captureResult = CaptureResult(
            imageData: Data([9]),
            metadata: CaptureMetadata(
                size: capturedWindow.bounds.size,
                mode: .window,
                applicationInfo: app,
                windowInfo: capturedWindow,
                selectorResolutionProofs: selectorResolutionProofs))
        let applications = RecordingApplicationService(applications: [app], windows: [resolvedWindow])
        let capture = RecordingScreenCaptureService(result: captureResult)
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
        XCTAssertEqual(result.capture.metadata.selectorResolutionProofs, selectorResolutionProofs)
        XCTAssertEqual(result.target.selectorResolutionProofs, selectorResolutionProofs)
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
            output: DesktopObservationOutputOptions(snapshotID: SnapshotReferenceFixtures.first.rawValue),
            timeout: DesktopObservationTimeouts(detection: 60)))

        XCTAssertNotNil(result.elements)
        XCTAssertEqual(automation.detectCalls, 1)
        XCTAssertEqual(automation.lastSnapshotID, SnapshotReferenceFixtures.first.rawValue)
        XCTAssertEqual(automation.lastWindowContext?.applicationName, "Fixture")
        XCTAssertEqual(automation.lastWindowContext?.applicationBundleId, "com.example.fixture")
        XCTAssertEqual(automation.lastWindowContext?.windowTitle, "Editor")
        XCTAssertEqual(automation.lastWindowContext?.windowID, 77)
        XCTAssertEqual(automation.lastWindowContext?.shouldFocusWebContent, false)
        XCTAssertEqual(automation.lastWindowContext?.includeMenuBarElements, false)
        XCTAssertEqual(automation.lastWindowContext?.accessibilityTimeoutSeconds, 60)
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.window",
            "detection.ax",
            "desktop.observe",
        ])
    }

    func testCombinedObservationRejectsEmptyIncompleteAccessibilityEvidenceButPreservesRaster() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 177,
            title: "Incomplete",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-incomplete-combined-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let automation = RecordingUIAutomationService(fixedResult: ElementDetectionResult(
            snapshotId: "empty-incomplete",
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 0,
                method: "AXorcist",
                truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true))))
        let snapshots = InMemorySnapshotManager()
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: automation,
            applications: RecordingApplicationService(applications: [app], windows: [window]),
            snapshotManager: snapshots)

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .accessibility),
                output: DesktopObservationOutputOptions(
                    path: outputURL.path,
                    saveRawScreenshot: true,
                    saveSnapshot: true)))
            XCTFail("Expected empty incomplete combined evidence to fail")
        } catch let error as PeekabooError {
            guard case .accessibilityIncomplete = error else {
                XCTFail("Expected accessibilityIncomplete, got \(error)")
                return
            }
        }

        XCTAssertEqual(automation.detectCalls, 1)
        let reservedSnapshotID = try XCTUnwrap(automation.lastSnapshotID)
        XCTAssertNotNil(SnapshotReference(rawValue: reservedSnapshotID))
        let ownsFailedReservation = try await snapshots.ownsSnapshot(snapshotId: reservedSnapshotID)
        XCTAssertFalse(ownsFailedReservation)
        XCTAssertEqual(try Data(contentsOf: outputURL), Data([9]))
        let publishedSnapshots = try await snapshots.listSnapshots()
        XCTAssertTrue(publishedSnapshots.isEmpty)
    }

    func testCombinedObservationRejectsExactEmptyAccessibilityEvidenceFromLegacyHostShape() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 178,
            title: "Legacy empty",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let automation = RecordingUIAutomationService(fixedResult: ElementDetectionResult(
            snapshotId: "legacy-empty",
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 0,
                method: "AXorcist")))
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: automation,
            applications: RecordingApplicationService(applications: [app], windows: [window]))

        var capturedError: PeekabooError?
        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .accessibility)))
            XCTFail("Expected exact empty combined evidence to fail")
        } catch let error as PeekabooError {
            capturedError = error
        }
        guard case .accessibilityIncomplete? = capturedError else {
            XCTFail("Expected accessibilityIncomplete, got \(String(describing: capturedError))")
            return
        }
        XCTAssertTrue(capturedError?.localizedDescription.contains("Exact window 178") == true)
    }

    func testScreenshotOnlyObservationPreservesExactEmptyAccessibilitySuccess() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 179,
            title: "Pixels only",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-screenshot-only-empty-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let automation = RecordingUIAutomationService(fixedResult: ElementDetectionResult(
            snapshotId: "unused-empty",
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "AXorcist")))
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: automation,
            applications: RecordingApplicationService(applications: [app], windows: [window]))

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .none),
            output: DesktopObservationOutputOptions(
                path: outputURL.path,
                saveRawScreenshot: true)))

        XCTAssertNil(result.elements)
        XCTAssertEqual(automation.detectCalls, 0)
        XCTAssertEqual(try Data(contentsOf: outputURL), Data([9]))
    }

    func testCombinedObservationPreservesUsefulPartialIncompleteAccessibilityEvidence() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 180,
            title: "Partial",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let partial = DetectedElement(
            id: "B1",
            type: .button,
            label: "Recovered",
            bounds: CGRect(x: 20, y: 30, width: 100, height: 32))
        let automation = RecordingUIAutomationService(fixedResult: ElementDetectionResult(
            snapshotId: "partial-incomplete",
            screenshotPath: "",
            elements: DetectedElements(buttons: [partial]),
            metadata: DetectionMetadata(
                detectionTime: 0.01,
                elementCount: 1,
                method: "AXorcist",
                truncationInfo: DetectionTruncationInfo(incompleteAccessibilityRead: true))))
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: automation,
            applications: RecordingApplicationService(applications: [app], windows: [window]))

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .accessibility)))

        XCTAssertEqual(result.elements?.elements.buttons.map(\.id), ["B1"])
        XCTAssertEqual(result.elements?.metadata.truncationInfo?.incompleteAccessibilityRead, true)
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
        XCTAssertEqual(ocr.qualities, [.fast])
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

    func testObservationSelectivelyUsesOCRForIdentifierDerivedButtonLabel() async throws {
        let app = Self.app()
        let window = Self.window(id: 79, title: "OCR Repair", bounds: CGRect(x: 10, y: 20, width: 200, height: 100))
        let applications = RecordingApplicationService(applications: [app], windows: [window])
        let capture = RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window))
        let automation = RecordingUIAutomationService(elements: DetectedElements(buttons: [
            DetectedElement(
                id: "B1",
                type: .button,
                label: "permission deny",
                bounds: CGRect(x: 30, y: 70, width: 100, height: 30),
                attributes: [
                    "role": "AXButton",
                    "description": "button",
                    "identifier": "permission-deny-button",
                    "isActionable": "true",
                ]),
        ]))
        let ocr = RecordingOCRRecognizer(result: OCRTextResult(
            observations: [
                OCRTextObservation(
                    text: "Don't Allow",
                    confidence: 0.9,
                    boundingBox: CGRect(x: 0.1, y: 0.3, width: 0.4, height: 0.2)),
            ],
            imageSize: CGSize(width: 200, height: 100)))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            applications: applications,
            ocrRecognizer: ocr)

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .accessibility)))

        XCTAssertEqual(ocr.recognizeCalls, 1)
        XCTAssertEqual(ocr.targetedRegions.count, 1)
        XCTAssertEqual(ocr.targetedRegions.first?.normalizedBounds, CGRect(
            x: 0.06,
            y: 0.42,
            width: 0.58,
            height: 0.46))
        XCTAssertEqual(result.elements?.elements.buttons.first?.label, "Don't Allow")
        XCTAssertEqual(result.elements?.elements.buttons.first?.attributes["labelSource"], "ocr")
        XCTAssertEqual(result.elements?.metadata.method, "fake+OCR")
        XCTAssertTrue(result.timings.spans.map(\.name).contains("detection.ocr"))
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
        let detectionStarted = expectation(description: "snapshot observation reached detection")
        let allowDetectionToFinish = ObservationDetectionSuspension {
            detectionStarted.fulfill()
        }
        defer { allowDetectionToFinish.release() }
        let automation = RecordingUIAutomationService(elements: DetectedElements(buttons: [
            DetectedElement(
                id: "B1",
                type: .button,
                label: "Save",
                bounds: CGRect(x: 20, y: 30, width: 40, height: 20),
                isEnabled: true),
        ]), detectionSuspension: allowDetectionToFinish)
        let service = try DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(
                result: Self.captureResult(
                    imageData: Self.testPNGData(size: window.bounds.size),
                    app: app,
                    window: window)),
            automation: automation,
            applications: applications,
            snapshotManager: snapshotManager)

        let observation = Task {
            try await service.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .accessibility),
                output: DesktopObservationOutputOptions(
                    path: outputURL.path,
                    saveSnapshot: true)))
        }
        await fulfillment(of: [detectionStarted], timeout: 2)
        let latestDuringDetection = await snapshotManager.getMostRecentSnapshot()
        let listedDuringDetection = try await snapshotManager.listSnapshots()
        XCTAssertNil(latestDuringDetection)
        XCTAssertTrue(listedDuringDetection.isEmpty)

        allowDetectionToFinish.release()
        let result = try await observation.value

        XCTAssertEqual(result.files.rawScreenshotPath, outputURL.path)
        let resultSnapshotID = try XCTUnwrap(result.elements?.snapshotId)
        XCTAssertNotNil(SnapshotReference(rawValue: resultSnapshotID))
        XCTAssertEqual(automation.lastSnapshotID, resultSnapshotID)
        XCTAssertEqual(result.files.publishedSnapshotID, resultSnapshotID)
        let ownsPublishedSnapshot = try await snapshotManager.ownsSnapshot(snapshotId: resultSnapshotID)
        XCTAssertTrue(ownsPublishedSnapshot)
        let latestAfterPublication = await snapshotManager.getMostRecentSnapshot()
        XCTAssertEqual(latestAfterPublication, resultSnapshotID)
        let storedDetection = try await snapshotManager.getDetectionResult(snapshotId: resultSnapshotID)
        XCTAssertEqual(storedDetection?.screenshotPath, outputURL.path)
        XCTAssertEqual(storedDetection?.elements.all.first?.id, "B1")

        let storedSnapshot = try await snapshotManager.getUIAutomationSnapshot(snapshotId: resultSnapshotID)
        XCTAssertEqual(storedSnapshot?.screenshotPath, outputURL.path)
        XCTAssertEqual(storedSnapshot?.applicationBundleId, "com.example.fixture")
        XCTAssertEqual(storedSnapshot?.windowTitle, "Snapshot")
        XCTAssertEqual(storedSnapshot?.windowBounds, window.bounds)
        XCTAssertTrue(result.timings.spans.map(\.name).contains("snapshot.write"))

        try? FileManager.default.removeItem(at: outputURL)
    }

    func testSnapshotObservationRequiresProducerBoundManagerBeforeCapture() async throws {
        let app = Self.app()
        let window = Self.window(
            id: 189,
            title: "Snapshot authority",
            bounds: CGRect(x: 10, y: 20, width: 160, height: 120))

        for (manager, expectedCreateCalls) in [
            (
                SnapshotMutationRecordingManager(
                    wrapping: InMemorySnapshotManager(),
                    supportsProducerBoundSnapshotReferences: false),
                0),
            (
                SnapshotMutationRecordingManager(
                    wrapping: InMemorySnapshotManager(),
                    supportsProducerBoundSnapshotReferences: true,
                    createdSnapshotReferenceOverride: "snapshot-legacy"),
                1),
        ] {
            let capture = RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window))
            let service = DesktopObservationService(
                screenCapture: capture,
                automation: RecordingUIAutomationService(),
                applications: RecordingApplicationService(applications: [app], windows: [window]),
                snapshotManager: manager)

            do {
                _ = try await service.observe(DesktopObservationRequest(
                    target: .app(identifier: "Fixture", window: .automatic),
                    detection: DesktopDetectionOptions(mode: .accessibility),
                    output: DesktopObservationOutputOptions(saveSnapshot: true)))
                XCTFail("Expected an unsupported snapshot authority to fail before capture")
            } catch is SnapshotError {
                // Expected: either unsupported producer authority or a malformed claimed reference.
            }

            XCTAssertEqual(manager.createCalls.count, expectedCreateCalls)
            XCTAssertTrue(capture.operations.isEmpty)
        }
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
        let ocr = TimedOutOCRRecognizer()
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
}

@MainActor
extension DesktopObservationServiceTests {
    func testExactWindowLaneIgnoresMutableMinimizedHint() async throws {
        let process = ApplicationProcessIdentity(processIdentifier: 123, processStartIdentity: 700)
        let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: process.processIdentifier,
            ownerProcessStartIdentity: process.processStartIdentity,
            capturedBounds: bounds,
            isMinimized: false)
        let app = ServiceApplicationInfo(
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let window = Self.window(
            id: identity.windowID,
            title: "Captured",
            bounds: bounds,
            mutationIdentity: identity)
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(result: Self.captureResult(app: app, window: window)),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [app], windows: [window]),
            exactWindowMetadataProvider: StableExactWindowMetadataProvider(),
            processStartIdentityProvider: { _ in process.processStartIdentity },
            windowMutationIdentityProvider: { _ in identity })

        let result = try await service.observe(DesktopObservationRequest(
            target: .windowID(CGWindowID(identity.windowID)),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(result.target.window?.windowID, identity.windowID)
    }

    func testExactPIDObservationSerializesOnlyItsProcessFrame() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-observation-process-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let process = ApplicationProcessIdentity(processIdentifier: 510, processStartIdentity: 77)
        let otherProcess = ApplicationProcessIdentity(processIdentifier: 511, processStartIdentity: 88)
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let windowIdentity = WindowMutationIdentity(
            windowID: 201,
            ownerProcessIdentifier: process.processIdentifier,
            ownerProcessStartIdentity: process.processStartIdentity,
            capturedBounds: bounds)
        let app = ServiceApplicationInfo(
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let window = Self.window(
            id: windowIdentity.windowID,
            title: "Scoped",
            bounds: bounds,
            mutationIdentity: windowIdentity)
        let captureStarted = expectation(description: "exact PID frame started")
        let captureSuspension = ObservationDetectionSuspension { captureStarted.fulfill() }
        let service = DesktopObservationService(
            screenCapture: SuspendingObservationCaptureService(
                result: Self.captureResult(app: app, window: window),
                suspension: captureSuspension),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [app], windows: [window]),
            operationLaneCoordinator: coordinator,
            processStartIdentityProvider: { pid in
                pid == process.processIdentifier ? process.processStartIdentity : otherProcess.processStartIdentity
            },
            windowMutationIdentityProvider: { _ in windowIdentity })
        let sameProcessWriterStarted = ObservationLaneLatch()
        let otherProcessWriterStarted = ObservationLaneLatch()

        let observation = Task {
            try await service.observe(DesktopObservationRequest(
                target: .pid(process.processIdentifier, window: .automatic),
                detection: DesktopDetectionOptions(mode: .none)))
        }
        await fulfillment(of: [captureStarted], timeout: 2)

        let sameProcessWriter = Task {
            try await coordinator.run(scope: .process(process), access: .write) {
                await sameProcessWriterStarted.open()
            }
        }
        let otherProcessWriter = Task {
            try await coordinator.run(scope: .process(otherProcess), access: .write) {
                await otherProcessWriterStarted.open()
            }
        }

        let otherProcessOverlapped = await otherProcessWriterStarted.opensWithin(.seconds(1))
        let sameProcessOverlapped = await sameProcessWriterStarted.opensWithin(.milliseconds(100))
        XCTAssertTrue(otherProcessOverlapped)
        XCTAssertFalse(sameProcessOverlapped)
        captureSuspension.release()

        _ = try await observation.value
        try await sameProcessWriter.value
        try await otherProcessWriter.value
        let sameProcessEventuallyStarted = await sameProcessWriterStarted.isOpen
        XCTAssertTrue(sameProcessEventuallyStarted)
    }

    func testCancelledExactPIDObservationReleasesPartialClaimsWithoutCapturing() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-observation-cancel-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let process = ApplicationProcessIdentity(processIdentifier: 520, processStartIdentity: 99)
        let ownerStarted = ObservationLaneLatch()
        let ownerRelease = ObservationLaneLatch()
        let captureStarted = expectation(description: "cancelled observation never captured")
        captureStarted.isInverted = true
        let app = ServiceApplicationInfo(
            processIdentifier: process.processIdentifier,
            processStartIdentity: process.processStartIdentity,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
        let window = Self.window(
            id: 202,
            title: "Queued",
            bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let service = DesktopObservationService(
            screenCapture: RecordingScreenCaptureService(
                result: Self.captureResult(app: app, window: window),
                onCapture: { captureStarted.fulfill() }),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [app], windows: [window]),
            operationLaneCoordinator: coordinator,
            processStartIdentityProvider: { _ in process.processStartIdentity })

        let owner = Task {
            try await coordinator.run(scope: .process(process), access: .write) {
                await ownerStarted.open()
                await ownerRelease.wait()
            }
        }
        await ownerStarted.wait()
        let observation = Task {
            try await service.observe(DesktopObservationRequest(
                target: .pid(process.processIdentifier, window: .automatic),
                detection: DesktopDetectionOptions(mode: .none)))
        }
        try await Task.sleep(for: .milliseconds(50))
        observation.cancel()

        do {
            _ = try await observation.value
            XCTFail("Expected queued observation cancellation")
        } catch is CancellationError {
            // Expected: cancellation releases the already-held global ancestor claim.
        }
        await ownerRelease.open()
        try await owner.value
        await fulfillment(of: [captureStarted], timeout: 0.2)
        try await coordinator.run(scope: .global, access: .write) {}
    }
}

@MainActor
extension DesktopObservationServiceTests {
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

@MainActor
func makeOCRObservationServiceForTesting(_ recognizer: any OCRRecognizing) -> DesktopObservationService {
    let app = ServiceApplicationInfo(
        processIdentifier: 123,
        bundleIdentifier: "com.example.fixture",
        name: "Fixture",
        windowCount: 1)
    let window = ServiceWindowInfo(
        windowID: 105,
        title: "OCR fixture",
        bounds: CGRect(x: 100, y: 100, width: 500, height: 400),
        windowLevel: 0,
        alpha: 1,
        layer: 0,
        isOnScreen: true,
        sharingState: .readOnly)
    let capture = CaptureResult(
        imageData: Data([9]),
        metadata: CaptureMetadata(
            size: window.bounds.size,
            mode: .window,
            applicationInfo: app,
            windowInfo: window))
    return DesktopObservationService(
        screenCapture: RecordingScreenCaptureService(result: capture),
        automation: RecordingUIAutomationService(),
        applications: RecordingApplicationService(applications: [app], windows: [window]),
        ocrRecognizer: recognizer)
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
final class RecordingApplicationService: ApplicationServiceProtocol {
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
final class RecordingScreenCaptureService: ScreenCaptureServiceProtocol,
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
    var visualizerModes: [CaptureVisualizerMode] = []

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
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.visualizerModes.append(visualizerMode)
        self.operations.append(.screen(displayIndex, scale, self.engine))
        self.onCapture()
        return self.result
    }

    func captureWindow(
        appIdentifier: String,
        windowIndex: Int?,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.visualizerModes.append(visualizerMode)
        self.operations.append(.window(appIdentifier, windowIndex, scale, self.engine))
        self.onCapture()
        return self.result
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.visualizerModes.append(visualizerMode)
        self.operations.append(.windowID(Int(windowID), scale, self.engine))
        self.onCapture()
        return self.result
    }

    func captureFrontmost(
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.visualizerModes.append(visualizerMode)
        self.operations.append(.frontmost(scale, self.engine))
        self.onCapture()
        return self.result
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        self.visualizerModes.append(visualizerMode)
        self.operations.append(.area(rect, scale, self.engine))
        self.onCapture()
        return self.result
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }
}

@MainActor
final class RecordingUIAutomationService: UIAutomationServiceProtocol {
    private let delay: TimeInterval
    private let ignoresCancellation: Bool
    private let elements: DetectedElements
    private let result: ElementDetectionResult?
    private let detectionSuspension: ObservationDetectionSuspension?
    var detectCalls = 0
    var lastSnapshotID: String?
    var lastWindowContext: WindowContext?

    fileprivate init(
        delay: TimeInterval = 0,
        ignoresCancellation: Bool = false,
        elements: DetectedElements = DetectedElements(groups: [DetectedElement(
            id: "fixture-root",
            type: .group,
            label: "Fixture",
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1))]),
        result: ElementDetectionResult? = nil,
        detectionSuspension: ObservationDetectionSuspension? = nil)
    {
        self.delay = delay
        self.ignoresCancellation = ignoresCancellation
        self.elements = elements
        self.result = result
        self.detectionSuspension = detectionSuspension
    }

    init(fixedResult: ElementDetectionResult) {
        self.delay = 0
        self.ignoresCancellation = false
        self.elements = fixedResult.elements
        self.result = fixedResult
        self.detectionSuspension = nil
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
        if let result = self.result {
            return result
        }
        return ElementDetectionResult(
            snapshotId: snapshotId ?? "generated",
            screenshotPath: "/tmp/fake.png",
            elements: self.elements,
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: self.elements.all.count,
                method: "fake"))
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

final class RecordingOCRRecognizer: OCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private let result: OCRTextResult
    var recognizeCalls = 0
    private var recordedTargetedRegions: [OCRRecognitionRegion] = []
    private var recordedQualities: [OCRRecognitionQuality] = []

    var targetedRegions: [OCRRecognitionRegion] {
        self.lock.withLock { self.recordedTargetedRegions }
    }

    var qualities: [OCRRecognitionQuality] {
        self.lock.withLock { self.recordedQualities }
    }

    init(result: OCRTextResult) {
        self.result = result
    }

    func recognizeText(in _: Data, timeoutSeconds _: TimeInterval) async throws -> OCRTextResult {
        self.lock.withLock { self.recognizeCalls += 1 }
        return self.result
    }

    func recognizeText(
        in _: Data,
        timeoutSeconds _: TimeInterval,
        quality: OCRRecognitionQuality) async throws -> OCRTextResult
    {
        self.lock.withLock {
            self.recognizeCalls += 1
            self.recordedQualities.append(quality)
        }
        return self.result
    }

    func recognizeText(
        in _: Data,
        timeoutSeconds _: TimeInterval,
        regions: [OCRRecognitionRegion]) async throws -> OCRTextResult
    {
        self.lock.withLock {
            self.recognizeCalls += 1
            self.recordedTargetedRegions = regions
        }
        return self.result
    }
}

@MainActor
private final class SuspendingObservationCaptureService: ScreenCaptureServiceProtocol {
    private let result: CaptureResult
    private let suspension: ObservationDetectionSuspension

    init(result: CaptureResult, suspension: ObservationDetectionSuspension) {
        self.result = result
        self.suspension = suspension
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        await self.suspension.wait()
        return self.result
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        await self.suspension.wait()
        return self.result
    }

    func captureWindow(
        windowID _: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        await self.suspension.wait()
        return self.result
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        await self.suspension.wait()
        return self.result
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        await self.suspension.wait()
        return self.result
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }
}

private actor ObservationLaneLatch {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool {
        self.opened
    }

    func open() {
        guard !self.opened else { return }
        self.opened = true
        let pending = self.continuations
        self.continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !self.opened else { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }

    func opensWithin(_ duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while !self.opened, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return self.opened
    }
}

private final class TimedOutOCRRecognizer: OCRRecognizing, @unchecked Sendable {
    private let lock = NSLock()
    private var timeout: TimeInterval = 0

    var receivedTimeout: TimeInterval {
        self.lock.withLock { self.timeout }
    }

    func recognizeText(in _: Data, timeoutSeconds: TimeInterval) async throws -> OCRTextResult {
        self.lock.withLock { self.timeout = timeoutSeconds }
        throw CaptureError.detectionTimedOut(timeoutSeconds)
    }
}
