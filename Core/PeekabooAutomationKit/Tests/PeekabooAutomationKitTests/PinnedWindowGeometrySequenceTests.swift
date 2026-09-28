import ApplicationServices
import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct PinnedWindowGeometrySequenceTests {
    @Test
    func `queued native fixture exposes back-to-back geometry loss`() async throws {
        let fixture = GeometrySequenceFixture()
        let admission = fixture.admission()
        _ = try await fixture.dispatch(fixture.identity, .position(fixture.target.origin), admission)
        _ = try await fixture.dispatch(fixture.identity, .size(fixture.target.size), admission)
        let final = try await fixture.repin(fixture.identity, fixture.target, admission.deadline)
        #expect(final.capturedBounds?.origin == fixture.original.origin)
        #expect(final.capturedBounds != fixture.target)
    }

    @Test
    func `size waits for acknowledged intermediate layout before using the new receipt`() async throws {
        let fixture = GeometrySequenceFixture()
        fixture.holdFirstRepin = true
        let task = fixture.start()
        await fixture.entered.wait()
        #expect(fixture.writes == [.position(fixture.target.origin)])
        #expect(fixture.frame == fixture.original)
        await fixture.release.open()
        let result = try await task.value
        #expect(result == .definite(unitCount: .init(2)))
        #expect(fixture.frame == fixture.target)
        #expect(fixture.receipts[1].capturedBounds == CGRect(
            origin: fixture.target.origin,
            size: fixture.original.size))
        #expect(fixture.deadlines.count == 2)
        #expect(fixture.deadlines[0] == fixture.deadlines[1])
        #expect(fixture.requestedBounds == [
            CGRect(origin: fixture.target.origin, size: fixture.original.size),
            fixture.target,
        ])
    }

    @Test(arguments: [0, 1, 2])
    func `unchanged components do not issue redundant native writes`(changedComponents: Int) async throws {
        let fixture = GeometrySequenceFixture()
        if changedComponents == 0 {
            fixture.target = fixture.original
        }
        if changedComponents == 1 {
            fixture.target.origin = fixture.original.origin
        }
        let result = try await fixture.run()
        #expect(fixture.writes.count == changedComponents)
        if changedComponents == 0 {
            #expect(result == .none)
        } else {
            #expect(result == .definite(unitCount: .init(changedComponents)))
        }
    }

    @Test(arguments: [false, true])
    func `unchanged minimized geometry requires fresh exact target validation`(liveTarget: Bool) async throws {
        let fixture = GeometrySequenceFixture()
        fixture.target = fixture.original
        fixture.minimized = true
        fixture.noChangeTargetValid = liveTarget
        if liveTarget {
            #expect(try await fixture.run() == .none)
        } else {
            let failure = try await self.failure(from: fixture.start())
            #expect(failure.mutation == .none)
        }
        #expect(fixture.noChangeValidationCount == 1)
        #expect(fixture.writes.isEmpty)
    }

    @Test(arguments: [1, 2])
    func `unknown completion stops without readback promotion and preserves the possible prefix`(
        unknownWrite: Int) async throws
    {
        let fixture = GeometrySequenceFixture()
        fixture.unknownWrite = unknownWrite
        let failure = try await self.failure(from: fixture.start())
        #expect(failure.mutation == .possible(unitCount: .init(unknownWrite)))
        let canonical = try #require(WindowManagementActionOutcome.geometryFailure(
            action: "set window bounds", failure: failure) as? DesktopActionFailure)
        #expect(canonical.outcome.state == .indeterminate)
        #expect(canonical.outcome.retrySafety == .unsafe)
        #expect(canonical.outcome.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(unknownWrite))
        #expect(fixture.writes.count == unknownWrite)
        #expect(fixture.deadlines.count == unknownWrite - 1)
        #expect(fixture.pending.isEmpty)
    }

    @Test(arguments: [1, 2])
    func `native identity loss keeps accepted writes but prevents further work`(lostAfterWrite: Int) async throws {
        let fixture = GeometrySequenceFixture()
        fixture.lostAfterWrite = lostAfterWrite
        let failure = try await self.failure(from: fixture.start())
        #expect(failure.mutation == .definite(unitCount: .init(lostAfterWrite)))
        #expect(fixture.writes.count == lostAfterWrite)
        #expect(fixture.deadlines.count == lostAfterWrite - 1)
    }

    @Test(arguments: GeometryReceiptMismatch.allCases, [1, 2])
    private func `readback cannot repin a different lifetime or arbitrary bounds`(
        mismatch: GeometryReceiptMismatch,
        phase: Int) async throws
    {
        let fixture = GeometrySequenceFixture()
        fixture.mismatch = (phase, mismatch)
        let failure = try await self.failure(from: fixture.start())
        #expect(failure.mutation == .definite(unitCount: .init(phase)))
        #expect(fixture.writes.count == phase)
    }

    @Test(arguments: [1, 2])
    func `late readback cannot extend the shared geometry deadline`(expiredAfterRepin: Int) async throws {
        let fixture = GeometrySequenceFixture()
        fixture.expiredAfterRepin = expiredAfterRepin
        let failure = try await self.failure(from: fixture.start())
        #expect(failure.mutation == .definite(unitCount: .init(expiredAfterRepin)))
        #expect(fixture.writes.count == expiredAfterRepin)
        #expect(fixture.deadlines.allSatisfy { $0 == fixture.initialTime.advanced(by: .seconds(2)) })
    }

    @Test
    func `unsettled position never dispatches resize`() async throws {
        let fixture = GeometrySequenceFixture()
        fixture.rejectFirstRepin = true
        let failure = try await self.failure(from: fixture.start())
        #expect(failure.mutation == .definite(unitCount: .one))
        #expect(fixture.writes.count == 1)
        #expect(fixture.frame == fixture.original)
        let canonical = try #require(WindowManagementActionOutcome.geometryFailure(
            action: "set window bounds", failure: failure) as? DesktopActionFailure)
        #expect(canonical.outcome.state == .dispatchedUnverified)
        #expect(canonical.outcome.evidence == .deliveryAccepted)
        #expect(canonical.outcome.retrySafety == .unsafe)
        #expect(canonical.outcome.dispatchState.unitCount == .one)
    }

    @Test
    func `cancellation during pending layout retains the accepted position only`() async throws {
        let fixture = GeometrySequenceFixture()
        fixture.holdFirstRepin = true
        let task = fixture.start()
        await fixture.entered.wait()
        task.cancel()
        await fixture.release.open()
        let failure = try await self.failure(from: task)
        #expect(failure.cause is CancellationError)
        #expect(failure.mutation == .definite(unitCount: .one))
        #expect(fixture.writes.count == 1)
    }

    @Test(arguments: [false, true], [false, true])
    func `detached native admission observes cancellation or expiry and drains claimed calls`(
        claimedBeforePause: Bool,
        cancel: Bool) async throws
    {
        let fixture = GeometrySequenceFixture()
        let entered = AsyncTestLatch()
        let release = AsyncTestLatch()
        let finished = AsyncTestLatch()
        let writes = AutomationTestLockedValue(0)
        let clock = fixture.clock
        let operations = PinnedWindowGeometryOperations(
            dispatch: { _, _, admission in
                await Task.detached {
                    if claimedBeforePause, admission.claimWrite() {
                        writes.withValue { $0 += 1 }
                    }
                    await entered.open()
                    await release.wait()
                    if !claimedBeforePause, admission.claimWrite() {
                        writes.withValue { $0 += 1 }
                    }
                    return PinnedWindowGeometryDispatch(
                        state: writes.value > 0 ? .accepted : .notDispatched,
                        identityRemainedPinned: true)
                }.value
            },
            repin: { identity, bounds, _ in
                fixture.receipt(bounds: bounds, original: identity)
            },
            validateNoChange: { _, _ in true },
            now: { clock.value })
        let task = Task {
            do {
                let result = try await completePinnedWindowGeometry(
                    expectedIdentity: fixture.identity,
                    bounds: fixture.target,
                    operations: operations)
                await finished.open()
                await entered.open()
                return result
            } catch {
                await finished.open()
                await entered.open()
                throw error
            }
        }
        await entered.wait()
        if cancel {
            task.cancel()
        } else {
            clock.value = fixture.initialTime.advanced(by: .seconds(3))
        }
        #expect(await finished.isOpen == false)
        await release.open()
        let failure = try await self.failure(from: task)
        #expect(writes.value == (claimedBeforePause ? 1 : 0))
        #expect(failure.mutation == (claimedBeforePause ? .definite(unitCount: .one) : .none))
        if cancel {
            #expect(failure.cause is CancellationError)
            if !claimedBeforePause {
                #expect(WindowManagementActionOutcome.geometryFailure(
                    action: "set window bounds", failure: failure) is CancellationError)
            }
        }
    }

    @Test(arguments: [AXError.cannotComplete, .failure, .noValue])
    func `unacknowledged native errors retain possible delivery`(error: AXError) {
        let dispatch = PinnedWindowGeometryDispatch(nativeResult: error, identityRemainedPinned: true)
        #expect(dispatch.state == .completionUnknown)
    }

    @Test(arguments: [AXError.attributeUnsupported, .actionUnsupported, .invalidUIElement, .apiDisabled])
    func `definitive native rejection does not invent delivery`(error: AXError) {
        let dispatch = PinnedWindowGeometryDispatch(nativeResult: error, identityRemainedPinned: true)
        #expect(dispatch.state == .notDispatched)
    }

    private func failure(
        from task: Task<DesktopActionMutationDisposition, any Error>) async throws -> PinnedWindowGeometryFailure
    {
        do {
            _ = try await task.value
            throw GeometrySequenceTestError.unexpectedSuccess
        } catch let failure as PinnedWindowGeometryFailure {
            return failure
        }
    }
}

private enum GeometryReceiptMismatch: CaseIterable, Sendable {
    case process, generation, window, bounds, missingBounds
}

private enum GeometrySequenceTestError: Error {
    case notSettled, unexpectedSuccess
}

@MainActor
private final class GeometrySequenceFixture {
    let original = CGRect(x: 720, y: 30, width: 1200, height: 852)
    var target = CGRect(x: 0, y: 30, width: 1920, height: 998)
    var frame = CGRect(x: 720, y: 30, width: 1200, height: 852)
    let initialTime = ContinuousClock.now
    let clock: AutomationTestLockedValue<ContinuousClock.Instant>
    let entered = AsyncTestLatch()
    let release = AsyncTestLatch()
    var holdFirstRepin = false
    var rejectFirstRepin = false
    var unknownWrite: Int?
    var lostAfterWrite: Int?
    var expiredAfterRepin: Int?
    var mismatch: (Int, GeometryReceiptMismatch)?
    var pending: [CGRect] = []
    var writes: [PinnedWindowGeometryValue] = []
    var receipts: [WindowMutationIdentity] = []
    var deadlines: [ContinuousClock.Instant] = []
    var requestedBounds: [CGRect] = []
    var minimized = false
    var noChangeTargetValid = true
    var noChangeValidationCount = 0

    init() {
        self.clock = AutomationTestLockedValue(self.initialTime)
    }

    var identity: WindowMutationIdentity {
        self.receipt(bounds: self.original)
    }

    func receipt(bounds: CGRect, original: WindowMutationIdentity? = nil) -> WindowMutationIdentity {
        WindowMutationIdentity(
            windowID: original?.windowID ?? 924,
            ownerProcessIdentifier: original?.ownerProcessIdentifier ?? 42,
            ownerProcessStartIdentity: original?.ownerProcessStartIdentity ?? 7,
            capturedBounds: bounds,
            isMinimized: self.minimized)
    }

    func admission() -> PinnedWindowGeometryAdmission {
        let clock = self.clock
        return PinnedWindowGeometryAdmission(
            deadline: self.initialTime.advanced(by: .seconds(2)),
            now: { clock.value })
    }

    func dispatch(
        _ identity: WindowMutationIdentity,
        _ value: PinnedWindowGeometryValue,
        _ admission: PinnedWindowGeometryAdmission) async throws -> PinnedWindowGeometryDispatch
    {
        guard admission.claimWrite() else { return .notDispatched }
        self.receipts.append(identity)
        self.writes.append(value)
        let next = switch value {
        case let .position(point): CGRect(origin: point, size: self.frame.size)
        case let .size(size): CGRect(origin: self.frame.origin, size: size)
        }
        if self.unknownWrite == self.writes.count {
            self.frame = next
            return .init(state: .completionUnknown, identityRemainedPinned: true)
        }
        self.pending.append(next)
        return .init(state: .accepted, identityRemainedPinned: self.lostAfterWrite != self.writes.count)
    }

    func repin(
        _ identity: WindowMutationIdentity,
        _ bounds: CGRect,
        _ deadline: ContinuousClock.Instant) async throws -> WindowMutationIdentity
    {
        self.deadlines.append(deadline)
        self.requestedBounds.append(bounds)
        if self.deadlines.count == 1 {
            await self.entered.open()
            if self.holdFirstRepin {
                await self.release.wait()
            }
            if self.rejectFirstRepin {
                throw GeometrySequenceTestError.notSettled
            }
        }
        for pending in self.pending {
            self.frame = pending
        }
        self.pending.removeAll()
        if self.expiredAfterRepin == self.deadlines.count {
            self.clock.value = self.initialTime.advanced(by: .seconds(3))
        }
        if let (phase, mismatch) = self.mismatch, phase == self.deadlines.count {
            return WindowMutationIdentity(
                windowID: mismatch == .window ? 925 : identity.windowID,
                ownerProcessIdentifier: mismatch == .process ? 43 : identity.ownerProcessIdentifier,
                ownerProcessStartIdentity: mismatch == .generation ? 8 : identity.ownerProcessStartIdentity,
                capturedBounds: mismatch == .missingBounds ? nil : mismatch == .bounds ? .zero : self.frame)
        }
        return self.receipt(bounds: self.frame, original: identity)
    }

    func run() async throws -> DesktopActionMutationDisposition {
        let clock = self.clock
        return try await completePinnedWindowGeometry(
            expectedIdentity: self.identity,
            bounds: self.target,
            operations: PinnedWindowGeometryOperations(
                dispatch: self.dispatch,
                repin: self.repin,
                validateNoChange: { identity, admission in
                    self.noChangeValidationCount += 1
                    try admission.check()
                    return self.noChangeTargetValid && identity.capturedBounds == self.frame
                },
                now: { clock.value }))
    }

    func start() -> Task<DesktopActionMutationDisposition, any Error> {
        Task {
            do {
                let result = try await self.run()
                await self.entered.open()
                return result
            } catch {
                await self.entered.open()
                throw error
            }
        }
    }
}
