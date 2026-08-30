import CoreGraphics
import PeekabooFoundation
import XCTest
@testable import PeekabooAutomationKit

@MainActor
final class DesktopObservationMenubarTests: XCTestCase {
    func testObservationCapturesResolvedMenuBarBoundsAsArea() async throws {
        let menuBarBounds = CGRect(x: 0, y: 1080, width: 1728, height: 37)
        let capture = MenuBarRecordingScreenCaptureService()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            targetResolver: MenuBarTargetResolver(
                target: ResolvedObservationTarget(kind: .menubar, bounds: menuBarBounds)))

        let result = try await service.observe(DesktopObservationRequest(
            target: .menubar,
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(capture.capturedAreas, [menuBarBounds])
        XCTAssertEqual(result.target.kind, .menubar)
        XCTAssertEqual(result.target.bounds, menuBarBounds)
        XCTAssertEqual(result.timings.spans.map(\.name), [
            "state.snapshot",
            "target.resolve",
            "capture.area",
            "desktop.observe",
        ])
    }

    func testMenuBarObservationReportsSharedTargetDiagnostics() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let screen = Self.primaryScreen()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            applications: UnusedApplicationService(),
            screens: MenuBarRecordingScreenService(screens: [screen]))

        let result = try await service.observe(DesktopObservationRequest(
            target: .menubar,
            detection: DesktopDetectionOptions(mode: .none)))

        let target = try XCTUnwrap(result.diagnostics.target)
        XCTAssertEqual(target.requestedKind, "menubar")
        XCTAssertEqual(target.resolvedKind, "menubar")
        XCTAssertEqual(target.source, "primary-screen")
        XCTAssertEqual(target.bounds, ObservationTargetResolver.menuBarBounds(for: screen))
        XCTAssertEqual(target.captureScaleHint, screen.scaleFactor)
    }

    func testPopoverObservationRefusesUnreceiptedWindowBeforeCapture() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let bounds = CGRect(x: 1200, y: 920, width: 320, height: 260)
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            targetResolver: MenuBarTargetResolver(target: ResolvedObservationTarget(
                kind: .menubarPopover,
                app: ApplicationIdentity(processIdentifier: 123, bundleIdentifier: nil, name: "Trimmy"),
                window: WindowIdentity(windowID: 42, title: "", bounds: bounds, index: 0),
                bounds: bounds)))

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .menubarPopover(hints: ["Trimmy"]),
                detection: DesktopDetectionOptions(mode: .none)))
            XCTFail("Expected an unreceipted popover window to fail closed")
        } catch let error as DesktopObservationError {
            guard case .targetChanged = error else {
                return XCTFail("Expected targetChanged, received \(error)")
            }
        }

        XCTAssertTrue(capture.capturedWindowIDs.isEmpty)
    }

    func testPopoverObservationRejectsSameWindowIDFromReplacementGeneration() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let bounds = CGRect(x: 1200, y: 920, width: 320, height: 260)
        let original = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 700,
            capturedBounds: bounds)
        let replacement = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 701,
            capturedBounds: bounds)
        capture.windowCaptureResult = CaptureResult(
            imageData: Data([4, 5, 6]),
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 123,
                    processStartIdentity: 701,
                    bundleIdentifier: "dev.peekaboo.replacement",
                    name: "Replacement"),
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "",
                    bounds: bounds,
                    index: 0,
                    mutationIdentity: replacement)))
        let target = ResolvedObservationTarget(
            kind: .menubarPopover,
            app: ApplicationIdentity(
                processIdentifier: 123,
                processStartIdentity: 700,
                bundleIdentifier: nil,
                name: "Original"),
            window: WindowIdentity(windowID: 42, title: "", bounds: bounds, index: 0),
            bounds: bounds,
            detectionContext: WindowContext(
                applicationName: "Original",
                applicationProcessId: 123,
                windowTitle: "",
                windowID: 42,
                windowBounds: bounds,
                windowMutationIdentity: original))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            targetResolver: MenuBarTargetResolver(target: target))

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .menubarPopover(hints: ["Original"]),
                detection: DesktopDetectionOptions(mode: .none)))
            XCTFail("Expected replacement generation to fail capture receipt validation")
        } catch let error as DesktopObservationError {
            guard case .targetChanged = error else {
                return XCTFail("Expected targetChanged, received \(error)")
            }
        }

        XCTAssertEqual(capture.capturedWindowIDs, [42, 42])
    }

    func testPopoverObservationWithOpenIfNeededIsNoChangeWhenAlreadyOpen() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let bounds = CGRect(x: 1200, y: 920, width: 320, height: 260)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 700,
            capturedBounds: bounds)
        capture.windowCaptureResult = CaptureResult(
            imageData: Data([4, 5, 6]),
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: 123,
                    processStartIdentity: 700,
                    bundleIdentifier: "dev.peekaboo.fixture",
                    name: "Fixture"),
                windowInfo: ServiceWindowInfo(
                    windowID: 42,
                    title: "",
                    bounds: bounds,
                    index: 0,
                    mutationIdentity: identity)))
        let target = ResolvedObservationTarget(
            kind: .menubarPopover,
            app: ApplicationIdentity(
                processIdentifier: 123,
                processStartIdentity: 700,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture"),
            window: WindowIdentity(windowID: 42, title: "", bounds: bounds, index: 0),
            bounds: bounds,
            detectionContext: WindowContext(
                applicationName: "Fixture",
                applicationBundleId: "dev.peekaboo.fixture",
                applicationProcessId: 123,
                windowTitle: "",
                windowID: 42,
                windowBounds: bounds,
                windowMutationIdentity: identity))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            targetResolver: MenuBarTargetResolver(target: target))

        let result = try await service.observeActionResult(DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Fixture"],
                openIfNeeded: .init(clickHint: "Fixture", settleDelayNanoseconds: 0)),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(capture.capturedWindowIDs, [42])
        XCTAssertEqual(result.outcome?.state, .confirmedNoChange)
        XCTAssertNil(result.outcome?.delivery)
        XCTAssertEqual(result.outcome?.dispatchState, DesktopActionOutcome.DispatchState.none)
        XCTAssertNil(result.targetIdentity)
        XCTAssertNil(result.selectedLeafEvidence)
        XCTAssertNil(result.payload.target.mutationTargetIdentity)
    }

    func testAlreadyOpenPopoverComposesForegroundCaptureOutcomeAndTarget() async throws {
        let fixture = try Self.alreadyOpenPopoverFixture()
        let capture = MenuBarRecordingScreenCaptureService()
        capture.windowCaptureResult = fixture.capture
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            targetResolver: MenuBarTargetResolver(target: fixture.target))

        let result = try await service.observeActionResult(DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Fixture"],
                openIfNeeded: .init(clickHint: "Fixture", settleDelayNanoseconds: 0)),
            capture: DesktopCaptureOptions(focus: .foreground),
            detection: DesktopDetectionOptions(mode: .none)))

        XCTAssertEqual(result.outcome?.state, .dispatchedUnverified)
        XCTAssertEqual(
            result.outcome?.delivery,
            DesktopActionOutcome.Delivery(mechanism: .capturePipeline, mode: .foreground))
        XCTAssertEqual(result.outcome?.dispatchState.unitCount, .one)
        XCTAssertEqual(result.targetIdentity, fixture.targetIdentity)
        XCTAssertEqual(result.payload.target.window?.windowID, fixture.identity.windowID)
    }

    func testAlreadyOpenPopoverPreservesForegroundCaptureFailureOutcomeAndTarget() async throws {
        let fixture = try Self.alreadyOpenPopoverFixture()
        let capture = MenuBarRecordingScreenCaptureService()
        capture.windowCaptureError = DesktopObservationError.targetNotFound("capture fixture")
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            targetResolver: MenuBarTargetResolver(target: fixture.target))

        do {
            _ = try await service.observeActionResult(DesktopObservationRequest(
                target: .menubarPopover(
                    hints: ["Fixture"],
                    openIfNeeded: .init(clickHint: "Fixture", settleDelayNanoseconds: 0)),
                capture: DesktopCaptureOptions(focus: .foreground),
                detection: DesktopDetectionOptions(mode: .none)))
            XCTFail("Expected foreground capture failure")
        } catch let failure as DesktopActionFailure {
            XCTAssertEqual(failure.outcome.state, .dispatchedUnverified)
            XCTAssertEqual(
                failure.outcome.delivery,
                DesktopActionOutcome.Delivery(mechanism: .capturePipeline, mode: .foreground))
            XCTAssertEqual(failure.outcome.dispatchState.unitCount, .one)
            XCTAssertEqual(failure.targetReceipt, fixture.targetIdentity.actionTargetReceipt)
            XCTAssertTrue(failure.causeDescription?.contains("capture fixture") == true)
        }
    }

    func testAlreadyOpenPopoverComposesWebFocusOutcomeUnitsAndTarget() async throws {
        let fixture = try Self.alreadyOpenPopoverFixture()
        let capture = MenuBarRecordingScreenCaptureService()
        capture.windowCaptureResult = fixture.capture
        let detection = Self.detectionResult(for: fixture.target)
        let automation = MenuBarRecordingAutomationService(actionResult: UIAutomationActionResult(
            payload: detection,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
            targetIdentity: fixture.targetIdentity))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            targetResolver: MenuBarTargetResolver(target: fixture.target))

        let result = try await service.observeActionResult(DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Fixture"],
                openIfNeeded: .init(clickHint: "Fixture", settleDelayNanoseconds: 0)),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true)))

        XCTAssertEqual(result.outcome?.state, .dispatchedUnverified)
        XCTAssertEqual(
            result.outcome?.delivery,
            DesktopActionOutcome.Delivery(mechanism: .capturePipeline, mode: .background))
        XCTAssertEqual(result.outcome?.dispatchState.unitCount, DesktopActionOutcome.DispatchUnitCount(2))
        XCTAssertEqual(result.targetIdentity, fixture.targetIdentity)
        XCTAssertEqual(automation.detectCalls, 1)
    }

    func testAlreadyOpenPopoverComposesForegroundCaptureAndWebFocusUnits() async throws {
        let fixture = try Self.alreadyOpenPopoverFixture()
        let capture = MenuBarRecordingScreenCaptureService()
        capture.windowCaptureResult = fixture.capture
        let automation = MenuBarRecordingAutomationService(actionResult: UIAutomationActionResult(
            payload: Self.detectionResult(for: fixture.target),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
            targetIdentity: fixture.targetIdentity))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            targetResolver: MenuBarTargetResolver(target: fixture.target))

        let result = try await service.observeActionResult(DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Fixture"],
                openIfNeeded: .init(clickHint: "Fixture", settleDelayNanoseconds: 0)),
            capture: DesktopCaptureOptions(focus: .foreground),
            detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true)))

        XCTAssertEqual(result.outcome?.state, .dispatchedUnverified)
        XCTAssertEqual(
            result.outcome?.delivery,
            DesktopActionOutcome.Delivery(mechanism: .capturePipeline, mode: .foreground))
        XCTAssertEqual(result.outcome?.dispatchState.unitCount, DesktopActionOutcome.DispatchUnitCount(3))
        XCTAssertEqual(result.targetIdentity, fixture.targetIdentity)
    }

    func testAlreadyOpenPopoverPreservesWebFocusFailureUnitsAndTarget() async throws {
        let fixture = try Self.alreadyOpenPopoverFixture()
        let capture = MenuBarRecordingScreenCaptureService()
        capture.windowCaptureResult = fixture.capture
        let detectionFailure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Web focus failed after dispatch.")
            .attributed(to: fixture.targetIdentity.actionTargetReceipt)
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(actionError: detectionFailure),
            targetResolver: MenuBarTargetResolver(target: fixture.target))

        do {
            _ = try await service.observeActionResult(DesktopObservationRequest(
                target: .menubarPopover(
                    hints: ["Fixture"],
                    openIfNeeded: .init(clickHint: "Fixture", settleDelayNanoseconds: 0)),
                detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true)))
            XCTFail("Expected web-focus failure")
        } catch let failure as DesktopActionFailure {
            XCTAssertEqual(failure.outcome.state, .indeterminate)
            XCTAssertEqual(
                failure.outcome.delivery,
                DesktopActionOutcome.Delivery(mechanism: .capturePipeline, mode: .background))
            XCTAssertEqual(failure.outcome.dispatchState.unitCount, DesktopActionOutcome.DispatchUnitCount(2))
            XCTAssertEqual(failure.targetReceipt, fixture.targetIdentity.actionTargetReceipt)
        }
    }

    func testPopoverConditionalTimeoutPreservesMutationUncertaintyAndExactReceipt() async throws {
        let fixture = try Self.alreadyOpenPopoverFixture()
        let statusBounds = CGRect(x: 1590, y: 1080, width: 20, height: 20)
        let statusIdentity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 321,
            ownerProcessStartIdentity: 654,
            capturedBounds: statusBounds)
        let statusTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: statusIdentity,
            bounds: statusBounds))
        let captureSuspension = MenuBarObservationSuspension()
        let capture = MenuBarRecordingScreenCaptureService()
        capture.windowCaptureResult = fixture.capture
        capture.windowCaptureSuspension = captureSuspension
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            targetResolver: MenuBarActionTargetResolver(result: UIAutomationActionResult(
                payload: fixture.target,
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: DesktopActionOutcome.DispatchUnitCount(3)),
                targetIdentity: statusTarget)))

        let observation = Task { @MainActor in
            try await service.observeActionResult(DesktopObservationRequest(
                target: .menubarPopover(
                    hints: ["Fixture"],
                    openIfNeeded: MenuBarPopoverOpenOptions(clickHint: "Fixture")),
                detection: DesktopDetectionOptions(mode: .none),
                timeout: DesktopObservationTimeouts(overall: 0.2)))
        }
        await captureSuspension.waitUntilEntered()

        do {
            _ = try await observation.value
            XCTFail("Expected conditional popover timeout")
        } catch let failure as DesktopActionFailure {
            XCTAssertEqual(failure.outcome.state, .indeterminate)
            XCTAssertEqual(failure.outcome.delivery?.mechanism, .windowTargetedEvents)
            XCTAssertEqual(failure.outcome.delivery?.mode, .background)
            XCTAssertEqual(failure.outcome.dispatchState.unitCount?.rawValue, 3)
            XCTAssertEqual(failure.outcome.retrySafety, .unsafe)
            XCTAssertEqual(failure.targetReceipt, statusTarget.actionTargetReceipt)
        }
        await captureSuspension.release()
    }

    func testPopoverSettleTimeoutPreservesDispatchedClickEvidence() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let statusBounds = CGRect(x: 1590, y: 1080, width: 20, height: 20)
        let statusIdentity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 321,
            ownerProcessStartIdentity: 654,
            capturedBounds: statusBounds)
        let mutationTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: statusIdentity,
            bounds: statusBounds))
        let menu = GenerationPinnedMenuBarRecordingMenuService(
            location: CGPoint(x: 1600, y: 1098),
            targetIdentity: mutationTarget)
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            applications: UnusedApplicationService(),
            menu: menu,
            screens: MenuBarRecordingScreenService(screens: [Self.primaryScreen()]))

        do {
            _ = try await service.observeActionResult(DesktopObservationRequest(
                target: .menubarPopover(
                    hints: ["Definitely Not Open Menu Extra For Test"],
                    openIfNeeded: MenuBarPopoverOpenOptions(
                        clickHint: "Definitely Not Open Menu Extra For Test",
                        settleDelayNanoseconds: 1_000_000_000)),
                detection: DesktopDetectionOptions(mode: .none),
                timeout: DesktopObservationTimeouts(overall: 0.1)))
            XCTFail("Expected post-click popover settlement timeout")
        } catch let failure as DesktopActionFailure {
            XCTAssertEqual(failure.outcome.state, .indeterminate)
            XCTAssertEqual(failure.outcome.delivery?.mechanism, .windowTargetedEvents)
            XCTAssertEqual(failure.outcome.delivery?.mode, .background)
            XCTAssertEqual(failure.outcome.dispatchState.unitCount?.rawValue, 3)
            XCTAssertEqual(failure.outcome.retrySafety, .unsafe)
            XCTAssertEqual(failure.targetReceipt, mutationTarget.actionTargetReceipt)
            XCTAssertEqual(failure.selectedLeafEvidence?.count, 1)
        }
        XCTAssertEqual(menu.clickedNames, ["Definitely Not Open Menu Extra For Test"])
        XCTAssertTrue(capture.capturedAreas.isEmpty)
        XCTAssertTrue(capture.capturedWindowIDs.isEmpty)
    }

    func testWebFocusConditionalTimeoutPreservesMutationUncertaintyAndExactReceipt() async throws {
        let fixture = try Self.alreadyOpenPopoverFixture()
        let detectionSuspension = MenuBarObservationSuspension()
        let capture = MenuBarRecordingScreenCaptureService()
        capture.windowCaptureResult = fixture.capture
        let automation = MenuBarRecordingAutomationService(
            actionResult: UIAutomationActionResult(
                payload: Self.detectionResult(for: fixture.target),
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: fixture.targetIdentity),
            detectionSuspension: detectionSuspension)
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            targetResolver: MenuBarActionTargetResolver(result: UIAutomationActionResult(
                payload: fixture.target,
                outcome: nil)))

        do {
            _ = try await service.observeActionResult(DesktopObservationRequest(
                target: .frontmost,
                detection: DesktopDetectionOptions(
                    mode: .accessibility,
                    allowWebFocusFallback: true),
                timeout: DesktopObservationTimeouts(overall: 0.02)))
            XCTFail("Expected conditional web-focus timeout")
        } catch let failure as DesktopActionFailure {
            XCTAssertEqual(failure.outcome.state, .indeterminate)
            XCTAssertEqual(failure.outcome.delivery?.mechanism, .capturePipeline)
            XCTAssertEqual(failure.outcome.delivery?.mode, .background)
            XCTAssertEqual(failure.outcome.dispatchState.unitCount, .one)
            XCTAssertEqual(failure.outcome.retrySafety, .unsafe)
            XCTAssertEqual(failure.targetReceipt, fixture.targetIdentity.actionTargetReceipt)
        }
        await detectionSuspension.release()
    }

    func testWebFocusTimeoutBeforeDetectionDispatchRemainsSafeCaptureTimeout() async throws {
        let fixture = try Self.alreadyOpenPopoverFixture()
        let captureSuspension = MenuBarObservationSuspension()
        let capture = MenuBarRecordingScreenCaptureService()
        capture.windowCaptureResult = fixture.capture
        capture.windowCaptureSuspension = captureSuspension
        let automation = MenuBarRecordingAutomationService(actionResult: UIAutomationActionResult(
            payload: Self.detectionResult(for: fixture.target),
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: fixture.targetIdentity))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            targetResolver: MenuBarActionTargetResolver(result: UIAutomationActionResult(
                payload: fixture.target,
                outcome: nil)))

        do {
            _ = try await service.observeActionResult(DesktopObservationRequest(
                target: .frontmost,
                detection: DesktopDetectionOptions(
                    mode: .accessibility,
                    allowWebFocusFallback: true),
                timeout: DesktopObservationTimeouts(overall: 0.02)))
            XCTFail("Expected pre-detection capture timeout")
        } catch let CaptureError.detectionTimedOut(seconds) {
            XCTAssertEqual(seconds, 0.02, accuracy: 0.001)
        }
        XCTAssertEqual(automation.detectCalls, 0)
        await captureSuspension.release()
    }

    func testOpenedPopoverRefusesToCollapseSetupAndWebFocusOntoDifferentWindows() async throws {
        let fixture = try Self.alreadyOpenPopoverFixture()
        let statusBounds = CGRect(x: 1590, y: 1080, width: 20, height: 20)
        let statusIdentity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 321,
            ownerProcessStartIdentity: 654,
            capturedBounds: statusBounds)
        let statusTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: statusIdentity,
            bounds: statusBounds))
        let resolvedTarget = ResolvedObservationTarget(
            kind: fixture.target.kind,
            app: fixture.target.app,
            window: fixture.target.window,
            bounds: fixture.target.bounds,
            detectionContext: fixture.target.detectionContext,
            mutationTargetIdentity: DesktopObservationMutationTargetIdentity(statusTarget))
        let setupResult = UIAutomationActionResult(
            payload: resolvedTarget,
            outcome: DesktopActionOutcome.dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(3)),
            targetIdentity: statusTarget)
        let capture = MenuBarRecordingScreenCaptureService()
        capture.windowCaptureResult = fixture.capture
        let detection = Self.detectionResult(for: resolvedTarget)
        let automation = MenuBarRecordingAutomationService(actionResult: UIAutomationActionResult(
            payload: detection,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
            targetIdentity: fixture.targetIdentity))
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: automation,
            targetResolver: MenuBarActionTargetResolver(result: setupResult))

        do {
            _ = try await service.observeActionResult(DesktopObservationRequest(
                target: .menubarPopover(
                    hints: ["Fixture"],
                    openIfNeeded: .init(clickHint: "Fixture", settleDelayNanoseconds: 0)),
                detection: DesktopDetectionOptions(mode: .accessibility, allowWebFocusFallback: true)))
            XCTFail("Expected incompatible mutation targets to fail closed")
        } catch let failure as DesktopActionFailure {
            XCTAssertEqual(failure.outcome.state, .dispatchedUnverified)
            XCTAssertEqual(
                failure.outcome.delivery,
                DesktopActionOutcome.Delivery(mechanism: .composite, mode: .background))
            XCTAssertEqual(failure.outcome.dispatchState.unitCount, DesktopActionOutcome.DispatchUnitCount(5))
            XCTAssertNil(failure.targetReceipt)
            XCTAssertEqual(automation.detectCalls, 1)
        }
    }
}

extension DesktopObservationMenubarTests {
    func testPopoverResolverPrefersHintedOwnerNearMenuBar() {
        let screen = ScreenInfo(
            index: 0,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
            isPrimary: true,
            scaleFactor: 2,
            displayID: 1)
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220)),
            Self.windowInfo(
                id: 3,
                ownerPID: 300,
                ownerName: "Window Server",
                title: "Menubar",
                bounds: CGRect(x: 0, y: 1080, width: 1728, height: 37),
                layer: 24),
        ]

        let candidate = ObservationMenuBarPopoverResolver.resolve(
            hints: ["Trimmy"],
            windowList: windows,
            screens: [screen])

        XCTAssertEqual(candidate?.windowID, 2)
        XCTAssertEqual(candidate?.ownerPID, 200)
    }

    func testPopoverResolverRejectsUnmatchedHints() {
        let screen = Self.primaryScreen()
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
        ]

        let candidate = ObservationMenuBarPopoverResolver.resolve(
            hints: ["Definitely Not Open Menu Extra For Test"],
            windowList: windows,
            screens: [screen])

        XCTAssertNil(candidate)
    }

    func testPopoverResolverSelectsFromCatalogCandidates() {
        let candidates = [
            ObservationMenuBarPopoverCandidate(
                windowID: 1,
                ownerPID: 100,
                ownerName: "Other",
                title: nil,
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180),
                layer: 0),
            ObservationMenuBarPopoverCandidate(
                windowID: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                title: "Menu",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220),
                layer: 0),
        ]

        let candidate = ObservationMenuBarPopoverResolver.resolve(
            hints: ["Trimmy"],
            candidates: candidates)

        XCTAssertEqual(candidate?.windowID, 2)
    }

    func testMenuBarWindowCatalogBuildsTypedSnapshot() {
        let screen = Self.primaryScreen()
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                title: "Menu",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220)),
        ]

        let snapshot = ObservationMenuBarWindowCatalog.snapshot(
            windowList: windows,
            screens: [screen])

        XCTAssertEqual(snapshot.candidates.map(\.windowID), [1, 2])
        XCTAssertEqual(snapshot.windowInfoByID[2]?.ownerName, "Trimmy")
        XCTAssertEqual(snapshot.windowInfoByID[2]?.title, "Menu")
    }

    func testMenuBarWindowCatalogFiltersSnapshotByOwnerPID() {
        let screen = Self.primaryScreen()
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220)),
        ]

        let snapshot = ObservationMenuBarWindowCatalog.snapshot(
            windowList: windows,
            screens: [screen],
            ownerPID: 200)

        XCTAssertEqual(snapshot.candidates.map(\.windowID), [2])
        XCTAssertEqual(snapshot.windowInfoByID[1]?.ownerName, "Other")
    }

    func testMenuBarWindowCatalogFindsWindowIDsByOwnerAndTitle() {
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Other",
                bounds: CGRect(x: 100, y: 900, width: 260, height: 180)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Trimmy",
                title: "Battery Menu",
                bounds: CGRect(x: 1100, y: 860, width: 300, height: 220)),
        ]

        XCTAssertEqual(ObservationMenuBarWindowCatalog.windowIDsForPID(
            ownerPID: 200,
            windowList: windows), [2])
        XCTAssertEqual(ObservationMenuBarWindowCatalog.windowIDsMatchingOwnerNameOrTitle(
            "battery",
            windowList: windows), [2])
    }

    func testMenuBarWindowCatalogBandCandidatesUsePreferredX() {
        let screen = Self.primaryScreen()
        let windows = [
            Self.windowInfo(
                id: 1,
                ownerPID: 100,
                ownerName: "Far",
                bounds: CGRect(x: 100, y: 940, width: 220, height: 160)),
            Self.windowInfo(
                id: 2,
                ownerPID: 200,
                ownerName: "Near",
                bounds: CGRect(x: 1160, y: 940, width: 240, height: 180)),
        ]

        let candidates = ObservationMenuBarWindowCatalog.bandCandidates(
            windowList: windows,
            preferredX: 1200,
            screens: [screen])

        XCTAssertEqual(candidates.map(\.windowID), [2])
    }

    func testPopoverOCRSelectorMatchesCandidateWindow() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let ocr = MenuBarRecordingOCRRecognizer(text: "Battery Sound")
        let selector = ObservationMenuBarPopoverOCRSelector(
            screenCapture: capture,
            screens: [Self.primaryScreen()],
            ocrRecognizer: ocr)
        let bounds = CGRect(x: 1000, y: 880, width: 320, height: 220)

        let match = try await selector.matchCandidate(
            windowID: 42,
            bounds: bounds,
            hints: ["battery"])

        XCTAssertEqual(capture.capturedWindowIDs, [42])
        XCTAssertEqual(capture.visualizerModes, [.none])
        XCTAssertEqual(match?.bounds, bounds)
        XCTAssertEqual(match?.windowID, CGWindowID(42))
    }

    func testPopoverOCRSelectorCapturesPreferredArea() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let ocr = MenuBarRecordingOCRRecognizer(text: "Wi-Fi Bluetooth")
        let screen = Self.primaryScreen()
        let selector = ObservationMenuBarPopoverOCRSelector(
            screenCapture: capture,
            screens: [screen],
            ocrRecognizer: ocr)

        let match = try await selector.matchArea(preferredX: 1600, hints: ["bluetooth"])

        let expected = try XCTUnwrap(ObservationMenuBarPopoverOCRSelector.popoverAreaRect(
            preferredX: 1600,
            screens: [screen]))
        XCTAssertEqual(capture.capturedAreas, [expected])
        XCTAssertEqual(capture.visualizerModes, [.none])
        XCTAssertEqual(match?.bounds, expected)
    }

    func testPopoverObservationCanOpenMenuExtraAndCaptureClickAreaFallback() async throws {
        let capture = MenuBarRecordingScreenCaptureService()
        let statusBounds = CGRect(x: 1590, y: 1080, width: 20, height: 20)
        let statusIdentity = WindowMutationIdentity(
            windowID: 700,
            ownerProcessIdentifier: 321,
            ownerProcessStartIdentity: 654,
            capturedBounds: statusBounds)
        let mutationTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: statusIdentity,
            bounds: statusBounds))
        let menu = GenerationPinnedMenuBarRecordingMenuService(
            location: CGPoint(x: 1600, y: 1098),
            targetIdentity: mutationTarget)
        let screen = Self.primaryScreen()
        let service = DesktopObservationService(
            screenCapture: capture,
            automation: MenuBarRecordingAutomationService(),
            applications: UnusedApplicationService(),
            menu: menu,
            screens: MenuBarRecordingScreenService(screens: [screen]),
            ocrRecognizer: MenuBarRecordingOCRRecognizer(text: "Definitely Not Open Menu Extra For Test"))
        let expected = try XCTUnwrap(ObservationMenuBarPopoverOCRSelector.popoverAreaRect(
            preferredX: 1600,
            screens: [screen]))

        let actionResult = try await service.observeActionResult(DesktopObservationRequest(
            target: .menubarPopover(
                hints: ["Definitely Not Open Menu Extra For Test"],
                openIfNeeded: MenuBarPopoverOpenOptions(
                    clickHint: "Definitely Not Open Menu Extra For Test",
                    settleDelayNanoseconds: 0)),
            detection: DesktopDetectionOptions(mode: .none)))

        let result = actionResult.payload
        XCTAssertEqual(menu.clickedNames, ["Definitely Not Open Menu Extra For Test"])
        XCTAssertEqual(capture.capturedAreas, [expected])
        XCTAssertEqual(result.target.kind, .menubarPopover)
        XCTAssertEqual(result.target.bounds, expected)
        XCTAssertEqual(result.diagnostics.target?.requestedKind, "menubar-popover")
        XCTAssertEqual(result.diagnostics.target?.resolvedKind, "menubar-popover")
        XCTAssertEqual(result.diagnostics.target?.source, "click-location-area-fallback")
        XCTAssertEqual(result.diagnostics.target?.hints, ["Definitely Not Open Menu Extra For Test"])
        XCTAssertEqual(result.diagnostics.target?.openIfNeeded, true)
        XCTAssertEqual(result.diagnostics.target?.clickHint, "Definitely Not Open Menu Extra For Test")
        XCTAssertNil(result.diagnostics.target?.windowID)
        XCTAssertEqual(
            result.target.mutationTargetIdentity,
            DesktopObservationMutationTargetIdentity(mutationTarget))
        XCTAssertEqual(
            actionResult.outcome?.delivery,
            DesktopActionOutcome.Delivery(mechanism: .windowTargetedEvents, mode: .background))
        XCTAssertEqual(actionResult.targetIdentity, mutationTarget)
        XCTAssertEqual(actionResult.selectedLeafEvidence?.count, 1)
    }

    func testPopoverObservationRefusesBeforeClickWithoutGenerationPinnedMenuCapability() async throws {
        let menu = MenuBarRecordingMenuService(location: CGPoint(x: 1600, y: 1098))
        let service = DesktopObservationService(
            screenCapture: MenuBarRecordingScreenCaptureService(),
            automation: MenuBarRecordingAutomationService(),
            applications: UnusedApplicationService(),
            menu: menu,
            screens: MenuBarRecordingScreenService(screens: [Self.primaryScreen()]))

        do {
            _ = try await service.observe(DesktopObservationRequest(
                target: .menubarPopover(
                    hints: ["Definitely Not Open Menu Extra For Test"],
                    openIfNeeded: .init(
                        clickHint: "Definitely Not Open Menu Extra For Test",
                        settleDelayNanoseconds: 0)),
                detection: DesktopDetectionOptions(mode: .none)))
            XCTFail("Expected pre-dispatch generation-pinning refusal")
        } catch let failure as DesktopActionFailure {
            XCTAssertEqual(failure.outcome.state, .refused)
            XCTAssertEqual(failure.outcome.refusalReason, .foregroundConsentRequired)
            XCTAssertEqual(failure.outcome.dispatchState, .none)
            XCTAssertTrue(failure.outcome.retrySafety == .safe)
        }

        XCTAssertTrue(menu.clickedNames.isEmpty)
    }

    private static func windowInfo(
        id: Int,
        ownerPID: Int,
        ownerName: String,
        title: String = "",
        bounds: CGRect,
        layer: Int = 0) -> [String: Any]
    {
        [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: ownerPID,
            kCGWindowOwnerName as String: ownerName,
            kCGWindowName as String: title,
            kCGWindowLayer as String: layer,
            kCGWindowIsOnscreen as String: true,
            kCGWindowAlpha as String: 1.0,
            kCGWindowBounds as String: [
                "X": bounds.origin.x,
                "Y": bounds.origin.y,
                "Width": bounds.width,
                "Height": bounds.height,
            ],
        ]
    }

    private static func alreadyOpenPopoverFixture() throws -> (
        target: ResolvedObservationTarget,
        capture: CaptureResult,
        identity: WindowMutationIdentity,
        targetIdentity: DesktopTargetIdentity)
    {
        let bounds = CGRect(x: 1200, y: 920, width: 320, height: 260)
        let identity = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 700,
            capturedBounds: bounds)
        let target = ResolvedObservationTarget(
            kind: .menubarPopover,
            app: ApplicationIdentity(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity,
                bundleIdentifier: "dev.peekaboo.fixture",
                name: "Fixture"),
            window: WindowIdentity(windowID: identity.windowID, title: "", bounds: bounds, index: 0),
            bounds: bounds,
            detectionContext: WindowContext(
                applicationName: "Fixture",
                applicationBundleId: "dev.peekaboo.fixture",
                applicationProcessId: identity.ownerProcessIdentifier,
                windowTitle: "",
                windowID: identity.windowID,
                windowBounds: bounds,
                windowMutationIdentity: identity))
        let capture = CaptureResult(
            imageData: Data([4, 5, 6]),
            metadata: CaptureMetadata(
                size: bounds.size,
                mode: .window,
                applicationInfo: ServiceApplicationInfo(
                    processIdentifier: identity.ownerProcessIdentifier,
                    processStartIdentity: identity.ownerProcessStartIdentity,
                    bundleIdentifier: "dev.peekaboo.fixture",
                    name: "Fixture"),
                windowInfo: ServiceWindowInfo(
                    windowID: identity.windowID,
                    title: "",
                    bounds: bounds,
                    index: 0,
                    mutationIdentity: identity)))
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
        return (target, capture, identity, DesktopTargetIdentity(exactWindow: exactWindow))
    }

    private static func detectionResult(
        for target: ResolvedObservationTarget) -> ElementDetectionResult
    {
        ElementDetectionResult(
            snapshotId: "web-focus",
            screenshotPath: "",
            elements: DetectedElements(buttons: [DetectedElement(
                id: "web-focus-button",
                type: .button,
                label: "Fixture",
                bounds: CGRect(x: 10, y: 10, width: 60, height: 24))]),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 1,
                method: "fixture",
                windowContext: target.detectionContext))
    }

    private static func primaryScreen() -> ScreenInfo {
        ScreenInfo(
            index: 0,
            name: "Main",
            frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
            visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
            isPrimary: true,
            scaleFactor: 2,
            displayID: 1)
    }
}

@MainActor
private final class MenuBarTargetResolver: ObservationTargetResolving {
    private let target: ResolvedObservationTarget

    init(target: ResolvedObservationTarget) {
        self.target = target
    }

    func resolve(
        _: DesktopObservationTargetRequest,
        snapshot _: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
    {
        self.target
    }
}

@MainActor
private final class MenuBarActionTargetResolver: ObservationTargetResolving {
    private let result: UIAutomationActionResult<ResolvedObservationTarget>

    init(result: UIAutomationActionResult<ResolvedObservationTarget>) {
        self.result = result
    }

    func resolve(
        _: DesktopObservationTargetRequest,
        snapshot _: DesktopStateSnapshot) async throws -> ResolvedObservationTarget
    {
        self.result.payload
    }

    func resolveActionResult(
        _: DesktopObservationTargetRequest,
        snapshot _: DesktopStateSnapshot) async throws -> UIAutomationActionResult<ResolvedObservationTarget>
    {
        self.result
    }
}

@MainActor
private final class MenuBarRecordingScreenCaptureService: ScreenCaptureServiceProtocol {
    let captureTransactionGateOwner: CaptureTransactionGateOwner = .service
    var capturedAreas: [CGRect] = []
    var capturedWindowIDs: [CGWindowID] = []
    var visualizerModes: [CaptureVisualizerMode] = []
    var windowCaptureResult: CaptureResult?
    var windowCaptureError: (any Error)?
    var windowCaptureSuspension: MenuBarObservationSuspension?

    func captureScreen(
        displayIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw DesktopObservationError.unsupportedTarget("screen")
    }

    func captureWindow(
        appIdentifier _: String,
        windowIndex _: Int?,
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw DesktopObservationError.unsupportedTarget("window")
    }

    func captureWindow(
        windowID: CGWindowID,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedWindowIDs.append(windowID)
        self.visualizerModes.append(visualizerMode)
        await self.windowCaptureSuspension?.wait()
        if let windowCaptureError {
            throw windowCaptureError
        }
        return self.windowCaptureResult ?? CaptureResult(
            imageData: Data([4, 5, 6]),
            metadata: CaptureMetadata(size: CGSize(width: 320, height: 260), mode: .window))
    }

    func captureFrontmost(
        visualizerMode _: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        throw DesktopObservationError.unsupportedTarget("frontmost")
    }

    func captureArea(
        _ rect: CGRect,
        visualizerMode: CaptureVisualizerMode,
        scale _: CaptureScalePreference) async throws -> CaptureResult
    {
        self.capturedAreas.append(rect)
        self.visualizerModes.append(visualizerMode)
        return CaptureResult(
            imageData: Data([1, 2, 3]),
            metadata: CaptureMetadata(size: rect.size, mode: .area))
    }

    func hasScreenRecordingPermission() async -> Bool {
        true
    }
}

@MainActor
private final class MenuBarRecordingAutomationService: UIAutomationObservationActionResultProviding {
    private let actionResult: UIAutomationActionResult<ElementDetectionResult>?
    private let actionError: (any Error)?
    private let detectionSuspension: MenuBarObservationSuspension?
    private(set) var detectCalls = 0

    init(
        actionResult: UIAutomationActionResult<ElementDetectionResult>? = nil,
        actionError: (any Error)? = nil,
        detectionSuspension: MenuBarObservationSuspension? = nil)
    {
        self.actionResult = actionResult
        self.actionError = actionError
        self.detectionSuspension = detectionSuspension
    }

    func detectElements(
        in _: Data,
        snapshotId _: String?,
        windowContext _: WindowContext?) async throws -> ElementDetectionResult
    {
        await self.detectionSuspension?.wait()
        self.detectCalls += 1
        if let actionError {
            throw actionError
        }
        if let actionResult {
            return actionResult.payload
        }
        throw DesktopObservationError.unsupportedTarget("detection")
    }

    func detectElementsActionResult(
        in _: Data,
        snapshotId _: String?,
        windowContext _: WindowContext?,
        requestTimeoutSec _: TimeInterval?) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        await self.detectionSuspension?.wait()
        self.detectCalls += 1
        if let actionError {
            throw actionError
        }
        guard let actionResult else {
            throw DesktopObservationError.unsupportedTarget("detection")
        }
        return actionResult
    }

    func inspectAccessibilityTreeActionResult(
        windowContext _: WindowContext?) async throws -> UIAutomationActionResult<ElementDetectionResult>
    {
        await self.detectionSuspension?.wait()
        if let actionError {
            throw actionError
        }
        guard let actionResult else {
            throw DesktopObservationError.unsupportedTarget("accessibility inspection")
        }
        return actionResult
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

private actor MenuBarObservationSuspension {
    private var continuation: CheckedContinuation<Void, Never>?
    private var entryContinuations: [CheckedContinuation<Void, Never>] = []
    private var entered = false
    private var released = false

    func wait() async {
        self.entered = true
        let entryContinuations = self.entryContinuations
        self.entryContinuations.removeAll()
        for continuation in entryContinuations {
            continuation.resume()
        }
        guard !self.released else { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func waitUntilEntered() async {
        guard !self.entered else { return }
        await withCheckedContinuation { self.entryContinuations.append($0) }
    }

    func release() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}

@MainActor
private final class MenuBarRecordingScreenService: ScreenServiceProtocol {
    private let screens: [ScreenInfo]

    init(screens: [ScreenInfo]) {
        self.screens = screens
    }

    var primaryScreen: ScreenInfo? {
        self.screens.first(where: \.isPrimary) ?? self.screens.first
    }

    func listScreens() -> [ScreenInfo] {
        self.screens
    }

    func screenContainingWindow(bounds: CGRect) -> ScreenInfo? {
        self.screens.first { $0.frame.intersects(bounds) }
    }

    func screen(at index: Int) -> ScreenInfo? {
        self.screens.first { $0.index == index }
    }
}

@MainActor
private class MenuBarRecordingMenuService: MenuServiceProtocol {
    private let location: CGPoint
    var clickedNames: [String] = []

    init(location: CGPoint) {
        self.location = location
    }

    func listMenus(for _: String) async throws -> MenuStructure {
        fatalError("unused")
    }

    func listFrontmostMenus() async throws -> MenuStructure {
        fatalError("unused")
    }

    func clickMenuItem(app _: String, itemPath _: String) async throws {}

    func clickMenuItemByName(app _: String, itemName _: String) async throws {}

    func clickMenuExtra(title _: String) async throws {}

    func isMenuExtraMenuOpen(title _: String, ownerPID _: pid_t?) async throws -> Bool {
        false
    }

    func menuExtraOpenMenuFrame(title _: String, ownerPID _: pid_t?) async throws -> CGRect? {
        nil
    }

    func listMenuExtras() async throws -> [MenuExtraInfo] {
        []
    }

    func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        []
    }

    func clickMenuBarItem(named name: String) async throws -> ClickResult {
        self.clickedNames.append(name)
        return ClickResult(elementDescription: name, location: self.location)
    }

    func clickMenuBarItem(at _: Int) async throws -> ClickResult {
        fatalError("unused")
    }
}

@MainActor
private final class GenerationPinnedMenuBarRecordingMenuService: MenuBarRecordingMenuService,
    MenuServiceExactLeafActionResultProviding
{
    private let targetIdentity: DesktopTargetIdentity

    init(location: CGPoint, targetIdentity: DesktopTargetIdentity) {
        self.targetIdentity = targetIdentity
        super.init(location: location)
    }

    override func listMenuBarItems(includeRaw _: Bool) async throws -> [MenuBarItemInfo] {
        try [MenuBarItemInfo(
            title: "Definitely Not Open Menu Extra For Test",
            index: 0,
            frame: self.targetIdentity.exactWindow?.bounds,
            selectionEvidence: self.evidence())]
    }

    func clickMenuItemActionResult(app _: String, itemPath _: String) async throws
        -> UIAutomationActionResult<Void>
    {
        fatalError("unused")
    }

    func clickMenuItemByNameActionResult(app _: String, itemName _: String) async throws
        -> UIAutomationActionResult<Void>
    {
        fatalError("unused")
    }

    func clickMenuExtraActionResult(title _: String) async throws -> UIAutomationActionResult<Void> {
        fatalError("unused")
    }

    func clickMenuBarItemActionResult(named name: String) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        let payload = try await self.clickMenuBarItem(named: name)
        return try UIAutomationActionResult(
            payload: payload,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(3)),
            targetIdentity: self.targetIdentity,
            selectedLeafEvidence: [self.evidence().selecting(
                normalizedSelector: DeterministicDesktopLeafSelector.normalized(name),
                matchKind: .exact)])
    }

    func clickMenuBarItemActionResult(at _: Int) async throws -> UIAutomationActionResult<ClickResult> {
        fatalError("unused")
    }

    func clickMenuBarItemActionResult(request: MenuBarItemActionRequest) async throws
        -> UIAutomationActionResult<ClickResult>
    {
        guard let name = request.name,
              try request.expectedLeafEvidence.hasSameResolvedLeaf(as: self.evidence())
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Fixture menu evidence changed")
        }
        return try await self.clickMenuBarItemActionResult(named: name)
    }

    private func evidence() throws -> DesktopSelectedLeafEvidence {
        guard let exactWindow = targetIdentity.exactWindow else {
            throw DesktopTargetIdentityError.incompleteExactWindow
        }
        return try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: "0",
            matchKind: .index,
            selectedProcessIdentity: exactWindow.identity.processIdentity,
            selectedWindowIdentity: exactWindow.identity,
            selectedIndex: 0,
            selectedTitle: "Definitely Not Open Menu Extra For Test",
            selectedIdentifier: "fixture.menu.extra",
            selectedRole: "AXStatusItem",
            selectedFrame: exactWindow.bounds,
            candidateSetSHA256: String(repeating: "a", count: 64),
            candidateCount: 1)
    }
}

@MainActor
private final class MenuBarRecordingOCRRecognizer: OCRRecognizing {
    private let text: String

    init(text: String) {
        self.text = text
    }

    func recognizeText(in _: Data, timeoutSeconds _: TimeInterval) async throws -> OCRTextResult {
        OCRTextResult(
            observations: [
                OCRTextObservation(
                    text: self.text,
                    confidence: 0.98,
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.2)),
            ],
            imageSize: CGSize(width: 320, height: 220))
    }
}
