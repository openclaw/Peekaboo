import Foundation
import os.log
import PeekabooFoundation

/// Executes one validated desktop operation under exactly one coordination lane.
@MainActor
final class DesktopOperationExecutor {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "DesktopOperationExecutor")
    private let laneCoordinator: DesktopOperationLaneCoordinator

    init(laneCoordinator: DesktopOperationLaneCoordinator = .shared) {
        self.laneCoordinator = laneCoordinator
    }

    func execute(_ plan: DesktopOperationPlan) async throws -> UIInputExecutionResult {
        try await self.laneCoordinator.run(scope: plan.laneScope, access: .write) {
            try await self.executeOwned(plan)
        }
    }

    func executeWithTargetIdentity(
        _ plan: DesktopOperationPlan) async throws -> UIAutomationActionResult<UIInputExecutionResult>
    {
        let targetIdentity = try plan.targetIdentity()
        do {
            let result = try await self.execute(plan)
            return UIAutomationActionResult(
                payload: result,
                outcome: result.outcome,
                targetIdentity: targetIdentity)
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: targetIdentity?.actionTargetReceipt)
        }
    }

    func executeOwned(_ plan: DesktopOperationPlan) async throws -> UIInputExecutionResult {
        do {
            let result = try await self.executePrepared(plan)
            await plan.finalize()
            return result
        } catch {
            await plan.finalize()
            throw error
        }
    }

    private func executePrepared(_ plan: DesktopOperationPlan) async throws -> UIInputExecutionResult {
        let startedAt = Date()
        try await plan.prepare()
        let routing = plan.routing()
        let result: UIInputExecutionResult
        switch routing.strategy {
        case .actionFirst:
            do {
                result = try await self.executeAction(plan, routing: routing, startedAt: startedAt)
            } catch let error as ActionInputError where error.allowsSynthesisFallback {
                self.logger.debug(
                    """
                    Desktop operation falling back verb=\(plan.verb.rawValue, privacy: .public) \
                    reason=\(error.fallbackReason.rawValue, privacy: .public)
                    """)
                result = try await self.executeSynthesis(
                    plan,
                    routing: routing,
                    startedAt: startedAt,
                    fallbackReason: error.fallbackReason)
            }
        case .synthFirst, .synthOnly:
            result = try await self.executeSynthesis(
                plan,
                routing: routing,
                startedAt: startedAt,
                fallbackReason: nil)
        case .actionOnly:
            result = try await self.executeAction(plan, routing: routing, startedAt: startedAt)
        }
        try Self.validateDeliveryIntent(plan.deliveryIntent, result: result)
        try await plan.postvalidate(result)
        await plan.success(result)
        return result
    }

    private static func validateDeliveryIntent(
        _ intent: DesktopOperationPlan.DeliveryIntent,
        result: UIInputExecutionResult) throws
    {
        let delivery = result.outcome.delivery
        let reportsBackgroundDelivery = delivery?.mode == .background && delivery?.mechanism != .globalEvents
        guard intent == .background,
              result.outcome.dispatchState.mutationDispatched,
              !reportsBackgroundDelivery
        else { return }
        let message = "Background desktop operation did not report background delivery"
        let hint = "Observe both the target and foreground app before retrying."
        if let failure = DesktopActionFailure(
            outcome: result.outcome,
            message: message,
            hint: hint)
        {
            throw failure
        }
        throw DesktopActionFailure.indeterminate(
            delivery: result.outcome.delivery,
            evidence: .completionUnknown,
            unitCount: result.outcome.dispatchState.unitCount,
            message: message,
            hint: hint)
    }

    private func executeAction(
        _ plan: DesktopOperationPlan,
        routing: DesktopOperationPlan.Routing,
        startedAt: Date) async throws -> UIInputExecutionResult
    {
        guard let action = plan.action else {
            throw ActionInputError.unsupported(.missingElement)
        }
        try await action.preflight()
        let result = try await action.execute()
        return UIInputExecutionResult(
            outcome: result.outcome,
            verb: plan.verb,
            strategy: routing.strategy,
            path: .action,
            bundleIdentifier: routing.bundleIdentifier,
            elementRole: result.elementRole,
            actionName: result.actionName,
            anchorPoint: result.anchorPoint,
            duration: Date().timeIntervalSince(startedAt))
    }

    private func executeSynthesis(
        _ plan: DesktopOperationPlan,
        routing: DesktopOperationPlan.Routing,
        startedAt: Date,
        fallbackReason: UIInputFallbackReason?) async throws -> UIInputExecutionResult
    {
        try await plan.synthesis.preflight()
        let outcome = try await plan.synthesis.execute()
        return UIInputExecutionResult(
            outcome: outcome,
            verb: plan.verb,
            strategy: routing.strategy,
            path: .synth,
            fallbackReason: fallbackReason,
            bundleIdentifier: routing.bundleIdentifier,
            duration: Date().timeIntervalSince(startedAt))
    }
}

extension ActionInputError {
    var allowsSynthesisFallback: Bool {
        switch self {
        case .unsupported:
            true
        case .staleElement, .permissionDenied, .targetUnavailable, .failed:
            false
        }
    }

    var fallbackReason: UIInputFallbackReason {
        switch self {
        case let .unsupported(reason):
            switch reason {
            case .actionUnsupported: .actionUnsupported
            case .attributeUnsupported: .attributeUnsupported
            case .valueNotSettable: .valueNotSettable
            case .secureValueNotAllowed: .secureValueNotAllowed
            case .menuShortcutUnavailable: .menuShortcutUnavailable
            case .missingElement: .missingElement
            }
        case .staleElement: .staleElement
        case .targetUnavailable, .failed, .permissionDenied: .actionFailed
        }
    }
}
