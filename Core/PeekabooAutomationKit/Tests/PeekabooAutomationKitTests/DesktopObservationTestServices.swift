import AppKit
import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import XCTest
@testable import PeekabooAutomationKit

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

    init(
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
final class ObservationDetectionSuspension {
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
