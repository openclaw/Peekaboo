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
    func `Cancelled background launch retains global lane through restoration confirmation`() async throws {
        let runningApplications = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier > 0 && !$0.isTerminated && $0.isFinishedLaunching
        }
        let runningApplication = try #require(runningApplications.first)
        let previousApplication = try #require(runningApplications.first {
            $0.processIdentifier != runningApplication.processIdentifier
        })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-launch-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let launchWaiting = ApplicationOperationLatch()
        let graceStarted = ApplicationOperationLatch()
        let graceRelease = ApplicationOperationLatch()
        let confirmationStarted = ApplicationOperationLatch()
        let confirmationRelease = ApplicationOperationLatch()
        let contenderStarted = ApplicationOperationLatch()
        let generation = SystemIdentityResolver.processStartIdentity(runningApplication.processIdentifier) ?? 70
        let activationNow = ApplicationOperationInstantBox(ContinuousClock.now)
        let frontmostPID = ApplicationOperationPIDBox(previousApplication.processIdentifier)
        var reconciliationObservedCancellation = false
        var nativeActivationRequests: [pid_t] = []
        var accessibilityActivationRequests: [pid_t] = []
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
            backgroundActivationLeaseFactory: { duration, _ in
                let lease = BackgroundLaunchActivationLease(
                    previousApplication: previousApplication,
                    observeActivations: false,
                    activationGraceDuration: duration,
                    nowProvider: { activationNow.value },
                    sleepHandler: { sleepDuration in
                        await graceStarted.open()
                        await graceRelease.wait()
                        activationNow.value = activationNow.value.advanced(by: sleepDuration)
                    },
                    restorationDependencies: BackgroundRestorationDependencies(
                        applicationActivationHandler: { application in
                            nativeActivationRequests.append(application.processIdentifier)
                            return true
                        },
                        accessibilityActivationHandler: { processIdentifier in
                            accessibilityActivationRequests.append(processIdentifier)
                            return true
                        },
                        applicationActiveProvider: { _ in false },
                        applicationTerminatedProvider: { _ in false },
                        frontmostProcessIdentifierProvider: { frontmostPID.value },
                        processStartIdentityProvider: { _ in generation },
                        confirmationSleepHandler: { sleepDuration in
                            reconciliationObservedCancellation = Task.isCancelled
                            await confirmationStarted.open()
                            await confirmationRelease.wait()
                            activationNow.value = activationNow.value.advanced(by: sleepDuration)
                        },
                        confirmationTimeout: .milliseconds(100)))
                frontmostPID.value = runningApplication.processIdentifier
                return lease
            })

        let launch = Task { @MainActor in
            try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                activates: false,
                waitForWindow: true))
        }
        await launchWaiting.wait()
        launch.cancel()
        await graceStarted.wait()
        let contender = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await contenderStarted.open()
            }
        }

        #expect(await !(contenderStarted.opensWithin(.milliseconds(100))))
        await graceRelease.open()
        await confirmationStarted.wait()
        #expect(!reconciliationObservedCancellation)
        #expect(await !contenderStarted.isOpen)
        await confirmationRelease.open()
        await #expect(throws: CancellationError.self) {
            try await launch.value
        }
        try await contender.value
        #expect(await contenderStarted.isOpen)
        #expect(!nativeActivationRequests.isEmpty)
        #expect(nativeActivationRequests.allSatisfy { $0 == previousApplication.processIdentifier })
        #expect(accessibilityActivationRequests.allSatisfy { $0 == previousApplication.processIdentifier })
    }

    @Test
    @MainActor
    func `Cancelled in-flight open retains lane until target receipt and reconciliation`() async throws {
        let runningApplication = try #require(NSWorkspace.shared.runningApplications.first {
            $0.processIdentifier > 0 && !$0.isTerminated && $0.isFinishedLaunching
        })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-open-lane-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let openStarted = ApplicationOperationLatch()
        let openRelease = ApplicationOperationLatch()
        let reconciliationStarted = ApplicationOperationLatch()
        let reconciliationRelease = ApplicationOperationLatch()
        let contenderStarted = ApplicationOperationLatch()
        let generation = SystemIdentityResolver.processStartIdentity(runningApplication.processIdentifier) ?? 70
        let activationNow = ApplicationOperationInstantBox(ContinuousClock.now)
        var openObservedCancellation = false
        var reconciliationObservedCancellation = false
        var nativeActivationRequests: [pid_t] = []
        var accessibilityActivationRequests: [pid_t] = []
        let service = ApplicationService(
            operationLaneCoordinator: coordinator,
            applicationOpenHandler: { _, _, _ in
                await openStarted.open()
                await openRelease.wait()
                openObservedCancellation = Task.isCancelled
                return runningApplication
            },
            processStartIdentityProvider: { _ in generation },
            backgroundLaunchActivationGraceDuration: .milliseconds(250),
            backgroundActivationLeaseFactory: { duration, _ in
                BackgroundLaunchActivationLease(
                    previousApplication: runningApplication,
                    observeActivations: false,
                    activationGraceDuration: duration,
                    nowProvider: { activationNow.value },
                    sleepHandler: { sleepDuration in
                        reconciliationObservedCancellation = Task.isCancelled
                        await reconciliationStarted.open()
                        await reconciliationRelease.wait()
                        activationNow.value = activationNow.value.advanced(by: sleepDuration)
                    },
                    restorationDependencies: BackgroundRestorationDependencies(
                        applicationActivationHandler: { application in
                            nativeActivationRequests.append(application.processIdentifier)
                            return true
                        },
                        accessibilityActivationHandler: { processIdentifier in
                            accessibilityActivationRequests.append(processIdentifier)
                            return true
                        },
                        applicationActiveProvider: { _ in false },
                        applicationTerminatedProvider: { _ in false },
                        frontmostProcessIdentifierProvider: { nil },
                        processStartIdentityProvider: { _ in generation },
                        confirmationSleepHandler: { _ in },
                        confirmationTimeout: .zero))
            })

        let launch = Task { @MainActor in
            try await service.launchApplication(request: ApplicationLaunchRequest(
                applicationIdentifier: "Finder",
                activates: false))
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
        await reconciliationStarted.wait()
        #expect(!openObservedCancellation)
        #expect(!reconciliationObservedCancellation)
        #expect(await !contenderStarted.isOpen)
        await reconciliationRelease.open()
        await #expect(throws: CancellationError.self) {
            try await launch.value
        }
        try await contender.value
        #expect(await contenderStarted.isOpen)
        #expect(nativeActivationRequests.isEmpty)
        #expect(accessibilityActivationRequests.isEmpty)
    }
}

@MainActor
private final class ApplicationOperationInstantBox {
    var value: ContinuousClock.Instant

    init(_ value: ContinuousClock.Instant) {
        self.value = value
    }
}

@MainActor
private final class ApplicationOperationPIDBox {
    var value: pid_t?

    init(_ value: pid_t?) {
        self.value = value
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
