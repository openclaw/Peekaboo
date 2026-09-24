import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct SnapshotMutationLifecycleTests {
    @Test(arguments: [false, true])
    func `pending and consumed disk leases refuse acquisition without hiding history`(
        consumed: Bool) async throws
    {
        let fixture = try await Self.diskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lease = try await fixture.first.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        if consumed {
            try await fixture.first.finishSnapshotMutation(lease, requiresFreshObservation: true)
            try await fixture.first.finishSnapshotMutation(lease, requiresFreshObservation: false)
        }
        let manager = SnapshotMutationRecordingManager(wrapping: fixture.second)
        var operationCalled = false
        var outcomeCalled = false

        let caught = await #expect(throws: DesktopActionFailure.self) {
            try await manager.withSnapshotMutation(
                snapshotId: " \n\(fixture.snapshotID) \n",
                targetIdentity: fixture.targetIdentity,
                operation: { operationCalled = true },
                outcome: { _ in
                    outcomeCalled = true
                    return .confirmedNoChange()
                })
        }

        let failure = try #require(caught)
        #expect(failure.standardErrorCode == .snapshotStale)
        #expect(failure.outcome.state == .refused)
        #expect(failure.outcome.dispatchState == .none)
        #expect(failure.outcome.retrySafety == .safe)
        #expect(failure.outcome.refusalReason == .targetUnavailable)
        #expect(failure.outcome.projection.requiresFreshObservation == false)
        #expect(failure.targetReceipt == fixture.targetIdentity.actionTargetReceipt)
        #expect(!operationCalled)
        #expect(!outcomeCalled)
        #expect(manager.beginCalls == [fixture.snapshotID])
        #expect(manager.finishCalls.isEmpty)
        #expect(try Self.receiptState(fixture) == (consumed ? "requiresFreshObservation" : "pending"))
        try await Self.expectHistoricalReads(fixture)
    }

    @Test(arguments: DesktopActionOutcomeFixtures.canonicalCases)
    func `successful operations finalize from the canonical outcome`(
        outcomeCase: CanonicalDesktopActionOutcomeCase) async throws
    {
        let fixture = try await Self.diskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = SnapshotMutationRecordingManager(wrapping: fixture.first)
        var operationCalls = 0
        var outcomeCalls = 0

        let value = try await manager.withSnapshotMutation(
            snapshotId: fixture.snapshotID,
            operation: {
                operationCalls += 1
                let receiptState = try Self.receiptState(fixture)
                #expect(receiptState == "pending")
                await #expect(throws: PeekabooError.self) {
                    _ = try await fixture.second.beginSnapshotMutation(snapshotId: fixture.snapshotID)
                }
                return "completed"
            },
            outcome: { result in
                outcomeCalls += 1
                #expect(result == "completed")
                return outcomeCase.outcome
            })

        #expect(value == "completed")
        #expect(operationCalls == 1)
        #expect(outcomeCalls == 1)
        #expect(manager.beginCalls == [fixture.snapshotID])
        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == outcomeCase.requiresFreshObservation)
        try await Self.expectEligibility(fixture, consumed: outcomeCase.requiresFreshObservation)
        try await Self.expectHistoricalReads(fixture)
    }

    @Test
    func `successful operation without a canonical outcome consumes the snapshot`() async throws {
        let fixture = try await Self.diskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = SnapshotMutationRecordingManager(wrapping: fixture.first)

        let value = try await manager.withSnapshotMutation(
            snapshotId: fixture.snapshotID,
            operation: { 42 },
            outcome: { _ in nil })

        #expect(value == 42)
        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == true)
        try await Self.expectEligibility(fixture, consumed: true)
        try await Self.expectHistoricalReads(fixture)
    }

    @Test(arguments: [false, true])
    func `composed disposition applies only when no canonical outcome exists`(
        requiresFreshObservation: Bool) async throws
    {
        let fixture = try await Self.diskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = SnapshotMutationRecordingManager(wrapping: fixture.first)

        _ = try await manager.withSnapshotMutation(
            snapshotId: fixture.snapshotID,
            operation: { requiresFreshObservation },
            outcome: { _ in nil },
            fallbackRequiresFreshObservation: { $0 })

        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == requiresFreshObservation)
        try await Self.expectEligibility(fixture, consumed: requiresFreshObservation)
        try await Self.expectHistoricalReads(fixture)
    }

    @Test(arguments: DesktopActionOutcomeFixtures.canonicalCases)
    func `canonical outcomes cannot be overridden by a conflicting fallback disposition`(
        outcomeCase: CanonicalDesktopActionOutcomeCase) async throws
    {
        let fixture = try await Self.diskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = SnapshotMutationRecordingManager(wrapping: fixture.first)
        var fallbackCalled = false

        _ = try await manager.withSnapshotMutation(
            snapshotId: fixture.snapshotID,
            operation: { outcomeCase.outcome },
            outcome: { $0 },
            fallbackRequiresFreshObservation: { _ in
                fallbackCalled = true
                return !outcomeCase.requiresFreshObservation
            })

        #expect(!fallbackCalled)
        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == outcomeCase.requiresFreshObservation)
        try await Self.expectEligibility(fixture, consumed: outcomeCase.requiresFreshObservation)
    }

    @Test(arguments: DesktopActionOutcomeFixtures.canonicalCases.filter(\.isFailureEligible))
    func `typed operation failures retain their identity and canonical lease disposition`(
        outcomeCase: CanonicalDesktopActionOutcomeCase) async throws
    {
        let fixture = try await Self.diskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = SnapshotMutationRecordingManager(wrapping: fixture.first)
        let expected = try #require(outcomeCase.failure)
        var outcomeCalled = false

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await manager.withSnapshotMutation(
                snapshotId: fixture.snapshotID,
                operation: { () async throws -> String in throw expected },
                outcome: { _ in
                    outcomeCalled = true
                    return .confirmedNoChange()
                })
        }

        #expect(failure == expected)
        #expect(!outcomeCalled)
        #expect(manager.beginCalls == [fixture.snapshotID])
        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == outcomeCase.requiresFreshObservation)
        try await Self.expectEligibility(fixture, consumed: outcomeCase.requiresFreshObservation)
        try await Self.expectHistoricalReads(fixture)
    }

    @Test
    func `proven receipt refusal releases the unused snapshot lease`() async throws {
        let fixture = try await Self.diskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = SnapshotMutationRecordingManager(wrapping: fixture.first)
        let refusal = SnapshotTargetReceiptPreDispatchError(.missingProcessGeneration)

        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await manager.withSnapshotMutation(
                snapshotId: fixture.snapshotID,
                operation: { () async throws -> String in throw refusal },
                outcome: { _ in
                    Issue.record("A thrown receipt refusal must not project a returned outcome")
                    return nil
                })
        }

        #expect(failure == refusal.actionFailure)
        #expect(manager.finishCalls.count == 1)
        #expect(manager.finishCalls.first?.requiresFreshObservation == false)
        try await Self.expectEligibility(fixture, consumed: false)
    }

    @Test(arguments: UnknownOperationFailure.allCases)
    func `unknown operation failures remain pending instead of becoming acquisition refusals`(
        failureCase: UnknownOperationFailure) async throws
    {
        let fixture = try await Self.diskFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let manager = SnapshotMutationRecordingManager(wrapping: fixture.first)
        var operationCalled = false

        let error = await #expect(throws: (any Error).self) {
            _ = try await manager.withSnapshotMutation(
                snapshotId: fixture.snapshotID,
                targetIdentity: fixture.targetIdentity,
                operation: { () async throws -> String in
                    operationCalled = true
                    throw failureCase.error
                },
                outcome: { _ in
                    Issue.record("An unknown operation failure must not project a returned outcome")
                    return nil
                })
        }

        #expect(operationCalled)
        #expect(!(error is DesktopActionFailure))
        switch failureCase {
        case .unexpected:
            #expect(error as? OperationError == .unexpected)
        case .stale:
            let raw = try #require(error as? PeekabooError)
            guard case let .snapshotStale(message) = raw else {
                Issue.record("Expected the original operation's snapshotStale error")
                return
            }
            #expect(message == "Operation completion is unknown")
        case .cancelled:
            #expect(error is CancellationError)
        }
        #expect(manager.beginCalls == [fixture.snapshotID])
        #expect(manager.finishCalls.isEmpty)
        #expect(try Self.receiptState(fixture) == "pending")
        await #expect(throws: PeekabooError.self) {
            _ = try await fixture.second.beginSnapshotMutation(snapshotId: fixture.snapshotID)
        }
        try await Self.expectHistoricalReads(fixture)
    }

    @Test(arguments: [nil, "", " \n\t "] as [String?])
    func `absent snapshot identifiers bypass lease acquisition and outcome projection`(
        snapshotID: String?) async throws
    {
        let manager = SnapshotMutationRecordingManager(wrapping: InMemorySnapshotManager())
        var operationCalls = 0

        let value = try await manager.withSnapshotMutation(
            snapshotId: snapshotID,
            operation: {
                operationCalls += 1
                return "snapshot-free"
            },
            outcome: { _ in
                Issue.record("A snapshot-free operation must bypass lease outcome projection")
                return nil
            })

        #expect(value == "snapshot-free")
        #expect(operationCalls == 1)
        #expect(manager.beginCalls.isEmpty)
        #expect(manager.finishCalls.isEmpty)
        #expect(manager.createCalls.isEmpty)
    }

    enum UnknownOperationFailure: CaseIterable, Sendable {
        case unexpected
        case stale
        case cancelled

        var error: any Error {
            switch self {
            case .unexpected: OperationError.unexpected
            case .stale: PeekabooError.snapshotStale("Operation completion is unknown")
            case .cancelled: CancellationError()
            }
        }
    }

    private enum OperationError: Error, Equatable {
        case unexpected
    }

    private struct DiskFixture {
        let root: URL
        let first: SnapshotManager
        let second: SnapshotManager
        let snapshotID: String
        let targetIdentity: DesktopTargetIdentity

        var receiptURL: URL {
            self.root.appendingPathComponent(self.snapshotID).appendingPathComponent("mutation-receipt.json")
        }
    }

    private struct StoredReceiptState: Decodable {
        let state: String
    }

    private static func diskFixture() async throws -> DiskFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-mutation-lifecycle-\(UUID().uuidString)", isDirectory: true)
        do {
            let first = SnapshotManager(snapshotStorageURL: root)
            let second = SnapshotManager(snapshotStorageURL: root)
            let snapshotID = try await first.createSnapshot()
            let target = AutomationTestFixtures.linkedSnapshotTarget(snapshotID: snapshotID)
            try await first.storeDetectionResult(
                snapshotId: snapshotID,
                result: AutomationTestFixtures.detectionResult(
                    snapshotID: snapshotID,
                    elements: DetectedElements(textFields: [
                        AutomationTestFixtures.detectedElement(id: "field", value: "historical-value"),
                    ]),
                    windowContext: target.desktopTarget.windowContext))
            let fixture = try DiskFixture(
                root: root,
                first: first,
                second: second,
                snapshotID: snapshotID,
                targetIdentity: target.targetIdentity)
            try await self.expectHistoricalReads(fixture)
            return fixture
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static func receiptState(_ fixture: DiskFixture) throws -> String {
        try JSONDecoder().decode(StoredReceiptState.self, from: Data(contentsOf: fixture.receiptURL)).state
    }

    private static func expectEligibility(_ fixture: DiskFixture, consumed: Bool) async throws {
        if consumed {
            #expect(try self.receiptState(fixture) == "requiresFreshObservation")
            await #expect(throws: PeekabooError.self) {
                _ = try await fixture.second.beginSnapshotMutation(snapshotId: fixture.snapshotID)
            }
        } else {
            #expect(!FileManager.default.fileExists(atPath: fixture.receiptURL.path))
            let lease = try await fixture.second.beginSnapshotMutation(snapshotId: fixture.snapshotID)
            try await fixture.second.finishSnapshotMutation(lease, requiresFreshObservation: false)
        }
    }

    private static func expectHistoricalReads(_ fixture: DiskFixture) async throws {
        for manager in [fixture.first, fixture.second] {
            let history = try #require(try await manager.getDetectionResult(snapshotId: fixture.snapshotID))
            #expect(history.snapshotId == fixture.snapshotID)
            #expect(history.elements.textFields.first?.value == "historical-value")
            #expect(try await manager.getElement(snapshotId: fixture.snapshotID, elementId: "field")?.value ==
                "historical-value")
        }
    }
}
