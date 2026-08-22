import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ForegroundModifierClickCompletedRestorationTests {
    @Test
    func `app-only accepted restoration losing CAS is counted once and not retried`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let targetWindow = try Self.window(id: 7, process: targetProcess, x: 100)
        var frontmost = priorProcess
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var inputActivity = SharedInputActivityToken.trackedZero
        var activationAttempted = false
        var exactRestoreAttempted = false
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
                activate: { process, dispatchGuard in
                    #expect(process == priorProcess)
                    try dispatchGuard.validate(.applicationActivation)
                    try dispatchGuard.didAcceptDispatch(.applicationActivation)
                    activationAttempted = true
                    frontmost = priorProcess
                    try dispatchGuard.validate(.applicationActivation)
                    inputActivity = inputActivity.afterKeyboardInput()
                    try dispatchGuard.didCompleteDispatch(.applicationActivation)
                    return true
                },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, clickType, _ in
                    inputActivity = inputActivity.afterModifierClick(clickType)
                    return .confirmedChange(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { _, _ in
                    exactRestoreAttempted = true
                    return .confirmedNoChange()
                },
                sharedInputActivityToken: { inputActivity },
                restoreCursor: { _, _, _ in .notNeeded }))

        let failure = await self.failure(from: executor, targetWindow: targetWindow)

        #expect(activationAttempted)
        #expect(!exactRestoreAttempted)
        #expect(failure?.outcome.state == .indeterminate)
        #expect(failure?.outcome.dispatchState.unitCount?.rawValue == 3)
        #expect(failure?.outcome.retrySafety == .unsafe)
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
