import CoreGraphics
import Foundation
import os.log
import PeekabooAutomationKitTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@Suite(.serialized)
@MainActor
struct WindowEnumerationTimeoutTests {
    @Test
    func `AX rows without stable window identity make an AX-only inventory partial`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 40, processStartIdentity: 5)
        let service = Self.makeService { _ in identity.processStartIdentity }
        let context = WindowEnumerationContext(
            service: service,
            app: Self.application(identity: identity),
            startTime: Date(),
            axTimeout: 0.05,
            hasScreenRecording: true,
            logger: Self.logger,
            processIdentity: identity,
            cgSnapshotProvider: { nil },
            applicationRunningProvider: { true },
            axEnumerator: { _, _ in
                DetachedAXWindowEnumerationResult(
                    descriptors: [DetachedAXWindowDescriptor(
                        windowID: nil,
                        title: "Unidentified",
                        bounds: CGRect(x: 10, y: 20, width: 800, height: 600))],
                    focusedWindowID: nil,
                    timedOut: false,
                    incomplete: false,
                    reportedWindowCount: 1)
            })

        let output = try await context.run()
        let inventory: DesktopTargetPlanning.Inventory<ServiceWindowInfo> = .windowOutput(output)

        #expect(output.data.windows.isEmpty)
        #expect(output.summary.status == .partial)
        #expect(output.metadata.warnings == [
            "Accessibility omitted 1 window row without stable window identity",
        ])
        #expect(!inventory.isComplete)
    }

    @Test
    func `missing screen recording notice does not poison complete AX selector inventory`() {
        let identity = ApplicationProcessIdentity(processIdentifier: 39, processStartIdentity: 4)
        let service = Self.makeService { _ in identity.processStartIdentity }
        let window = ServiceWindowInfo(
            windowID: 331,
            title: "AX Window",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600),
            mutationIdentity: WindowMutationIdentity(
                windowID: 331,
                ownerProcessIdentifier: identity.processIdentifier,
                ownerProcessStartIdentity: identity.processStartIdentity,
                capturedBounds: CGRect(x: 10, y: 20, width: 800, height: 600)))
        let output = service.buildWindowListOutput(
            windows: [window],
            app: Self.application(identity: identity),
            startTime: Date(),
            warnings: [],
            additionalHints: ["Screen recording permission not granted - window listing may be slower"])
        let inventory: DesktopTargetPlanning.Inventory<ServiceWindowInfo> = .windowOutput(output)

        #expect(output.summary.status == .success)
        #expect(output.metadata.warnings.isEmpty)
        #expect(output.metadata.hints.contains(
            "Screen recording permission not granted - window listing may be slower"))
        #expect(inventory.isComplete)
        #expect(inventory.warnings.isEmpty)
        #expect(inventory.items.map(\.windowID) == [331])
    }

    @Test
    func `successful presentation output with incomplete row identity remains partial for mutation`() {
        let identity = ApplicationProcessIdentity(processIdentifier: 37, processStartIdentity: 2)
        let service = Self.makeService { _ in identity.processStartIdentity }
        let incomplete = ServiceWindowInfo(
            windowID: 329,
            title: "Incomplete",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600))
        let output = service.buildWindowListOutput(
            windows: [incomplete],
            app: Self.application(identity: identity),
            startTime: Date(),
            warnings: [])

        let inventory: DesktopTargetPlanning.Inventory<ServiceWindowInfo> = .windowOutput(output)

        #expect(output.summary.status == .success)
        #expect(!inventory.isComplete)
        #expect(inventory.warnings == [
            "Window 329 did not include a process-generation mutation receipt.",
        ])
    }

    @Test
    func `unmaterialized CoreGraphics owner rows make inventory partial`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 41, processStartIdentity: 6)
        let service = Self.makeService { _ in identity.processStartIdentity }
        let cgWindow = ServiceWindowInfo(
            windowID: 332,
            title: "CG Window",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600))
        let context = WindowEnumerationContext(
            service: service,
            app: Self.application(identity: identity),
            startTime: Date(),
            axTimeout: 0.05,
            hasScreenRecording: true,
            logger: Self.logger,
            processIdentity: identity,
            cgSnapshotProvider: { .init(windows: [cgWindow], omittedOwnerRowCount: 1) },
            applicationRunningProvider: { true },
            axEnumerator: { _, _ in
                DetachedAXWindowEnumerationResult(
                    descriptors: [],
                    focusedWindowID: nil,
                    timedOut: false,
                    incomplete: false,
                    reportedWindowCount: 0)
            })

        let output = try await context.run()

        #expect(output.summary.status == .partial)
        #expect(output.metadata.warnings == [
            "CoreGraphics omitted 1 owner window row without complete identity evidence",
        ])
        #expect(output.data.windows.first?.observationCapability ==
            .pixelsOnly(reason: .noMatchingAccessibilityWindow))
    }

    @Test
    func `unmatched AX rows without stable identity make hybrid inventory partial`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 38, processStartIdentity: 3)
        let service = Self.makeService { _ in identity.processStartIdentity }
        let cgWindow = ServiceWindowInfo(
            windowID: 330,
            title: "CG Window",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600))
        let context = WindowEnumerationContext(
            service: service,
            app: Self.application(identity: identity),
            startTime: Date(),
            axTimeout: 0.05,
            hasScreenRecording: true,
            logger: Self.logger,
            processIdentity: identity,
            cgSnapshotProvider: { .init(windows: [cgWindow]) },
            applicationRunningProvider: { true },
            axEnumerator: { _, _ in
                DetachedAXWindowEnumerationResult(
                    descriptors: [DetachedAXWindowDescriptor(
                        windowID: nil,
                        title: "Unmatched AX Window",
                        bounds: CGRect(x: 1200, y: 20, width: 500, height: 400))],
                    focusedWindowID: nil,
                    timedOut: false,
                    incomplete: false,
                    reportedWindowCount: 1)
            })

        let output = try await context.run()

        #expect(output.data.windows.map(\.windowID) == [cgWindow.windowID])
        #expect(output.summary.status == .partial)
        #expect(output.metadata.warnings == [
            "Accessibility omitted 1 unmatched window row without stable identity",
        ])
    }

    @Test
    func `CG inventory survives an AX hard timeout as partial output`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 42, processStartIdentity: 7)
        let service = Self.makeService { _ in identity.processStartIdentity }
        let cgWindow = ServiceWindowInfo(
            windowID: 333,
            title: "CG Window",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600))
        let context = WindowEnumerationContext(
            service: service,
            app: Self.application(identity: identity),
            startTime: Date(),
            axTimeout: 0.05,
            hasScreenRecording: true,
            logger: Self.logger,
            processIdentity: identity,
            cgSnapshotProvider: { .init(windows: [cgWindow]) },
            applicationRunningProvider: { true },
            axEnumerator: { _, _ in throw CaptureError.detectionTimedOut(0.05) })

        let output = try await context.run()

        #expect(output.data.windows.map(\.windowID) == [333])
        #expect(output.data.windows.first?.observationCapability ==
            .unknown(reason: .accessibilityEnumerationIncomplete))
        #expect(output.summary.status == .partial)
        #expect(output.metadata.warnings.contains { $0.contains("timed out") })
    }

    @Test
    func `AX descriptor count shortfall keeps unmatched CG eligibility unknown`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 45, processStartIdentity: 10)
        let service = Self.makeService { _ in identity.processStartIdentity }
        let cgWindow = ServiceWindowInfo(
            windowID: 334,
            title: "CG Window",
            bounds: CGRect(x: 10, y: 20, width: 800, height: 600))
        let context = WindowEnumerationContext(
            service: service,
            app: Self.application(identity: identity),
            startTime: Date(),
            axTimeout: 0.05,
            hasScreenRecording: true,
            logger: Self.logger,
            processIdentity: identity,
            cgSnapshotProvider: { .init(windows: [cgWindow]) },
            applicationRunningProvider: { true },
            axEnumerator: { _, _ in
                // Production never filters AX rows for renderability. A shortfall means a read was
                // lost; this inconsistent injected result proves the merge still fails closed.
                DetachedAXWindowEnumerationResult(
                    descriptors: [],
                    focusedWindowID: nil,
                    timedOut: false,
                    incomplete: false,
                    reportedWindowCount: 1)
            })

        let output = try await context.run()

        #expect(output.data.windows.first?.observationCapability ==
            .unknown(reason: .accessibilityEnumerationIncomplete))
        #expect(output.metadata.warnings.contains { $0.contains("Accessibility reported 1 windows") })
    }

    @Test
    func `complete AX enrichment preserves CG order and focus metadata`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 43, processStartIdentity: 8)
        let service = Self.makeService { _ in identity.processStartIdentity }
        let bounds = CGRect(x: 20, y: 30, width: 700, height: 500)
        let cgWindow = ServiceWindowInfo(windowID: 444, title: "", bounds: bounds)
        let result = DetachedAXWindowEnumerationResult(
            descriptors: [
                DetachedAXWindowDescriptor(
                    windowID: 444,
                    title: "AX Title",
                    bounds: bounds,
                    isMainWindow: true,
                    subrole: "AXStandardWindow",
                    isMinimized: false),
            ],
            focusedWindowID: 444,
            timedOut: false,
            incomplete: false,
            reportedWindowCount: 1)
        let context = WindowEnumerationContext(
            service: service,
            app: Self.application(identity: identity, isActive: true),
            startTime: Date(),
            axTimeout: 0.1,
            hasScreenRecording: true,
            logger: Self.logger,
            processIdentity: identity,
            cgSnapshotProvider: { .init(windows: [cgWindow]) },
            applicationRunningProvider: { true },
            axEnumerator: { _, _ in result })

        let output = try await context.run()
        let window = try #require(output.data.windows.first)

        #expect(window.windowID == 444)
        #expect(window.title == "AX Title")
        #expect(window.isMainWindow)
        #expect(window.isKeyWindow == true)
        #expect(window.isFrontmost == true)
        #expect(window.observationCapability == .combinedEligible)
        #expect(output.summary.status == .success)
        #expect(output.metadata.warnings.isEmpty)
    }

    @Test
    func `process generation drift discards the complete inventory`() async throws {
        let identity = ApplicationProcessIdentity(processIdentifier: 44, processStartIdentity: 9)
        let generationReadCount = AutomationTestLockedValue(0)
        let service = Self.makeService { _ in
            generationReadCount.withValue {
                $0 += 1
                return $0 == 1 ? identity.processStartIdentity : identity.processStartIdentity + 1
            }
        }
        let context = WindowEnumerationContext(
            service: service,
            app: Self.application(identity: identity),
            startTime: Date(),
            axTimeout: 0.1,
            hasScreenRecording: true,
            logger: Self.logger,
            processIdentity: identity,
            cgSnapshotProvider: {
                .init(windows: [ServiceWindowInfo(windowID: 555, title: "CG", bounds: .zero)])
            },
            applicationRunningProvider: { true },
            axEnumerator: { _, _ in
                DetachedAXWindowEnumerationResult(
                    descriptors: [],
                    focusedWindowID: nil,
                    timedOut: false,
                    incomplete: false,
                    reportedWindowCount: 0)
            })

        await #expect(throws: (any Error).self) {
            _ = try await context.run()
        }
    }

    private static let logger = Logger(subsystem: "boo.peekaboo.tests", category: "WindowEnumerationTimeout")

    private static func application(
        identity: ApplicationProcessIdentity,
        isActive: Bool = false) -> ServiceApplicationInfo
    {
        ServiceApplicationInfo(
            processIdentifier: identity.processIdentifier,
            processStartIdentity: identity.processStartIdentity,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            isActive: isActive)
    }

    private static func makeService(
        processStartIdentityProvider: @escaping ApplicationService.ProcessStartIdentityProvider) -> ApplicationService
    {
        ApplicationService(
            applicationOpenHandler: { _, _, _ in throw FixtureError.unused },
            processStartIdentityProvider: processStartIdentityProvider)
    }
}

private enum FixtureError: Error {
    case unused
}

@Suite(.serialized)
struct DetachedAXWindowEnumerationCoordinatorTests {
    @Test
    func `timing reserves result publication grace before hard escape`() {
        let timing = DetachedAXWindowEnumerationTiming(hardTimeoutSeconds: 2)
        #expect(timing.softTimeoutSeconds > 1.7)
        #expect(timing.softTimeoutSeconds < timing.hardTimeoutSeconds)
        #expect(timing.hardTimeoutSeconds == 2)
    }

    @Test
    func `worker validates process generation and rejects foreign child ownership`() throws {
        let request = DetachedAXWindowEnumerationRequest(
            processIdentifier: 42,
            expectedProcessStartIdentity: 7,
            timeoutSeconds: 1,
            maximumWindowCount: 100)
        try DetachedAXWindowEnumerationWorker.validateIdentity(request) { pid in
            #expect(pid == 42)
            return 7
        }
        #expect(throws: (any Error).self) {
            try DetachedAXWindowEnumerationWorker.validateIdentity(request) { _ in 8 }
        }
        #expect(DetachedAXWindowEnumerationWorker.isExpectedOwner(
            observedProcessIdentifier: 42,
            expectedProcessIdentifier: 42))
        #expect(!DetachedAXWindowEnumerationWorker.isExpectedOwner(
            observedProcessIdentifier: 43,
            expectedProcessIdentifier: 42))
    }

    @Test
    func `noncooperative AX work hard-times out without blocking caller`() async throws {
        let gate = EnumerationBlockingGate()
        let startedAt = ContinuousClock.now

        await #expect(throws: CaptureError.self) {
            _ = try await DetachedAXWindowEnumerationCoordinator.run(
                processIdentifier: 91001,
                processStartIdentity: 1,
                timeoutSeconds: 0.05)
            { _ in
                gate.markStarted()
                gate.wait()
                return Self.emptyResult
            }
        }
        let elapsed = startedAt.duration(to: .now).timeInterval
        #expect(elapsed < 0.5)
        gate.release()
    }

    @Test
    func `same generation queued work expires without starting while another PID proceeds`() async throws {
        let gate = EnumerationBlockingGate()
        let first = Task {
            try await DetachedAXWindowEnumerationCoordinator.run(
                processIdentifier: 91002,
                processStartIdentity: 2,
                timeoutSeconds: 2)
            { _ in
                gate.markStarted()
                gate.wait()
                return Self.emptyResult
            }
        }
        #expect(gate.waitUntilStarted())

        let samePIDStarted = EnumerationFlag()
        await #expect(throws: CaptureError.self) {
            _ = try await DetachedAXWindowEnumerationCoordinator.run(
                processIdentifier: 91002,
                processStartIdentity: 2,
                timeoutSeconds: 0.05)
            { _ in
                samePIDStarted.set()
                return Self.emptyResult
            }
        }
        #expect(!samePIDStarted.value)

        let otherPID = try await DetachedAXWindowEnumerationCoordinator.run(
            processIdentifier: 91003,
            processStartIdentity: 3,
            timeoutSeconds: 0.5)
        { request in
            #expect(request.expectedProcessStartIdentity == 3)
            return Self.emptyResult
        }
        #expect(otherPID.descriptors.isEmpty)

        gate.release()
        _ = try await first.value
    }

    @Test
    @MainActor
    func `cancellation returns promptly while MainActor remains responsive`() async throws {
        let gate = EnumerationBlockingGate()
        var heartbeat = false
        let task = Task.detached {
            try await DetachedAXWindowEnumerationCoordinator.run(
                processIdentifier: 91004,
                processStartIdentity: 4,
                timeoutSeconds: 5)
            { _ in
                gate.markStarted()
                gate.wait()
                return Self.emptyResult
            }
        }
        #expect(gate.waitUntilStarted())

        Task { @MainActor in heartbeat = true }
        let heartbeatDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !heartbeat, ContinuousClock.now < heartbeatDeadline {
            await Task.yield()
        }
        #expect(heartbeat)

        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        gate.release()
    }

    private static let emptyResult = DetachedAXWindowEnumerationResult(
        descriptors: [],
        focusedWindowID: nil,
        timedOut: false,
        incomplete: false,
        reportedWindowCount: 0)
}

private final class EnumerationBlockingGate: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseGate = DispatchSemaphore(value: 0)

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
}

private final class EnumerationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        self.lock.withLock { self.storage }
    }

    func set() {
        self.lock.withLock { self.storage = true }
    }
}

extension Duration {
    fileprivate var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
