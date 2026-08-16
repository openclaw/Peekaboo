import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooCore

@MainActor
struct RemoteDesktopObservationFailurePreservationTests {
    @Test
    func `untyped post-processing failure preserves process-only remote target`() throws {
        let target = try Self.processTarget(processIdentifier: 6101, processStartIdentity: 7101)
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))

        let error = RemoteDesktopObservationService.failurePreservingOutcome(
            ObservationPostProcessingError(),
            from: UIAutomationActionResult(payload: (), outcome: outcome, targetIdentity: target))
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.outcome == outcome)
        #expect(failure.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 6101,
            processStartIdentity: 7101))
    }

    @Test
    func `typed pre-dispatch refusal composes with prior remote dispatch`() throws {
        let target = try Self.exactTarget(
            processIdentifier: 6102,
            processStartIdentity: 7102,
            windowID: 8102)
        let outcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: Self.delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let refusal = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Local validation target disappeared")
            .attributed(to: DesktopActionTargetReceipt(
                processIdentifier: 6109,
                processStartIdentity: 7109,
                windowID: 8109))

        let error = RemoteDesktopObservationService.failurePreservingOutcome(
            refusal,
            from: UIAutomationActionResult(payload: (), outcome: outcome, targetIdentity: target))
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 6102,
            processStartIdentity: 7102,
            windowID: 8102))
    }

    @Test
    func `two dispatched phases sum units and drop incompatible targets`() throws {
        let target = try Self.exactTarget(
            processIdentifier: 6103,
            processStartIdentity: 7103,
            windowID: 8103)
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let laterFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: Self.delivery,
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3),
            message: "Local commit completion is unknown")
            .attributed(to: DesktopActionTargetReceipt(
                processIdentifier: 6103,
                processStartIdentity: 7103,
                windowID: 8104))

        let error = RemoteDesktopObservationService.failurePreservingOutcome(
            laterFailure,
            from: UIAutomationActionResult(payload: (), outcome: outcome, targetIdentity: target))
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 5)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == nil)
    }

    @Test
    func `missing prior outcome returns original post-processing error`() {
        let original = ObservationPostProcessingReferenceError()

        let error = RemoteDesktopObservationService.failurePreservingOutcome(
            original,
            from: UIAutomationActionResult(payload: (), outcome: nil, targetIdentity: nil))

        #expect((error as? ObservationPostProcessingReferenceError) === original)
    }

    private static let delivery = DesktopActionOutcome.Delivery(
        mechanism: .capturePipeline,
        mode: .background)

    private static func processTarget(
        processIdentifier: Int32,
        processStartIdentity: UInt64) throws -> DesktopTargetIdentity
    {
        try DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity))
    }

    private static func exactTarget(
        processIdentifier: Int32,
        processStartIdentity: UInt64,
        windowID: Int) throws -> DesktopTargetIdentity
    {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: windowID,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: bounds)
        return try DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
            identity: identity,
            bounds: bounds))
    }
}

private struct ObservationPostProcessingError: LocalizedError {
    var errorDescription: String? {
        "Observation post-processing failed"
    }
}

private final class ObservationPostProcessingReferenceError: Error {}
