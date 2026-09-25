import Darwin
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

extension DesktopOperationLaneCoordinatorTests {
    private static let deadlineLockNames = [
        "global.turnstile.lock",
        "global.lock",
        "process-600-10.turnstile.lock",
        "process-600-10.lock",
        "window-600-10-131.turnstile.lock",
        "window-600-10-131.lock",
    ]

    @Test(arguments: [-1, 0, 1], Self.deadlineLockNames)
    func `Every successful lock admission respects the original deadline`(
        deadlineOffsetMilliseconds: Int,
        heldLockName: String) async throws
    {
        try await Self.withHeldDeadlineLock(named: heldLockName) { root, holder in
            let clock = AutomationTestLockedValue(ContinuousClock.now)
            let retries = AutomationTestLockedValue(0)
            let dispatched = AutomationTestLockedValue(false)
            let coordinator = DesktopOperationLaneCoordinator(
                coordinationRootURL: root,
                now: { clock.value },
                retrySleep: {
                    retries.withValue { $0 += 1 }
                    clock.withValue {
                        $0 = $0.advanced(by: .seconds(15) + .milliseconds(deadlineOffsetMilliseconds))
                    }
                    #expect(flock(holder, LOCK_UN) == 0)
                })

            do {
                try await coordinator.run(scope: .window(Self.window(windowID: 131)), access: .write) {
                    dispatched.value = true
                }
                #expect(deadlineOffsetMilliseconds < 0, "A deadline-expired admission must not succeed")
            } catch let failure as DesktopActionFailure {
                #expect(deadlineOffsetMilliseconds >= 0, "Admission before the deadline must remain available")
                Self.expectAdmissionTimeout(failure, path: root.appendingPathComponent(heldLockName).path)
            }

            #expect(retries.value == 1)
            #expect(dispatched.value == (deadlineOffsetMilliseconds < 0))
            try Self.expectDeadlineLocksReleased(in: root)
            let recovered = try await coordinator.run(scope: .window(Self.window(windowID: 131)), access: .write) {
                true
            }
            #expect(recovered)
        }
    }

    @Test
    func `Cancellation wins before late successful admission and releases all claims`() async throws {
        try await Self.withHeldDeadlineLock(named: "window-600-10-131.lock") { root, holder in
            let waiting = AsyncTestLatch()
            let resume = AsyncTestLatch()
            let dispatched = AutomationTestLockedValue(false)
            let clock = AutomationTestLockedValue(ContinuousClock.now)
            let coordinator = DesktopOperationLaneCoordinator(
                coordinationRootURL: root,
                now: { clock.value },
                retrySleep: {
                    await waiting.open()
                    await resume.wait()
                })
            let waiter = Task {
                try await coordinator.run(scope: .window(Self.window(windowID: 131)), access: .write) {
                    dispatched.value = true
                }
            }
            let reachedWait = await waiting.opensWithin(.seconds(1))
            waiter.cancel()
            clock.withValue { $0 = $0.advanced(by: .seconds(16)) }
            #expect(flock(holder, LOCK_UN) == 0)
            await resume.open()

            await #expect(throws: CancellationError.self) {
                try await waiter.value
            }
            #expect(reachedWait)
            #expect(!dispatched.value)
            try Self.expectDeadlineLocksReleased(in: root)
        }
    }

    @Test
    @MainActor
    func `Refused lane admission leaves the original snapshot reusable`() async throws {
        let root = Self.temporaryDirectory(named: "deadline-snapshot")
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshots = InMemorySnapshotManager()
        let snapshotID = try await snapshots.createSnapshot()
        let instant = ContinuousClock.now
        let coordinator = DesktopOperationLaneCoordinator(
            coordinationRootURL: root,
            lockWait: .zero,
            now: { instant })
        var dispatched = false

        do {
            try await snapshots.withSnapshotMutation(
                snapshotId: snapshotID,
                operation: {
                    try await coordinator.run(scope: .global, access: .write) {
                        dispatched = true
                    }
                },
                outcome: { _ in nil })
            Issue.record("Expected an admission timeout")
        } catch let failure as DesktopActionFailure {
            Self.expectAdmissionTimeout(failure, path: root.appendingPathComponent("global.lock").path)
        }

        #expect(!dispatched)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let lease = try await snapshots.beginSnapshotMutation(snapshotId: snapshotID)
        try await snapshots.finishSnapshotMutation(lease, requiresFreshObservation: false)
    }

    @Test
    func `An admitted operation can outlive its lock wait budget`() async throws {
        let root = Self.temporaryDirectory(named: "deadline-body-lifetime")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AutomationTestLockedValue(ContinuousClock.now)
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root, now: { clock.value })
        #expect(DesktopOperationLaneCoordinator.maximumLockWait == .seconds(15))

        let result = try await coordinator.run(scope: .global, access: .write) {
            clock.withValue { $0 = $0.advanced(by: .seconds(30)) }
            return 41
        }

        #expect(result == 41)
        try Self.expectDeadlineLocksReleased(in: root)
    }

    @Test
    func `An admitted body error is not reclassified as a lock admission refusal`() async throws {
        let root = Self.temporaryDirectory(named: "deadline-body-error")
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AutomationTestLockedValue(ContinuousClock.now)
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root, now: { clock.value })

        do {
            let _: Void = try await coordinator.run(scope: .global, access: .write) {
                clock.withValue { $0 = $0.advanced(by: .seconds(30)) }
                throw DesktopOperationLaneError.lockTimeout(path: "admitted-body")
            }
            Issue.record("Expected the original body error")
        } catch let error as DesktopOperationLaneError {
            guard case let .lockTimeout(path) = error else {
                Issue.record("Expected the original lockTimeout body error")
                return
            }
            #expect(path == "admitted-body")
        }

        try Self.expectDeadlineLocksReleased(in: root)
    }

    static func expectAdmissionTimeout(_ failure: DesktopActionFailure, path: String) {
        let projection = failure.outcome.projection
        #expect(failure.standardErrorCode == .timeout)
        #expect(failure.message.contains(path))
        #expect(projection.state == .refused)
        #expect(projection.dispatchState == .none)
        #expect(projection.retrySafe)
        #expect(!projection.mutationDispatched)
        #expect(!projection.requiresFreshObservation)
    }

    private static func withHeldDeadlineLock<Result>(
        named fileName: String,
        operation: (URL, Int32) async throws -> Result) async throws -> Result
    {
        let root = Self.temporaryDirectory(named: "deadline-admission")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(fileName).path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(descriptor, LOCK_UN) }
        return try await operation(root, descriptor)
    }

    private static func expectDeadlineLocksReleased(in root: URL) throws {
        for fileName in self.deadlineLockNames {
            let path = root.appendingPathComponent(fileName).path
            let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            try #require(descriptor >= 0)
            defer { close(descriptor) }
            try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0, "Leaked claim: \(fileName)")
            _ = flock(descriptor, LOCK_UN)
        }
    }
}
