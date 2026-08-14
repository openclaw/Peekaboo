import AppKit
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

struct ApplicationServiceOperationLaneTests {
    @Test
    @MainActor
    func `Quit revalidates process generation after waiting for its execution lane`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-application-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: 70)
        let ownerStarted = ApplicationOperationLatch()
        let ownerRelease = ApplicationOperationLatch()
        let unrelatedStarted = ApplicationOperationLatch()
        let currentGeneration = ApplicationOperationGenerationBox(70)
        var terminationCalls = 0
        let service = ApplicationService(
            operationLaneCoordinator: coordinator,
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in currentGeneration.value },
            applicationQuitHandler: { _, _ in
                terminationCalls += 1
                return true
            })

        let owner = Task { @MainActor in
            try await coordinator.run(scope: .process(expectedIdentity), access: .write) {
                await ownerStarted.open()
                await ownerRelease.wait()
            }
        }
        await ownerStarted.wait()
        let quit = Task { @MainActor in
            try await service.quitApplication(request: ApplicationQuitRequest(
                identifier: "PID:\(runningApplication.processIdentifier)",
                expectedIdentity: expectedIdentity))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(terminationCalls == 0)
        let unrelated = Task {
            try await coordinator.run(
                scope: .process(ApplicationProcessIdentity(
                    processIdentifier: runningApplication.processIdentifier + 1,
                    processStartIdentity: 700)),
                access: .write)
            {
                await unrelatedStarted.open()
            }
        }
        #expect(await unrelatedStarted.opensWithin(.milliseconds(100)))
        currentGeneration.value = 71
        await ownerRelease.open()

        try await owner.value
        try await unrelated.value
        await #expect(throws: PeekabooError.self) {
            try await quit.value
        }
        #expect(terminationCalls == 0)
    }

    @Test
    @MainActor
    func `Visibility mutation leaves unrelated process lanes available`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated
        })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-visibility-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let visibilitySleepStarted = ApplicationOperationLatch()
        let visibilitySleepRelease = ApplicationOperationLatch()
        let unrelatedStarted = ApplicationOperationLatch()
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: 80)
        var isHidden = false
        let service = ApplicationService(
            operationLaneCoordinator: coordinator,
            applicationOpenHandler: { _, _, _ in runningApplication },
            processStartIdentityProvider: { _ in processIdentity.processStartIdentity },
            applicationHiddenProvider: { _ in isHidden },
            applicationVisibilityHandler: { _, hidden in hidden },
            applicationVisibilitySleepHandler: { _ in
                await visibilitySleepStarted.open()
                await visibilitySleepRelease.wait()
                isHidden = true
            },
            applicationVisibilityTimeout: 1)

        let visibility = Task { @MainActor in
            try await service.hideApplicationActionResult(
                identifier: "PID:\(runningApplication.processIdentifier)")
        }
        await visibilitySleepStarted.wait()
        let unrelated = Task {
            try await coordinator.run(
                scope: .process(ApplicationProcessIdentity(
                    processIdentifier: runningApplication.processIdentifier + 1,
                    processStartIdentity: 800)),
                access: .write)
            {
                await unrelatedStarted.open()
            }
        }

        #expect(await unrelatedStarted.opensWithin(.milliseconds(100)))
        await visibilitySleepRelease.open()
        let result = try await visibility.value
        try await unrelated.value
        #expect(result.outcome?.state == .confirmedChange)
    }

    @Test
    @MainActor
    func `Cancelled background no-op retains its read lane through readiness`() async throws {
        let runningApplication = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-background-noop-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let readinessStarted = ApplicationOperationLatch()
        let contenderStarted = ApplicationOperationLatch()
        let generation = try #require(SystemIdentityResolver.processStartIdentity(
            runningApplication.processIdentifier))
        let service = ApplicationService(
            operationLaneCoordinator: coordinator,
            applicationOpenHandler: { _, _, _ in runningApplication },
            runningApplicationsForURLProvider: { _ in [runningApplication] },
            applicationReadinessHandler: { _ in
                Task { await readinessStarted.open() }
                return false
            },
            processStartIdentityProvider: { _ in generation },
            applicationReadinessTimeout: 30)

        let launch = Task { @MainActor in
            try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                waitForWindow: true))
        }
        await readinessStarted.wait()
        let contender = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await contenderStarted.open()
            }
        }

        #expect(await !(contenderStarted.opensWithin(.milliseconds(100))))
        launch.cancel()
        await #expect(throws: CancellationError.self) {
            try await launch.value
        }
        try await contender.value
        #expect(await contenderStarted.isOpen)
    }

    @Test
    @MainActor
    func `Cancelled foreground open retains its write lane until native completion`() async throws {
        let runningApplication = try #require(
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-foreground-open-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let openStarted = ApplicationOperationLatch()
        let openRelease = ApplicationOperationLatch()
        let contenderStarted = ApplicationOperationLatch()
        let generation = try #require(SystemIdentityResolver.processStartIdentity(
            runningApplication.processIdentifier))
        var openObservedCancellation = false
        let service = ApplicationService(
            operationLaneCoordinator: coordinator,
            applicationOpenHandler: { _, _, _ in
                await openStarted.open()
                await openRelease.wait()
                openObservedCancellation = Task.isCancelled
                return runningApplication
            },
            processStartIdentityProvider: { _ in generation })

        let launch = Task { @MainActor in
            try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                activates: true))
        }
        await openStarted.wait()
        launch.cancel()
        let contender = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await contenderStarted.open()
            }
        }

        #expect(await !(contenderStarted.opensWithin(.milliseconds(100))))
        await openRelease.open()
        do {
            _ = try await launch.value
            Issue.record("Expected canonical post-dispatch cancellation")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .dispatchedUnverified)
            #expect(failure.outcome.evidence == .operationStillRunning)
            #expect(failure.outcome.retrySafety == .unsafe)
        }
        #expect(!openObservedCancellation)
        try await contender.value
        #expect(await contenderStarted.isOpen)
    }
}

private actor ApplicationOperationLatch {
    private var opened = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var isOpen: Bool {
        self.opened
    }

    func open() {
        guard !self.opened else { return }
        self.opened = true
        let pending = self.continuations
        self.continuations.removeAll()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        guard !self.opened else { return }
        await withCheckedContinuation { self.continuations.append($0) }
    }

    func opensWithin(_ duration: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: duration)
        while !self.opened, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return self.opened
    }
}

private final class ApplicationOperationGenerationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt64

    init(_ value: UInt64) {
        self.storedValue = value
    }

    var value: UInt64 {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }
}
