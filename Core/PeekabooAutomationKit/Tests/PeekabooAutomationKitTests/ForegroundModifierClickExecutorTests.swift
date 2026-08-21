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
            source: CGEventSource(stateID: .hidSystemState))

        #expect(events.map(\.type) == [.leftMouseDown, .leftMouseUp, .leftMouseDown, .leftMouseUp])
        #expect(events.map { $0.getIntegerValueField(.mouseEventClickState) } == [1, 1, 2, 2])
        #expect(events.allSatisfy { $0.flags.contains([.maskCommand, .maskShift]) })
        #expect(CGEventSource.flagsState(.combinedSessionState) == priorFlags)
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
                focusExactWindow: { window in
                    frontmost = target
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { identity in
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
                focusExactWindow: { window in
                    frontmost = target
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _ in
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

    @Test
    func `stale exact target refuses before modifier or click dispatch`() async throws {
        var dispatched = false
        let root = self.temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: DesktopOperationLaneCoordinator(coordinationRootURL: root),
            dependencies: .init(
                focusExactWindow: { _ in
                    dispatched = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { nil },
                currentFocusedExactWindow: { nil },
                activate: { _ in false },
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
                focusExactWindow: { _ in
                    dispatched = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { nil },
                currentFocusedExactWindow: { nil },
                activate: { _ in
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
                focusExactWindow: { _ in
                    dispatched = true
                    return .confirmedNoChange()
                },
                currentFrontmostIdentity: { prior },
                currentFocusedExactWindow: { nil },
                activate: { _ in
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
                focusExactWindow: { window in
                    frontmost = target
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { identity in
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
                focusExactWindow: { window in
                    frontmost = target
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { identity in
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
                focusExactWindow: { window in
                    focusCalls.append(window.identity.windowID)
                    focusedWindow = window
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { process },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _ in
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
                validateExactWindow: { _, _ in true }))

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
                focusExactWindow: { window in
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
                activate: { _ in false },
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
                focusExactWindow: { window in
                    if window == priorWindow {
                        throw DesktopActionFailure.indeterminate(
                            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                            evidence: .completionUnknown,
                            unitCount: restorationUnits,
                            message: "focus restoration response was lost")
                    }
                    frontmost = targetProcess
                    focusedWindow = targetWindow
                    return .confirmedChange(
                        delivery: .init(mechanism: .nativeFramework, mode: .foreground),
                        unitCount: .one)
                },
                currentFrontmostIdentity: { frontmost },
                currentFocusedExactWindow: { focusedWindow },
                activate: { _ in false },
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
                focusExactWindow: { window in
                    if window == priorWindow {
                        throw ModifierClickTestError.focusRestoreFailed
                    }
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
                activate: { _ in false },
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
