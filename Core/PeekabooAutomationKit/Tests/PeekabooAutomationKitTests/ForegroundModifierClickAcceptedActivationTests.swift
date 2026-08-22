import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ForegroundModifierClickAcceptedActivationTests {
    @Test(arguments: PendingActivationInterruption.allCases)
    func `accepted incomplete activation is indeterminate and performs zero cleanup`(
        _ interruption: PendingActivationInterruption) async throws
    {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let targetBounds = CGRect(x: 100, y: 100, width: 100, height: 100)
        let priorWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 6,
                ownerProcessIdentifier: priorProcess.processIdentifier,
                ownerProcessStartIdentity: priorProcess.processStartIdentity,
                capturedBounds: priorBounds),
            bounds: priorBounds)
        var frontmost = priorProcess
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        let inputActivity = AcceptedActivationInputState()
        var clickAttempted = false
        var cursorWriteAttempted = false
        var exactRestoreAttempted = false
        var appActivationAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, dispatchGuard in
                    try dispatchGuard.validate(.applicationActivation)
                    if interruption == .inputChanged {
                        inputActivity.value = inputActivity.value.afterKeyboardInput()
                    } else if interruption == .heldKey {
                        inputActivity.value = inputActivity.value.withHeldKey(4)
                    } else if interruption == .heldButton {
                        inputActivity.value = inputActivity.value.withHeldMouseButton(.left)
                    }
                    try dispatchGuard.didAcceptDispatch(.applicationActivation)
                    if interruption == .inputChangedAfterActivationCompletion {
                        frontmost = targetProcess
                        focusedWindow = nil
                        try dispatchGuard.didCompleteDispatch(.applicationActivation)
                        inputActivity.value = inputActivity.value.afterKeyboardInput()
                        try dispatchGuard.validate(.setMainWindow)
                    }
                    if interruption == .postconditionFailureAfterReturnedOutcome {
                        frontmost = targetProcess
                        focusedWindow = nil
                        try dispatchGuard.didCompleteDispatch(.applicationActivation)
                        focusedWindow = window
                        return .confirmedChange(
                            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                            unitCount: .one)
                    }
                    if interruption == .targetVisibleWithoutWindow {
                        frontmost = targetProcess
                        focusedWindow = nil
                    }
                    throw interruption.error
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in
                    appActivationAttempted = true
                    return true
                },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in cursorWriteAttempted = true },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in
                    if interruption == .postconditionFailureAfterReturnedOutcome {
                        inputActivity.validationCount += 1
                        guard inputActivity.validationCount > 1 else { return true }
                        inputActivity.value = inputActivity.value.afterKeyboardInput()
                        return false
                    }
                    return true
                },
                restoreExactWindow: { _, _ in
                    exactRestoreAttempted = true
                    return .confirmedNoChange()
                },
                sharedInputActivityToken: { inputActivity.value }))

        let failure = await self.failure(from: executor, targetProcess: targetProcess, bounds: targetBounds)

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.dispatchState.unitCount == .one)
        #expect(failure?.outcome.retrySafety == .unsafe)
        #expect(failure?.targetReceipt == DesktopActionTargetReceipt(
            processIdentifier: targetProcess.processIdentifier,
            processStartIdentity: targetProcess.processStartIdentity,
            windowID: 7))
        #expect(!clickAttempted)
        #expect(!cursorWriteAttempted)
        #expect(!exactRestoreAttempted)
        #expect(!appActivationAttempted)
    }

    private func failure(
        from executor: ForegroundModifierClickExecutor,
        targetProcess: ApplicationProcessIdentity,
        bounds: CGRect) async -> DesktopActionFailure?
    {
        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 120, y: 120),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: targetProcess.processIdentifier,
                    ownerProcessStartIdentity: targetProcess.processStartIdentity,
                    capturedBounds: bounds),
                windowBounds: bounds))
            Issue.record("Expected accepted incomplete activation failure")
            return nil
        } catch let failure as DesktopActionFailure {
            return failure
        } catch {
            Issue.record("Expected DesktopActionFailure, got \(error)")
            return nil
        }
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-accepted-activation-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

enum PendingActivationInterruption: CaseIterable, Equatable, Sendable {
    case cancellation
    case timeout
    case inputChanged
    case heldKey
    case heldButton
    case targetVisibleWithoutWindow
    case inputChangedAfterActivationCompletion
    case postconditionFailureAfterReturnedOutcome

    var error: any Error {
        switch self {
        case .cancellation:
            CancellationError()
        case .timeout:
            FocusError.timeoutWaitingForCondition
        case .inputChanged,
             .heldKey,
             .heldButton,
             .inputChangedAfterActivationCompletion,
             .postconditionFailureAfterReturnedOutcome:
            ModifierClickFocusOwnershipLossFailure(failure: .preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Shared input changed during accepted activation."))
        case .targetVisibleWithoutWindow:
            DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Activation completion is unknown.")
        }
    }
}

private final class AcceptedActivationInputState: @unchecked Sendable {
    var value = SharedInputActivityToken.trackedZero
    var validationCount = 0
}
