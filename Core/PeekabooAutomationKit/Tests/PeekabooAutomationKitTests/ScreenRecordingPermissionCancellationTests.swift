import Foundation
import PeekabooFoundation
import Testing
@_spi(Testing) @testable import PeekabooAutomationKit

@MainActor
struct ScreenRecordingPermissionCancellationTests {
    @Test
    func `ownership refusal survives required permission evaluation`() async throws {
        let blocker = ScreenCaptureKitOwnerLease.UncoordinatedProcess(
            processIdentifier: 4242, processStartIdentity: 9001, executablePath: "/synthetic/Host")
        let diagnostic = ScreenCaptureKitOwnershipDiagnostic.capturing(
            ScreenCaptureKitOwnerLease.LeaseError.uncoordinatedProcesses([blocker]), stage: .entry)
        var probes = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            coreGraphicsEvidence: { false },
            shareableContentProbe: {
                probes += 1
                throw diagnostic
            })
        let gate = ScreenCapturePermissionGate(evaluator: checker)
        let error = await #expect(throws: ScreenCaptureKitOwnershipDiagnostic.self) {
            try await gate.requirePermission(
                logger: MockLoggingService().logger(category: "test"),
                correlationId: "test")
        }
        #expect(error == diagnostic)
        #expect(probes == 1)
    }

    @Test
    func `cancel during transient permission retry skips second probe`() async {
        let logger = MockLoggingService().logger(category: "test")
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
                throw Self.transientDenial
            })

        let task = Task { @MainActor in
            await checker.hasPermission(logger: logger)
        }

        while probeCount == 0 {
            await Task.yield()
        }
        task.cancel()

        #expect(await task.value == false)
        #expect(probeCount == 1)
    }

    @Test
    func `noncancelled transient permission retry probes twice`() async {
        let logger = MockLoggingService().logger(category: "test")
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            shareableContentProbe: {
                probeCount += 1
                throw Self.transientDenial
            })

        #expect(await checker.hasPermission(logger: logger) == false)
        #expect(probeCount == 2)
    }

    @Test
    func `classic permission policy accepts protected metadata without probing ScreenCaptureKit`() async {
        let logger = MockLoggingService().logger(category: "test")
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            coreGraphicsEvidence: { true },
            shareableContentProbe: { probeCount += 1 })

        let granted = await checker.hasPermission(logger: logger, policy: .coreGraphicsOnly)

        #expect(granted)
        #expect(probeCount == 0)
    }

    @Test
    func `classic permission policy refuses redaction risk without protected metadata`() async {
        let logger = MockLoggingService().logger(category: "test")
        var probeCount = 0
        let checker = ScreenRecordingPermissionChecker(
            preflight: { false },
            coreGraphicsEvidence: { false },
            shareableContentProbe: { probeCount += 1 })

        let granted = await checker.hasPermission(logger: logger, policy: .coreGraphicsOnly)

        #expect(!granted)
        #expect(probeCount == 0)
    }

    private static let transientDenial = NSError(
        domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain",
        code: -3801,
        userInfo: [
            NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture",
        ])
}
