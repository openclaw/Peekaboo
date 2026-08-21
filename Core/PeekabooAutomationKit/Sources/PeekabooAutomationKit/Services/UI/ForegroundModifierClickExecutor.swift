import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
final class ForegroundModifierClickExecutor {
    struct Dependencies {
        let focusExactWindow: @MainActor (
            UIAutomationTarget.ExactWindow,
            FocusFirstDispatchGuard) async throws -> DesktopActionOutcome
        let currentFrontmostIdentity: @MainActor () -> ApplicationProcessIdentity?
        let currentFocusedExactWindow: @MainActor () -> UIAutomationTarget.ExactWindow?
        let activate: @MainActor (
            ApplicationProcessIdentity,
            FocusFirstDispatchGuard) async throws -> Bool
        let currentCursorLocation: @MainActor () -> CGPoint?
        let moveCursor: @MainActor (CGPoint) throws -> Void
        let click: @MainActor (CGPoint, ClickType, [PointerModifier]) throws -> DesktopActionOutcome
        let validateExactWindow: @Sendable (WindowMutationIdentity, CGRect) -> Bool
    }

    private let laneCoordinator: DesktopOperationLaneCoordinator
    private let dependencies: Dependencies

    init(
        laneCoordinator: DesktopOperationLaneCoordinator,
        dependencies: Dependencies)
    {
        self.laneCoordinator = laneCoordinator
        self.dependencies = dependencies
    }

    func execute(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: request.windowIdentity,
            bounds: request.windowBounds)
        let targetIdentity = DesktopTargetIdentity(exactWindow: exactWindow)
        do {
            return try await self.laneCoordinator.run(scope: .global, access: .write) {
                try await self.executeOwned(request, exactWindow: exactWindow, targetIdentity: targetIdentity)
            }
        } catch let failure as DesktopActionFailure {
            throw failure.attributed(to: targetIdentity.actionTargetReceipt)
        }
    }

    private func executeOwned(
        _ request: ForegroundModifierClickRequest,
        exactWindow: UIAutomationTarget.ExactWindow,
        targetIdentity: DesktopTargetIdentity) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        try self.validate(request, exactWindow: exactWindow)
        guard let priorFrontmost = self.dependencies.currentFrontmostIdentity() else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not capture the prior foreground application for restoration.")
        }
        let priorFocusedWindow = self.dependencies.currentFocusedExactWindow()
        guard priorFrontmost != exactWindow.identity.processIdentity || priorFocusedWindow != nil else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not capture the exact prior focused window for restoration.")
        }
        guard let originalCursor = self.dependencies.currentCursorLocation() else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not capture the physical cursor for restoration.")
        }
        var sequence = DesktopActionSequenceAccumulator()
        var primaryFailure: (any Error)?
        var cleanupFailures: [(phase: String, failure: DesktopActionFailure)] = []

        do {
            let focusOutcome = try await self.dependencies.focusExactWindow(exactWindow, FocusFirstDispatchGuard())
            sequence.record(.reportedOutcome(focusOutcome, defaultDispatchedUnitCount: .one))
            guard focusOutcome.isConfirmed,
                  self.dependencies.currentFrontmostIdentity() == request.windowIdentity.processIdentity,
                  self.dependencies.currentFocusedExactWindow() == exactWindow,
                  self.dependencies.validateExactWindow(request.windowIdentity, request.windowBounds)
            else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Modifier-click could not confirm the exact foreground window.")
            }
        } catch {
            primaryFailure = error
        }

        if primaryFailure == nil {
            do {
                let clickOutcome = try self.dependencies.click(
                    request.point,
                    request.clickType,
                    request.modifiers)
                sequence.record(.reportedOutcome(clickOutcome, defaultDispatchedUnitCount: .one))
            } catch {
                primaryFailure = error
            }
        }

        var cursorRestoration = SharedDesktopRestorationStatus.notNeeded
        let cursorRestorationPrefixCount = sequence.completedStepCount
        do {
            cursorRestoration = try self.restoreCursorIfOwned(
                original: originalCursor,
                lastWritten: request.point,
                sequence: &sequence)
        } catch {
            cleanupFailures.append((
                phase: "Cursor restoration",
                failure: self.restorationFailure(
                    error,
                    stepWasRecorded: sequence.completedStepCount != cursorRestorationPrefixCount,
                    delivery: Self.globalForeground,
                    message: "Modifier-click could not restore the physical cursor.")))
        }

        var focusRestoration = SharedDesktopRestorationStatus.notNeeded
        let focusRestorationPrefixCount = sequence.completedStepCount
        do {
            focusRestoration = try await self.restoreFocusIfOwned(
                priorProcess: priorFrontmost,
                priorWindow: priorFocusedWindow,
                targetWindow: exactWindow,
                sequence: &sequence)
        } catch {
            cleanupFailures.append((
                phase: "Focus restoration",
                failure: self.restorationFailure(
                    error,
                    stepWasRecorded: sequence.completedStepCount != focusRestorationPrefixCount,
                    delivery: Self.nativeForeground,
                    message: "Modifier-click could not restore the prior foreground window or application.")))
        }

        if !cleanupFailures.isEmpty {
            var failures = cleanupFailures
            if let primaryFailure {
                failures.insert((
                    phase: "Primary action",
                    failure: self.primaryActionFailure(primaryFailure)), at: 0)
            }
            var aggregate = sequence
            for entry in failures.dropLast() {
                aggregate.record(.outcome(entry.failure.outcome))
            }
            let leaf = failures[failures.index(before: failures.endIndex)]
            throw aggregate.failure(
                combining: leaf.failure,
                message: "Modifier-click cleanup did not fully restore the shared desktop.",
                hint: "Inspect the shared desktop state before taking another input action.",
                causeDescription: failures.map(Self.failureDescription).joined(separator: " "))
        }

        if let primaryFailure {
            if let failure = primaryFailure as? DesktopActionFailure {
                throw sequence.failure(
                    combining: failure,
                    message: "Modifier-click failed after foreground setup began.",
                    hint: "Observe the exact target before deciding whether to retry.")
            }
            let leaf = DesktopActionFailure.indeterminate(
                delivery: Self.globalForeground,
                evidence: .completionUnknown,
                message: "Modifier-click completion is unknown.",
                hint: "Observe the exact target before deciding whether to retry.",
                causeDescription: primaryFailure.localizedDescription)
            throw sequence.failure(
                combining: leaf,
                message: "Modifier-click failed after foreground setup began.",
                hint: "Observe the exact target before deciding whether to retry.")
        }

        let resolution = sequence.successResolution()
        guard let outcome = resolution.outcome else {
            throw DesktopActionFailure.indeterminate(
                delivery: Self.globalForeground,
                evidence: .completionUnknown,
                unitCount: resolution.mutationDisposition.unitCount,
                message: "Modifier-click completed without a composable action outcome.",
                hint: "Observe the exact target before deciding whether to retry.")
        }
        return UIAutomationActionResult(
            payload: ForegroundModifierClickResult(
                cursorRestoration: cursorRestoration,
                focusRestoration: focusRestoration),
            outcome: outcome,
            targetIdentity: targetIdentity)
    }

    private func validate(
        _ request: ForegroundModifierClickRequest,
        exactWindow: UIAutomationTarget.ExactWindow) throws
    {
        guard request.point.x.isFinite,
              request.point.y.isFinite,
              exactWindow.bounds.contains(request.point)
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Modifier-click point must be finite and inside the exact target window.")
        }
        guard !request.modifiers.isEmpty,
              Set(request.modifiers.map(\.rawValue)).count == request.modifiers.count
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Modifier-click requires one or more unique modifiers.")
        }
        guard request.clickType != .longPress else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "Modifier-click does not support long press.")
        }
        guard self.dependencies.validateExactWindow(request.windowIdentity, request.windowBounds) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click exact-window receipt is stale.")
        }
    }

    private func restoreCursorIfOwned(
        original: CGPoint,
        lastWritten: CGPoint,
        sequence: inout DesktopActionSequenceAccumulator) throws -> SharedDesktopRestorationStatus
    {
        guard let current = self.dependencies.currentCursorLocation() else {
            throw ForegroundModifierClickError.cursorRestorationUnverified
        }
        if Self.pointsMatch(current, original) {
            return .notNeeded
        }
        guard Self.pointsMatch(current, lastWritten) else {
            return .preservedNewerState
        }
        try self.dependencies.moveCursor(original)
        sequence.record(.dispatched(route: .local, delivery: Self.globalForeground, unitCount: .one))
        guard self.dependencies.currentCursorLocation().map({ Self.pointsMatch($0, original) }) == true else {
            throw ForegroundModifierClickError.cursorRestorationUnverified
        }
        return .restored
    }

    private func restoreFocusIfOwned(
        priorProcess: ApplicationProcessIdentity,
        priorWindow: UIAutomationTarget.ExactWindow?,
        targetWindow: UIAutomationTarget.ExactWindow,
        sequence: inout DesktopActionSequenceAccumulator) async throws -> SharedDesktopRestorationStatus
    {
        if let priorWindow {
            let currentWindow = self.dependencies.currentFocusedExactWindow()
            if currentWindow == priorWindow {
                return .notNeeded
            }
            guard priorWindow != targetWindow, currentWindow == targetWindow else {
                return .preservedNewerState
            }
            let outcome: DesktopActionOutcome
            do {
                let dispatchGuard = FocusFirstDispatchGuard {
                    let dispatchCurrent = self.dependencies.currentFocusedExactWindow()
                    if dispatchCurrent == priorWindow {
                        throw ForegroundModifierClickError.focusRestorationBecameUnnecessary
                    }
                    guard dispatchCurrent == targetWindow else {
                        throw ForegroundModifierClickError.focusRestorationOwnershipLost
                    }
                }
                outcome = try await self.dependencies.focusExactWindow(priorWindow, dispatchGuard)
            } catch ForegroundModifierClickError.focusRestorationBecameUnnecessary {
                return .notNeeded
            } catch ForegroundModifierClickError.focusRestorationOwnershipLost {
                return .preservedNewerState
            }
            sequence.record(.reportedOutcome(outcome, defaultDispatchedUnitCount: .one))
            guard outcome.isConfirmed,
                  self.dependencies.currentFocusedExactWindow() == priorWindow
            else {
                throw ForegroundModifierClickError.focusRestorationUnverified
            }
            return .restored
        }

        guard priorProcess != targetWindow.identity.processIdentity else { return .notNeeded }
        let current = self.dependencies.currentFrontmostIdentity()
        if current == priorProcess {
            return .notNeeded
        }
        guard current == targetWindow.identity.processIdentity else {
            return .preservedNewerState
        }
        do {
            let dispatchGuard = FocusFirstDispatchGuard {
                let dispatchCurrent = self.dependencies.currentFrontmostIdentity()
                if dispatchCurrent == priorProcess {
                    throw ForegroundModifierClickError.focusRestorationBecameUnnecessary
                }
                guard dispatchCurrent == targetWindow.identity.processIdentity else {
                    throw ForegroundModifierClickError.focusRestorationOwnershipLost
                }
            }
            guard try await self.dependencies.activate(priorProcess, dispatchGuard) else {
                throw ForegroundModifierClickError.focusRestorationUnverified
            }
        } catch ForegroundModifierClickError.focusRestorationBecameUnnecessary {
            return .notNeeded
        } catch ForegroundModifierClickError.focusRestorationOwnershipLost {
            return .preservedNewerState
        }
        sequence.record(.dispatched(route: .local, delivery: Self.nativeForeground, unitCount: .one))
        guard self.dependencies.currentFrontmostIdentity() == priorProcess else {
            throw ForegroundModifierClickError.focusRestorationUnverified
        }
        return .restored
    }

    private func primaryActionFailure(_ error: any Error) -> DesktopActionFailure {
        if let failure = error as? DesktopActionFailure {
            return failure
        }
        return .indeterminate(
            delivery: Self.globalForeground,
            evidence: .completionUnknown,
            message: "Modifier-click completion is unknown.",
            hint: "Observe the exact target before deciding whether to retry.",
            causeDescription: error.localizedDescription)
    }

    private func restorationFailure(
        _ error: any Error,
        stepWasRecorded: Bool,
        delivery: DesktopActionOutcome.Delivery,
        message: String) -> DesktopActionFailure
    {
        if let failure = error as? DesktopActionFailure {
            return failure
        }
        if stepWasRecorded {
            return .preDispatchRefusal(
                reason: .targetUnavailable,
                message: message,
                hint: "Inspect the shared desktop state before taking another input action.",
                causeDescription: error.localizedDescription)
        }
        return .indeterminate(
            delivery: delivery,
            evidence: .completionUnknown,
            message: message,
            hint: "Inspect the shared desktop state before taking another input action.",
            causeDescription: error.localizedDescription)
    }

    private static func failureDescription(
        _ entry: (phase: String, failure: DesktopActionFailure)) -> String
    {
        "\(entry.phase): \(entry.failure.message) \(entry.failure.causeDescription ?? "")"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pointsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 0.5 && abs(lhs.y - rhs.y) <= 0.5
    }

    private static let globalForeground = DesktopActionOutcome.Delivery(
        mechanism: .globalEvents,
        mode: .foreground)
    private static let nativeForeground = DesktopActionOutcome.Delivery(
        mechanism: .nativeFramework,
        mode: .foreground)
}

private enum ForegroundModifierClickError: LocalizedError {
    case cursorRestorationUnverified
    case focusRestorationBecameUnnecessary
    case focusRestorationOwnershipLost
    case focusRestorationUnverified

    var errorDescription: String? {
        switch self {
        case .cursorRestorationUnverified:
            "The physical cursor did not return to its captured location."
        case .focusRestorationBecameUnnecessary:
            "The prior foreground state was restored before Peekaboo dispatched restoration."
        case .focusRestorationOwnershipLost:
            "Newer foreground state replaced Peekaboo's target before restoration dispatch."
        case .focusRestorationUnverified:
            "The prior foreground window or application could not be re-established."
        }
    }
}
