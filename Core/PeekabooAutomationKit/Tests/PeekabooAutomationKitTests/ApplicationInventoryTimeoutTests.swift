import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ApplicationInventoryTimeoutTests {
    @Test
    @MainActor
    func `one timed out process returns truthful partial inventory without dropping other apps`() async throws {
        let healthyPID: pid_t = 41001
        let poisonedPID: pid_t = 41002
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            processStartIdentityProvider: { pid in UInt64(pid) + 100 },
            runningApplicationProcessIdentifiersProvider: { [healthyPID, poisonedPID] },
            applicationWindowCatalogProvider: {
                [
                    Self.window(id: 101, pid: healthyPID, appName: "Healthy Hidden App"),
                    Self.window(id: 202, pid: poisonedPID, appName: "Poisoned Hidden Helper"),
                ]
            },
            applicationMetadataProvider: { pid, _, timeout in
                if pid == poisonedPID {
                    throw CaptureError.detectionTimedOut(timeout)
                }
                return DetachedApplicationMetadata(
                    bundleIdentifier: "com.example.healthy",
                    name: "Healthy Hidden App",
                    bundlePath: "/Applications/Healthy Hidden App.app",
                    isHidden: true,
                    activationPolicy: .regular,
                    isFinishedLaunching: true)
            },
            applicationMetadataTimeout: 0.05)

        let output = try await service.listApplications()
        let healthy = try #require(output.data.applications.first { $0.processIdentifier == healthyPID })
        let poisoned = try #require(output.data.applications.first { $0.processIdentifier == poisonedPID })

        #expect(healthy.isHidden)
        #expect(healthy.isHiddenKnown == true)
        #expect(healthy.windowIDs == [101])
        #expect(healthy.metadataWarnings == nil)
        #expect(poisoned.name == "Poisoned Hidden Helper")
        #expect(!poisoned.isHidden)
        #expect(poisoned.isHiddenKnown == false)
        #expect(poisoned.activationPolicy == nil)
        #expect(poisoned.windowIDs == [202])
        #expect(poisoned.metadataWarnings?.contains { $0.contains("timed out after 0.05s") } == true)
        #expect(output.summary.status == .partial)
        #expect(output.summary.counts["incompleteApplications"] == 1)
        #expect(output.metadata.warnings == poisoned.metadataWarnings)
    }

    @Test
    @MainActor
    func `cancelled global inventory publishes no partial result`() async throws {
        let started = ApplicationInventoryGate()
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            processStartIdentityProvider: { _ in 7 },
            runningApplicationProcessIdentifiersProvider: { [42001, 42002] },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { _, _, _ in
                await started.markStarted()
                try await Task.sleep(for: .seconds(30))
                throw ApplicationInventoryFixtureError.unused
            },
            applicationMetadataTimeout: 30)

        let task = Task { @MainActor in
            try await service.listApplications()
        }
        await started.wait()
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test
    @MainActor
    func `metadata fanout obeys its concurrency cap`() async throws {
        let processIdentifiers = Array(44001...44012).map(pid_t.init)
        let probe = ApplicationMetadataConcurrencyProbe()
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            processStartIdentityProvider: { _ in 7 },
            runningApplicationProcessIdentifiersProvider: { processIdentifiers },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, _, _ in
                await probe.enterAndWait()
                return Self.metadata(name: "App \(pid)")
            },
            applicationMetadataTimeout: 5,
            maximumConcurrentApplicationMetadataReads: 3)

        let task = Task { @MainActor in
            try await service.listApplications()
        }
        await probe.waitUntilEntered(3)
        try await Task.sleep(for: .milliseconds(50))
        #expect(await probe.maximumInFlight == 3)
        #expect(await probe.totalEntered == 3)
        await probe.releaseAll()

        let output = try await task.value
        #expect(output.data.applications.count == processIdentifiers.count)
        #expect(await probe.maximumInFlight == 3)
    }

    @Test
    @MainActor
    func `many-process inventory waits for one bound rather than summing every process timeout`() async throws {
        let processIdentifiers = Array(45001...45064).map(pid_t.init)
        let poisonedPID = processIdentifiers[2]
        let lateWorker = ApplicationInventoryBlockingGate()
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            processStartIdentityProvider: { pid in UInt64(pid) + 10 },
            runningApplicationProcessIdentifiersProvider: { Array(processIdentifiers.reversed()) },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, generation, timeout in
                try await DetachedApplicationMetadataCoordinator.run(
                    processIdentifier: pid,
                    processStartIdentity: generation,
                    timeoutSeconds: timeout)
                { _ in
                    if pid == poisonedPID {
                        lateWorker.markStarted()
                        lateWorker.wait()
                        lateWorker.markFinished()
                    }
                    return Self.metadata(name: String(format: "App %05d", pid))
                }
            },
            applicationMetadataTimeout: 0.05,
            maximumConcurrentApplicationMetadataReads: 8)

        let startedAt = ContinuousClock.now
        let output = try await service.listApplications()
        let elapsed = startedAt.duration(to: .now).timeInterval
        let poisoned = try #require(output.data.applications.first { $0.processIdentifier == poisonedPID })

        #expect(elapsed < 0.5)
        #expect(output.data.applications.count == processIdentifiers.count)
        #expect(output.data.applications.map(\.name) == output.data.applications.map(\.name).sorted())
        #expect(poisoned.isHiddenKnown == false)
        #expect(poisoned.metadataWarnings?.contains { $0.contains("timed out") } == true)

        lateWorker.release()
        #expect(lateWorker.waitUntilFinished())
        // The detached worker completed too late to mutate the already-published value.
        #expect(poisoned.isHiddenKnown == false)
        #expect(poisoned.metadataWarnings?.contains { $0.contains("timed out") } == true)
    }

    @Test
    @MainActor
    func `overall deadline bounds an all-stalled fleet and marks unstarted rows unknown`() async throws {
        let processIdentifiers = Array(46001...46128).map(pid_t.init)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            processStartIdentityProvider: { pid in UInt64(pid) + 10 },
            runningApplicationProcessIdentifiersProvider: { processIdentifiers },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { _, _, timeout in
                try await Task.sleep(for: .milliseconds(50))
                throw CaptureError.detectionTimedOut(timeout)
            },
            applicationMetadataTimeout: 0.05,
            applicationInventoryOverallTimeout: 0.11,
            maximumConcurrentApplicationMetadataReads: 8)

        let startedAt = ContinuousClock.now
        let output = try await service.listApplications()
        let elapsed = startedAt.duration(to: .now).timeInterval

        #expect(elapsed < 0.3)
        #expect(output.data.applications.count == processIdentifiers.count)
        #expect(output.data.applications.allSatisfy { $0.isHiddenKnown == false })
        #expect(output.metadata.warnings.contains { $0.contains("inventory deadline") })
    }

    @Test
    @MainActor
    func `metadata reads launched near the overall deadline receive only its remaining budget`() async throws {
        let processIdentifiers: [pid_t] = [47001, 47002]
        let clockStart = ContinuousClock.now
        var clockReadCount = 0
        let timeoutRecorder = ApplicationMetadataTimeoutRecorder()
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            processStartIdentityProvider: { pid in UInt64(pid) + 10 },
            runningApplicationProcessIdentifiersProvider: { processIdentifiers },
            applicationWindowCatalogProvider: { [] },
            applicationInventoryNowProvider: {
                defer { clockReadCount += 1 }
                return clockReadCount < 2
                    ? clockStart
                    : clockStart.advanced(by: .milliseconds(90))
            },
            applicationMetadataProvider: { pid, _, timeout in
                await timeoutRecorder.record(processIdentifier: pid, timeout: timeout)
                return Self.metadata(name: "App \(pid)")
            },
            applicationMetadataTimeout: 0.5,
            applicationInventoryOverallTimeout: 0.1,
            maximumConcurrentApplicationMetadataReads: 1)

        let output = try await service.listApplications()
        let recordedTimeouts = await timeoutRecorder.timeouts

        #expect(output.data.applications.count == processIdentifiers.count)
        #expect(recordedTimeouts.count == processIdentifiers.count)
        #expect(abs(recordedTimeouts[0] - 0.1) < 0.001)
        #expect(abs(recordedTimeouts[1] - 0.01) < 0.001)
    }

    @Test
    func `noncooperative per-process metadata times out without holding caller`() async throws {
        let gate = ApplicationInventoryBlockingGate()
        let startedAt = ContinuousClock.now

        await #expect(throws: CaptureError.self) {
            _ = try await DetachedApplicationMetadataCoordinator.run(
                processIdentifier: 43001,
                processStartIdentity: nil,
                timeoutSeconds: 0.05)
            { _ in
                gate.markStarted()
                gate.wait()
                return Self.metadata(name: "Late")
            }
        }

        #expect(startedAt.duration(to: .now).timeInterval < 0.5)
        gate.release()
    }

    @Test
    func `repeated inventory does not enqueue behind a still-blocked process lane`() async throws {
        let gate = ApplicationInventoryBlockingGate()
        let repeatedStarted = ApplicationInventoryFlag()

        await #expect(throws: CaptureError.self) {
            _ = try await DetachedApplicationMetadataCoordinator.run(
                processIdentifier: 43003,
                processStartIdentity: nil,
                timeoutSeconds: 0.05)
            { _ in
                gate.markStarted()
                gate.wait()
                gate.markFinished()
                return Self.metadata(name: "Late")
            }
        }

        let repeatedStartedAt = ContinuousClock.now
        await #expect(throws: CaptureError.self) {
            _ = try await DetachedApplicationMetadataCoordinator.run(
                processIdentifier: 43003,
                processStartIdentity: nil,
                timeoutSeconds: 0.05)
            { _ in
                repeatedStarted.set()
                return Self.metadata(name: "Duplicate")
            }
        }
        #expect(repeatedStartedAt.duration(to: .now).timeInterval < 0.1)
        #expect(!repeatedStarted.value)

        gate.release()
        #expect(gate.waitUntilFinished())
    }

    @Test
    func `cancelled noncooperative metadata returns while detached lane finishes later`() async throws {
        let gate = ApplicationInventoryBlockingGate()
        let task = Task {
            try await DetachedApplicationMetadataCoordinator.run(
                processIdentifier: 43002,
                processStartIdentity: nil,
                timeoutSeconds: 30)
            { _ in
                gate.markStarted()
                gate.wait()
                return Self.metadata(name: "Late")
            }
        }
        #expect(gate.waitUntilStarted())

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        gate.release()
    }

    private static func metadata(name: String) -> DetachedApplicationMetadata {
        DetachedApplicationMetadata(
            bundleIdentifier: "com.example.fixture",
            name: name,
            bundlePath: nil,
            isHidden: false,
            activationPolicy: .regular,
            isFinishedLaunching: true)
    }

    private static func window(id: Int, pid: pid_t, appName: String) -> WindowIdentityInfo {
        WindowIdentityInfo(
            windowID: CGWindowID(id),
            title: appName,
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            ownerPID: pid,
            applicationName: appName,
            bundleIdentifier: nil,
            layer: 0,
            alpha: 1,
            axIdentifier: nil)
    }
}

private enum ApplicationInventoryFixtureError: Error {
    case unused
}

private actor ApplicationInventoryGate {
    private var started = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func markStarted() {
        self.started = true
        let waiters = self.continuations
        self.continuations.removeAll()
        for continuation in waiters {
            continuation.resume()
        }
    }

    func wait() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.continuations.append(continuation)
        }
    }
}

private final class ApplicationInventoryBlockingGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    func markStarted() {
        self.started.signal()
    }

    func waitUntilStarted() -> Bool {
        self.started.wait(timeout: .now() + 1) == .success
    }

    func wait() {
        self.releaseGate.wait()
    }

    func release() {
        self.releaseGate.signal()
    }

    func markFinished() {
        self.finished.signal()
    }

    func waitUntilFinished() -> Bool {
        self.finished.wait(timeout: .now() + 1) == .success
    }
}

private final class ApplicationInventoryFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        self.lock.withLock { self.storage }
    }

    func set() {
        self.lock.withLock { self.storage = true }
    }
}

private actor ApplicationMetadataConcurrencyProbe {
    private var inFlight = 0
    private(set) var maximumInFlight = 0
    private(set) var totalEntered = 0
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func enterAndWait() async {
        self.inFlight += 1
        self.totalEntered += 1
        self.maximumInFlight = max(self.maximumInFlight, self.inFlight)
        let totalEntered = self.totalEntered
        let satisfied = self.enteredWaiters.filter { totalEntered >= $0.count }
        self.enteredWaiters.removeAll { totalEntered >= $0.count }
        for waiter in satisfied {
            waiter.continuation.resume()
        }
        if !self.released {
            await withCheckedContinuation { continuation in
                self.releaseWaiters.append(continuation)
            }
        }
        self.inFlight -= 1
    }

    func waitUntilEntered(_ count: Int) async {
        guard self.totalEntered < count else { return }
        await withCheckedContinuation { continuation in
            self.enteredWaiters.append((count, continuation))
        }
    }

    func releaseAll() {
        self.released = true
        let waiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor ApplicationMetadataTimeoutRecorder {
    private(set) var timeouts: [TimeInterval] = []

    func record(processIdentifier _: pid_t, timeout: TimeInterval) {
        self.timeouts.append(timeout)
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
