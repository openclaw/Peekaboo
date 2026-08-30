import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation

private struct FocusRestorationObservation: Equatable {
    let frontmostProcess: ApplicationProcessIdentity
    let focusedWindow: UIAutomationTarget.ExactWindow?
}

@MainActor
private final class FocusRestorationOwnershipState {
    var expected: FocusRestorationObservation

    init(expected: FocusRestorationObservation) {
        self.expected = expected
    }
}

@MainActor
private final class TargetFocusOwnershipState {
    var expected: TargetFocusObservation
    var hasAcceptedApplicationActivation = false
    var hasPendingApplicationActivation = false

    init(expected: TargetFocusObservation) {
        self.expected = expected
    }
}

private struct ModifierClickFocusRestorationAttempt: Sendable {
    let status: SharedDesktopRestorationStatus?
    let error: (any Error)?
    let sequence: DesktopActionSequenceAccumulator
}

@MainActor
private struct ModifierClickFocusRestorationContext {
    let priorProcess: ApplicationProcessIdentity
    let priorWindow: UIAutomationTarget.ExactWindow?
    let targetWindow: UIAutomationTarget.ExactWindow
    let ownedTargetFocus: TargetFocusObservation
    let inputActivityToken: SharedInputActivityToken
    let sequence: DesktopActionSequenceAccumulator
}

private struct TargetFocusObservation: Equatable {
    let frontmostProcess: ApplicationProcessIdentity
    let focusedWindow: UIAutomationTarget.ExactWindow?

    init(_ frontmost: ApplicationProcessIdentity, _ window: UIAutomationTarget.ExactWindow?) {
        self.frontmostProcess = frontmost
        self.focusedWindow = window
    }
}

struct ModifierClickDispatchBarrierFailure: Error {
    let failure: DesktopActionFailure
}

struct ModifierClickPointerRouteLossFailure: Error {
    let failure: DesktopActionFailure
}

struct ModifierClickInputActivityLossFailure: Error {
    let failure: DesktopActionFailure
}

struct ModifierClickFocusOwnershipLossFailure: Error {
    let failure: DesktopActionFailure
}

@MainActor
final class ForegroundModifierClickExecutor {
    typealias ExactWindowFocusExecutor = @MainActor (
        UIAutomationTarget.ExactWindow,
        FocusDispatchGuard) async throws -> DesktopActionOutcome
    typealias PreparedClickExecutor = @MainActor () throws -> DesktopActionOutcome
    typealias ClickPrepareExecutor = @MainActor (
        CGPoint,
        ClickType,
        [PointerModifier]) throws -> PreparedClickExecutor
    typealias CursorRestoreExecutor = @MainActor (
        CGPoint,
        CGPoint,
        SharedInputActivityToken) throws -> SharedDesktopRestorationStatus

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
        let sharedInputActivityToken: @MainActor () -> SharedInputActivityToken
        let restoreCursor: CursorRestoreExecutor
        let prepareClick: ClickPrepareExecutor
        let validateExactWindow: @Sendable (WindowMutationIdentity, CGRect) -> Bool
        let exactWindowRouteAtPoint: @MainActor (
            CGPoint,
            CGWindowID) -> BackgroundInputDriver.MouseWindowRouteCandidate?
        let pointerReceiverAtPoint: @MainActor (CGPoint) -> BackgroundInputDriver.PointerReceiverIdentity?

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
            exactWindowRouteAtPoint: (@MainActor (
                CGPoint,
                CGWindowID) -> BackgroundInputDriver.MouseWindowRouteCandidate?)? = nil,
            pointerReceiverAtPoint: (@MainActor (CGPoint) -> BackgroundInputDriver.PointerReceiverIdentity?)? = nil,
            restoreExactWindow: ExactWindowFocusExecutor? = nil,
            sharedInputActivityToken: @escaping @MainActor () -> SharedInputActivityToken = { .zero },
            restoreCursor: CursorRestoreExecutor? = nil,
            prepareClick: ClickPrepareExecutor? = nil)
        {
            self.focusExactWindow = focusExactWindow
            self.restoreExactWindow = restoreExactWindow ?? focusExactWindow
            self.currentFrontmostIdentity = currentFrontmostIdentity
            self.currentFocusedExactWindow = currentFocusedExactWindow
            self.activate = activate
            self.currentCursorLocation = currentCursorLocation
            self.moveCursor = moveCursor
            self.sharedInputActivityToken = sharedInputActivityToken
            self.restoreCursor = restoreCursor ?? { original, lastWritten, expectedActivity in
                try CursorRestorationOwnership.restore(
                    CursorRestorationOwnership.Receipt(
                        original: original,
                        lastWritten: lastWritten,
                        activityToken: expectedActivity),
                    currentActivity: sharedInputActivityToken,
                    currentLocation: currentCursorLocation,
                    move: moveCursor)
            }
            self.prepareClick = prepareClick ?? { point, clickType, modifiers in
                { try click(point, clickType, modifiers) }
            }
            self.validateExactWindow = validateExactWindow
            self.exactWindowRouteAtPoint = exactWindowRouteAtPoint ?? { point, windowID in
                guard let window = currentFocusedExactWindow(),
                      CGWindowID(window.identity.windowID) == windowID,
                      window.bounds.contains(point)
                else { return nil }
                return BackgroundInputDriver.MouseWindowRouteCandidate(
                    windowID: windowID,
                    processIdentifier: window.identity.ownerProcessIdentifier,
                    layer: Int(CGWindowLevelForKey(.normalWindow)),
                    bounds: window.bounds)
            }
            self.pointerReceiverAtPoint = pointerReceiverAtPoint ?? { point in
                guard let window = currentFocusedExactWindow(), window.bounds.contains(point) else { return nil }
                return BackgroundInputDriver.PointerReceiverIdentity(
                    processIdentifier: window.identity.ownerProcessIdentifier,
                    windowID: CGWindowID(window.identity.windowID))
            }
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
        var enteredOwned = false
        do {
            return try await self.laneCoordinator.run(scope: .global, access: .write) {
                enteredOwned = true
                return try await self.executeOwned(
                    request,
                    exactWindow: exactWindow,
                    targetIdentity: targetIdentity)
            }
        } catch is CancellationError where !enteredOwned {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Modifier-click was cancelled before acquiring its foreground operation lane.")
                .attributed(to: targetIdentity.actionTargetReceipt)
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
        let preparedClick = try self.prepareClickBeforeForegroundSetup(request)
        guard let priorFrontmost = self.dependencies.currentFrontmostIdentity() else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not capture the prior foreground application for restoration.")
        }
        guard let priorFocusedWindow = self.dependencies.currentFocusedExactWindow() else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not capture the exact prior focused window for restoration.")
        }
        guard self.dependencies.currentCursorLocation() != nil else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not capture the physical cursor for restoration.")
        }
        let initialInputActivityToken = try self.requireReleasedInputActivity()
        var sequence = DesktopActionSequenceAccumulator()
        var primaryFailure: (any Error)?
        var cleanupFailures: [(phase: String, failure: DesktopActionFailure)] = []
        var originalCursor: CGPoint?
        var inputActivityToken: SharedInputActivityToken? = initialInputActivityToken
        var clickAttempted = false
        var cleanupAllowed = true
        let priorObservation = TargetFocusObservation(priorFrontmost, priorFocusedWindow)
        let targetObservation = TargetFocusObservation(exactWindow.identity.processIdentity, exactWindow)
        let focusOwnership = TargetFocusOwnershipState(expected: priorObservation)

        do {
            let focusGuard = self.makeTargetFocusGuard(
                exactWindow: exactWindow,
                targetObservation: targetObservation,
                inputActivityToken: initialInputActivityToken,
                ownership: focusOwnership)
            let focusOutcome = try await self.dependencies.focusExactWindow(exactWindow, focusGuard)
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
        } catch let ownershipLoss as ModifierClickFocusOwnershipLossFailure {
            if focusOwnership.hasAcceptedApplicationActivation {
                primaryFailure = self.acceptedActivationFailure(
                    ownershipLoss.failure,
                    sequence: &sequence)
            } else {
                primaryFailure = ownershipLoss.failure
            }
            cleanupAllowed = false
            if focusOwnership.hasPendingApplicationActivation {
                inputActivityToken = nil
            }
        } catch {
            if focusOwnership.hasAcceptedApplicationActivation {
                primaryFailure = self.acceptedActivationFailure(error, sequence: &sequence)
            } else {
                primaryFailure = error
            }
            if focusOwnership.hasPendingApplicationActivation {
                cleanupAllowed = false
                inputActivityToken = nil
            }
        }

        if primaryFailure == nil {
            let attempt = self.attemptClick(
                request,
                exactWindow: exactWindow,
                preparedClick: preparedClick,
                inputActivityToken: inputActivityToken,
                sequence: sequence)
            sequence = attempt.sequence
            inputActivityToken = attempt.inputActivityToken
            primaryFailure = attempt.primaryFailure
            originalCursor = attempt.originalCursor
            clickAttempted = attempt.clickAttempted
            cleanupAllowed = attempt.cleanupAllowed
        }

        var cursorRestoration = SharedDesktopRestorationStatus.notNeeded
        if cleanupAllowed, clickAttempted, let originalCursor, let ownedInputActivity = inputActivityToken {
            let cursorRestorationPrefixCount = sequence.completedStepCount
            do {
                cursorRestoration = try self.dependencies.restoreCursor(
                    originalCursor,
                    request.point,
                    ownedInputActivity)
                if cursorRestoration == .restored {
                    sequence.record(.dispatched(route: .local, delivery: Self.globalForeground, unitCount: .one))
                    inputActivityToken = ownedInputActivity.afterMouseMove()
                }
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
        if cleanupAllowed, let inputActivityToken,
           self.dependencies.sharedInputActivityToken() == inputActivityToken
        {
            let focusRestorationPrefixCount = sequence.completedStepCount
            let attempt = await self.restoreFocusAcrossCancellationBoundary(.init(
                priorProcess: priorFrontmost,
                priorWindow: priorFocusedWindow,
                targetWindow: exactWindow,
                ownedTargetFocus: focusOwnership.expected,
                inputActivityToken: inputActivityToken,
                sequence: sequence))
            sequence = attempt.sequence
            if let status = attempt.status {
                focusRestoration = status
            } else if let error = attempt.error {
                cleanupFailures.append((
                    phase: "Focus restoration",
                    failure: self.restorationFailure(
                        error,
                        stepWasRecorded: sequence.completedStepCount != focusRestorationPrefixCount,
                        delivery: Self.nativeForeground,
                        message: "Modifier-click could not restore the prior foreground window or application.")))
            }
        } else if cleanupAllowed, clickAttempted {
            focusRestoration = .preservedNewerState
        }

        try self.requireSuccessfulCleanupAndAction(
            cleanupFailures: cleanupFailures,
            primaryFailure: primaryFailure,
            sequence: sequence)

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
}

extension ForegroundModifierClickExecutor {
    private struct ClickAttempt {
        let sequence: DesktopActionSequenceAccumulator
        let inputActivityToken: SharedInputActivityToken?
        let primaryFailure: (any Error)?
        let originalCursor: CGPoint?
        let clickAttempted: Bool
        let cleanupAllowed: Bool
    }

    private func attemptClick(
        _ request: ForegroundModifierClickRequest,
        exactWindow: UIAutomationTarget.ExactWindow,
        preparedClick: PreparedClickExecutor,
        inputActivityToken: SharedInputActivityToken?,
        sequence: DesktopActionSequenceAccumulator) -> ClickAttempt
    {
        var sequence = sequence
        var inputActivityToken = inputActivityToken
        var primaryFailure: (any Error)?
        var originalCursor: CGPoint?
        var clickAttempted = false
        var cleanupAllowed = true
        let preClickInputActivity = self.dependencies.sharedInputActivityToken()
        if let ownedPreFocusActivity = inputActivityToken,
           preClickInputActivity == ownedPreFocusActivity
        {
            if let currentCursor = self.dependencies.currentCursorLocation() {
                originalCursor = currentCursor
                do {
                    guard self.dependencies.currentFrontmostIdentity() == request.windowIdentity.processIdentity,
                          self.dependencies.currentFocusedExactWindow() == exactWindow
                    else {
                        throw DesktopActionFailure.preDispatchRefusal(
                            reason: .targetUnavailable,
                            message: "Modifier-click exact foreground ownership changed before click dispatch.")
                    }
                    guard self.dependencies.sharedInputActivityToken() == preClickInputActivity else {
                        throw ModifierClickInputActivityLossFailure(failure: .preDispatchRefusal(
                            reason: .targetUnavailable,
                            message: "Modifier-click physical cursor activity changed before click dispatch."))
                    }
                    try self.validateFinalPointerRoute(request)
                    guard self.dependencies.sharedInputActivityToken() == preClickInputActivity else {
                        throw ModifierClickInputActivityLossFailure(failure: .preDispatchRefusal(
                            reason: .targetUnavailable,
                            message: "Modifier-click physical input changed during final route validation."))
                    }
                    try Task.checkCancellation()
                    clickAttempted = true
                    let clickOutcome = try preparedClick()
                    sequence.record(.reportedOutcome(clickOutcome, defaultDispatchedUnitCount: .one))
                    inputActivityToken = preClickInputActivity.afterModifierClick(
                        request.clickType,
                        modifiers: request.modifiers)
                } catch let inputFailure as ModifierClickInputActivityLossFailure {
                    primaryFailure = inputFailure.failure
                    cleanupAllowed = false
                } catch let routeFailure as ModifierClickPointerRouteLossFailure {
                    primaryFailure = routeFailure.failure
                    cleanupAllowed = false
                } catch let barrierFailure as ModifierClickDispatchBarrierFailure {
                    primaryFailure = barrierFailure.failure
                    cleanupAllowed = false
                } catch {
                    primaryFailure = error
                }
            } else {
                primaryFailure = DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Modifier-click could not recapture the physical cursor immediately before clicking.")
            }
        } else {
            primaryFailure = DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click detected newer shared input while focusing its target.",
                hint: "Observe the shared desktop before deciding whether to retry.")
            cleanupAllowed = false
            inputActivityToken = nil
        }

        return ClickAttempt(
            sequence: sequence,
            inputActivityToken: inputActivityToken,
            primaryFailure: primaryFailure,
            originalCursor: originalCursor,
            clickAttempted: clickAttempted,
            cleanupAllowed: cleanupAllowed)
    }

    private func requireSuccessfulCleanupAndAction(
        cleanupFailures: [(phase: String, failure: DesktopActionFailure)],
        primaryFailure: (any Error)?,
        sequence: DesktopActionSequenceAccumulator) throws
    {
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
            if primaryFailure is CancellationError,
               sequence.mutationDisposition == .none
            {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .requestCancelled,
                    message: "Modifier-click was cancelled before click dispatch.")
            }
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
    }

    private func prepareClickBeforeForegroundSetup(
        _ request: ForegroundModifierClickRequest) throws -> PreparedClickExecutor
    {
        do {
            return try self.dependencies.prepareClick(
                request.point,
                request.clickType,
                request.modifiers)
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error as PeekabooError {
            let reason: DesktopActionOutcome.RefusalReason = switch error {
            case .permissionDeniedEventSynthesizing: .permissionDenied
            default: .operationUnsupported
            }
            throw DesktopActionFailure.preDispatchRefusal(
                reason: reason,
                message: "Modifier-click could not prepare its event sequence before foreground setup.",
                hint: "Grant Event Synthesizing permission or inspect the runtime before retrying.",
                causeDescription: error.localizedDescription)
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "Modifier-click could not prepare its event sequence before foreground setup.",
                hint: "Inspect the runtime before retrying.",
                causeDescription: error.localizedDescription)
        }
    }

    private func requireReleasedInputActivity() throws -> SharedInputActivityToken {
        let inputActivity = self.dependencies.sharedInputActivityToken()
        guard !inputActivity.hasHeldInput else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click requires every autorepeating key or held mouse button " +
                    "to be released before focus.",
                hint: "Release held input and retry from a fresh observation.")
        }
        return inputActivity
    }

    private func validateFinalPointerRoute(_ request: ForegroundModifierClickRequest) throws {
        guard let exactWindowRoute = self.dependencies.exactWindowRouteAtPoint(
            request.point,
            CGWindowID(request.windowIdentity.windowID))
        else {
            throw ModifierClickPointerRouteLossFailure(failure: .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click exact target has no provable on-screen WindowServer row.",
                hint: "Observe the exact target again before retrying."))
        }
        guard let pointerReceiver = self.dependencies.pointerReceiverAtPoint(request.point) else {
            throw ModifierClickPointerRouteLossFailure(failure: .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click point has no provable Accessibility receiver.",
                hint: "Observe the exact target again before retrying."))
        }
        guard self.dependencies.validateExactWindow(request.windowIdentity, request.windowBounds) else {
            throw ModifierClickPointerRouteLossFailure(failure: .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click exact-window identity changed before event dispatch.",
                hint: "Observe the exact target again before retrying."))
        }
        guard exactWindowRoute.windowID == CGWindowID(request.windowIdentity.windowID),
              exactWindowRoute.processIdentifier == request.windowIdentity.ownerProcessIdentifier,
              exactWindowRoute.bounds == request.windowBounds,
              pointerReceiver.processIdentifier == request.windowIdentity.ownerProcessIdentifier,
              pointerReceiver.windowID == CGWindowID(request.windowIdentity.windowID)
        else {
            throw ModifierClickPointerRouteLossFailure(failure: .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click exact target or Accessibility receiver changed before dispatch.",
                hint: "Observe the exact target again before retrying."))
        }
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
        guard request.clickType != .right, !request.modifiers.contains(.control) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "Modifier-click does not support contextual right- or Control-click restoration.")
        }
        guard self.dependencies.validateExactWindow(request.windowIdentity, request.windowBounds) else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click exact-window receipt is stale.")
        }
    }

    private func currentTargetFocusObservation() -> TargetFocusObservation? {
        guard let frontmostProcess = self.dependencies.currentFrontmostIdentity() else { return nil }
        let focusedWindow = self.dependencies.currentFocusedExactWindow()
        guard focusedWindow == nil || focusedWindow?.identity.processIdentity == frontmostProcess else {
            return nil
        }
        return TargetFocusObservation(frontmostProcess, focusedWindow)
    }
}

extension ForegroundModifierClickExecutor {
    private func makeTargetFocusGuard(
        exactWindow: UIAutomationTarget.ExactWindow,
        targetObservation: TargetFocusObservation,
        inputActivityToken: SharedInputActivityToken,
        ownership: TargetFocusOwnershipState) -> FocusDispatchGuard
    {
        FocusDispatchGuard(
            requiresStrictDispatchOwnership: true,
            validateOwnership: { _ in
                guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
                    throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Modifier-click shared input changed before target focus dispatch."))
                }
                guard let current = self.currentTargetFocusObservation() else {
                    throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Modifier-click prior foreground state changed before target focus dispatch."))
                }
                guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
                    throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Modifier-click shared input changed while observing target focus ownership."))
                }
                if current == targetObservation, ownership.expected == targetObservation {
                    throw ForegroundModifierClickError.focusTargetSatisfied
                }
                if current == targetObservation {
                    throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Modifier-click target was focused by newer external state."))
                }
                guard current == ownership.expected else {
                    throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Modifier-click foreground ownership changed during target focus."))
                }
            },
            validateAcceptedActivation: {
                guard self.dependencies.sharedInputActivityToken() == inputActivityToken,
                      let current = self.currentTargetFocusObservation(),
                      self.dependencies.sharedInputActivityToken() == inputActivityToken
                else {
                    throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Modifier-click foreground ownership changed during target activation."))
                }
                if current == ownership.expected {
                    return
                }
                if current.frontmostProcess == exactWindow.identity.processIdentity,
                   current.frontmostProcess != ownership.expected.frontmostProcess
                {
                    return
                }
                throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Modifier-click source focus changed during target activation."))
            },
            acceptedDispatch: { stage in
                guard stage == .applicationActivation else { return }
                ownership.hasAcceptedApplicationActivation = true
                ownership.hasPendingApplicationActivation = true
                guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
                    throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Modifier-click shared input changed during target activation."))
                }
            },
            completeDispatch: { stage in
                try self.completeTargetFocusDispatch(
                    stage,
                    exactWindow: exactWindow,
                    targetObservation: targetObservation,
                    inputActivityToken: inputActivityToken,
                    ownership: ownership)
            })
    }

    private func completeTargetFocusDispatch(
        _ stage: FocusDispatchStage,
        exactWindow: UIAutomationTarget.ExactWindow,
        targetObservation: TargetFocusObservation,
        inputActivityToken: SharedInputActivityToken,
        ownership: TargetFocusOwnershipState) throws
    {
        guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
            throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click shared input changed before verifying target focus ownership."))
        }
        guard let current = self.currentTargetFocusObservation() else {
            throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not verify target-focus ownership after dispatch."))
        }
        guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
            throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click shared input changed while verifying target focus ownership."))
        }
        let isAllowed = switch stage {
        case .applicationActivation:
            current.frontmostProcess == exactWindow.identity.processIdentity &&
                (current.focusedWindow == nil ||
                    current.focusedWindow?.identity.processIdentity == exactWindow.identity.processIdentity)
        case .setMainWindow:
            current == ownership.expected || current == targetObservation
        case .raiseWindow:
            current == targetObservation
        case .spaceTransition, .unspecified:
            false
        }
        guard isAllowed else {
            throw ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click target focus produced an ambiguous foreground state."))
        }
        if stage == .applicationActivation {
            ownership.hasPendingApplicationActivation = false
        }
        if current == targetObservation {
            ownership.hasPendingApplicationActivation = false
            throw ForegroundModifierClickError.focusTargetSatisfied
        }
        ownership.expected = current
    }

    private func makeFocusRestorationGuard(
        context: ModifierClickFocusRestorationContext,
        priorObservation: FocusRestorationObservation,
        ownership: FocusRestorationOwnershipState) -> FocusDispatchGuard
    {
        let priorProcess = context.priorProcess
        let inputActivityToken = context.inputActivityToken
        return FocusDispatchGuard(
            requiresStrictDispatchOwnership: true,
            validateOwnership: { _ in
                guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
                    throw ForegroundModifierClickError.focusRestorationOwnershipLost
                }
                guard let current = self.currentFocusRestorationObservation() else {
                    throw ForegroundModifierClickError.focusRestorationOwnershipLost
                }
                guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
                    throw ForegroundModifierClickError.focusRestorationOwnershipLost
                }
                if current == priorObservation {
                    throw ForegroundModifierClickError.focusRestorationSatisfied
                }
                guard current == ownership.expected else {
                    throw ForegroundModifierClickError.focusRestorationOwnershipLost
                }
            },
            validateAcceptedActivation: {
                guard self.dependencies.sharedInputActivityToken() == inputActivityToken,
                      let current = self.currentFocusRestorationObservation(),
                      self.dependencies.sharedInputActivityToken() == inputActivityToken
                else {
                    throw ForegroundModifierClickError.focusRestorationOwnershipLost
                }
                if current == ownership.expected {
                    return
                }
                if current.frontmostProcess == priorProcess,
                   current.frontmostProcess != ownership.expected.frontmostProcess,
                   current.focusedWindow == nil || current == priorObservation
                {
                    return
                }
                throw ForegroundModifierClickError.focusRestorationOwnershipLost
            },
            completeDispatch: { stage in
                try self.completeFocusRestorationDispatch(
                    stage,
                    context: context,
                    priorObservation: priorObservation,
                    ownership: ownership)
            })
    }

    private func completeFocusRestorationDispatch(
        _ stage: FocusDispatchStage,
        context: ModifierClickFocusRestorationContext,
        priorObservation: FocusRestorationObservation,
        ownership: FocusRestorationOwnershipState) throws
    {
        let priorProcess = context.priorProcess
        let inputActivityToken = context.inputActivityToken
        guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
            throw ForegroundModifierClickError.focusRestorationOwnershipLost
        }
        guard let current = self.currentFocusRestorationObservation() else {
            throw ForegroundModifierClickError.focusRestorationOwnershipLost
        }
        guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
            throw ForegroundModifierClickError.focusRestorationOwnershipLost
        }
        let isAllowed = switch stage {
        case .applicationActivation:
            current.frontmostProcess == priorProcess &&
                current.frontmostProcess != ownership.expected.frontmostProcess &&
                (current.focusedWindow == nil || current == priorObservation)
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
    }

    private func makeApplicationRestorationGuard(
        _ context: ModifierClickFocusRestorationContext) -> FocusDispatchGuard
    {
        let priorProcess = context.priorProcess
        let targetWindow = context.targetWindow
        let inputActivityToken = context.inputActivityToken
        var activationAccepted = false
        return FocusDispatchGuard(
            requiresStrictDispatchOwnership: false,
            validateOwnership: { _ in
                guard self.dependencies.sharedInputActivityToken() == inputActivityToken else {
                    throw ForegroundModifierClickError.focusRestorationOwnershipLost
                }
                let dispatchCurrent = self.dependencies.currentFrontmostIdentity()
                if dispatchCurrent == priorProcess {
                    if activationAccepted {
                        return
                    }
                    throw ForegroundModifierClickError.focusRestorationBecameUnnecessary
                }
                guard dispatchCurrent == targetWindow.identity.processIdentity else {
                    throw ForegroundModifierClickError.focusRestorationOwnershipLost
                }
            },
            acceptedDispatch: { stage in
                if stage == .applicationActivation {
                    activationAccepted = true
                }
            },
            completeDispatch: { _ in
                guard self.dependencies.sharedInputActivityToken() == inputActivityToken,
                      self.dependencies.currentFrontmostIdentity() == priorProcess
                else {
                    throw ForegroundModifierClickError.focusRestorationOwnershipLost
                }
            })
    }

    private func restoreFocusIfOwned(
        _ context: ModifierClickFocusRestorationContext,
        sequence: inout DesktopActionSequenceAccumulator) async throws -> SharedDesktopRestorationStatus
    {
        let priorProcess = context.priorProcess
        let priorWindow = context.priorWindow
        let targetWindow = context.targetWindow
        let ownedTargetFocus = context.ownedTargetFocus
        if let priorWindow {
            let currentWindow = self.dependencies.currentFocusedExactWindow()
            if currentWindow == priorWindow {
                return .notNeeded
            }
            guard priorWindow != targetWindow else {
                return .preservedNewerState
            }
            guard let initialObservation = self.currentFocusRestorationObservation() else {
                throw ForegroundModifierClickError.focusRestorationUnverified
            }
            let targetObservation = FocusRestorationObservation(
                frontmostProcess: targetWindow.identity.processIdentity,
                focusedWindow: targetWindow)
            let ownedIntermediate = FocusRestorationObservation(
                frontmostProcess: ownedTargetFocus.frontmostProcess,
                focusedWindow: ownedTargetFocus.focusedWindow)
            guard initialObservation == targetObservation || initialObservation == ownedIntermediate else {
                return .preservedNewerState
            }
            let ownership = FocusRestorationOwnershipState(expected: initialObservation)
            let priorObservation = FocusRestorationObservation(
                frontmostProcess: priorWindow.identity.processIdentity,
                focusedWindow: priorWindow)
            let outcome: DesktopActionOutcome
            do {
                let dispatchGuard = self.makeFocusRestorationGuard(
                    context: context,
                    priorObservation: priorObservation,
                    ownership: ownership)
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
        let dispatchGuard = self.makeApplicationRestorationGuard(context)
        do {
            let verified = try await self.dependencies.activate(priorProcess, dispatchGuard)
            guard verified else {
                if dispatchGuard.acceptedApplicationActivationDispatch {
                    sequence.record(.dispatched(route: .local, delivery: Self.nativeForeground, unitCount: .one))
                    throw ForegroundModifierClickError.focusRestorationUnverified
                }
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Modifier-click focus restoration activation was rejected before dispatch.")
            }
        } catch ForegroundModifierClickError.focusRestorationBecameUnnecessary {
            return .notNeeded
        } catch ForegroundModifierClickError.focusRestorationOwnershipLost {
            if dispatchGuard.acceptedApplicationActivationDispatch {
                sequence.record(.dispatched(route: .local, delivery: Self.nativeForeground, unitCount: .one))
                throw ForegroundModifierClickError.focusRestorationUnverified
            }
            return .preservedNewerState
        } catch is CancellationError where !dispatchGuard.acceptedApplicationActivationDispatch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Modifier-click focus restoration was cancelled before activation dispatch.")
        }
        sequence.record(.dispatched(route: .local, delivery: Self.nativeForeground, unitCount: .one))
        guard self.dependencies.currentFrontmostIdentity() == priorProcess else {
            throw ForegroundModifierClickError.focusRestorationUnverified
        }
        return .restored
    }

    private func restoreFocusAcrossCancellationBoundary(
        _ context: ModifierClickFocusRestorationContext) async -> ModifierClickFocusRestorationAttempt
    {
        // Accepted foreground work must be restored even when the requesting task was cancelled.
        // This task is awaited while the caller continues to own the global desktop operation lane.
        let restorationTask = Task { @MainActor in
            var sequence = context.sequence
            do {
                let status = try await self.restoreFocusIfOwned(context, sequence: &sequence)
                return ModifierClickFocusRestorationAttempt(
                    status: status,
                    error: nil,
                    sequence: sequence)
            } catch {
                return ModifierClickFocusRestorationAttempt(
                    status: nil,
                    error: error,
                    sequence: sequence)
            }
        }
        return await restorationTask.value
    }

    private func currentFocusRestorationObservation() -> FocusRestorationObservation? {
        guard let frontmostProcess = self.dependencies.currentFrontmostIdentity() else { return nil }
        let focusedWindow = self.dependencies.currentFocusedExactWindow()
        guard focusedWindow == nil || focusedWindow?.identity.processIdentity == frontmostProcess else { return nil }
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

    private func acceptedActivationFailure(
        _ error: any Error,
        sequence: inout DesktopActionSequenceAccumulator) -> DesktopActionFailure
    {
        if let failure = error as? DesktopActionFailure,
           failure.outcome.dispatchState.mutationDispatched
        {
            return failure
        }
        if sequence.mutationDisposition == .none {
            sequence.record(.dispatched(route: .local, delivery: Self.nativeForeground, unitCount: .one))
        }
        return .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Modifier-click target activation was accepted but did not observably complete.",
            hint: "Observe the shared desktop before deciding whether to retry.",
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
        if error is CancellationError, !stepWasRecorded {
            return .preDispatchRefusal(
                reason: .requestCancelled,
                message: message,
                causeDescription: error.localizedDescription)
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
    case focusTargetSatisfied
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
        case .focusTargetSatisfied:
            "The exact modifier-click target became focused before another focus dispatch was needed."
        case .focusRestorationUnverified:
            "The prior foreground window or application could not be re-established."
        }
    }
}
