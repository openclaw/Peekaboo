import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ForegroundModifierClickCompletedRestorationTests {
    @Test
    func `pending restoration adopts missing destination window until exact terminal window`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorWindow = try Self.window(id: 6, process: priorProcess, x: 0)
        let targetWindow = try Self.window(id: 7, process: targetProcess, x: 100)
        var frontmost = priorProcess
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var inputActivity = SharedInputActivityToken.trackedZero
        var destinationIntermediateAccepted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, _ in
                    frontmost = targetProcess
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, clickType, _ in
                    inputActivity = inputActivity.afterModifierClick(clickType)
                    return .confirmedChange(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { _, dispatchGuard in
                    try dispatchGuard.validate(.applicationActivation)
                    try dispatchGuard.didAcceptDispatch(.applicationActivation)
                    frontmost = priorProcess
                    focusedWindow = nil
                    destinationIntermediateAccepted = true
                    try dispatchGuard.didCompleteDispatch(.applicationActivation)
                    try dispatchGuard.validate(.setMainWindow)
                    try dispatchGuard.didCompleteDispatch(.setMainWindow)
                    try dispatchGuard.validate(.raiseWindow)
                    focusedWindow = priorWindow
                    do {
                        try dispatchGuard.didCompleteDispatch(.raiseWindow)
                    } catch ForegroundModifierClickError.focusRestorationSatisfied {
                        return .confirmedChange(
                            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                            unitCount: .one)
                    }
                    Issue.record("Strict restoration completion should terminate at the exact prior window")
                    return .confirmedNoChange()
                },
                sharedInputActivityToken: { inputActivity },
                restoreCursor: { _, _, _ in .notNeeded }))

        let result = try await executor.execute(Self.request(for: targetWindow))

        #expect(destinationIntermediateAccepted)
        #expect(result.payload.focusRestoration == .restored)
        #expect(frontmost == priorProcess)
        #expect(focusedWindow == priorWindow)
    }

    @Test
    func `pending restoration preserves a different destination window`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorWindow = try Self.window(id: 6, process: priorProcess, x: 0)
        let targetWindow = try Self.window(id: 7, process: targetProcess, x: 100)
        let newerDestinationWindow = try Self.window(id: 9, process: priorProcess, x: 340)
        var frontmost = priorProcess
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var inputActivity = SharedInputActivityToken.trackedZero
        var laterMutationAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, _ in
                    frontmost = targetProcess
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, clickType, _ in
                    inputActivity = inputActivity.afterModifierClick(clickType)
                    return .confirmedChange(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { _, dispatchGuard in
                    try dispatchGuard.validate(.applicationActivation)
                    try dispatchGuard.didAcceptDispatch(.applicationActivation)
                    frontmost = priorProcess
                    focusedWindow = newerDestinationWindow
                    try dispatchGuard.didCompleteDispatch(.applicationActivation)
                    laterMutationAttempted = true
                    focusedWindow = priorWindow
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                sharedInputActivityToken: { inputActivity },
                restoreCursor: { _, _, _ in .notNeeded }))

        let result = try await executor.execute(Self.request(for: targetWindow))

        #expect(result.payload.focusRestoration == .preservedNewerState)
        #expect(frontmost == priorProcess)
        #expect(focusedWindow == newerDestinationWindow)
        #expect(!laterMutationAttempted)
    }

    @Test
    func `pending restoration rejects a different window in the source process`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorWindow = try Self.window(id: 6, process: priorProcess, x: 0)
        let targetWindow = try Self.window(id: 7, process: targetProcess, x: 100)
        let newerSourceWindow = try Self.window(id: 8, process: targetProcess, x: 220)
        var frontmost = priorProcess
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var inputActivity = SharedInputActivityToken.trackedZero
        var destinationMutationAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, _ in
                    frontmost = targetProcess
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, clickType, _ in
                    inputActivity = inputActivity.afterModifierClick(clickType)
                    return .confirmedChange(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { _, dispatchGuard in
                    try dispatchGuard.validate(.applicationActivation)
                    try dispatchGuard.didAcceptDispatch(.applicationActivation)
                    focusedWindow = newerSourceWindow
                    try dispatchGuard.validateAcceptedActivationSettlement()
                    destinationMutationAttempted = true
                    frontmost = priorProcess
                    focusedWindow = priorWindow
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                sharedInputActivityToken: { inputActivity },
                restoreCursor: { _, _, _ in .notNeeded }))

        let result = try await executor.execute(Self.request(for: targetWindow))

        #expect(result.payload.focusRestoration == .preservedNewerState)
        #expect(frontmost == targetProcess)
        #expect(focusedWindow == newerSourceWindow)
        #expect(!destinationMutationAttempted)
    }

    @Test
    func `completed activation without focused window restores after target focus failure`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorWindow = try Self.window(id: 6, process: priorProcess, x: 0)
        let targetWindow = try Self.window(id: 7, process: targetProcess, x: 100)
        var frontmost = priorProcess
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var clickAttempted = false
        var restoreAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, dispatchGuard in
                    try dispatchGuard.validate(.applicationActivation)
                    try dispatchGuard.didAcceptDispatch(.applicationActivation)
                    frontmost = targetProcess
                    focusedWindow = nil
                    try dispatchGuard.didCompleteDispatch(.applicationActivation)
                    try dispatchGuard.validate(.setMainWindow)
                    throw CompletedRestorationTestError.targetFocusFailed
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { window, dispatchGuard in
                    #expect(window == priorWindow)
                    try dispatchGuard()
                    restoreAttempted = true
                    frontmost = priorProcess
                    focusedWindow = priorWindow
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                }))

        let failure = await self.failure(from: executor, targetWindow: targetWindow)

        #expect(failure?.outcome.state == .indeterminate)
        #expect(restoreAttempted)
        #expect(!clickAttempted)
        #expect(frontmost == priorProcess)
        #expect(focusedWindow == priorWindow)
    }

    @Test
    func `cross application missing prior exact window refuses every write`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let targetWindow = try Self.window(id: 7, process: targetProcess, x: 100)
        var focusAttempted = false
        var clickAttempted = false
        var cursorWriteAttempted = false
        var restorationActivationAttempted = false
        var exactRestoreAttempted = false
        var cursorRestoreAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, _ in
                    focusAttempted = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { priorProcess },
                currentFocusedExactWindow: { nil },
                activate: { _, _ in
                    restorationActivationAttempted = true
                    return false
                },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in cursorWriteAttempted = true },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { _, _ in
                    exactRestoreAttempted = true
                    return .confirmedNoChange()
                },
                restoreCursor: { _, _, _ in
                    cursorRestoreAttempted = true
                    return .notNeeded
                }))

        let failure = await self.failure(from: executor, targetWindow: targetWindow)

        #expect(failure?.outcome.state == .refused)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.message.contains("exact prior focused window") == true)
        #expect(!focusAttempted)
        #expect(!clickAttempted)
        #expect(!cursorWriteAttempted)
        #expect(!restorationActivationAttempted)
        #expect(!exactRestoreAttempted)
        #expect(!cursorRestoreAttempted)
    }

    @Test
    func `real cancellation after completed action runs exact restoration uncancelled`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorWindow = try Self.window(id: 6, process: priorProcess, x: 0)
        let targetWindow = try Self.window(id: 7, process: targetProcess, x: 100)
        var frontmost = priorProcess
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var inputActivity = SharedInputActivityToken.trackedZero
        var restoreObservedUncancelledTask = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, _ in
                    frontmost = targetProcess
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, clickType, _ in
                    inputActivity = inputActivity.afterModifierClick(clickType)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .confirmedChange(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { window, dispatchGuard in
                    #expect(window == priorWindow)
                    restoreObservedUncancelledTask = !Task.isCancelled
                    try Task.checkCancellation()
                    try dispatchGuard.validate(.applicationActivation)
                    frontmost = priorProcess
                    focusedWindow = priorWindow
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                sharedInputActivityToken: { inputActivity },
                restoreCursor: { _, _, _ in .notNeeded }))

        let actionTask = Task { @MainActor in
            try await executor.execute(Self.request(for: targetWindow))
        }
        let result = try await actionTask.value

        #expect(restoreObservedUncancelledTask)
        #expect(result.payload.focusRestoration == .restored)
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 3)
        #expect(frontmost == priorProcess)
        #expect(focusedWindow == priorWindow)
    }

    private func failure(
        from executor: ForegroundModifierClickExecutor,
        targetWindow: UIAutomationTarget.ExactWindow) async -> DesktopActionFailure?
    {
        do {
            _ = try await executor.execute(Self.request(for: targetWindow))
            Issue.record("Expected restoration failure")
            return nil
        } catch let failure as DesktopActionFailure {
            return failure
        } catch {
            Issue.record("Expected DesktopActionFailure, got \(error)")
            return nil
        }
    }

    private static func request(for window: UIAutomationTarget.ExactWindow) -> ForegroundModifierClickRequest {
        ForegroundModifierClickRequest(
            point: CGPoint(x: 120, y: 120),
            clickType: .single,
            modifiers: [.command],
            windowIdentity: window.identity,
            windowBounds: window.bounds)
    }

    private static func window(
        id: Int,
        process: ApplicationProcessIdentity,
        x: CGFloat) throws -> UIAutomationTarget.ExactWindow
    {
        let bounds = CGRect(x: x, y: x, width: 100, height: 100)
        return try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: id,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-completed-restoration-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

private enum CompletedRestorationTestError: Error {
    case targetFocusFailed
}
