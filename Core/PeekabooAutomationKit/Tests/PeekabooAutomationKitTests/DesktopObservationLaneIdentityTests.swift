import CoreGraphics
import Foundation
import os
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct DesktopObservationLaneIdentityTests {
    private nonisolated static let phases: [(DesktopObservationLaneValidationPhase, String)] = [
        (.beforeOperation, "before the operation"),
        (.afterOperation, "after the operation"),
        (.afterCapture, "after capture"),
    ]
    private nonisolated static let bounds = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test(arguments: Self.phases)
    func `unavailable identity`(phase: DesktopObservationLaneValidationPhase, wording: String) {
        let service = self.makeService(windowIdentity: { _ in nil })

        #expect(throws: DesktopObservationError.targetChanged(
            "the exact window identity could not be re-read \(wording) " +
                "(the window or its owner process was unavailable, or its bounds moved while being read)"))
        {
            try service.validateCurrentLaneIdentity(self.windowPlan(), phase: phase)
        }
    }

    @Test(arguments: [-1, Int(UInt32.max) + 1])
    func `unrepresentable window ID is unavailable`(windowID: Int) {
        let service = self.makeService(windowIdentity: { _ in
            Issue.record("An unrepresentable window ID must not reach the provider")
            return Self.identity()
        })

        #expect(throws: DesktopObservationError.targetChanged(
            "the exact window identity could not be re-read before the operation " +
                "(the window or its owner process was unavailable, or its bounds moved while being read)"))
        {
            try service.validateCurrentLaneIdentity(
                self.windowPlan(identity: Self.identity(windowID: windowID)),
                phase: .beforeOperation)
        }
    }

    @Test(arguments: ["window ID", "owner PID", "owner process generation", "bounds"])
    func `names only changed component`(component: String) {
        let current: WindowMutationIdentity = switch component {
        case "window ID": Self.identity(windowID: 43)
        case "owner PID": Self.identity(ownerPID: 124)
        case "owner process generation": Self.identity(generation: 701)
        default: Self.identity(bounds: Self.bounds.offsetBy(dx: 1, dy: 0))
        }
        let service = self.makeService(windowIdentity: { _ in current })

        #expect(throws: DesktopObservationError.targetChanged(
            "the exact window \(component) changed after capture"))
        {
            try service.validateCurrentLaneIdentity(self.windowPlan(), phase: .afterCapture)
        }
    }

    @Test(arguments: [false, true])
    func `names multiple changed components`(allComponents: Bool) {
        let current = Self.identity(
            windowID: allComponents ? 43 : 42,
            ownerPID: allComponents ? 124 : 123,
            generation: 701,
            bounds: Self.bounds.offsetBy(dx: 1, dy: 0))
        let service = self.makeService(windowIdentity: { _ in current })
        let components = allComponents
            ? "window ID, owner PID, owner process generation and bounds"
            : "owner process generation and bounds"

        #expect(throws: DesktopObservationError.targetChanged(
            "the exact window \(components) changed after the operation"))
        {
            try service.validateCurrentLaneIdentity(self.windowPlan(), phase: .afterOperation)
        }
    }

    @Test
    func `missing captured bounds remains A mismatch`() {
        let current = WindowMutationIdentity(
            windowID: 42,
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 700)
        let service = self.makeService(windowIdentity: { _ in current })

        #expect(throws: DesktopObservationError.targetChanged("the exact window bounds changed after capture")) {
            try service.validateCurrentLaneIdentity(self.windowPlan(), phase: .afterCapture)
        }
    }

    @Test(arguments: Self.phases, [nil, 701] as [UInt64?])
    func `process generation failure`(
        phaseAndWording: (DesktopObservationLaneValidationPhase, String),
        generation: UInt64?)
    {
        let service = self.makeService(processGeneration: { _ in generation })
        let identity = Self.identity().processIdentity
        let plan = DesktopObservationLanePlan(
            scope: .process(identity),
            access: .read,
            expectedProcessIdentity: identity,
            expectedWindowIdentity: nil)

        #expect(throws: DesktopObservationError.targetChanged(
            "the target process generation changed \(phaseAndWording.1)"))
        {
            try service.validateCurrentLaneIdentity(plan, phase: phaseAndWording.0)
        }
    }

    @Test(arguments: Self.phases)
    func `matching identities pass`(phase: DesktopObservationLaneValidationPhase, wording _: String) throws {
        let service = self.makeService(windowIdentity: { _ in Self.identity().withMinimizedState(true) })
        let process = Self.identity().processIdentity

        try service.validateCurrentLaneIdentity(self.windowPlan(), phase: phase)
        try service.validateCurrentLaneIdentity(
            DesktopObservationLanePlan(
                scope: .process(process),
                access: .read,
                expectedProcessIdentity: process,
                expectedWindowIdentity: nil),
            phase: phase)
        try service.validateCurrentLaneIdentity(.global, phase: phase)
        try service.validateCurrentLaneIdentity(nil, phase: phase)
    }

    @Test
    func `lane rejects change before running operation`() async {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let service = self.makeService(windowIdentity: { _ in
            reads.withLock { count in
                count += 1
                return count == 1 ? Self.identity() : nil
            }
        })

        await #expect(throws: DesktopObservationError.targetChanged(
            "the exact window identity could not be re-read before the operation " +
                "(the window or its owner process was unavailable, or its bounds moved while being read)"))
        {
            try await service.withDesktopOperationLane(for: self.request()) { _ in
                Issue.record("The operation must not run after failed identity validation")
            }
        }
        #expect(reads.withLock { $0 } == 2)
    }

    @Test
    func `lane rejects change after running operation`() async {
        let current = OSAllocatedUnfairLock(initialState: Self.identity())
        let service = self.makeService(windowIdentity: { _ in current.withLock { $0 } })

        await #expect(throws: DesktopObservationError.targetChanged(
            "the exact window bounds changed after the operation"))
        {
            try await service.withDesktopOperationLane(for: self.request()) { _ in
                current.withLock { $0 = Self.identity(bounds: Self.bounds.offsetBy(dx: 1, dy: 0)) }
            }
        }
    }

    @Test
    func `observation rejects change immediately after capture`() async {
        let current = OSAllocatedUnfairLock(initialState: Self.identity())
        let capture = self.makeCaptureService {
            current.withLock { $0 = Self.identity(generation: 701) }
        }
        let service = self.makeService(capture: capture, windowIdentity: { _ in current.withLock { $0 } })
        // Suppress the existing passive receipt recovery while keeping this observation detection-free.
        let request = DesktopObservationRequest(
            target: .windowID(42),
            detection: DesktopDetectionOptions(mode: .none, allowWebFocusFallback: true))

        await #expect(throws: DesktopObservationError.targetChanged(
            "the exact window owner process generation changed after capture"))
        {
            _ = try await service.observe(request)
        }
        #expect(capture.operations.count == 1)
    }

    private func request() -> DesktopObservationRequest {
        DesktopObservationRequest(target: .windowID(42), detection: DesktopDetectionOptions(mode: .none))
    }

    private func windowPlan(identity: WindowMutationIdentity = Self.identity()) -> DesktopObservationLanePlan {
        DesktopObservationLanePlan(
            scope: .window(identity),
            access: .read,
            expectedProcessIdentity: identity.processIdentity,
            expectedWindowIdentity: identity)
    }

    private nonisolated static func identity(
        windowID: Int = 42,
        ownerPID: Int32 = 123,
        generation: UInt64 = 700,
        bounds: CGRect = Self.bounds) -> WindowMutationIdentity
    {
        WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: ownerPID,
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds)
    }

    private func makeService(
        capture: RecordingScreenCaptureService? = nil,
        processGeneration: @escaping @Sendable (pid_t) -> UInt64? = { _ in 700 },
        windowIdentity: @escaping @Sendable (CGWindowID) -> WindowMutationIdentity? = { _ in Self.identity() })
        -> DesktopObservationService
    {
        DesktopObservationService(
            screenCapture: capture ?? self.makeCaptureService(),
            automation: RecordingUIAutomationService(),
            applications: RecordingApplicationService(applications: [Self.application()], windows: [Self.window()]),
            exactWindowMetadataProvider: LaneExactWindowMetadataProvider(),
            processStartIdentityProvider: processGeneration,
            windowMutationIdentityProvider: windowIdentity)
    }

    private func makeCaptureService(onCapture: @escaping @MainActor () -> Void = {}) -> RecordingScreenCaptureService {
        RecordingScreenCaptureService(
            result: CaptureResult(
                imageData: Data([1]),
                metadata: CaptureMetadata(
                    size: Self.bounds.size,
                    mode: .window,
                    applicationInfo: Self.application(),
                    windowInfo: Self.window())),
            onCapture: onCapture)
    }

    private static func application() -> ServiceApplicationInfo {
        ServiceApplicationInfo(
            processIdentifier: 123,
            processStartIdentity: 700,
            bundleIdentifier: "com.example.fixture",
            name: "Fixture",
            windowCount: 1)
    }

    private static func window() -> ServiceWindowInfo {
        ServiceWindowInfo(windowID: 42, title: "Captured", bounds: self.bounds, mutationIdentity: self.identity())
    }
}

private struct LaneExactWindowMetadataProvider: ExactWindowMetadataProviding {
    func metadata(for windowID: CGWindowID) -> ExactWindowObservationMetadata? {
        guard windowID == 42 else { return nil }
        return ExactWindowObservationMetadata(
            ownerProcessIdentifier: 123,
            ownerProcessStartIdentity: 700,
            title: "Captured",
            bounds: CGRect(x: 100, y: 100, width: 400, height: 300),
            applicationName: "Fixture")
    }

    func processStartIdentity(for _: Int32) -> UInt64? {
        700
    }
}
