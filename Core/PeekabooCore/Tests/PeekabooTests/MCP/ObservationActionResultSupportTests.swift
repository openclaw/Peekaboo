import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP
import Testing
@testable import PeekabooAgentRuntime

struct ObservationActionResultSupportTests {
    @Test
    func `typed refusal after confirmed observation dispatch remains retry unsafe`() throws {
        let target = try Self.target(windowID: 71)
        let priorOutcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: Self.delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let laterFailure = DesktopActionFailure.preDispatchRefusal(
            route: .bridge,
            reason: .permissionDenied,
            message: "Rendering was refused")

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(payload: (), outcome: priorOutcome, targetIdentity: target),
            operation: "inspect_ui")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.delivery == Self.delivery)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == Self.receipt(windowID: 71))
    }

    @Test
    func `typed indeterminate follow up sums exact units and retains matching target`() throws {
        let target = try Self.target(windowID: 72)
        let priorOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let laterFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: Self.delivery,
            evidence: .responseLost,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3),
            message: "Rendering response was lost")
            .attributed(to: Self.receipt(windowID: 72))

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(payload: (), outcome: priorOutcome, targetIdentity: target),
            operation: "see")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .responseLost)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 5)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == Self.receipt(windowID: 72))
    }

    @Test
    func `typed follow up drops contradictory aggregate target`() throws {
        let target = try Self.target(windowID: 73)
        let priorOutcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let laterFailure = DesktopActionFailure.indeterminate(
            route: .bridge,
            delivery: Self.delivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "A different target failed")
            .attributed(to: Self.receipt(windowID: 74))

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(payload: (), outcome: priorOutcome, targetIdentity: target),
            operation: "see")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == nil)
    }

    @Test
    func `untyped follow up after confirmed dispatch preserves units target and retry unsafety`() throws {
        let target = try Self.target(windowID: 75)
        let priorOutcome = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: Self.delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(4))

        let error = ObservationActionResultSupport.preservingFailure(
            ObservationRenderingError(),
            after: UIAutomationActionResult(payload: (), outcome: priorOutcome, targetIdentity: target),
            operation: "inspect_ui")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.delivery == Self.delivery)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 4)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.targetReceipt == Self.receipt(windowID: 75))
    }

    @Test
    func `metadata projects process generation without inventing a window`() throws {
        let target = try Self.processTarget(processIdentifier: 5201, processStartIdentity: 6201)
        let result = UIAutomationActionResult(
            payload: (),
            outcome: DesktopActionOutcome.dispatchedUnverified(
                delivery: Self.delivery,
                evidence: .deliveryAccepted,
                unitCount: .one),
            targetIdentity: target)

        let metadata = try ObservationActionResultSupport.metadata(merging: [:], result: result)
        let fields = try #require(metadata?.objectValue)
        let receipt = try #require(fields["target_receipt"]?.objectValue)

        #expect(receipt["pid"] == .int(5201))
        #expect(receipt["process_start_identity_decimal"] == .string("6201"))
        #expect(receipt["window_id"] == nil)
    }

    @Test
    func `typed failure retains compatible process scope across exact follow up`() throws {
        let target = try Self.processTarget(processIdentifier: 5202, processStartIdentity: 6202)
        let priorOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let laterFailure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Follow-up target disappeared")
            .attributed(to: DesktopActionTargetReceipt(
                processIdentifier: 5202,
                processStartIdentity: 6202,
                windowID: 82))

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(payload: (), outcome: priorOutcome, targetIdentity: target),
            operation: "see")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 5202,
            processStartIdentity: 6202))
        #expect(failure.outcome.retrySafety == .unsafe)
    }

    @Test
    func `two dispatched phases drop incompatible process generation`() throws {
        let target = try Self.processTarget(processIdentifier: 5203, processStartIdentity: 6203)
        let priorOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let laterFailure = DesktopActionFailure.indeterminate(
            delivery: Self.delivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Follow-up target changed generation")
            .attributed(to: DesktopActionTargetReceipt(
                processIdentifier: 5203,
                processStartIdentity: 7203))

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(payload: (), outcome: priorOutcome, targetIdentity: target),
            operation: "inspect_ui")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.targetReceipt == nil)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(failure.outcome.retrySafety == .unsafe)
    }

    @Test
    func `untyped failure retains process-only target`() throws {
        let target = try Self.processTarget(processIdentifier: 5204, processStartIdentity: 6204)
        let priorOutcome = DesktopActionOutcome.confirmedChange(
            delivery: Self.delivery,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))

        let error = ObservationActionResultSupport.preservingFailure(
            ObservationRenderingError(),
            after: UIAutomationActionResult(payload: (), outcome: priorOutcome, targetIdentity: target),
            operation: "see")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 5204,
            processStartIdentity: 6204))
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(failure.outcome.retrySafety == .unsafe)
    }

    @Test
    func `later unknown dispatch does not inherit prior no-dispatch exact target`() throws {
        let priorTarget = try Self.target(windowID: 91)
        let laterFailure = DesktopActionFailure.indeterminate(
            delivery: Self.delivery,
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2),
            message: "Follow-up dispatch target is unknown")

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(
                payload: (),
                outcome: DesktopActionOutcome.confirmedNoChange(),
                targetIdentity: priorTarget),
            operation: "see")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.targetReceipt == nil)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(failure.outcome.retrySafety == .unsafe)
    }

    @Test
    func `unknown prior dispatch is not attributed to later no-dispatch target`() throws {
        let priorOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let laterFailure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Follow-up target disappeared")
            .attributed(to: Self.receipt(windowID: 92))

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(payload: (), outcome: priorOutcome, targetIdentity: nil),
            operation: "inspect_ui")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.targetReceipt == nil)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        #expect(failure.outcome.retrySafety == .unsafe)
    }

    @Test
    func `only later dispatched phase owns aggregate process target`() throws {
        let priorTarget = try Self.target(windowID: 93)
        let laterTarget = DesktopActionTargetReceipt(
            processIdentifier: 5303,
            processStartIdentity: 6303)
        let laterFailure = DesktopActionFailure.indeterminate(
            delivery: Self.delivery,
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3),
            message: "Follow-up process dispatch is unknown")
            .attributed(to: laterTarget)

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(
                payload: (),
                outcome: DesktopActionOutcome.confirmedNoChange(),
                targetIdentity: priorTarget),
            operation: "see")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.targetReceipt == laterTarget)
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(failure.outcome.retrySafety == .unsafe)
    }

    @Test
    func `two dispatched phases retain compatible common process scope and sum units`() throws {
        let priorTarget = try Self.processTarget(processIdentifier: 5304, processStartIdentity: 6304)
        let priorOutcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: Self.delivery,
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let laterFailure = DesktopActionFailure.indeterminate(
            delivery: Self.delivery,
            evidence: .completionUnknown,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3),
            message: "Exact-window follow-up completion is unknown")
            .attributed(to: DesktopActionTargetReceipt(
                processIdentifier: 5304,
                processStartIdentity: 6304,
                windowID: 94))

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(payload: (), outcome: priorOutcome, targetIdentity: priorTarget),
            operation: "inspect_ui")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 5304,
            processStartIdentity: 6304))
        #expect(failure.outcome.dispatchState.unitCount?.rawValue == 5)
        #expect(failure.outcome.retrySafety == .unsafe)
    }

    @Test
    func `two no-dispatch phases retain compatible process refusal scope`() throws {
        let priorTarget = try Self.target(
            processIdentifier: 5305,
            processStartIdentity: 6305,
            windowID: 95)
        let laterFailure = DesktopActionFailure.preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Process-scoped follow-up was refused")
            .attributed(to: DesktopActionTargetReceipt(
                processIdentifier: 5305,
                processStartIdentity: 6305))

        let error = ObservationActionResultSupport.preservingFailure(
            laterFailure,
            after: UIAutomationActionResult(
                payload: (),
                outcome: DesktopActionOutcome.confirmedNoChange(),
                targetIdentity: priorTarget),
            operation: "see")
        let failure = try #require(error as? DesktopActionFailure)

        #expect(failure.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: 5305,
            processStartIdentity: 6305))
        #expect(failure.outcome.dispatchState == .none)
        #expect(failure.outcome.retrySafety == .safe)
    }

    private static let delivery = DesktopActionOutcome.Delivery(
        mechanism: .accessibilityAction,
        mode: .background)

    private static func target(windowID: Int) throws -> DesktopTargetIdentity {
        try self.target(
            processIdentifier: 5151,
            processStartIdentity: 6161,
            windowID: windowID)
    }

    private static func target(
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

    private static func processTarget(
        processIdentifier: Int32,
        processStartIdentity: UInt64) throws -> DesktopTargetIdentity
    {
        try DesktopTargetIdentity(processIdentity: ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity))
    }

    private static func receipt(windowID: Int) -> DesktopActionTargetReceipt {
        DesktopActionTargetReceipt(
            processIdentifier: 5151,
            processStartIdentity: 6161,
            windowID: windowID)
    }
}

private struct ObservationRenderingError: LocalizedError {
    var errorDescription: String? {
        "Observation rendering failed"
    }
}
