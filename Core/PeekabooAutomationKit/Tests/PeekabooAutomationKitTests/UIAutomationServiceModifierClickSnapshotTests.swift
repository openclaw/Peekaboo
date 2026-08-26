import CoreGraphics
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct UIAutomationServiceModifierClickSnapshotTests {
    @Test
    func `service owns the modifier click snapshot lease before foreground work`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager.containing(fixture.detectionResult))
        let service = UIAutomationService(snapshotManager: manager)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let heldLease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)

        do {
            _ = try await service.foregroundModifierClickWithOutcome(Self.request(
                fixture.snapshotID,
                exactWindow: exactWindow))
            Issue.record("Expected the service-owned lease attempt to reject concurrent replay")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }

        try await manager.finishSnapshotMutation(heldLease, requiresFreshObservation: false)
        #expect(manager.beginCalls == [fixture.snapshotID, fixture.snapshotID])
    }

    @Test
    func `mismatched snapshot authority refuses and releases the unused lease`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager.containing(fixture.detectionResult))
        let service = UIAutomationService(snapshotManager: manager)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let otherBounds = CGRect(x: 900, y: 900, width: 200, height: 200)
        let otherIdentity = WindowMutationIdentity(
            windowID: exactWindow.identity.windowID + 1,
            ownerProcessIdentifier: exactWindow.identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: exactWindow.identity.ownerProcessStartIdentity,
            capturedBounds: otherBounds)
        let otherWindow = try UIAutomationTarget.ExactWindow(identity: otherIdentity, bounds: otherBounds)

        do {
            _ = try await service.foregroundModifierClickWithOutcome(Self.request(
                fixture.snapshotID,
                point: CGPoint(x: 950, y: 950),
                exactWindow: otherWindow))
            Issue.record("Expected mismatched snapshot authority to refuse before foreground work")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: otherWindow).actionTargetReceipt)
        }

        let retryLease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(retryLease, requiresFreshObservation: false)
        #expect(manager.finishCalls.first?.requiresFreshObservation == false)
    }

    @Test
    func `blank and consumed modifier click snapshots refuse before foreground work`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager.containing(fixture.detectionResult))
        let service = UIAutomationService(snapshotManager: manager)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)

        do {
            _ = try await service.foregroundModifierClickWithOutcome(Self.request(
                "   ",
                exactWindow: exactWindow))
            Issue.record("Expected a blank snapshot identifier to refuse")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .invalidRequest)
            #expect(failure.outcome.dispatchState == .none)
        }

        do {
            _ = try await service.foregroundModifierClickWithOutcome(Self.request(
                "missing-snapshot",
                exactWindow: exactWindow))
            Issue.record("Expected a missing host snapshot to refuse")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .targetUnavailable)
            #expect(failure.outcome.dispatchState == .none)
        }

        let consumedLease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(consumedLease, requiresFreshObservation: true)
        do {
            _ = try await service.foregroundModifierClickWithOutcome(Self.request(
                fixture.snapshotID,
                exactWindow: exactWindow))
            Issue.record("Expected a consumed snapshot to refuse")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
    }

    @Test
    func `successful host operation consumes one lease and blocks replay`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager.containing(fixture.detectionResult))
        let service = UIAutomationService(snapshotManager: manager)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        var operationCount = 0

        let result = try await service.withModifierClickSnapshotLease(Self.request(
            fixture.snapshotID,
            exactWindow: exactWindow))
        {
            operationCount += 1
            return UIAutomationActionResult(
                payload: .init(cursorRestoration: .restored, focusRestoration: .restored),
                outcome: .dispatchedUnverified(
                    delivery: .init(mechanism: .composite, mode: .foreground),
                    evidence: .deliveryAccepted,
                    unitCount: .one),
                targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow))
        }

        #expect(result.outcome?.dispatchState == .dispatched(unitCount: .one))
        #expect(operationCount == 1)
        #expect(manager.beginCalls == [fixture.snapshotID])
        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == true)
        await #expect(throws: (any Error).self) {
            _ = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        }
    }

    @Test
    func `typed predispatch refusal releases the host lease for a safe retry`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager.containing(fixture.detectionResult))
        let service = UIAutomationService(snapshotManager: manager)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)

        do {
            _ = try await service.withModifierClickSnapshotLease(Self.request(
                fixture.snapshotID,
                exactWindow: exactWindow))
            {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Injected exact-target refusal")
            }
            Issue.record("Expected the typed predispatch refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }

        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == false)
        let retryLease = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await manager.finishSnapshotMutation(retryLease, requiresFreshObservation: false)
    }

    @Test(arguments: [false, true])
    func `raw operation error and cancellation consume the host lease`(cancel: Bool) async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager.containing(fixture.detectionResult))
        let service = UIAutomationService(snapshotManager: manager)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)

        do {
            _ = try await service.withModifierClickSnapshotLease(Self.request(
                fixture.snapshotID,
                exactWindow: exactWindow))
            {
                if cancel {
                    throw CancellationError()
                }
                throw ModifierClickSnapshotFixtureError.rawFailure
            }
            Issue.record("Expected an indeterminate raw operation failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }

        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == true)
        await #expect(throws: (any Error).self) {
            _ = try await manager.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        }
    }

    @Test
    func `lease finalization failure is exact target indeterminate`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager.containing(fixture.detectionResult))
        manager.failFinish = true
        let service = UIAutomationService(snapshotManager: manager)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)

        do {
            _ = try await service.withModifierClickSnapshotLease(Self.request(
                fixture.snapshotID,
                exactWindow: exactWindow))
            {
                UIAutomationActionResult(
                    payload: .init(cursorRestoration: .restored, focusRestoration: .restored),
                    outcome: .dispatchedUnverified(
                        delivery: .init(mechanism: .composite, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one),
                    targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow))
            }
            Issue.record("Expected lease finalization to fail closed")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }

        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == true)
    }

    @Test
    func `predispatch refusal cannot hide lease finalization failure`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager.containing(fixture.detectionResult))
        manager.failFinish = true
        let service = UIAutomationService(snapshotManager: manager)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)

        do {
            _ = try await service.withModifierClickSnapshotLease(Self.request(
                fixture.snapshotID,
                exactWindow: exactWindow))
            {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Injected exact-target refusal")
            }
            Issue.record("Expected failed refusal finalization to become indeterminate")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: exactWindow).actionTargetReceipt)
        }

        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == false)
    }

    @Test
    func `snapshot mismatch cannot hide lease finalization failure`() async throws {
        let fixture = AutomationTestFixtures.linkedSnapshotTarget()
        let manager = try await SnapshotMutationRecordingManager(
            wrapping: InMemorySnapshotManager.containing(fixture.detectionResult))
        manager.failFinish = true
        let service = UIAutomationService(snapshotManager: manager)
        let exactWindow = try #require(fixture.targetIdentity.exactWindow)
        let mismatchedBounds = exactWindow.bounds.offsetBy(dx: 1000, dy: 1000)
        let mismatchedIdentity = WindowMutationIdentity(
            windowID: exactWindow.identity.windowID + 1,
            ownerProcessIdentifier: exactWindow.identity.ownerProcessIdentifier,
            ownerProcessStartIdentity: exactWindow.identity.ownerProcessStartIdentity,
            capturedBounds: mismatchedBounds)
        let mismatchedWindow = try UIAutomationTarget.ExactWindow(
            identity: mismatchedIdentity,
            bounds: mismatchedBounds)

        do {
            _ = try await service.withModifierClickSnapshotLease(Self.request(
                fixture.snapshotID,
                point: mismatchedBounds.origin,
                exactWindow: mismatchedWindow))
            {
                Issue.record("Mismatched snapshot authority must refuse before operation entry")
                return UIAutomationActionResult(
                    payload: .init(cursorRestoration: .notNeeded, focusRestoration: .notNeeded),
                    outcome: nil)
            }
            Issue.record("Expected failed mismatch finalization to become indeterminate")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == DesktopTargetIdentity(exactWindow: mismatchedWindow).actionTargetReceipt)
        }

        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == false)
    }

    private static func request(
        _ snapshotID: String,
        point: CGPoint = CGPoint(x: 40, y: 50),
        exactWindow: UIAutomationTarget.ExactWindow) -> ForegroundModifierClickRequest
    {
        ForegroundModifierClickRequest(
            point: point,
            clickType: .single,
            modifiers: [.command],
            snapshotID: snapshotID,
            windowIdentity: exactWindow.identity,
            windowBounds: exactWindow.bounds)
    }
}

private enum ModifierClickSnapshotFixtureError: Error {
    case rawFailure
}
