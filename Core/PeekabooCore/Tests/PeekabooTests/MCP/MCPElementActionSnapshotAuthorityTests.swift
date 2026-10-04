import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomationKit

@MainActor
@Suite(.serialized)
struct MCPElementActionSnapshotAuthorityTests {
    @Test(arguments: [false, true], [false, true])
    func `confirmed results validate inside the lease before invalidating implicit latest`(
        noChange: Bool,
        requireExactWindow: Bool) async throws
    {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let snapshot = try #require(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID))
        let expected = try MCPElementActionSnapshotAuthority.expectedTargetIdentity(
            snapshot,
            requireExactWindow: requireExactWindow)
        let suppliedTarget = try #require(fixture.automation.uiAutomationOutcomeTargetIdentity)
        let outcome = noChange ? DesktopActionOutcome.confirmedNoChange() : Self.confirmedChange
        let supplied = Self.result(outcome: outcome, target: suppliedTarget)
        var events: [String] = []

        let completed = try await MCPElementActionSnapshotAuthority.withConfirmedMutation(
            snapshot: snapshot,
            expectedTarget: expected,
            context: fixture.context,
            operation: "Synthetic element mutation",
            mutate: {
                events.append("mutate")
                #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
                #expect(fixture.snapshots.finishCalls.isEmpty)
                await #expect(throws: PeekabooError.self) {
                    _ = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
                }
                #expect(await fixture.context.uiSnapshots.getSnapshot(id: nil)?.id == fixture.snapshotID)
                return supplied
            },
            validateResult: { result in
                events.append("validate")
                #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
                #expect(fixture.snapshots.finishCalls.isEmpty)
                #expect(result.outcome == outcome)
                #expect(result.targetIdentity == suppliedTarget)
                #expect(result.payload.target == "T1")
            })

        #expect(events == ["mutate", "validate"])
        #expect(completed.result.outcome == supplied.outcome)
        #expect(completed.result.targetIdentity == supplied.targetIdentity)
        #expect(completed.result.payload.actionName == supplied.payload.actionName)
        #expect(completed.result.payload.newValue == supplied.payload.newValue)
        #expect(completed.invalidatedSnapshotID == (noChange ? nil : fixture.snapshotID))
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == false)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: nil)?.id == (noChange ? fixture.snapshotID : nil))
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID) != nil)
        try await Self.expectReusable(fixture)
    }

    @Test(arguments: [false, true])
    func `pending and consumed leases reject before either caller closure`(consumed: Bool) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let snapshot = try #require(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID))
        let expected = try MCPElementActionSnapshotAuthority.expectedTargetIdentity(snapshot, requireExactWindow: true)
        let lease = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        if consumed {
            try await fixture.storage.finishSnapshotMutation(lease, requiresFreshObservation: true)
        }
        var mutationCalls = 0
        var validationCalls = 0

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await MCPElementActionSnapshotAuthority.withConfirmedMutation(
                snapshot: snapshot,
                expectedTarget: expected,
                context: fixture.context,
                operation: "Synthetic element mutation",
                mutate: {
                    mutationCalls += 1
                    return Self.result(outcome: Self.confirmedChange, target: expected)
                },
                validateResult: { _ in validationCalls += 1 })
        }

        #expect(failure?.outcome.refusalReason == .targetUnavailable)
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(failure?.targetReceipt == expected.actionTargetReceipt)
        #expect(mutationCalls == 0 && validationCalls == 0)
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.isEmpty)
    }

    @Test(arguments: RejectedResult.allCases)
    func `canonical outcome and target gates precede caller validation`(rejected: RejectedResult) async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let snapshot = try #require(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID))
        let expected = try MCPElementActionSnapshotAuthority.expectedTargetIdentity(snapshot, requireExactWindow: true)
        let supplied = rejected.result(expected: expected)
        var mutationCalls = 0
        var validationCalls = 0

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await MCPElementActionSnapshotAuthority.withConfirmedMutation(
                snapshot: snapshot,
                expectedTarget: expected,
                context: fixture.context,
                operation: "Synthetic element mutation",
                mutate: {
                    mutationCalls += 1
                    return supplied
                },
                validateResult: { _ in validationCalls += 1 })
        }

        #expect(failure?.outcome.retrySafety == .unsafe)
        #expect(failure?.outcome.projection.requiresFreshObservation == true)
        #expect(mutationCalls == 1 && validationCalls == 0)
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == true)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: nil)?.id == fixture.snapshotID)
        try await Self.expectNotReusable(fixture)
    }

    @Test
    func `caller validation failure consumes the lease without replacing the failure`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let snapshot = try #require(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID))
        let expected = try MCPElementActionSnapshotAuthority.expectedTargetIdentity(snapshot, requireExactWindow: true)
        let suppliedFailure = DesktopActionFailure.indeterminate(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Synthetic typed result mismatch",
            hint: "Observe the exact target")
            .attributed(to: expected.actionTargetReceipt)
        var validationCalls = 0

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await MCPElementActionSnapshotAuthority.withConfirmedMutation(
                snapshot: snapshot,
                expectedTarget: expected,
                context: fixture.context,
                operation: "Synthetic element mutation",
                mutate: { Self.result(outcome: Self.confirmedChange, target: expected) },
                validateResult: { _ in
                    validationCalls += 1
                    #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
                    #expect(fixture.snapshots.finishCalls.isEmpty)
                    throw suppliedFailure
                })
        }

        #expect(failure == suppliedFailure)
        #expect(validationCalls == 1)
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == true)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: nil)?.id == fixture.snapshotID)
        try await Self.expectNotReusable(fixture)
    }

    @Test
    func `canonical predispatch refusal escapes unchanged and leaves authority reusable`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let snapshot = try #require(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID))
        let expected = try MCPElementActionSnapshotAuthority.expectedTargetIdentity(snapshot, requireExactWindow: true)
        let suppliedFailure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Synthetic refusal before input")
            .attributed(to: expected.actionTargetReceipt)

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await MCPElementActionSnapshotAuthority.withConfirmedMutation(
                snapshot: snapshot,
                expectedTarget: expected,
                context: fixture.context,
                operation: "Synthetic element mutation",
                mutate: { throw suppliedFailure })
        }

        #expect(failure == suppliedFailure)
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == false)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: nil)?.id == fixture.snapshotID)
        try await Self.expectReusable(fixture)
    }

    @Test(arguments: [false, true], [false, true])
    func `unknown errors and cancellation from either closure leave the lease pending`(
        cancellation: Bool,
        duringValidation: Bool) async throws
    {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let snapshot = try #require(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID))
        let expected = try MCPElementActionSnapshotAuthority.expectedTargetIdentity(snapshot, requireExactWindow: true)
        let suppliedError: any Error = cancellation ? CancellationError() : SyntheticError.completionUnknown
        var validationCalls = 0

        do {
            _ = try await MCPElementActionSnapshotAuthority.withConfirmedMutation(
                snapshot: snapshot,
                expectedTarget: expected,
                context: fixture.context,
                operation: "Synthetic element mutation",
                mutate: {
                    if !duringValidation {
                        throw suppliedError
                    }
                    return Self.result(outcome: Self.confirmedChange, target: expected)
                },
                validateResult: { _ in
                    validationCalls += 1
                    throw suppliedError
                })
            Issue.record("Unknown completion must not return success")
        } catch {
            if cancellation {
                #expect(error is CancellationError)
            } else {
                #expect(error as? SyntheticError == .completionUnknown)
            }
        }

        #expect(validationCalls == (duringValidation ? 1 : 0))
        #expect(fixture.snapshots.beginCalls == [fixture.snapshotID])
        #expect(fixture.snapshots.finishCalls.isEmpty)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: nil)?.id == fixture.snapshotID)
        try await Self.expectNotReusable(fixture)
    }

    @Test
    func `lease finalization failure prevents success and implicit invalidation`() async throws {
        let fixture = try await MCPSnapshotMutationTestFixture.make()
        let snapshot = try #require(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID))
        let expected = try MCPElementActionSnapshotAuthority.expectedTargetIdentity(snapshot, requireExactWindow: true)
        fixture.snapshots.failFinish = true
        var validationCalls = 0

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await MCPElementActionSnapshotAuthority.withConfirmedMutation(
                snapshot: snapshot,
                expectedTarget: expected,
                context: fixture.context,
                operation: "Synthetic element mutation",
                mutate: { Self.result(outcome: Self.confirmedChange, target: expected) },
                validateResult: { _ in validationCalls += 1 })
        }

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.retrySafety == .unsafe)
        #expect(failure?.targetReceipt == expected.actionTargetReceipt)
        #expect(validationCalls == 1)
        #expect(fixture.snapshots.finishCalls.count == 1)
        #expect(fixture.snapshots.finishCalls.first?.requiresFreshObservation == false)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: nil)?.id == fixture.snapshotID)
        try await Self.expectNotReusable(fixture)
    }

    private static var confirmedChange: DesktopActionOutcome {
        .confirmedChange(delivery: .init(mechanism: .accessibilityValue, mode: .background), unitCount: .one)
    }

    private static func result(
        outcome: DesktopActionOutcome?,
        target: DesktopTargetIdentity?) -> UIAutomationActionResult<ElementActionResult>
    {
        UIAutomationActionResult(
            payload: .init(target: "T1", actionName: "AXSetValue", anchorPoint: nil, newValue: "synthetic value"),
            outcome: outcome,
            targetIdentity: target)
    }

    private static func expectReusable(_ fixture: MCPSnapshotMutationTestFixture) async throws {
        let lease = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        try await fixture.storage.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    private static func expectNotReusable(_ fixture: MCPSnapshotMutationTestFixture) async throws {
        await #expect(throws: PeekabooError.self) {
            _ = try await fixture.storage.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        }
        #expect(try await fixture.snapshots.getDetectionResult(snapshotId: fixture.snapshotID) != nil)
        #expect(await fixture.context.uiSnapshots.getSnapshot(id: fixture.snapshotID) != nil)
    }

    private enum SyntheticError: Error, Equatable {
        case completionUnknown
    }

    enum RejectedResult: String, CaseIterable, Sendable {
        case unverified, missingOutcome, missingTarget, foreignTarget, foreground

        @MainActor
        func result(expected: DesktopTargetIdentity) -> UIAutomationActionResult<ElementActionResult> {
            let outcome: DesktopActionOutcome? = switch self {
            case .unverified:
                .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityValue, mode: .background),
                    evidence: .deliveryAccepted)
            case .missingOutcome:
                nil
            case .foreground:
                .confirmedChange(delivery: .init(mechanism: .globalEvents, mode: .foreground), unitCount: .one)
            case .missingTarget, .foreignTarget:
                MCPElementActionSnapshotAuthorityTests.confirmedChange
            }
            let target: DesktopTargetIdentity? = switch self {
            case .missingTarget: nil
            case .foreignTarget: AutomationTestFixtures.linkedDesktopTarget().windowTargetIdentity
            default: expected
            }
            return MCPElementActionSnapshotAuthorityTests.result(outcome: outcome, target: target)
        }
    }
}
