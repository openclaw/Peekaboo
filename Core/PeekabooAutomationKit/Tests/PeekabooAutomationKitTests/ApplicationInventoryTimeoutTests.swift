import CoreGraphics
import Foundation
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
struct ApplicationInventoryTimeoutTests {
    @Test
    @MainActor
    func `omitted and identity-incomplete live processes make inventory partial`() async throws {
        let changedPID: pid_t = 40001
        let missingIdentityPID: pid_t = 40002
        let changedGeneration = AutomationTestLockedValue<UInt64>(70)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            processStartIdentityProvider: { pid in
                pid == changedPID ? changedGeneration.value : nil
            },
            runningApplicationProcessIdentifiersProvider: { [changedPID, missingIdentityPID] },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { pid, _, _ in
                if pid == changedPID {
                    changedGeneration.value = 71
                }
                return Self.metadata(name: "App \(pid)")
            })

        let output = try await service.listApplications()

        #expect(output.data.applications.map(\.processIdentifier) == [missingIdentityPID])
        #expect(output.summary.status == .partial)
        #expect(output.summary.counts["incompleteApplications"] == 1)
        #expect(output.summary.counts["omittedApplications"] == 1)
        #expect(output.metadata.warnings.contains { $0.contains("changed process generation") })
        #expect(output.metadata.warnings.contains { $0.contains("Process-generation identity was unavailable") })
    }

    @Test
    @MainActor
    func `metadata without a usable name records an omitted inventory row`() async throws {
        let pid: pid_t = 40003
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            processStartIdentityProvider: { _ in 73 },
            runningApplicationProcessIdentifiersProvider: { [pid] },
            applicationWindowCatalogProvider: { [] },
            applicationMetadataProvider: { _, _, _ in
                DetachedApplicationMetadata(
                    bundleIdentifier: "com.example.unnamed",
                    name: nil,
                    bundlePath: nil,
                    isHidden: false,
                    activationPolicy: .regular,
                    isFinishedLaunching: true)
            })

        let output = try await service.listApplications()

        #expect(output.data.applications.isEmpty)
        #expect(output.summary.status == .partial)
        #expect(output.summary.counts["incompleteApplications"] == 0)
        #expect(output.summary.counts["omittedApplications"] == 1)
        #expect(output.metadata.warnings == ["Application PID \(pid) metadata lacked a usable name and was omitted."])
    }

    @Test
    @MainActor
    func `mutation inventory uses only selector fields and skips presentation enrichment`() async throws {
        let pid: pid_t = 40004
        let application = ServiceApplicationInfo(
            processIdentifier: pid,
            processStartIdentity: 74,
            bundleIdentifier: "com.example.fixture",
            name: "Editor")
        var windowCatalogReadCount = 0
        let metadataReadCount = AutomationTestLockedValue(0)
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            applicationMutationCandidateProvider: { _ in
                ApplicationIdentifierMatcher.Candidate(
                    processIdentifier: pid,
                    bundleIdentifier: "com.example.fixture",
                    name: "Editor",
                    isRegularApplication: true)
            },
            processStartIdentityProvider: { _ in 74 },
            runningApplicationProcessIdentifiersProvider: { [pid] },
            applicationWindowCatalogProvider: {
                windowCatalogReadCount += 1
                return nil
            },
            applicationMetadataProvider: { _, _, _ in
                metadataReadCount.withValue { $0 += 1 }
                return Self.metadata(name: "Editor")
            })
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            inventoryProvider: { try await service.applicationMutationInventory() },
            exactIdentifierProvider: { _ in application })

        let byName = try await planner.plan(identifier: "Editor")
        let byBundle = try await planner.plan(identifier: "com.example.fixture")

        #expect(byName.processIdentity == application.processIdentity)
        #expect(byBundle.processIdentity == application.processIdentity)
        #expect(windowCatalogReadCount == 0)
        #expect(metadataReadCount.value == 0)
    }

    @Test
    @MainActor
    func `mutation inventory reports missing and drifting process generations as partial`() async throws {
        let stablePID: pid_t = 40005
        let missingPID: pid_t = 40006
        let driftingPID: pid_t = 40007
        var driftingReads = 0
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            applicationMutationCandidateProvider: { pid in
                ApplicationIdentifierMatcher.Candidate(
                    processIdentifier: pid,
                    bundleIdentifier: "com.example.\(pid)",
                    name: "App \(pid)")
            },
            processStartIdentityProvider: { pid -> UInt64? in
                switch pid {
                case stablePID: return 75
                case missingPID: return nil
                case driftingPID:
                    driftingReads += 1
                    return driftingReads == 1 ? 76 : 77
                default: return nil
                }
            },
            runningApplicationProcessIdentifiersProvider: { [stablePID, missingPID, driftingPID] })

        let inventory = try await service.applicationMutationInventory()

        #expect(inventory.items.map(\.processIdentifier) == [stablePID])
        #expect(!inventory.isComplete)
        #expect(inventory.warnings == [
            "Application PID \(missingPID) lacked process-generation identity and was omitted.",
            "Application PID \(driftingPID) changed process generation during inventory and was omitted.",
        ])
    }

    @Test
    @MainActor
    func `mutation inventory omits a live process without a usable selector name`() async throws {
        let namedPID: pid_t = 40008
        let unnamedPID: pid_t = 40009
        let service = ApplicationService(
            applicationOpenHandler: { _, _, _ in throw ApplicationInventoryFixtureError.unused },
            applicationMutationCandidateProvider: { pid in
                ApplicationIdentifierMatcher.Candidate(
                    processIdentifier: pid,
                    bundleIdentifier: "com.example.\(pid)",
                    name: pid == unnamedPID ? "  \n" : "Named App")
            },
            processStartIdentityProvider: { pid in UInt64(pid) + 100 },
            runningApplicationProcessIdentifiersProvider: { [namedPID, unnamedPID] })

        let inventory = try await service.applicationMutationInventory()

        #expect(inventory.items.map(\.processIdentifier) == [namedPID])
        #expect(!inventory.isComplete)
        #expect(inventory.warnings == [
            "Application PID \(unnamedPID) metadata lacked a usable name and was omitted.",
        ])
    }

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
