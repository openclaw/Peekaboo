import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@MainActor
@Suite(.serialized)
struct ApplicationServiceBridgeCancellationTests {
    @Test
    func `Pre-cancelled lifecycle bridges never start their main actor operation`() async {
        for operation in LifecycleOperation.allCases {
            let service = CancellationProbeApplicationService()
            let call = Task {
                withUnsafeCurrentTask { task in
                    task?.cancel()
                }
                _ = try await operation.call(service)
            }

            await #expect(throws: CancellationError.self, "\(operation) started after cancellation") {
                try await call.value
            }
            #expect(service.started.isEmpty)
            #expect(service.completed.isEmpty)
        }
    }

    @Test
    func `Cancellation queued behind a busy main actor never starts the lifecycle operation`() async {
        for operation in LifecycleOperation.allCases {
            let service = CancellationProbeApplicationService()
            let bridgeCallReady = DispatchSemaphore(value: 0)

            await #expect(throws: CancellationError.self, "\(operation) started after queued cancellation") {
                try await withThrowingTaskGroup(of: DesktopActionOutcome?.self) { group in
                    group.addTask {
                        bridgeCallReady.signal()
                        return try await operation.call(service)
                    }

                    #expect(self.waitForSignal(bridgeCallReady))
                    self.allowBridgeCallToQueue()
                    group.cancelAll()
                    return try await group.next()
                }
            }

            #expect(service.started.isEmpty)
            #expect(service.cancelled.isEmpty)
            #expect(service.completed.isEmpty)
        }
    }

    private nonisolated func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + 1) == .success
    }

    private nonisolated func allowBridgeCallToQueue() {
        Thread.sleep(forTimeInterval: 0.05)
    }

    @Test
    func `Lifecycle bridges propagate cooperative in-flight cancellation`() async throws {
        for operation in LifecycleOperation.allCases {
            let service = CancellationProbeApplicationService()
            let call = Task {
                try await operation.call(service)
            }

            let deadline = ContinuousClock.now + .seconds(1)
            while !service.started.contains(operation), ContinuousClock.now < deadline {
                await Task.yield()
            }
            try #require(service.started.contains(operation), "\(operation) did not begin")

            call.cancel()

            await #expect(throws: CancellationError.self, "\(operation) returned success after cancellation") {
                try await call.value
            }
            #expect(service.cancelled == [operation])
            #expect(service.completed.isEmpty)
        }
    }

    @Test
    func `Lifecycle bridges preserve receipts returned after in-flight cancellation`() async throws {
        for operation in LifecycleOperation.allCases {
            let service = CancellationProbeApplicationService(cancellationBehavior: .returnReceipt)
            let call = Task {
                try await operation.call(service)
            }

            let deadline = ContinuousClock.now + .seconds(1)
            while !service.started.contains(operation), ContinuousClock.now < deadline {
                await Task.yield()
            }
            try #require(service.started.contains(operation), "\(operation) did not begin")

            call.cancel()

            let outcome = try await call.value
            #expect(outcome == service.actionOutcome)
            #expect(service.cancelled == [operation])
            #expect(service.completed == [operation])
        }
    }
}

private enum LifecycleOperation: String, CaseIterable, Sendable {
    case launch
    case relaunch
    case activate
    case quit
    case hide

    nonisolated func call(_ service: CancellationProbeApplicationService) async throws -> DesktopActionOutcome? {
        switch self {
        case .launch:
            try await ApplicationServiceBridge.launchApplication(
                applications: service,
                request: ApplicationLaunchRequest(applicationIdentifier: "Fixture")
            ).outcome
        case .relaunch:
            try await ApplicationServiceBridge.relaunchApplication(
                applications: service,
                request: ApplicationRelaunchRequest(
                    targetIdentifier: "Fixture",
                    launchRequest: ApplicationLaunchRequest(applicationIdentifier: "Fixture")
                )
            ).outcome
        case .activate:
            try await ApplicationServiceBridge.activateApplication(
                applications: service,
                request: ApplicationActivationRequest(identifier: "Fixture")
            ).outcome
        case .quit:
            try await ApplicationServiceBridge.quitApplication(
                applications: service,
                request: ApplicationQuitRequest(identifier: "Fixture")
            ).outcome
        case .hide:
            try await ApplicationServiceBridge.hideApplication(
                applications: service,
                identifier: "Fixture"
            ).outcome
        }
    }
}

@MainActor
private final class CancellationProbeApplicationService: StubApplicationService,
ApplicationServiceActionResultProviding {
    enum CancellationBehavior {
        case propagate
        case returnReceipt
    }

    let actionOutcome = DesktopActionOutcome.confirmedChange(
        delivery: .init(mechanism: .nativeFramework, mode: .background),
        unitCount: .one
    )

    private let application: ServiceApplicationInfo
    private let cancellationBehavior: CancellationBehavior
    private(set) var started: [LifecycleOperation] = []
    private(set) var cancelled: [LifecycleOperation] = []
    private(set) var completed: [LifecycleOperation] = []

    init(cancellationBehavior: CancellationBehavior = .propagate) {
        let application = ServiceApplicationInfo(
            processIdentifier: 42,
            processStartIdentity: 7,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture"
        )
        self.application = application
        self.cancellationBehavior = cancellationBehavior
        super.init(applications: [application])
    }

    func launchApplicationActionResult(
        request _: ApplicationLaunchRequest
    ) async throws -> DesktopActionResult<ServiceApplicationInfo> {
        try await self.suspend(.launch)
        return DesktopActionResult(payload: self.application, outcome: self.actionOutcome)
    }

    func relaunchApplicationActionResult(
        request _: ApplicationRelaunchRequest
    ) async throws -> DesktopActionResult<ServiceApplicationInfo> {
        try await self.suspend(.relaunch)
        return DesktopActionResult(payload: self.application, outcome: self.actionOutcome)
    }

    func activateApplicationActionResult(
        request _: ApplicationActivationRequest
    ) async throws -> DesktopActionResult<Void> {
        try await self.suspend(.activate)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func quitApplicationActionResult(
        request _: ApplicationQuitRequest
    ) async throws -> DesktopActionResult<Bool> {
        try await self.suspend(.quit)
        return DesktopActionResult(payload: true, outcome: self.actionOutcome)
    }

    func hideApplicationActionResult(identifier _: String) async throws -> DesktopActionResult<Void> {
        try await self.suspend(.hide)
        return DesktopActionResult(outcome: self.actionOutcome)
    }

    func unhideApplicationActionResult(identifier _: String) async throws -> DesktopActionResult<Void> {
        DesktopActionResult(outcome: nil)
    }

    private func suspend(_ operation: LifecycleOperation) async throws {
        self.started.append(operation)
        do {
            try await Task.sleep(for: .seconds(1))
            self.completed.append(operation)
        } catch is CancellationError {
            self.cancelled.append(operation)
            switch self.cancellationBehavior {
            case .propagate:
                throw CancellationError()
            case .returnReceipt:
                self.completed.append(operation)
            }
        }
    }
}
