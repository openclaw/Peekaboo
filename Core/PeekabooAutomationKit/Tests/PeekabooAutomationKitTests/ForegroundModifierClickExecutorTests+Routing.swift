import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

extension ForegroundModifierClickExecutorTests {
    @Test
    func `AX receiver derives authoritative window owner from a remote leaf`() throws {
        let window = SystemWindowIdentity(
            windowID: 7,
            ownerProcessIdentifier: 22,
            title: "",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: nil)

        let receiver = try #require(BackgroundInputDriver.pointerReceiverIdentity(
            accessibilityProcessIdentifier: 2200,
            windowID: 7,
            windowIdentity: window))

        #expect(receiver.processIdentifier == 22)
        #expect(receiver.windowID == 7)
        #expect(receiver.accessibilityProcessIdentifier == 2200)
    }

    @Test
    func `AX receiver refuses incomplete leaf and window identity`() {
        let window = SystemWindowIdentity(
            windowID: 7,
            ownerProcessIdentifier: 22,
            title: "",
            bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
            layer: 0,
            alpha: 1,
            isOnScreen: true,
            sharingState: nil)

        #expect(BackgroundInputDriver.pointerReceiverIdentity(
            accessibilityProcessIdentifier: nil,
            windowID: 7,
            windowIdentity: window) == nil)
        #expect(BackgroundInputDriver.pointerReceiverIdentity(
            accessibilityProcessIdentifier: 0,
            windowID: 7,
            windowIdentity: window) == nil)
        #expect(BackgroundInputDriver.pointerReceiverIdentity(
            accessibilityProcessIdentifier: 2200,
            windowID: nil,
            windowIdentity: window) == nil)
        #expect(BackgroundInputDriver.pointerReceiverIdentity(
            accessibilityProcessIdentifier: 2200,
            windowID: 7,
            windowIdentity: nil) == nil)
    }

    @Test(arguments: ModifierClickPointerReceiverCase.allCases)
    func `AX receiver owns click through routing behind system rows and rejects overlays`(
        _ receiverCase: ModifierClickPointerReceiverCase) async throws
    {
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        let targetRoute = BackgroundInputDriver.MouseWindowRouteCandidate(
            windowID: 7,
            processIdentifier: target.processIdentifier,
            layer: 0,
            bounds: bounds)
        let dockRoute = BackgroundInputDriver.MouseWindowRouteCandidate(
            windowID: 70,
            processIdentifier: 700,
            layer: 20,
            bounds: bounds)
        let nameplateRoute = BackgroundInputDriver.MouseWindowRouteCandidate(
            windowID: 71,
            processIdentifier: 701,
            layer: 3,
            bounds: bounds)
        let targetReceiver = BackgroundInputDriver.PointerReceiverIdentity(
            processIdentifier: target.processIdentifier,
            windowID: 7,
            accessibilityProcessIdentifier: 2200)
        var cursor = CGPoint(x: 10, y: 10)
        var clickAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, dispatchGuard in
                    do {
                        try dispatchGuard.validate(.setMainWindow)
                    } catch ForegroundModifierClickError.focusTargetSatisfied {
                        return .confirmedNoChange()
                    }
                    Issue.record("Already-focused receiver fixture must not dispatch focus")
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { target },
                currentFocusedExactWindow: { exactWindow },
                activate: { _, _ in false },
                currentCursorLocation: { cursor },
                moveCursor: { cursor = $0 },
                click: { point, _, _ in
                    clickAttempted = true
                    cursor = point
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true },
                exactWindowRouteAtPoint: { point, windowID in
                    BackgroundInputDriver.exactOnScreenWindowRoute(
                        at: point,
                        windowID: windowID,
                        candidates: [dockRoute, nameplateRoute, targetRoute])
                },
                pointerReceiverAtPoint: { _ in
                    switch receiverCase {
                    case .matching: targetReceiver
                    case .overlayReceiver: BackgroundInputDriver.PointerReceiverIdentity(
                            processIdentifier: 33,
                            windowID: 8)
                    case .unavailable: nil
                    }
                }))
        let request = ForegroundModifierClickRequest(
            point: CGPoint(x: 20, y: 20),
            clickType: .single,
            modifiers: [.command],
            windowIdentity: exactWindow.identity,
            windowBounds: bounds)

        if receiverCase == .matching {
            _ = try await executor.execute(request)
            #expect(clickAttempted)
            #expect(cursor == CGPoint(x: 10, y: 10))
        } else {
            await #expect(throws: DesktopActionFailure.self) {
                _ = try await executor.execute(request)
            }
            #expect(!clickAttempted)
        }
    }

    @Test
    func `exact target disappearance before event post blocks click and cleanup`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        let targetRoute = BackgroundInputDriver.MouseWindowRouteCandidate(
            windowID: 7,
            processIdentifier: target.processIdentifier,
            layer: 0,
            bounds: bounds)
        var exactWindowRoute: BackgroundInputDriver.MouseWindowRouteCandidate? = targetRoute
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        var cursorReads = 0
        var clickAttempted = false
        var cleanupAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, dispatchGuard in
                    try dispatchGuard()
                    frontmost = target
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in
                    cleanupAttempted = true
                    return true
                },
                currentCursorLocation: {
                    cursorReads += 1
                    if cursorReads == 2 {
                        exactWindowRoute = nil
                    }
                    return CGPoint(x: 20, y: 20)
                },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                exactWindowRouteAtPoint: { _, _ in exactWindowRoute }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: exactWindow.identity,
                windowBounds: bounds))
            Issue.record("Expected a missing exact target row to block the prepared click")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount == .one)
        }
        #expect(exactWindowRoute == nil)
        #expect(!clickAttempted)
        #expect(!cleanupAttempted)
        #expect(frontmost == target)
        #expect(focusedWindow == exactWindow)
    }

    @Test
    func `shared input during final route resolution blocks click and cleanup`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        let targetRoute = BackgroundInputDriver.MouseWindowRouteCandidate(
            windowID: 7,
            processIdentifier: target.processIdentifier,
            layer: 0,
            bounds: bounds)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        var activity = SharedInputActivityToken.trackedZero
        var clickAttempted = false
        var cleanupAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, dispatchGuard in
                    try dispatchGuard()
                    frontmost = target
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in
                    cleanupAttempted = true
                    return true
                },
                currentCursorLocation: { CGPoint(x: 20, y: 20) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                exactWindowRouteAtPoint: { _, _ in
                    defer { activity = activity.afterMouseMove() }
                    return targetRoute
                },
                sharedInputActivityToken: { activity }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: exactWindow.identity,
                windowBounds: bounds))
            Issue.record("Expected input during final route validation to block the prepared click")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount == .one)
        }
        #expect(!clickAttempted)
        #expect(!cleanupAttempted)
        #expect(frontmost == target)
        #expect(focusedWindow == exactWindow)
    }

    @Test
    func `exact window replacement before event post blocks click and cleanup`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        let targetRoute = BackgroundInputDriver.MouseWindowRouteCandidate(
            windowID: 7,
            processIdentifier: target.processIdentifier,
            layer: 0,
            bounds: bounds)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        let validationState = ModifierClickValidationCounter()
        var clickAttempted = false
        var cleanupAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, dispatchGuard in
                    try dispatchGuard()
                    frontmost = target
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in
                    cleanupAttempted = true
                    return true
                },
                currentCursorLocation: { CGPoint(x: 20, y: 20) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in
                    validationState.count += 1
                    return validationState.identityIsCurrent
                },
                exactWindowRouteAtPoint: { _, _ in
                    validationState.routeQueryCount += 1
                    validationState.identityIsCurrent = false
                    return targetRoute
                }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: exactWindow.identity,
                windowBounds: bounds))
            Issue.record("Expected final exact-window replacement to block the prepared click")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount == .one)
        }
        #expect(validationState.count == 3)
        #expect(validationState.routeQueryCount == 1)
        #expect(!clickAttempted)
        #expect(!cleanupAttempted)
        #expect(frontmost == target)
        #expect(focusedWindow == exactWindow)
    }

    @Test
    func `cancellation after target focus refuses the click and restores only owned focus`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        let priorWindow = try Self.priorWindow(process: prior)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var clickAttempted = false
        var focusCleanupAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, dispatchGuard in
                    try dispatchGuard()
                    frontmost = target
                    focusedWindow = window
                    withUnsafeCurrentTask { $0?.cancel() }
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { identity, dispatchGuard in
                    try dispatchGuard()
                    frontmost = identity
                    focusedWindow = nil
                    return true
                },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { window, dispatchGuard in
                    try dispatchGuard()
                    focusCleanupAttempted = true
                    frontmost = window.identity.processIdentity
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                }))
        let operation = Task { @MainActor in
            try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: exactWindow.identity,
                windowBounds: bounds))
        }

        do {
            _ = try await operation.value
            Issue.record("Expected cancellation after focus to refuse the click")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.mutationDispatched)
        }
        #expect(!clickAttempted)
        #expect(focusCleanupAttempted)
        #expect(frontmost == prior)
        #expect(focusedWindow == priorWindow)
    }

    @Test(arguments: FocusInputTransition.allCases)
    func `input transition during target focus blocks click and all cleanup writes`(
        _ transition: FocusInputTransition) async throws
    {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        var activity = SharedInputActivityToken.trackedZero
        var clickAttempted = false
        var focusCleanupAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, dispatchGuard in
                    try dispatchGuard()
                    frontmost = target
                    focusedWindow = window
                    activity = transition.activity(after: activity)
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in
                    focusCleanupAttempted = true
                    return true
                },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                sharedInputActivityToken: { activity }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: exactWindow.identity,
                windowBounds: bounds))
            Issue.record("Expected newer shared input to block modifier-click")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount == .one)
        }
        #expect(!clickAttempted)
        #expect(!focusCleanupAttempted)
        #expect(frontmost == target)
        #expect(focusedWindow == exactWindow)
    }

    @Test(arguments: HeldInputCase.allCases)
    func `initial held key autorepeat or mouse button refuses before focus`(
        _ heldInput: HeldInputCase) async throws
    {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        let priorWindow = try Self.priorWindow(process: prior)
        let activity = heldInput.activity(after: .trackedZero)
        var focusAttempted = false
        var clickAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, _ in
                    focusAttempted = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { prior },
                currentFocusedExactWindow: { priorWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                sharedInputActivityToken: { activity }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: exactWindow.identity,
                windowBounds: bounds))
            Issue.record("Expected held physical input to refuse before focus")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(!focusAttempted)
        #expect(!clickAttempted)
    }

    @Test
    func `shared input after one owned focus write blocks every later write`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let intermediateBounds = CGRect(x: 120, y: 0, width: 100, height: 100)
        let targetWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        let intermediateWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 8,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: intermediateBounds),
            bounds: intermediateBounds)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        var activity = SharedInputActivityToken.trackedZero
        var focusWriteCount = 0
        var clickAttempted = false
        var cleanupAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, dispatchGuard in
                    do {
                        try dispatchGuard.validate(.applicationActivation)
                        frontmost = target
                        focusedWindow = intermediateWindow
                        focusWriteCount += 1
                        try dispatchGuard.didCompleteDispatch(.applicationActivation)
                        activity = activity.afterMouseMove()
                        try dispatchGuard.validate(.setMainWindow)
                        focusWriteCount += 1
                        return .confirmedChange(
                            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                            unitCount: .one)
                    } catch let ownershipLoss as ModifierClickFocusOwnershipLossFailure {
                        throw ModifierClickFocusOwnershipLossFailure(failure: .indeterminate(
                            route: .local,
                            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                            evidence: .completionUnknown,
                            unitCount: .one,
                            message: ownershipLoss.localizedDescription))
                    }
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in
                    cleanupAttempted = true
                    return true
                },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                sharedInputActivityToken: { activity }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: targetWindow.identity,
                windowBounds: bounds))
            Issue.record("Expected shared input to stop the remaining focus sequence")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount == .one)
        }
        #expect(focusWriteCount == 1)
        #expect(!clickAttempted)
        #expect(!cleanupAttempted)
        #expect(frontmost == target)
        #expect(focusedWindow == intermediateWindow)
    }
}
