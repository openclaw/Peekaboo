import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

@MainActor
struct ForegroundModifierClickExecutorTests {
    @Test
    func `modifier click encodes flags only on a prebuilt mouse sequence`() throws {
        let priorFlags = CGEventSource.flagsState(.combinedSessionState)
        let events = try UIAutomationService.makeModifierClickEvents(
            point: CGPoint(x: 220, y: 240),
            clickType: .double,
            modifiers: [.command, .shift],
            source: CGEventSource(stateID: .hidSystemState),
            eventSourceUserData: 42)

        #expect(events.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2])
        #expect(events.allSatisfy { $0.flags.contains([.maskCommand, .maskShift]) })
        #expect(events.allSatisfy { $0.getIntegerValueField(.eventSourceUserData) == 42 })
        #expect(CGEventSource.flagsState(.combinedSessionState) == priorFlags)
    }

    @Test
    func `private event sources expose distinct counter state tables`() throws {
        let first = try #require(CGEventSource(stateID: .privateState))
        let second = try #require(CGEventSource(stateID: .privateState))

        #expect(first.sourceStateID != .privateState)
        #expect(second.sourceStateID != .privateState)
        #expect(first.sourceStateID != second.sourceStateID)
    }

    @Test
    func `modifier click restores only its own cursor and foreground writes`() async throws {
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let point = CGPoint(x: 220, y: 240)
        let originalCursor = CGPoint(x: 20, y: 30)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var cursor = originalCursor
        var clickedModifiers: [PointerModifier] = []
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
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var cursor = preflightCursor
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    try beforeDispatch()
                    frontmost = target
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
        var focusedWindow: UIAutomationTarget.ExactWindow?
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
        var clickAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _, _ in throw ModifierClickTestError.focusRestoreFailed },
                currentFrontmostIdentity: { prior },
                currentFocusedExactWindow: { nil },
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
                currentFocusedExactWindow: { nil },
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
                    frontmost = targetProcess
                    focusedWindow = intermediateWindow
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
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
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

extension ForegroundModifierClickExecutorTests {
    @Test
    func `pointer route drift before event post blocks click and cleanup`() async throws {
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
        let overlayRoute = BackgroundInputDriver.MouseWindowRouteCandidate(
            windowID: 70,
            processIdentifier: 700,
            layer: 8,
            bounds: CGRect(x: 10, y: 10, width: 50, height: 50))
        var pointerRoute = targetRoute
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
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
                        pointerRoute = overlayRoute
                    }
                    return CGPoint(x: 20, y: 20)
                },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true },
                pointerRouteAtPoint: { _ in pointerRoute }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 20, y: 20),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: exactWindow.identity,
                windowBounds: bounds))
            Issue.record("Expected an occluding route to block the prepared click")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount == .one)
        }
        #expect(pointerRoute == overlayRoute)
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
        var focusedWindow: UIAutomationTarget.ExactWindow?
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
                    return validationState.count < 3
                },
                pointerRouteAtPoint: { _ in targetRoute }))

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
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
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
                    focusCleanupAttempted = true
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
                validateExactWindow: { _, _ in true }))
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
        #expect(focusedWindow == nil)
    }

    @Test
    func `shared input during target focus blocks click and all cleanup writes`() async throws {
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
        var focusedWindow: UIAutomationTarget.ExactWindow?
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
                    activity = activity.afterMouseMove()
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
        var focusedWindow: UIAutomationTarget.ExactWindow?
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

    @Test
    func `foreground drift during cursor recapture refuses before click dispatch`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let newer = ApplicationProcessIdentity(processIdentifier: 33, processStartIdentity: 330)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: target.processIdentifier,
                ownerProcessStartIdentity: target.processStartIdentity,
                capturedBounds: bounds),
            bounds: bounds)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var cursorReads = 0
        var clickAttempted = false
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
                activate: { _, _ in false },
                currentCursorLocation: {
                    cursorReads += 1
                    if cursorReads == 2 {
                        frontmost = newer
                        focusedWindow = nil
                    }
                    return CGPoint(x: 10, y: 10)
                },
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
                windowIdentity: exactWindow.identity,
                windowBounds: bounds))
        }
        #expect(!clickAttempted)
        #expect(frontmost == newer)
    }

    @Test
    func `cursor movement or stationary click generation wins before restoration write`() throws {
        let expected = SharedInputActivityToken.trackedZero
        let original = CGPoint(x: 10, y: 10)
        let lastWritten = CGPoint(x: 20, y: 20)
        for newer in [expected.afterMouseMove(), expected.afterModifierClick(.single)] {
            var activityReads = 0
            var cursor = lastWritten
            var moveAttempted = false

            let status = try CursorRestorationOwnership.restore(
                original: original,
                lastWritten: lastWritten,
                activityToken: expected,
                currentActivity: {
                    activityReads += 1
                    return activityReads == 1 ? expected : newer
                },
                currentLocation: { cursor },
                move: {
                    moveAttempted = true
                    cursor = $0
                })

            #expect(status == .preservedNewerState)
            #expect(!moveAttempted)
            #expect(cursor == lastWritten)
        }
    }

    @Test(arguments: SharedDesktopInterruption.allCases)
    func `newer shared input suppresses cursor and focus cleanup`(
        _ interruption: SharedDesktopInterruption) async throws
    {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let point = CGPoint(x: 20, y: 20)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var cursor = CGPoint(x: 10, y: 10)
        var activity = SharedInputActivityToken.trackedZero
        var cursorCleanupAttempted = false
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
                currentCursorLocation: { cursor },
                moveCursor: { location in
                    cursorCleanupAttempted = true
                    cursor = location
                },
                click: { location, clickType, _ in
                    cursor = location
                    activity = interruption.activity(
                        after: activity.afterModifierClick(clickType))
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true },
                sharedInputActivityToken: { activity }))

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
        #expect(!cursorCleanupAttempted)
        #expect(!focusCleanupAttempted)
        #expect(cursor == point)
        #expect(frontmost == target)
    }

    @Test
    func `private source mouse up barrier waits for the complete sequence`() throws {
        let clock = ContinuousClock()
        var now = clock.now
        let deadline = now.advanced(by: .milliseconds(3))
        var counter: UInt32 = 7
        var steps = 0

        try ModifierClickDispatchBarrier.waitForMouseUps(
            baseline: 7,
            expectedIncrement: 2,
            deadline: deadline,
            now: { now },
            counter: { counter },
            runLoopStep: {
                steps += 1
                counter += 1
                now = now.advanced(by: .milliseconds(1))
            })

        #expect(steps == 2)
        #expect(counter == 9)
    }

    @Test
    func `mouse up barrier timeout is cleanup unsafe and accounts one click unit`() {
        let clock = ContinuousClock()
        var now = clock.now
        let deadline = now.advanced(by: .milliseconds(1))
        do {
            try ModifierClickDispatchBarrier.waitForMouseUps(
                baseline: 7,
                expectedIncrement: 1,
                deadline: deadline,
                now: { now },
                counter: { 7 },
                runLoopStep: { now = deadline })
            Issue.record("Expected the modifier-click delivery barrier to time out")
        } catch let failure as ModifierClickDispatchBarrierFailure {
            #expect(failure.failure.outcome.state == .indeterminate)
            #expect(failure.failure.outcome.dispatchState.unitCount == .one)
            #expect(failure.failure.outcome.retrySafety == .unsafe)
        } catch {
            Issue.record("Unexpected barrier error: \(error)")
        }
    }

    @Test
    func `uncertain click barrier skips cursor and focus cleanup`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let point = CGPoint(x: 20, y: 20)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var cursor = CGPoint(x: 10, y: 10)
        var cursorCleanupAttempted = false
        var focusCleanupAttempted = false
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
                activate: { _, _ in
                    focusCleanupAttempted = true
                    return true
                },
                currentCursorLocation: { cursor },
                moveCursor: {
                    cursorCleanupAttempted = true
                    cursor = $0
                },
                click: { location, _, _ in
                    cursor = location
                    throw ModifierClickDispatchBarrierFailure(failure: .indeterminate(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .completionUnknown,
                        unitCount: .one,
                        message: "fixture barrier timeout"))
                },
                validateExactWindow: { _, _ in true }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: point,
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: target.processIdentifier,
                    ownerProcessStartIdentity: target.processStartIdentity,
                    capturedBounds: bounds),
                windowBounds: bounds))
            Issue.record("Expected uncertain modifier-click delivery")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 2)
        }
        #expect(!cursorCleanupAttempted)
        #expect(!focusCleanupAttempted)
        #expect(cursor == point)
        #expect(frontmost == target)
    }

    @Test
    func `cursor restoration failure still attempts focus restoration`() async throws {
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let point = CGPoint(x: 220, y: 240)
        let originalCursor = CGPoint(x: 20, y: 30)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var cursor = originalCursor
        var cursorRestoreAttempted = false
        var focusRestoreAttempted = false
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
                activate: { identity, beforeDispatch in
                    try beforeDispatch()
                    focusRestoreAttempted = true
                    frontmost = identity
                    focusedWindow = nil
                    return true
                },
                currentCursorLocation: { cursor },
                moveCursor: { _ in
                    cursorRestoreAttempted = true
                    throw ModifierClickTestError.cursorRestoreFailed
                },
                click: { location, _, _ in
                    cursor = location
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: point,
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: target.processIdentifier,
                    ownerProcessStartIdentity: target.processStartIdentity,
                    capturedBounds: bounds),
                windowBounds: bounds))
            Issue.record("Expected cleanup failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount == nil)
            #expect(failure.causeDescription?.contains("Cursor restoration") == true)
        }

        #expect(cursorRestoreAttempted)
        #expect(focusRestoreAttempted)
        #expect(cursor == point)
        #expect(frontmost == prior)
    }

    @Test
    func `unreadable cursor during cleanup is indeterminate and still restores focus`() async throws {
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let point = CGPoint(x: 220, y: 240)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var cursor: CGPoint? = CGPoint(x: 20, y: 30)
        var focusRestoreAttempted = false
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
                activate: { identity, beforeDispatch in
                    try beforeDispatch()
                    focusRestoreAttempted = true
                    frontmost = identity
                    focusedWindow = nil
                    return true
                },
                currentCursorLocation: { cursor },
                moveCursor: { _ in Issue.record("Unreadable cursor must not be moved blindly") },
                click: { _, _, _ in
                    cursor = nil
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: point,
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: target.processIdentifier,
                    ownerProcessStartIdentity: target.processStartIdentity,
                    capturedBounds: bounds),
                windowBounds: bounds))
            Issue.record("Expected unreadable-cursor cleanup failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.causeDescription?.contains("Cursor restoration") == true)
        }

        #expect(focusRestoreAttempted)
        #expect(frontmost == prior)
    }

    @Test
    func `post-dispatch cursor verification failure does not double count restoration`() async throws {
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let bounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let point = CGPoint(x: 220, y: 240)
        let originalCursor = CGPoint(x: 20, y: 30)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow?
        var cursor = originalCursor
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
                activate: { identity, beforeDispatch in
                    try beforeDispatch()
                    frontmost = identity
                    focusedWindow = nil
                    return true
                },
                currentCursorLocation: { cursor },
                moveCursor: { _ in },
                click: { location, _, _ in
                    cursor = location
                    return .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: point,
                clickType: .single,
                modifiers: [.command],
                windowIdentity: WindowMutationIdentity(
                    windowID: 7,
                    ownerProcessIdentifier: target.processIdentifier,
                    ownerProcessStartIdentity: target.processStartIdentity,
                    capturedBounds: bounds),
                windowBounds: bounds))
            Issue.record("Expected cursor restoration verification failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 4)
            #expect(failure.causeDescription?.contains("Cursor restoration") == true)
        }

        #expect(cursor == point)
        #expect(frontmost == prior)
    }

    @Test
    func `same application modifier click restores the prior exact window`() async throws {
        let process = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorBounds = CGRect(x: 20, y: 20, width: 500, height: 300)
        let targetBounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let priorWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 6,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: priorBounds),
            bounds: priorBounds)
        let targetWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: targetBounds),
            bounds: targetBounds)
        var focusedWindow = priorWindow
        var focusCalls: [Int] = []
        var cursor = CGPoint(x: 20, y: 30)
        var processActivationAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    #expect(window == targetWindow)
                    var focusSequence = DesktopActionSequenceAccumulator()
                    try beforeDispatch.validate(.setMainWindow)
                    focusSequence.record(.dispatched(
                        route: .local,
                        delivery: .init(mechanism: .accessibilityValue, mode: .foreground),
                        unitCount: .one))
                    try beforeDispatch.didCompleteDispatch(.setMainWindow)
                    try beforeDispatch.validate(.raiseWindow)
                    focusCalls.append(window.identity.windowID)
                    focusedWindow = window
                    focusSequence.record(.dispatched(
                        route: .local,
                        delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                        unitCount: .one))
                    do {
                        try beforeDispatch.didCompleteDispatch(.raiseWindow)
                        Issue.record("Exact target focus should terminate after the owned raise")
                    } catch ForegroundModifierClickError.focusTargetSatisfied {
                        return FocusDispatchAccounting.verifiedFocusOutcome(focusSequence.successResolution())
                    }
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { process },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, beforeDispatch in
                    try beforeDispatch()
                    processActivationAttempted = true
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
                validateExactWindow: { _, _ in true },
                restoreExactWindow: { window, beforeDispatch in
                    try beforeDispatch()
                    #expect(window == priorWindow)
                    focusCalls.append(window.identity.windowID)
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                        unitCount: .one)
                }))

        let result = try await executor.execute(ForegroundModifierClickRequest(
            point: CGPoint(x: 220, y: 240),
            clickType: .single,
            modifiers: [.command],
            windowIdentity: targetWindow.identity,
            windowBounds: targetBounds))

        #expect(result.payload.focusRestoration == .restored)
        #expect(focusedWindow == priorWindow)
        #expect(focusCalls == [targetWindow.identity.windowID, priorWindow.identity.windowID])
        #expect(!processActivationAttempted)
    }

    @Test
    func `newer exact window at restoration dispatch wins compare and swap`() async throws {
        let process = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorBounds = CGRect(x: 20, y: 20, width: 500, height: 300)
        let targetBounds = CGRect(x: 100, y: 100, width: 600, height: 400)
        let newerBounds = CGRect(x: 40, y: 40, width: 450, height: 280)
        let priorWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 6,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: priorBounds),
            bounds: priorBounds)
        let targetWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 7,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: targetBounds),
            bounds: targetBounds)
        let newerWindow = try UIAutomationTarget.ExactWindow(
            identity: WindowMutationIdentity(
                windowID: 8,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: newerBounds),
            bounds: newerBounds)
        let point = CGPoint(x: 220, y: 240)
        var focusedWindow = priorWindow
        var dispatchedWindows: [Int] = []
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    if window == priorWindow {
                        focusedWindow = newerWindow
                        try beforeDispatch()
                        Issue.record("Restoration must not overwrite the newer exact window")
                    } else {
                        try beforeDispatch()
                    }
                    dispatchedWindows.append(window.identity.windowID)
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { process },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { point },
                moveCursor: { _ in },
                click: { _, _, _ in
                    .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true }))

        let result = try await executor.execute(ForegroundModifierClickRequest(
            point: point,
            clickType: .single,
            modifiers: [.command],
            windowIdentity: targetWindow.identity,
            windowBounds: targetBounds))

        #expect(result.payload.focusRestoration == .preservedNewerState)
        #expect(focusedWindow == newerWindow)
        #expect(dispatchedWindows == [targetWindow.identity.windowID])
    }

    @Test
    func `failed target focus still restores the prior exact window`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorBounds = CGRect(x: 20, y: 20, width: 500, height: 300)
        let targetBounds = CGRect(x: 100, y: 100, width: 600, height: 400)
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
        var frontmost = priorProcess
        var focusedWindow = priorWindow
        var clickAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    try beforeDispatch()
                    frontmost = window.identity.processIdentity
                    focusedWindow = window
                    if window == targetWindow {
                        throw DesktopActionFailure.indeterminate(
                            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                            evidence: .completionUnknown,
                            unitCount: .one,
                            message: "focus verification failed")
                    }
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 20, y: 30) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    clickAttempted = true
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true }))

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 220, y: 240),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: targetWindow.identity,
                windowBounds: targetBounds))
        }

        #expect(!clickAttempted)
        #expect(frontmost == priorProcess)
        #expect(focusedWindow == priorWindow)
    }

    @Test
    func `focus restoration failure contributes its dispatched units to cleanup outcome`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorBounds = CGRect(x: 20, y: 20, width: 500, height: 300)
        let targetBounds = CGRect(x: 100, y: 100, width: 600, height: 400)
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
        let restorationUnits = try #require(DesktopActionOutcome.DispatchUnitCount(2))
        var frontmost = priorProcess
        var focusedWindow = priorWindow
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    if window == priorWindow {
                        try beforeDispatch()
                        throw DesktopActionFailure.indeterminate(
                            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                            evidence: .completionUnknown,
                            unitCount: restorationUnits,
                            message: "focus restoration response was lost")
                    }
                    try beforeDispatch()
                    frontmost = targetProcess
                    focusedWindow = targetWindow
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 220, y: 240) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    .dispatchedUnverified(
                        delivery: .init(mechanism: .globalEvents, mode: .foreground),
                        evidence: .deliveryAccepted,
                        unitCount: .one)
                },
                validateExactWindow: { _, _ in true }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 220, y: 240),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: targetWindow.identity,
                windowBounds: targetBounds))
            Issue.record("Expected focus restoration failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 4)
            #expect(failure.causeDescription?.contains("Focus restoration") == true)
            #expect(failure.causeDescription?.contains("response was lost") == true)
        }
    }

    @Test
    func `cleanup aggregation preserves response loss from an earlier failure`() async throws {
        let priorProcess = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let targetProcess = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let priorBounds = CGRect(x: 20, y: 20, width: 500, height: 300)
        let targetBounds = CGRect(x: 100, y: 100, width: 600, height: 400)
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
        var frontmost = priorProcess
        var focusedWindow = priorWindow
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    if window == priorWindow {
                        try beforeDispatch()
                        throw ModifierClickTestError.focusRestoreFailed
                    }
                    try beforeDispatch()
                    frontmost = targetProcess
                    focusedWindow = targetWindow
                    throw DesktopActionFailure.indeterminate(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        evidence: .responseLost,
                        unitCount: .one,
                        message: "target focus response was lost")
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _, _ in false },
                currentCursorLocation: { CGPoint(x: 20, y: 30) },
                moveCursor: { _ in },
                click: { _, _, _ in
                    Issue.record("Click must not run after failed target focus")
                    return .confirmedNoChange()
                },
                validateExactWindow: { _, _ in true }))

        do {
            _ = try await executor.execute(ForegroundModifierClickRequest(
                point: CGPoint(x: 220, y: 240),
                clickType: .single,
                modifiers: [.command],
                windowIdentity: targetWindow.identity,
                windowBounds: targetBounds))
            Issue.record("Expected aggregated cleanup failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.evidence == .responseLost)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.causeDescription?.contains("Primary action") == true)
            #expect(failure.causeDescription?.contains("Focus restoration") == true)
        }
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-modifier-click-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

@MainActor
private final class ModifierClickDispatchGuardState {
    var ownershipIsValid = true
    var validationCount = 0
    var adoptionCount = 0
    var currentState = 0
    var expectedState = 0
    var intermediateState = 1
    var finalState = 2
}

private final class ModifierClickValidationCounter: @unchecked Sendable {
    var count = 0
}

enum SharedDesktopInterruption: CaseIterable, Sendable {
    case stationaryClick
    case keyboard
    case scroll

    func activity(after token: SharedInputActivityToken) -> SharedInputActivityToken {
        switch self {
        case .stationaryClick:
            token.afterModifierClick(.single)
        case .keyboard:
            token.afterKeyboardInput()
        case .scroll:
            token.afterScrollInput()
        }
    }
}

private enum ModifierClickTestError: LocalizedError {
    case cursorRestoreFailed
    case focusRestoreFailed

    var errorDescription: String? {
        switch self {
        case .cursorRestoreFailed:
            "cursor restore failed"
        case .focusRestoreFailed:
            "focus restore failed"
        }
    }
}

private actor ModifierClickLaneSuspension {
    private var held = false
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        self.held = true
        let continuations = self.heldContinuations
        self.heldContinuations.removeAll()
        continuations.forEach { $0.resume() }
        await withCheckedContinuation { self.releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        guard !self.held else { return }
        await withCheckedContinuation { self.heldContinuations.append($0) }
    }

    func release() {
        self.releaseContinuation?.resume()
        self.releaseContinuation = nil
    }
}
