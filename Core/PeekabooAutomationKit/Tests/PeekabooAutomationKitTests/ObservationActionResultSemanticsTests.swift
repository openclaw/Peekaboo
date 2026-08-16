import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
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
        let payloadFixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 544, processStartIdentity: 6544),
            windowID: 73,
            bounds: bounds)
        let payload = AutomationTestFixtures.detectionResult(
            snapshotID: "targeted",
            screenshotPath: "",
            windowContext: payloadFixture.windowContext)
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
        let payloadFixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: provider.processIdentity,
            windowID: 74,
            bounds: bounds)
        let payload = AutomationTestFixtures.detectionResult(
            snapshotID: "targeted",
            screenshotPath: "",
            windowContext: payloadFixture.windowContext)

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
        let statusFixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 545, processStartIdentity: 6545),
            windowID: 70,
            bounds: statusBounds)
        let statusTarget = statusFixture.windowTargetIdentity
        let popoverBounds = CGRect(x: 700, y: 20, width: 240, height: 300)
        let popoverFixture = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 546, processStartIdentity: 6546),
            bundleIdentifier: "dev.peekaboo.popover",
            applicationName: "Popover",
            windowID: 71,
            windowTitle: "Popover",
            bounds: popoverBounds,
            isMainWindow: false)
        let payload = DesktopObservationResult(
            target: ResolvedObservationTarget(
                kind: .menubarPopover,
                app: ApplicationIdentity(popoverFixture.application),
                window: WindowIdentity(popoverFixture.window),
                bounds: popoverBounds,
                detectionContext: popoverFixture.windowContext,
                mutationTargetIdentity: DesktopObservationMutationTargetIdentity(statusTarget)),
            capture: CaptureResult(
                imageData: Data([1]),
                metadata: CaptureMetadata(
                    size: popoverBounds.size,
                    mode: .window,
                    applicationInfo: popoverFixture.application,
                    windowInfo: popoverFixture.window)),
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

    @Test
    func `generic failures reject selected leaves from an unrelated target`() throws {
        let phase = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 545, processStartIdentity: 6545),
            windowID: 70)
        let unrelated = AutomationTestFixtures.linkedDesktopTarget(
            processIdentity: .init(processIdentifier: 546, processStartIdentity: 6546),
            windowID: 71)
        let evidence = try DesktopSelectedLeafEvidence(
            kind: .menuBarItem,
            normalizedSelector: "fixture",
            matchKind: .exact,
            selectedTargetReceipt: unrelated.windowTargetReceipt,
            selectedIndex: 0,
            selectedTitle: "Fixture",
            selectedIdentifier: "fixture.item",
            selectedRole: "AXMenuBarItem",
            selectedFrame: CGRect(x: 0, y: 0, width: 18, height: 18),
            candidateSetSHA256: DesktopSelectedLeafEvidence.digestCandidateSet(["fixture"]),
            candidateCount: 1)
        let result = UIAutomationActionResult(
            payload: (),
            outcome: DesktopActionOutcome.dispatchedUnverified(
                delivery: Self.delivery,
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: phase.windowTargetIdentity,
            selectedLeafEvidence: [evidence])

        let preserved = ObservationActionResultSemantics.preservingFailure(
            FixtureError.failed,
            after: result,
            operation: "Fixture observation")
        let failure = try #require(preserved as? DesktopActionFailure)

        #expect(failure.outcome.state == .dispatchedUnverified)
        #expect(failure.message == FixtureError.failed.localizedDescription)
        #expect(failure.causeDescription == String(describing: FixtureError.failed))
        #expect(failure.targetReceipt == phase.windowTargetReceipt)
        #expect(failure.selectedLeafEvidence == nil)
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

    private enum FixtureError: Error {
        case failed
    }
}
