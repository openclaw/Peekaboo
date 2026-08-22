import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ForegroundModifierClickAcceptedActivationTests {
    @Test
    func `synchronous activation completion precedes legacy settlement validation`() async throws {
        let targetIsActive = true
        var validationCount = 0
        var sleepAttempted = false
        let dispatchGuard = FocusDispatchGuard {
            validationCount += 1
            guard !targetIsActive else {
                throw AcceptedActivationSettlementTestError.ownershipLost
            }
        }

        let settled = try await FocusAcceptedActivationSettlement.wait(
            dispatchGuard: dispatchGuard,
            pollCount: 30,
            interval: .milliseconds(100),
            isSettled: { targetIsActive },
            sleep: { _ in sleepAttempted = true })

        #expect(settled)
        #expect(validationCount == 0)
        #expect(!sleepAttempted)
    }

    @Test
    func `activation completing during the final interval settles`() async throws {
        var targetIsActive = false
        var settlementCheckCount = 0
        var validationCount = 0
        var sleepCount = 0
        let dispatchGuard = FocusDispatchGuard {
            validationCount += 1
        }

        let settled = try await FocusAcceptedActivationSettlement.wait(
            dispatchGuard: dispatchGuard,
            pollCount: 1,
            interval: .milliseconds(100),
            isSettled: {
                settlementCheckCount += 1
                return targetIsActive
            },
            sleep: { _ in
                sleepCount += 1
                targetIsActive = true
            })

        #expect(settled)
        #expect(settlementCheckCount == 2)
        #expect(validationCount == 1)
        #expect(sleepCount == 1)
    }

    @Test
    func `foreign activation during the final interval is ownership loss not timeout`() async throws {
        let priorProcessIdentifier: pid_t = 11
        let targetProcessIdentifier: pid_t = 22
        let foreignProcessIdentifier: pid_t = 33
        var frontmostProcessIdentifier = priorProcessIdentifier
        var settlementCheckCount = 0
        var validationCount = 0
        var sleepCount = 0
        let dispatchGuard = FocusDispatchGuard {
            validationCount += 1
            guard frontmostProcessIdentifier == priorProcessIdentifier ||
                frontmostProcessIdentifier == targetProcessIdentifier
            else {
                throw AcceptedActivationSettlementTestError.ownershipLost
            }
        }

        do {
            _ = try await FocusAcceptedActivationSettlement.wait(
                dispatchGuard: dispatchGuard,
                pollCount: 1,
                interval: .milliseconds(100),
                isSettled: {
                    settlementCheckCount += 1
                    return frontmostProcessIdentifier == targetProcessIdentifier
                },
                sleep: { _ in
                    sleepCount += 1
                    frontmostProcessIdentifier = foreignProcessIdentifier
                })
            Issue.record("Expected final-interval foreign activation to lose ownership")
        } catch let error as AcceptedActivationSettlementTestError {
            #expect(error == .ownershipLost)
        } catch {
            Issue.record("Expected ownership loss, got \(error)")
        }

        #expect(frontmostProcessIdentifier == foreignProcessIdentifier)
        #expect(settlementCheckCount == 2)
        #expect(validationCount == 2)
        #expect(sleepCount == 1)
    }

    @Test
    func `input during focused window observation refuses before activation dispatch`() async throws {
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
        var inputActivity = SharedInputActivityToken.trackedZero
        var focusedWindowObservationCount = 0
        var activationMutationAttempted = false
        var clickAttempted = false
        var cursorWriteAttempted = false
        var restorationAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, dispatchGuard in
                    try dispatchGuard.validate(.applicationActivation)
                    activationMutationAttempted = true
                    try dispatchGuard.didAcceptDispatch(.applicationActivation)
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { priorProcess },
                currentFocusedExactWindow: {
                    focusedWindowObservationCount += 1
                    if focusedWindowObservationCount == 2 {
                        inputActivity = inputActivity.afterKeyboardInput()
                    }
                    return priorWindow
                },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in cursorWriteAttempted = true },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { _, _ in
                    restorationAttempted = true
                    return .confirmedNoChange()
                },
                sharedInputActivityToken: { inputActivity }))

        let failure = await self.failure(from: executor, targetProcess: targetProcess, bounds: targetBounds)

        #expect(focusedWindowObservationCount == 2)
        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.message.contains("while observing target focus ownership") == true)
        #expect(!activationMutationAttempted)
        #expect(!clickAttempted)
        #expect(!cursorWriteAttempted)
        #expect(!restorationAttempted)
    }

    @Test
    func `accepted activation settlement rejects intervening third party foreground`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let thirdPartyProcess = ApplicationProcessIdentity(processIdentifier: 33, processStartIdentity: 330)
        var frontmost = priorProcess
        var validationCount = 0
        var settlementCheckCount = 0
        var sleepCount = 0
        let dispatchGuard = FocusDispatchGuard(
            requiresStrictDispatchOwnership: true,
            validateOwnership: { stage in
                #expect(stage == .applicationActivation)
                validationCount += 1
                guard frontmost == priorProcess || frontmost == targetProcess else {
                    throw AcceptedActivationSettlementTestError.ownershipLost
                }
            },
            completeDispatch: { _ in })

        do {
            _ = try await FocusAcceptedActivationSettlement.wait(
                dispatchGuard: dispatchGuard,
                pollCount: 30,
                interval: .milliseconds(100),
                isSettled: {
                    settlementCheckCount += 1
                    return frontmost == targetProcess
                },
                sleep: { interval in
                    #expect(interval == .milliseconds(100))
                    sleepCount += 1
                    frontmost = sleepCount == 1 ? thirdPartyProcess : targetProcess
                })
            Issue.record("Expected intervening third-party activation to end settlement")
        } catch let error as AcceptedActivationSettlementTestError {
            #expect(error == .ownershipLost)
        } catch {
            Issue.record("Expected ownership loss, got \(error)")
        }

        #expect(frontmost == thirdPartyProcess)
        #expect(validationCount == 2)
        #expect(settlementCheckCount == 2)
        #expect(sleepCount == 1)
    }

    @Test
    func `pending activation rejects a different window in the source process`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let newerBounds = CGRect(x: 20, y: 20, width: 100, height: 100)
        let targetBounds = CGRect(x: 100, y: 100, width: 100, height: 100)
        let priorWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 6,
                ownerProcessIdentifier: priorProcess.processIdentifier,
                ownerProcessStartIdentity: priorProcess.processStartIdentity,
                capturedBounds: priorBounds),
            bounds: priorBounds)
        let newerSourceWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 8,
                ownerProcessIdentifier: priorProcess.processIdentifier,
                ownerProcessStartIdentity: priorProcess.processStartIdentity,
                capturedBounds: newerBounds),
            bounds: newerBounds)
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var destinationMutationAttempted = false
        var clickAttempted = false
        var restorationAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, dispatchGuard in
                    try dispatchGuard.validate(.applicationActivation)
                    try dispatchGuard.didAcceptDispatch(.applicationActivation)
                    focusedWindow = newerSourceWindow
                    try dispatchGuard.validateAcceptedActivationSettlement()
                    destinationMutationAttempted = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { priorProcess },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { _, _ in
                    restorationAttempted = true
                    return .confirmedNoChange()
                },
                sharedInputActivityToken: { .trackedZero }))

        let failure = await self.failure(from: executor, targetProcess: targetProcess, bounds: targetBounds)

        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.dispatchState.unitCount == .one)
        #expect(failure?.causeDescription?.contains("source focus changed") == true)
        #expect(focusedWindow == newerSourceWindow)
        #expect(!destinationMutationAttempted)
        #expect(!clickAttempted)
        #expect(!restorationAttempted)
    }

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

private enum AcceptedActivationSettlementTestError: Error, Equatable {
    case ownershipLost
}
