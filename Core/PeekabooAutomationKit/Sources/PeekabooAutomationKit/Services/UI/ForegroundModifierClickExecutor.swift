import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation

private struct FocusRestorationObservation: Equatable {
    let frontmostProcess: ApplicationProcessIdentity
    let focusedWindow: UIAutomationTarget.ExactWindow
}

@MainActor
private final class FocusRestorationOwnershipState {
    var expected: FocusRestorationObservation

    init(expected: FocusRestorationObservation) {
        self.expected = expected
    }
}

@MainActor
final class ForegroundModifierClickExecutor {
    typealias ExactWindowFocusExecutor = @MainActor (
        UIAutomationTarget.ExactWindow,
        FocusDispatchGuard) async throws -> DesktopActionOutcome

    struct Dependencies {
        let focusExactWindow: ExactWindowFocusExecutor
        let restoreExactWindow: ExactWindowFocusExecutor
        let currentFrontmostIdentity: @MainActor () -> ApplicationProcessIdentity?
        let currentFocusedExactWindow: @MainActor () -> UIAutomationTarget.ExactWindow?
        let activate: @MainActor (
            ApplicationProcessIdentity,
            FocusDispatchGuard) async throws -> Bool
        let currentCursorLocation: @MainActor () -> CGPoint?
        let moveCursor: @MainActor (CGPoint) throws -> Void
        let click: @MainActor (CGPoint, ClickType, [PointerModifier]) throws -> DesktopActionOutcome
        let validateExactWindow: @Sendable (WindowMutationIdentity, CGRect) -> Bool

        init(
            focusExactWindow: @escaping ExactWindowFocusExecutor,
            currentFrontmostIdentity: @escaping @MainActor () -> ApplicationProcessIdentity?,
            currentFocusedExactWindow: @escaping @MainActor () -> UIAutomationTarget.ExactWindow?,
            activate: @escaping @MainActor (
                ApplicationProcessIdentity,
                FocusDispatchGuard) async throws -> Bool,
            currentCursorLocation: @escaping @MainActor () -> CGPoint?,
            moveCursor: @escaping @MainActor (CGPoint) throws -> Void,
            click: @escaping @MainActor (CGPoint, ClickType, [PointerModifier]) throws -> DesktopActionOutcome,
            validateExactWindow: @escaping @Sendable (WindowMutationIdentity, CGRect) -> Bool,
            restoreExactWindow: ExactWindowFocusExecutor? = nil)
        {
            self.focusExactWindow = focusExactWindow
            self.restoreExactWindow = restoreExactWindow ?? focusExactWindow
            self.currentFrontmostIdentity = currentFrontmostIdentity
            self.currentFocusedExactWindow = currentFocusedExactWindow
            self.activate = activate
            self.currentCursorLocation = currentCursorLocation
            self.moveCursor = moveCursor
            self.click = click
            self.validateExactWindow = validateExactWindow
        }
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
        guard self.dependencies.currentCursorLocation() != nil else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not capture the physical cursor for restoration.")
        }
        var sequence = DesktopActionSequenceAccumulator()
        var primaryFailure: (any Error)?
        var cleanupFailures: [(phase: String, failure: DesktopActionFailure)] = []
        var originalCursor: CGPoint?
        var clickAttempted = false

        do {
            let focusOutcome = try await self.dependencies.focusExactWindow(exactWindow, FocusDispatchGuard())
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
            if let currentCursor = self.dependencies.currentCursorLocation() {
                originalCursor = currentCursor
                do {
                    guard self.dependencies.currentFrontmostIdentity() == request.windowIdentity.processIdentity,
                          self.dependencies.currentFocusedExactWindow() == exactWindow,
                          self.dependencies.validateExactWindow(request.windowIdentity, request.windowBounds)
                    else {
                        throw DesktopActionFailure.preDispatchRefusal(
                            reason: .targetUnavailable,
                            message: "Modifier-click exact foreground ownership changed before click dispatch.")
                    }
                    clickAttempted = true
                    let clickOutcome = try self.dependencies.click(
                        request.point,
                        request.clickType,
                        request.modifiers)
                    sequence.record(.reportedOutcome(clickOutcome, defaultDispatchedUnitCount: .one))
                } catch {
                    primaryFailure = error
                }
            } else {
                primaryFailure = DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Modifier-click could not recapture the physical cursor immediately before clicking.")
            }
        }

        var cursorRestoration = SharedDesktopRestorationStatus.notNeeded
        if clickAttempted, let originalCursor {
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
            if sequence.mutationDisposition == .none {
                throw primaryFailure
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
            guard let initialObservation = self.currentFocusRestorationObservation() else {
                throw ForegroundModifierClickError.focusRestorationUnverified
            }
            let targetObservation = FocusRestorationObservation(
                frontmostProcess: targetWindow.identity.processIdentity,
                focusedWindow: targetWindow)
            guard initialObservation == targetObservation else {
                return .preservedNewerState
            }
            let ownership = FocusRestorationOwnershipState(expected: targetObservation)
            let priorObservation = FocusRestorationObservation(
                frontmostProcess: priorWindow.identity.processIdentity,
                focusedWindow: priorWindow)
            let outcome: DesktopActionOutcome
            do {
                let dispatchGuard = FocusDispatchGuard(
                    requiresStrictDispatchOwnership: true,
                    validateOwnership: { _ in
                        guard let current = self.currentFocusRestorationObservation() else {
                            throw ForegroundModifierClickError.focusRestorationOwnershipLost
                        }
                        if current == priorObservation {
                            throw ForegroundModifierClickError.focusRestorationSatisfied
                        }
                        guard current == ownership.expected else {
                            throw ForegroundModifierClickError.focusRestorationOwnershipLost
                        }
                    },
                    completeDispatch: { stage in
                        guard let current = self.currentFocusRestorationObservation() else {
                            throw ForegroundModifierClickError.focusRestorationOwnershipLost
                        }
                        let isAllowed = switch stage {
                        case .applicationActivation:
                            // The exact pre-click window is the only attributable activation result.
                            // Another window in the prior app may be newer user or application state.
                            current == priorObservation
                        case .setMainWindow:
                            current == ownership.expected || current == priorObservation
                        case .raiseWindow:
                            current == ownership.expected || current == priorObservation
                        case .spaceTransition, .unspecified:
                            false
                        }
                        guard isAllowed else {
                            throw ForegroundModifierClickError.focusRestorationOwnershipLost
                        }
                        if current == priorObservation {
                            throw ForegroundModifierClickError.focusRestorationSatisfied
                        }
                        ownership.expected = current
                    })
                outcome = try await self.dependencies.restoreExactWindow(priorWindow, dispatchGuard)
            } catch let interruption as FocusRestorationOwnershipLoss {
                if let partialOutcome = interruption.partialOutcome {
                    sequence.record(.reportedOutcome(partialOutcome, defaultDispatchedUnitCount: .one))
                }
                return .preservedNewerState
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
            let dispatchGuard = FocusDispatchGuard {
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

    private func currentFocusRestorationObservation() -> FocusRestorationObservation? {
        guard let frontmostProcess = self.dependencies.currentFrontmostIdentity(),
              let focusedWindow = self.dependencies.currentFocusedExactWindow(),
              focusedWindow.identity.processIdentity == frontmostProcess
        else { return nil }
        return FocusRestorationObservation(
            frontmostProcess: frontmostProcess,
            focusedWindow: focusedWindow)
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

struct FocusRestorationOwnershipLoss: Error {
    let partialOutcome: DesktopActionOutcome?
}

enum ForegroundModifierClickError: LocalizedError {
    case cursorRestorationUnverified
    case focusRestorationBecameUnnecessary
    case focusRestorationOwnershipLost
    case focusRestorationSatisfied
    case focusRestorationUnverified

    var errorDescription: String? {
        switch self {
        case .cursorRestorationUnverified:
            "The physical cursor did not return to its captured location."
        case .focusRestorationBecameUnnecessary:
            "The prior foreground state was restored before Peekaboo dispatched restoration."
        case .focusRestorationOwnershipLost:
            "Newer foreground state replaced Peekaboo's target before restoration dispatch."
        case .focusRestorationSatisfied:
            "The prior foreground state was restored by Peekaboo's accepted dispatch."
        case .focusRestorationUnverified:
            "The prior foreground window or application could not be re-established."
        }
    }
}
