import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ObservationActionResultSemanticsTests {
    @Test(arguments: Self.nonPublishableOutcomes)
    func `nonpublishable provider outcomes retain exact canonical failure`(
        outcome: DesktopActionOutcome) throws
    {
        let target = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 541,
            processStartIdentity: 6541))

        do {
            try ObservationActionResultSemantics.requirePublishableOutcome(
                outcome,
                targetIdentity: target,
                operation: "Fixture observation",
                requiresOutcome: true)
            Issue.record("Expected nonpublishable observation outcome to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == outcome)
            #expect(failure.targetReceipt == DesktopActionTargetReceipt(
                processIdentifier: 541,
                processStartIdentity: 6541))
        }
    }

    @Test(arguments: Self.publishableOutcomes)
    func `publishable provider outcomes remain admitted`(outcome: DesktopActionOutcome) {
        #expect(throws: Never.self) {
            try ObservationActionResultSemantics.requirePublishableOutcome(
                outcome,
                targetIdentity: nil,
                operation: "Fixture observation",
                requiresOutcome: true)
        }
    }

    @Test
    func `required missing outcome becomes target-bound indeterminate failure`() throws {
        let target = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 542,
            processStartIdentity: 6542))

        do {
            try ObservationActionResultSemantics.requirePublishableOutcome(
                nil,
                targetIdentity: target,
                operation: "Fixture observation",
                requiresOutcome: true)
            Issue.record("Expected missing required outcome to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState == .mayHaveDispatched(unitCount: nil))
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == DesktopActionTargetReceipt(
                processIdentifier: 542,
                processStartIdentity: 6542))
        }
    }

    @Test
    func `read-only legacy observation may omit outcome`() {
        #expect(throws: Never.self) {
            try ObservationActionResultSemantics.requirePublishableOutcome(
                nil,
                targetIdentity: nil,
                operation: "Read-only observation",
                requiresOutcome: false)
        }
    }

    @Test
    func `provider and payload target mismatch preserves dispatched units as indeterminate`() throws {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let provider = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 543,
            processStartIdentity: 6543))
        let payload = Self.detectionResult(
            processIdentifier: 544,
            processStartIdentity: 6544,
            windowID: 73,
            bounds: bounds)
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))

        do {
            _ = try ObservationActionResultSemantics.coalescedTarget(
                actionTarget: provider,
                payload: payload,
                outcome: outcome,
                operation: "Fixture observation",
                requiresTarget: true)
            Issue.record("Expected contradictory provider and payload targets to fail")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == nil)
        }
    }

    @Test
    func `compatible process and exact payload coalesce to exact window`() throws {
        let bounds = CGRect(x: 30, y: 40, width: 500, height: 320)
        let provider = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: 545,
            processStartIdentity: 6545))
        let payload = Self.detectionResult(
            processIdentifier: 545,
            processStartIdentity: 6545,
            windowID: 74,
            bounds: bounds)

        let target = try ObservationActionResultSemantics.coalescedTarget(
            actionTarget: provider,
            payload: payload,
            outcome: .dispatchedUnverified(
                delivery: Self.delivery,
                evidence: .deliveryAccepted,
                unitCount: .one),
            operation: "Fixture observation",
            requiresTarget: true)

        #expect(target?.processIdentity == provider.processIdentity)
        #expect(target?.exactWindow?.identity.windowID == 74)
        #expect(target?.exactWindow?.bounds == bounds)
    }

    @Test
    func `read-only global payload remains targetless`() throws {
        let target = try ObservationActionResultSemantics.coalescedTarget(
            actionTarget: nil,
            payload: ElementDetectionResult(
                snapshotId: "global",
                screenshotPath: "",
                elements: DetectedElements(),
                metadata: DetectionMetadata(detectionTime: 0, elementCount: 0, method: "fixture")),
            outcome: nil,
            operation: "Global observation",
            requiresTarget: false)

        #expect(target == nil)
    }

    @Test
    func `menu-bar mutation target excludes the captured popover identity`() throws {
        let statusBounds = CGRect(x: 900, y: 0, width: 20, height: 20)
        let statusIdentity = WindowMutationIdentity(
            windowID: 70,
            ownerProcessIdentifier: 545,
            ownerProcessStartIdentity: 6545,
            capturedBounds: statusBounds)
        let statusTarget = try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: statusIdentity,
            bounds: statusBounds))
        let popoverBounds = CGRect(x: 700, y: 20, width: 240, height: 300)
        let popoverIdentity = WindowMutationIdentity(
            windowID: 71,
            ownerProcessIdentifier: 546,
            ownerProcessStartIdentity: 6546,
            capturedBounds: popoverBounds)
        let popoverApplication = ServiceApplicationInfo(
            processIdentifier: 546,
            processStartIdentity: 6546,
            bundleIdentifier: "dev.peekaboo.popover",
            name: "Popover")
        let popoverWindow = ServiceWindowInfo(
            windowID: 71,
            title: "Popover",
            bounds: popoverBounds,
            index: 0,
            mutationIdentity: popoverIdentity)
        let payload = DesktopObservationResult(
            target: ResolvedObservationTarget(
                kind: .menubarPopover,
                app: ApplicationIdentity(popoverApplication),
                window: WindowIdentity(popoverWindow),
                bounds: popoverBounds,
                detectionContext: WindowContext(
                    applicationProcessId: 546,
                    windowID: 71,
                    windowBounds: popoverBounds,
                    windowMutationIdentity: popoverIdentity),
                mutationTargetIdentity: DesktopObservationMutationTargetIdentity(statusTarget)),
            capture: CaptureResult(
                imageData: Data([1]),
                metadata: CaptureMetadata(
                    size: popoverBounds.size,
                    mode: .window,
                    applicationInfo: popoverApplication,
                    windowInfo: popoverWindow)),
            elements: nil)

        let target = try ObservationActionResultSemantics.coalescedTarget(
            actionTarget: statusTarget,
            payload: payload,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: DesktopActionOutcome.DispatchUnitCount(3)),
            operation: "Menu-bar popover observation",
            requiresTarget: true)

        #expect(target == statusTarget)
        #expect(target?.exactWindow?.identity.windowID == 70)
    }

    private static let delivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    private static let nonPublishableOutcomes: [DesktopActionOutcome] = [
        .refused(reason: .permissionDenied),
        .partial(delivery: Self.delivery, unitCount: DesktopActionOutcome.DispatchUnitCount(2)),
        .suspectedNoop(delivery: Self.delivery, unitCount: .one),
        .indeterminate(
            delivery: Self.delivery,
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3)),
    ]

    private static let publishableOutcomes: [DesktopActionOutcome] = [
        .confirmedChange(delivery: Self.delivery, unitCount: .one),
        .confirmedNoChange(),
        .dispatchedUnverified(delivery: Self.delivery, evidence: .deliveryAccepted, unitCount: .one),
    ]

    private static func detectionResult(
        processIdentifier: Int32,
        processStartIdentity: UInt64,
        windowID: Int,
        bounds: CGRect) -> ElementDetectionResult
    {
        let identity = WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: bounds)
        return ElementDetectionResult(
            snapshotId: "targeted",
            screenshotPath: "",
            elements: DetectedElements(),
            metadata: DetectionMetadata(
                detectionTime: 0,
                elementCount: 0,
                method: "fixture",
                windowContext: WindowContext(
                    applicationProcessId: processIdentifier,
                    windowID: windowID,
                    windowBounds: bounds,
                    windowMutationIdentity: identity)))
    }
}
