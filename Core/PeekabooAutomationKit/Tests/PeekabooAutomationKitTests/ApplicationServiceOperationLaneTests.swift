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
        currentGeneration.value = 71
        await ownerRelease.open()

        try await owner.value
        await #expect(throws: PeekabooError.self) {
            try await quit.value
        }
        #expect(terminationCalls == 0)
    }

    @Test
    @MainActor
    func `Cancelled background launch retains global lane through activation heartbeat`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated && $0.isFinishedLaunching
        })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-launch-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let launchWaiting = ApplicationOperationLatch()
        let heartbeatStarted = ApplicationOperationLatch()
        let heartbeatRelease = ApplicationOperationLatch()
        let contenderStarted = ApplicationOperationLatch()
        let generation = SystemIdentityResolver.processStartIdentity(runningApplication.processIdentifier) ?? 70
        let activationNow = ContinuousClock.now
        let service = ApplicationService(
            operationLaneCoordinator: coordinator,
            applicationOpenHandler: { _, _, _ in runningApplication },
            applicationReadinessHandler: { _ in
                Task { await launchWaiting.open() }
                return false
            },
            processStartIdentityProvider: { _ in generation },
            applicationReadinessTimeout: 5,
            backgroundLaunchActivationGraceDuration: .milliseconds(250),
            backgroundActivationLeaseFactory: { duration in
                BackgroundLaunchActivationLease(
                    observeActivations: false,
                    activationGraceDuration: duration,
                    nowProvider: { activationNow },
                    sleepHandler: { _ in
                        await heartbeatStarted.open()
                        await heartbeatRelease.wait()
                    },
                    frontmostProcessIdentifierProvider: { nil },
                    restorationHandler: { _ in })
            })

        let launch = Task { @MainActor in
            try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                activates: false,
                waitForWindow: true))
        }
        await launchWaiting.wait()
        launch.cancel()
        await heartbeatStarted.wait()
        let contender = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await contenderStarted.open()
            }
        }

        #expect(await !(contenderStarted.opensWithin(.milliseconds(100))))
        await heartbeatRelease.open()
        await #expect(throws: CancellationError.self) {
            try await launch.value
        }
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
