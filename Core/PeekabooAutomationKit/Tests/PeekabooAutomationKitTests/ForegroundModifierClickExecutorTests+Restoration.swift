import CoreGraphics
import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit

extension ForegroundModifierClickExecutorTests {
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
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        var cursorReads = 0
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
                CursorRestorationOwnership.Receipt(
                    original: original,
                    lastWritten: lastWritten,
                    activityToken: expected),
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
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
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
                click: { location, clickType, modifiers in
                    cursor = location
                    activity = interruption.activity(
                        after: activity.afterModifierClick(clickType, modifiers: modifiers))
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
    func `uncertain click barrier skips cursor and focus cleanup`() async throws {
        let prior = ApplicationProcessIdentity(processIdentifier: 11, processStartIdentity: 110)
        let target = ApplicationProcessIdentity(processIdentifier: 22, processStartIdentity: 220)
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        let point = CGPoint(x: 20, y: 20)
        var frontmost = prior
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
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
                    frontmost = window.identity.processIdentity
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
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
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
                    frontmost = window.identity.processIdentity
                    focusedWindow = window
                    if window.identity.processIdentity == prior {
                        focusRestoreAttempted = true
                    }
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
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        var cursor: CGPoint? = CGPoint(x: 20, y: 30)
        var focusRestoreAttempted = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { window, beforeDispatch in
                    try beforeDispatch()
                    frontmost = window.identity.processIdentity
                    focusedWindow = window
                    if window.identity.processIdentity == prior {
                        focusRestoreAttempted = true
                    }
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
        var focusedWindow: UIAutomationTarget.ExactWindow? = try Self.priorWindow(process: prior)
        var cursor = originalCursor
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
}
