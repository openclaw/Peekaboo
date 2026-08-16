import CoreGraphics
import Foundation
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class DesktopObservationReceiptRecoveryTests: XCTestCase {
    func testPassiveObservationRetriesOneChangedCaptureReceiptBeforeDetectionAndOutput() async throws {
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let changedBounds = CGRect(x: 101, y: 100, width: 500, height: 400)
        let resolver = RecordingReceiptTargetResolver(target: Self.receiptedTarget(bounds: bounds))
        var captures = [
            Self.receiptedCapture(bounds: changedBounds),
            Self.receiptedCapture(bounds: bounds),
        ]
        let capture = ReceiptRecoveryCaptureService(resultProvider: { captures.removeFirst() })
        let automation = ReceiptRecoveryAutomationService()
        let outputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-observation-receipt-retry-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outputPath) }
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            targetResolver: resolver)

        let result = try await service.observe(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .accessibility),
            output: DesktopObservationOutputOptions(path: outputPath.path, saveRawScreenshot: true)))

        XCTAssertEqual(resolver.resolveCalls, 2)
        XCTAssertEqual(capture.windowIDs, [42, 42])
        XCTAssertEqual(automation.detectCalls, 1)
        XCTAssertEqual(result.timings.spans.filter { $0.name == "detection.ax" }.count, 1)
        XCTAssertEqual(result.timings.spans.filter { $0.name == "output.write" }.count, 1)
        XCTAssertEqual(result.target.window?.bounds, bounds)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputPath.path))
    }

    func testPassiveObservationStopsAfterOneChangedCaptureReceiptRetry() async throws {
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let resolver = RecordingReceiptTargetResolver(target: Self.receiptedTarget(bounds: bounds))
        let capture = ReceiptRecoveryCaptureService(
            result: Self.receiptedCapture(bounds: CGRect(x: 101, y: 100, width: 500, height: 400)))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: ReceiptRecoveryAutomationService(),
            targetResolver: resolver)

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .none)))
            XCTFail("Expected the second changed capture receipt to fail")
        } catch let error as DesktopObservationError {
            guard case .targetChanged = error else {
                XCTFail("Expected targetChanged, got \(error)")
                return
            }
        }

        XCTAssertEqual(resolver.resolveCalls, 2)
        XCTAssertEqual(capture.captureCalls, 2)
    }

    func testPassiveObservationDoesNotRetryNonrecoverableCaptureErrors() async throws {
        let target = Self.receiptedTarget(bounds: CGRect(x: 100, y: 100, width: 500, height: 400))

        let notFoundResolver = RecordingReceiptTargetResolver(target: target)
        let notFoundCapture = ReceiptRecoveryCaptureService(resultProvider: {
            throw DesktopObservationError.targetNotFound("fixture")
        })
        let notFoundService = DesktopObservationService(
            screenCapture: notFoundCapture,
            automation: ReceiptRecoveryAutomationService(),
            targetResolver: notFoundResolver)
        do {
            _ = try await notFoundService.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .none)))
            XCTFail("Expected targetNotFound")
        } catch let error as DesktopObservationError {
            guard case .targetNotFound = error else {
                XCTFail("Expected targetNotFound, got \(error)")
                return
            }
        }
        XCTAssertEqual(notFoundResolver.resolveCalls, 1)
        XCTAssertEqual(notFoundCapture.captureCalls, 1)

        let captureFailedResolver = RecordingReceiptTargetResolver(target: target)
        let captureFailedCapture = ReceiptRecoveryCaptureService(resultProvider: {
            throw OperationError.captureFailed(reason: "fixture")
        })
        let captureFailedService = DesktopObservationService(
            screenCapture: captureFailedCapture,
            automation: ReceiptRecoveryAutomationService(),
            targetResolver: captureFailedResolver)
        do {
            _ = try await captureFailedService.observe(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .none)))
            XCTFail("Expected capture failure")
        } catch is OperationError {
            // Expected.
        }
        XCTAssertEqual(captureFailedResolver.resolveCalls, 1)
        XCTAssertEqual(captureFailedCapture.captureCalls, 1)
    }

    func testPotentiallyMutatingObservationModesDoNotRetryChangedCaptureReceipts() async throws {
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let target = Self.receiptedTarget(bounds: bounds)
        let changedCapture = Self.receiptedCapture(
            bounds: CGRect(x: 101, y: 100, width: 500, height: 400))
        let requests = [
            DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                capture: DesktopCaptureOptions(focus: .foreground),
                detection: DesktopDetectionOptions(mode: .none)),
            DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true)),
            DesktopObservationRequest(
                target: .menubarPopover(hints: ["Fixture"], openIfNeeded: MenuBarPopoverOpenOptions()),
                detection: DesktopDetectionOptions(mode: .none)),
        ]

        let expectedMutationDispatched: [Bool?] = [true, nil, false]
        for (index, request) in requests.enumerated() {
            let resolver = RecordingReceiptTargetResolver(target: target)
            let capture = ReceiptRecoveryCaptureService(result: changedCapture)
            let service = DesktopObservationService(
                screenCapture: capture,
                automation: ReceiptRecoveryAutomationService(),
                targetResolver: resolver)

            do {
                _ = try await service.observe(request)
                XCTFail("Expected changed capture receipt")
            } catch let failure as DesktopActionFailure {
                let expected = try XCTUnwrap(expectedMutationDispatched[index])
                XCTAssertEqual(
                    failure.outcome.dispatchState.mutationDispatched,
                    expected)
                XCTAssertEqual(
                    failure.outcome.retrySafety,
                    expected ? .unsafe : .safe)
                XCTAssertEqual(
                    failure.outcome.projection.requiresFreshObservation,
                    expected)
                XCTAssertTrue(failure.causeDescription?.contains("targetChanged") == true)
            } catch let error as DesktopObservationError {
                XCTAssertNil(expectedMutationDispatched[index])
                guard case .targetChanged = error else {
                    XCTFail("Expected targetChanged, got \(error)")
                    continue
                }
            }
            XCTAssertEqual(resolver.resolveCalls, 1)
            XCTAssertEqual(capture.captureCalls, 1)
        }
    }

    func testWebFocusCaptureFailureStaysPredispatchSafe() async throws {
        let target = Self.receiptedTarget(bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
        let resolver = RecordingReceiptTargetResolver(target: target)
        let capture = ReceiptRecoveryCaptureService(resultProvider: {
            throw OperationError.captureFailed(reason: "web-focus capture fixture")
        })
        let automation = ReceiptRecoveryAutomationService()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            targetResolver: resolver)

        do {
            _ = try await service.observeActionResult(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true)))
            XCTFail("Expected capture failure")
        } catch is DesktopActionFailure {
            XCTFail("Capture failed before web-focus detection, so no mutation outcome should be synthesized")
        } catch let OperationError.captureFailed(reason) {
            XCTAssertEqual(reason, "web-focus capture fixture")
        }

        XCTAssertEqual(resolver.resolveCalls, 1)
        XCTAssertEqual(capture.captureCalls, 1)
        XCTAssertEqual(automation.detectCalls, 0)
    }

    func testWebFocusDispatchIsAddedAfterSuccessfulCapture() async throws {
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let resolver = RecordingReceiptTargetResolver(target: Self.receiptedTarget(bounds: bounds))
        let capture = ReceiptRecoveryCaptureService(result: Self.receiptedCapture(bounds: bounds))
        let automation = ReceiptRecoveryAutomationService()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            targetResolver: resolver)

        let result = try await service.observeActionResult(DesktopObservationRequest(
            target: .app(identifier: "Fixture", window: .automatic),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true)))

        XCTAssertEqual(capture.captureCalls, 1)
        XCTAssertEqual(automation.detectCalls, 1)
        XCTAssertEqual(result.outcome?.state, .dispatchedUnverified)
        XCTAssertEqual(
            result.outcome?.delivery,
            DesktopActionOutcome.Delivery(mechanism: .capturePipeline, mode: .background))
        XCTAssertEqual(result.outcome?.dispatchState.unitCount, .one)
    }

    func testWebFocusDetectionFailureBecomesUnsafeOnlyAfterSuccessfulCapture() async throws {
        let bounds = CGRect(x: 100, y: 100, width: 500, height: 400)
        let resolver = RecordingReceiptTargetResolver(target: Self.receiptedTarget(bounds: bounds))
        let capture = ReceiptRecoveryCaptureService(result: Self.receiptedCapture(bounds: bounds))
        let automation = ReceiptRecoveryAutomationService(
            actionError: OperationError.captureFailed(reason: "web-focus detection fixture"))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            targetResolver: resolver)

        do {
            _ = try await service.observeActionResult(DesktopObservationRequest(
                target: .app(identifier: "Fixture", window: .automatic),
                detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true)))
            XCTFail("Expected detection failure")
        } catch let failure as DesktopActionFailure {
            XCTAssertEqual(failure.outcome.state, .dispatchedUnverified)
            XCTAssertTrue(failure.outcome.dispatchState.mutationDispatched)
            XCTAssertEqual(failure.outcome.retrySafety, .unsafe)
            XCTAssertEqual(
                failure.outcome.delivery,
                DesktopActionOutcome.Delivery(mechanism: .capturePipeline, mode: .background))
            XCTAssertEqual(failure.outcome.dispatchState.unitCount, .one)
            XCTAssertTrue(failure.causeDescription?.contains("web-focus detection fixture") == true)
        }

        XCTAssertEqual(capture.captureCalls, 1)
        XCTAssertEqual(automation.detectCalls, 1)
    }

    private static func receiptedTarget(bounds: CGRect) -> ResolvedObservationTarget {
        let receipt = self.receipt(bounds: bounds)
        return ResolvedObservationTarget(
            kind: .windowID(42),
            app: ApplicationIdentity(
                processIdentifier: 123,
                processStartIdentity: 700,
                bundleIdentifier: "com.example.fixture",
                name: "Fixture"),
            window: WindowIdentity(windowID: 42, title: "Fixture", bounds: bounds, index: 0),
            bounds: bounds,
            detectionContext: WindowContext(
                applicationName: "Fixture",
                applicationBundleId: "com.example.fixture",
                applicationProcessId: 123,
                windowTitle: "Fixture",
                windowID: 42,
                windowBounds: bounds,
                windowMutationIdentity: receipt))
    }

    private static func receiptedCapture(bounds: CGRect) -> CaptureResult {
        CaptureResult(
            imageData: Data([9]),
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 123,
                    processStartIdentity: 700,
                    bundleIdentifier: "com.example.fixture",
                    name: "Fixture",
                    windowCount: 1),
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "Fixture",
                    bounds: bounds,
                    windowLevel: 0,
                    alpha: 1,
                    layer: 0,
                    isOnScreen: true,
                    sharingState: .readOnly,
                    mutationIdentity: self.receipt(bounds: bounds))))
    }

    private static func receipt(bounds: CGRect) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 700,
            capturedBounds: bounds)
    }
}

@MainActor
private final class RecordingReceiptTargetResolver: ObservationTargetResolving {
    private let target: ResolvedObservationTarget
    private(set) var resolveCalls = 0

    init(target: ResolvedObservationTarget) {
        self.target = target
    }

    func resolve(
        _: DesktopObservationTargetRequest,
        snapshot _: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
    {
        self.resolveCalls += 1
        return self.target
    }
}

@MainActor
private final class ReceiptRecoveryCaptureService: ScreenCaptureServiceProtocol {
    private let resultProvider: @MainActor () throws -> CaptureResult
    private(set) var captureCalls = 0
    private(set) var windowIDs: [Int] = []

    init(result: CaptureResult) {
        self.resultProvider = { result }
    }

    init(resultProvider: @escaping @MainActor () throws -> CaptureResult) {
        self.resultProvider = resultProvider
    }

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capture()
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capture()
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.windowIDs.append(Int(windowID))
        return try self.capture()
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capture()
    }

    func captureArea(
        _: CGRect,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        try self.capture()
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }

    private func capture() throws -> CaptureResult {
        self.captureCalls += 1
        return try self.resultProvider()
    }
}

@MainActor
private final class ReceiptRecoveryAutomationService: UIAutomationObservationActionResultProviding {
    private let actionError: (any Error)?
    private(set) var detectCalls = 0

    init(actionError: (any Error)? = nil) {
        self.actionError = actionError
    }

    func detectElements(
        in _: Data,
        snapshotId: String?,
        windowContext _: WindowContext?) async throws -> ElementDetectionResult
    {
        try self.detectionResult(snapshotID: snapshotId)
    }

    func detectElementsActionResult(
        in _: Data,
        snapshotId: String?,
        windowContext: WindowContext?,
        requestTimeoutSec _: TimeInterval?) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        try UIAutomationActionResult(
            payload: self.detectionResult(snapshotID: snapshotId),
            outcome: windowContext?.shouldFocusWebContent == true
                ? .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one)
                : nil)
    }

    func inspectAccessibilityTreeActionResult(
        windowContext: WindowContext?) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        try UIAutomationActionResult(
            payload: self.detectionResult(snapshotID: nil),
            outcome: windowContext?.shouldFocusWebContent == true
                ? .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one)
                : nil)
    }

    private func detectionResult(snapshotID: String?) throws -> ElementDetectionResult {
        self.detectCalls += 1
        if let actionError {
            throw actionError
        }
        return ElementDetectionResult(
            snapshotId: snapshotID ?? "generated",
            screenshotPath: "/tmp/fake.png",
            elements: DetectedElements(buttons: [
                DetectedElement(id: "B1", type: .button, label: "Fixture", bounds: .zero),
            ]),
            metadata: DetectionMetadata(detectionTime: 0, elementCount: 1, method: "fake"))
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
