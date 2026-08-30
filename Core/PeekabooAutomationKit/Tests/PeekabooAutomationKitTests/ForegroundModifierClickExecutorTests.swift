import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ForegroundModifierClickExecutorTests {
    @Test
    func `modifier click restores only its own cursor and foreground writes`() async throws {
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let point = CGPoint(x: 220, y: 240)
        let originalCursor = CGPoint(x: 20, y: 30)
        let priorWindow = try Self.priorWindow(process: prior)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var cursor = originalCursor
        var clickedModifiers: [PointerModifier] = []
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    try beforeDispatch()
                    frontmost = window.identity.processIdentity
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { identity, beforeDispatch in
                    try beforeDispatch()
                    frontmost = identity
                    focusedWindow = nil
                    return true
                },
                currentCursorLocation: { cursor },
                moveCursor: { cursor = $0 },
                click: { location, _, modifiers in
                    clickedModifiers = modifiers
                    cursor = location
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true }))

        let result = try await executor.execute(ForegroundModifierClickRequest(
            point: point,
            clickType: .single,
            modifiers: [.command, .shift],
            windowIdentity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            windowBounds: bounds))

        #expect(result.payload.cursorRestoration == .restored)
        #expect(result.payload.focusRestoration == .restored)
        #expect(result.outcome?.delivery == .init(mechanism: .composite, mode: .foreground))
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 4)
        #expect(frontmost == prior)
        #expect(cursor == originalCursor)
        #expect(clickedModifiers == [.command, .shift])
    }

    @Test
    func `modifier click skips redundant focus when exact target is already focused`() async throws {
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let point = CGPoint(x: 220, y: 240)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        var cursor = CGPoint(x: 20, y: 30)
        var focusMutationAttempted = false
        var clickCount = 0
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
                    focusMutationAttempted = true
                    return .confirmedChange(
                        delivery: .init(mechanism: .accessibilityValue, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { target },
                currentFocusedExactWindow: { exactWindow },
                activate: { _, _ in false },
                currentCursorLocation: { cursor },
                moveCursor: { cursor = $0 },
                click: { location, _, _ in
                    clickCount += 1
                    cursor = location
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true }))

        let result = try await executor.execute(ForegroundModifierClickRequest(
            point: point,
            clickType: .single,
            modifiers: [.command],
            windowIdentity: exactWindow.identity,
            windowBounds: exactWindow.bounds))

        #expect(!focusMutationAttempted)
        #expect(clickCount == 1)
        #expect(result.payload.cursorRestoration == .restored)
        #expect(result.payload.focusRestoration == .notNeeded)
        #expect(result.outcome?.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(cursor == CGPoint(x: 20, y: 30))
    }

    @Test
    func `cursor restoration baseline is recaptured immediately before click dispatch`() async throws {
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let point = CGPoint(x: 220, y: 240)
        let preflightCursor = CGPoint(x: 20, y: 30)
        let cursorAfterFocus = CGPoint(x: 740, y: 520)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        var cursor = preflightCursor
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    try beforeDispatch()
                    frontmost = window.identity.processIdentity
                    focusedWindow = window
                    cursor = cursorAfterFocus
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { identity, beforeDispatch in
                    try beforeDispatch()
                    frontmost = identity
                    focusedWindow = nil
                    return true
                },
                currentCursorLocation: { cursor },
                moveCursor: { cursor = $0 },
                click: { location, _, _ in
                    cursor = location
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true }))

        let result = try await executor.execute(ForegroundModifierClickRequest(
            point: point,
            clickType: .single,
            modifiers: [.command],
            windowIdentity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            windowBounds: bounds))

        #expect(result.payload.cursorRestoration == .restored)
        #expect(cursor == cursorAfterFocus)
        #expect(frontmost == prior)
    }

    @Test
    func `focus dispatch guard revalidates ownership before every dispatch`() throws {
        let state = ModifierClickDispatchGuardState()
        let dispatchGuard = FocusDispatchGuard {
            state.validationCount += 1
            guard state.ownershipIsValid else { throw ModifierClickTestError.focusRestoreFailed }
        }

        try dispatchGuard()
        state.ownershipIsValid = false
        #expect(throws: ModifierClickTestError.self) {
            try dispatchGuard()
        }
        #expect(state.validationCount == 2)
    }

    @Test
    func `focus adapter normalizes only proven predispatch exits`() throws {
        let cancelled = try #require(UIAutomationService.modifierClickFocusFailure(
            CancellationError(),
            sequence: DesktopActionSequenceAccumulator()) as? DesktopActionFailure)
        #expect(cancelled.outcome.state == .refused)
        #expect(cancelled.outcome.refusalReason == .requestCancelled)
        #expect(cancelled.outcome.dispatchState == .none)

        let denied = try #require(UIAutomationService.modifierClickFocusFailure(
            PeekabooError.permissionDeniedAccessibility,
            sequence: DesktopActionSequenceAccumulator()) as? DesktopActionFailure)
        #expect(denied.outcome.state == .refused)
        #expect(denied.outcome.refusalReason == .permissionDenied)
        #expect(denied.outcome.dispatchState == .none)

        var dispatched = DesktopActionSequenceAccumulator()
        dispatched.record(.dispatched(
            route: .local,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one))
        let postDispatch = try #require(UIAutomationService.modifierClickFocusFailure(
            CancellationError(),
            sequence: dispatched) as? DesktopActionFailure)
        #expect(postDispatch.outcome.state == .indeterminate)
        #expect(postDispatch.outcome.retrySafety == .unsafe)
        #expect(postDispatch.outcome.dispatchState.unitCount == .one)
    }

    @Test
    func `strict focus guard rejects activation drift and admits unchanged set-main fallback`() throws {
        let state = ModifierClickDispatchGuardState()
        let dispatchGuard = FocusDispatchGuard(
            requiresStrictDispatchOwnership: true,
            validateOwnership: { _ in
                state.validationCount += 1
                guard state.currentState == state.expectedState else {
                    throw ModifierClickTestError.focusRestoreFailed
                }
            },
            completeDispatch: { stage in
                let isAllowed = switch stage {
                case .applicationActivation:
                    state.currentState == state.finalState
                case .setMainWindow:
                    state.currentState == state.expectedState || state.currentState == state.finalState
                case .raiseWindow:
                    state.currentState == state.expectedState || state.currentState == state.finalState
                case .spaceTransition, .unspecified:
                    false
                }
                guard isAllowed else {
                    throw ModifierClickTestError.focusRestoreFailed
                }
                state.adoptionCount += 1
                state.expectedState = state.currentState
            })

        try dispatchGuard.validate(.applicationActivation)
        state.currentState = state.intermediateState
        #expect(throws: ModifierClickTestError.self) {
            try dispatchGuard.didCompleteDispatch(.applicationActivation)
        }
        state.currentState = state.expectedState
        try dispatchGuard.validate(.setMainWindow)
        try dispatchGuard.didCompleteDispatch(.setMainWindow)
        try dispatchGuard.validate(.raiseWindow)
        try dispatchGuard.didCompleteDispatch(.raiseWindow)
        #expect(state.validationCount == 3)
        #expect(state.adoptionCount == 2)
        #expect(state.expectedState == 0)
        #expect(dispatchGuard.completedStrictTerminalDispatch)
    }

    @Test
    func `newer user cursor and focus state win compare and swap restoration`() async throws {
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let newer = ApplicationProcessIdentity(processIdentifier: 33, processStartIdentity: 330)
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let point = CGPoint(x: 220, y: 240)
        let userCursor = CGPoint(x: 900, y: 700)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        var cursor = CGPoint(x: 20, y: 30)
        var didMoveCursor = false
        var didReactivate = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    try beforeDispatch()
                    frontmost = target
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, beforeDispatch in
                    frontmost = newer
                    focusedWindow = nil
                    try beforeDispatch()
                    didReactivate = true
                    return true
                },
                currentCursorLocation: { cursor },
                moveCursor: { point in
                    didMoveCursor = true
                    cursor = point
                },
                click: { _, _, _ in
                    cursor = userCursor
                    frontmost = newer
                    focusedWindow = nil
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true }))

        let result = try await executor.execute(ForegroundModifierClickRequest(
            point: point,
            clickType: .single,
            modifiers: [.command],
            windowIdentity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            windowBounds: bounds))

        #expect(result.payload.cursorRestoration == .preservedNewerState)
        #expect(result.payload.focusRestoration == .preservedNewerState)
        #expect(!didMoveCursor)
        #expect(!didReactivate)
        #expect(cursor == userCursor)
        #expect(frontmost == newer)
    }
}

extension ForegroundModifierClickExecutorTests {
    @Test
    func `stale exact target refuses before modifier or click dispatch`() async throws {
        var dispatched = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, _ in
                    dispatched = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { nil },
                currentFocusedExactWindow: { nil },
                activate: { _, _ in false },
                currentCursorLocation: { nil },
                moveCursor: { _ in dispatched = true },
                click: { _, _, _ in
                    dispatched = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in false }))

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: 22,
                    ownerProcessStartIdentity: 220,
                    capturedBounds: CGRect(x: 0, y: 0, width: 100, height: 100)),
                windowBounds: CGRect(x: 0, y: 0, width: 100, height: 100)))
        }
        #expect(!dispatched)
    }

    @Test
    func `missing prior foreground identity refuses before focus or click dispatch`() async throws {
        var dispatched = false
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, _ in
                    dispatched = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { nil },
                currentFocusedExactWindow: { nil },
                activate: { _, _ in
                    dispatched = true
                    return true
                },
                currentCursorLocation: { nil },
                moveCursor: { _ in dispatched = true },
                click: { _, _, _ in
                    dispatched = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: 22,
                    ownerProcessStartIdentity: 220,
                    capturedBounds: bounds),
                windowBounds: bounds))
            Issue.record("Expected missing-prior-foreground refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.message.contains("prior foreground application"))
        }

        #expect(!dispatched)
    }

    @Test
    func `missing original cursor refuses before focus or click dispatch`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let priorWindow = try Self.priorWindow(process: prior)
        var dispatched = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, _ in
                    dispatched = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { prior },
                currentFocusedExactWindow: { priorWindow },
                activate: { _, _ in
                    dispatched = true
                    return true
                },
                currentCursorLocation: { nil },
                moveCursor: { _ in dispatched = true },
                click: { _, _, _ in
                    dispatched = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: 22,
                    ownerProcessStartIdentity: 220,
                    capturedBounds: bounds),
                windowBounds: bounds))
            Issue.record("Expected missing-original-cursor refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.message.contains("physical cursor"))
        }

        #expect(!dispatched)
    }

    @Test
    func `raw initial focus failure with no dispatch is preserved`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let priorWindow = try Self.priorWindow(process: prior)
        var clickAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, _ in throw ModifierClickTestError.focusRestoreFailed },
                currentFrontmostIdentity: { prior },
                currentFocusedExactWindow: { priorWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true }))

        await #expect(throws: ModifierClickTestError.self) {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: target.processIdentifier,
                    ownerProcessStartIdentity: target.processStartIdentity,
                    capturedBounds: bounds),
                windowBounds: bounds))
        }
        #expect(!clickAttempted)
    }

    @Test
    func `foreground drift before initial focus dispatch preserves newer state`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let newer = ApplicationProcessIdentity(processIdentifier: 33, processStartIdentity: 330)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let priorWindow = try Self.priorWindow(process: prior)
        var frontmost = prior
        var clickAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, beforeDispatch in
                    frontmost = newer
                    try beforeDispatch()
                    Issue.record("Initial focus must not overwrite newer foreground state")
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { priorWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true }))

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: target.processIdentifier,
                    ownerProcessStartIdentity: target.processStartIdentity,
                    capturedBounds: bounds),
                windowBounds: bounds))
        }
        #expect(!clickAttempted)
        #expect(frontmost == newer)
    }

    @Test
    func `inactive multi window target advances through owned activation focus`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let targetBounds = CGRect(x: 100, y: 100, width: 100, height: 100)
        let intermediateBounds = CGRect(x: 220, y: 100, width: 100, height: 100)
        let priorWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 6,
                ownerProcessIdentifier: priorProcess.processIdentifier,
                ownerProcessStartIdentity: priorProcess.processStartIdentity,
                capturedBounds: priorBounds),
            bounds: priorBounds)
        let targetWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: targetProcess.processIdentifier,
                ownerProcessStartIdentity: targetProcess.processStartIdentity,
                capturedBounds: targetBounds),
            bounds: targetBounds)
        let intermediateWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 8,
                ownerProcessIdentifier: targetProcess.processIdentifier,
                ownerProcessStartIdentity: targetProcess.processStartIdentity,
                capturedBounds: intermediateBounds),
            bounds: intermediateBounds)
        var frontmost = priorProcess
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var cursor = CGPoint(x: 10, y: 10)
        var clickAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, dispatchGuard in
                    try dispatchGuard.validate(.applicationActivation)
                    try dispatchGuard.didAcceptDispatch(.applicationActivation)
                    frontmost = targetProcess
                    focusedWindow = intermediateWindow
                    try dispatchGuard.validateAcceptedActivationSettlement()
                    try dispatchGuard.didCompleteDispatch(.applicationActivation)
                    try dispatchGuard.validate(.setMainWindow)
                    try dispatchGuard.didCompleteDispatch(.setMainWindow)
                    try dispatchGuard.validate(.raiseWindow)
                    focusedWindow = window
                    do {
                        try dispatchGuard.didCompleteDispatch(.raiseWindow)
                    } catch ForegroundModifierClickError.focusTargetSatisfied {
                        return .confirmedChange(
                            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                            unitCount: .one)
                    }
                    Issue.record("Owned exact target focus should terminate after raise")
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { cursor },
                moveCursor: { cursor = $0 },
                click: { location, _, _ in
                    clickAttempted = true
                    cursor = location
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { _, dispatchGuard in
                    try dispatchGuard()
                    frontmost = priorProcess
                    focusedWindow = priorWindow
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                }))

        let result = try await executor.execute(ForegroundModifierClickRequest(
            point: CGPoint(x: 120, y: 120),
            clickType: .single,
            modifiers: [.command],
            windowIdentity: targetWindow.identity,
            windowBounds: targetBounds))

        #expect(clickAttempted)
        #expect(result.payload.focusRestoration == .restored)
        #expect(frontmost == priorProcess)
        #expect(focusedWindow == priorWindow)
    }

    @Test
    func `owned activation intermediate restores prior window after focus failure`() async throws {
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
        let intermediateWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 8,
                ownerProcessIdentifier: targetProcess.processIdentifier,
                ownerProcessStartIdentity: targetProcess.processStartIdentity,
                capturedBounds: targetBounds),
            bounds: targetBounds)
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
                    frontmost = targetProcess
                    focusedWindow = intermediateWindow
                    try dispatchGuard.didCompleteDispatch(.applicationActivation)
                    throw ModifierClickTestError.focusRestoreFailed
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
                restoreExactWindow: { _, dispatchGuard in
                    try dispatchGuard()
                    restoreAttempted = true
                    frontmost = priorProcess
                    focusedWindow = priorWindow
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                }))

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 120, y: 120),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: targetProcess.processIdentifier,
                    ownerProcessStartIdentity: targetProcess.processStartIdentity,
                    capturedBounds: targetBounds),
                windowBounds: targetBounds))
        }

        #expect(restoreAttempted)
        #expect(!clickAttempted)
        #expect(frontmost == priorProcess)
        #expect(focusedWindow == priorWindow)
    }

    @Test
    func `click preparation failure refuses before foreground focus`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
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
                currentFocusedExactWindow: { nil },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                prepareClick: { _, _, _ in
                    throw PeekabooError.permissionDeniedEventSynthesizing
                }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: 22,
                    ownerProcessStartIdentity: 220,
                    capturedBounds: bounds),
                windowBounds: bounds))
            Issue.record("Expected preparation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.refusalReason == .permissionDenied)
        }

        #expect(!focusAttempted)
        #expect(!clickAttempted)
    }

    @Test
    func `cancellation before foreground lane is a typed predispatch refusal`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = DesktopOperationLaneCoordinator(coordinationRootURL: root)
        let suspension = ModifierClickLaneSuspension()
        let holder = Task {
            try await coordinator.run(scope: .global, access: .write) {
                await suspension.hold()
            }
        }
        await suspension.waitUntilHeld()
        var focusAttempted = false
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: coordinator,
            dependencies: .init(
                focusExactWindow: { _, _ in
                    focusAttempted = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { prior },
                currentFocusedExactWindow: { nil },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 10, y: 10) },
                moveCursor: { _ in },
                click: { _, _, _ in .confirmedNoChange() },
                validateExactWindow: { _, _ in true }))
        let operation = Task { @MainActor in
            try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: 22,
                    ownerProcessStartIdentity: 220,
                    capturedBounds: bounds),
                windowBounds: bounds))
        }
        operation.cancel()
        await suspension.release()
        _ = try await holder.value

        do {
            _ = try await operation.value
            Issue.record("Expected pre-lane cancellation refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .requestCancelled)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.targetReceipt == DesktopActionTargetReceipt(
                processIdentifier: 22,
                processStartIdentity: 220,
                windowID: 7))
        }
        #expect(!focusAttempted)
    }

    @Test
    func `external target focus between initial dispatch stages preserves newer state`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let priorWindow = try Self.priorWindow(process: prior)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = priorWindow
        var clickAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, dispatchGuard in
                    try dispatchGuard.validate(.setMainWindow)
                    try dispatchGuard.didCompleteDispatch(.setMainWindow)
                    frontmost = target
                    focusedWindow = window
                    try dispatchGuard.validate(.raiseWindow)
                    Issue.record("Initial focus must not claim an external exact-target transition")
                    return .confirmedNoChange()
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
                validateExactWindow: { _, _ in true }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: target.processIdentifier,
                    ownerProcessStartIdentity: target.processStartIdentity,
                    capturedBounds: bounds),
                windowBounds: bounds))
            Issue.record("Expected external exact-target focus to refuse")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }

        #expect(!clickAttempted)
        #expect(frontmost == target)
        #expect(focusedWindow?.identity.windowID == 7)
    }
}
