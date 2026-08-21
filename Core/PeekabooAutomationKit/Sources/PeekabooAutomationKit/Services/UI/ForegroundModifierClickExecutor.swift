import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
final class ForegroundModifierClickExecutor {
    struct Dependencies {
        let focusExactWindow: @MainActor (UIAutomationTarget.ExactWindow) async throws -> DesktopActionOutcome
        let currentFrontmostIdentity: @MainActor () -> ApplicationProcessIdentity?
        let currentFocusedExactWindow: @MainActor () -> UIAutomationTarget.ExactWindow?
        let activate: @MainActor (ApplicationProcessIdentity) async throws -> Bool
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
        let priorFrontmost = self.dependencies.currentFrontmostIdentity()
        let priorFocusedWindow = self.dependencies.currentFocusedExactWindow()
        guard priorFrontmost != exactWindow.identity.processIdentity || priorFocusedWindow != nil else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not capture the exact prior focused window for restoration.")
        }
        let originalCursor = self.dependencies.currentCursorLocation()
        var sequence = DesktopActionSequenceAccumulator()
        var primaryFailure: (any Error)?
        var cleanupFailures: [String] = []

        do {
            let focusOutcome = try await self.dependencies.focusExactWindow(exactWindow)
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
        do {
            cursorRestoration = try self.restoreCursorIfOwned(
                original: originalCursor,
                lastWritten: request.point,
                sequence: &sequence)
        } catch {
            cleanupFailures.append("Cursor restoration: \(error.localizedDescription)")
        }

        var focusRestoration = SharedDesktopRestorationStatus.notNeeded
        do {
            focusRestoration = try await self.restoreFocusIfOwned(
                priorProcess: priorFrontmost,
                priorWindow: priorFocusedWindow,
                targetWindow: exactWindow,
                sequence: &sequence)
        } catch {
            cleanupFailures.append("Focus restoration: \(error.localizedDescription)")
        }

        if !cleanupFailures.isEmpty {
            var causes = cleanupFailures
            if let primaryFailure {
                causes.insert("Primary action: \(primaryFailure.localizedDescription)", at: 0)
            }
            throw self.cleanupFailure(
                sequence: sequence,
                message: "Modifier-click cleanup did not fully restore the shared desktop.",
                causeDescription: causes.joined(separator: " "))
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
        original: CGPoint?,
        lastWritten: CGPoint,
        sequence: inout DesktopActionSequenceAccumulator) throws -> SharedDesktopRestorationStatus
    {
        guard let original else { return .notNeeded }
        guard let current = self.dependencies.currentCursorLocation() else {
            return .preservedNewerState
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
        priorProcess: ApplicationProcessIdentity?,
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
            let outcome = try await self.dependencies.focusExactWindow(priorWindow)
            sequence.record(.reportedOutcome(outcome, defaultDispatchedUnitCount: .one))
            guard outcome.isConfirmed,
                  self.dependencies.currentFocusedExactWindow() == priorWindow
            else {
                throw ForegroundModifierClickError.focusRestorationUnverified
            }
            return .restored
        }

        guard let priorProcess, priorProcess != targetWindow.identity.processIdentity else { return .notNeeded }
        let current = self.dependencies.currentFrontmostIdentity()
        if current == priorProcess {
            return .notNeeded
        }
        guard current == targetWindow.identity.processIdentity else {
            return .preservedNewerState
        }
        guard try await self.dependencies.activate(priorProcess) else {
            throw ForegroundModifierClickError.focusRestorationUnverified
        }
        sequence.record(.dispatched(route: .local, delivery: Self.nativeForeground, unitCount: .one))
        guard self.dependencies.currentFrontmostIdentity() == priorProcess else {
            throw ForegroundModifierClickError.focusRestorationUnverified
        }
        return .restored
    }

    private func cleanupFailure(
        sequence: DesktopActionSequenceAccumulator,
        message: String,
        causeDescription: String) -> DesktopActionFailure
    {
        .partial(
            route: .local,
            delivery: .init(mechanism: .composite, mode: .foreground),
            unitCount: sequence.mutationDisposition.unitCount,
            message: message,
            hint: "Inspect the shared desktop state before taking another input action.",
            causeDescription: causeDescription)
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
    case focusRestorationUnverified

    var errorDescription: String? {
        switch self {
        case .cursorRestorationUnverified:
            "The physical cursor did not return to its captured location."
        case .focusRestorationUnverified:
            "The prior foreground window or application could not be re-established."
        }
    }
}
