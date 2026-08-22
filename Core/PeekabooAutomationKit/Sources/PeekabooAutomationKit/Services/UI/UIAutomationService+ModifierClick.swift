import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
enum ModifierClickDispatchBarrier {
    static func waitForMouseUps(
        baseline: UInt32,
        expectedIncrement: UInt32,
        deadline: ContinuousClock.Instant,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        counter: () -> UInt32,
        runLoopStep: () -> Void) throws
    {
        while now() < deadline {
            if counter() &- baseline >= expectedIncrement {
                return
            }
            runLoopStep()
        }
        if counter() &- baseline >= expectedIncrement {
            return
        }
        throw ModifierClickDispatchBarrierFailure(failure: .indeterminate(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Modifier-click mouse-up delivery did not reach the session before cleanup.",
            hint: "Inspect the shared desktop state before taking another input action."))
    }
}

extension UIAutomationService {
    public func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        let focusService = FocusManagementService(operationLaneCoordinator: self.operationLaneCoordinator)
        let executor = ForegroundModifierClickExecutor(
            laneCoordinator: self.operationLaneCoordinator,
            dependencies: .init(
                focusExactWindow: { target, dispatchGuard in
                    var sequence = DesktopActionSequenceAccumulator()
                    do {
                        try await focusService.focusWindowWithOwnedLane(
                            windowID: CGWindowID(target.identity.windowID),
                            options: .init(timeout: 2, retryCount: 2, switchSpace: false),
                            expectedIdentity: target.identity,
                            dispatchGuard: dispatchGuard,
                            onDispatch: { sequence.record($0.sequenceStep) })
                    } catch ForegroundModifierClickError.focusTargetSatisfied {
                        return FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
                    } catch let ownershipLoss as ModifierClickFocusOwnershipLossFailure {
                        guard sequence.mutationDisposition.mutationDispatched else { throw ownershipLoss }
                        throw ModifierClickFocusOwnershipLossFailure(failure: sequence.failure(
                            combining: ownershipLoss.failure,
                            message: "Modifier-click target focus lost foreground ownership after dispatch.",
                            hint: "Inspect the shared desktop before taking another input action."))
                    } catch {
                        throw Self.modifierClickFocusFailure(error, sequence: sequence)
                    }
                    return FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
                },
                currentFrontmostIdentity: Self.currentFrontmostProcessIdentity,
                currentFocusedExactWindow: Self.currentFocusedExactWindow,
                activate: Self.activateAndVerify,
                currentCursorLocation: { self.syntheticInputDriver.currentLocation() },
                moveCursor: { try self.syntheticInputDriver.move(to: $0) },
                click: Self.postModifierClick,
                validateExactWindow: self.exactWindowIdentityValidator,
                exactWindowRouteAtPoint: {
                    BackgroundInputDriver.exactOnScreenWindowRoute(at: $0, windowID: $1)
                },
                pointerReceiverAtPoint: { BackgroundInputDriver.accessibilityPointerReceiver(at: $0) },
                restoreExactWindow: { target, dispatchGuard in
                    var sequence = DesktopActionSequenceAccumulator()
                    do {
                        try await focusService.focusWindowWithOwnedLane(
                            windowID: CGWindowID(target.identity.windowID),
                            options: .init(timeout: 2, retryCount: 2, switchSpace: false),
                            expectedIdentity: target.identity,
                            dispatchGuard: dispatchGuard,
                            onDispatch: { sequence.record($0.sequenceStep) })
                    } catch ForegroundModifierClickError.focusRestorationSatisfied {
                        guard sequence.mutationDisposition.mutationDispatched else {
                            throw ForegroundModifierClickError.focusRestorationBecameUnnecessary
                        }
                        return FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
                    } catch ForegroundModifierClickError.focusRestorationOwnershipLost {
                        let resolution = sequence.successResolution()
                        let partialOutcome = resolution.outcome ?? resolution.mutationDisposition.unitCount.map {
                            DesktopActionOutcome.indeterminate(
                                route: .local,
                                evidence: .completionUnknown,
                                unitCount: $0)
                        }
                        throw FocusRestorationOwnershipLoss(partialOutcome: partialOutcome)
                    } catch {
                        guard sequence.mutationDisposition.mutationDispatched else { throw error }
                        let leaf = error as? DesktopActionFailure ?? .preDispatchRefusal(
                            reason: .targetUnavailable,
                            message: error.localizedDescription)
                        throw sequence.failure(
                            combining: leaf,
                            message: "Exact-window restoration stopped after a foreground dispatch.",
                            hint: "Inspect the shared desktop before taking another input action.")
                    }
                    return FocusDispatchAccounting.verifiedFocusOutcome(sequence.successResolution())
                },
                sharedInputActivityToken: { self.syntheticInputDriver.sharedInputActivityToken() },
                restoreCursor: { original, lastWritten, activityToken in
                    try self.syntheticInputDriver.restoreCursorIfOwned(
                        original: original,
                        lastWritten: lastWritten,
                        activityToken: activityToken)
                },
                prepareClick: Self.prepareModifierClick))
        return try await executor.execute(request)
    }

    static func modifierClickFocusFailure(
        _ error: any Error,
        sequence: DesktopActionSequenceAccumulator) -> any Error
    {
        if error is CancellationError {
            if let failure = sequence.cancellationFailure(
                fallbackRoute: .local,
                message: "Exact-window focus was cancelled after foreground dispatch began.",
                hint: "Inspect the shared desktop before taking another input action.",
                causeDescription: "Modifier-click focus task cancelled")
            {
                return failure
            }
            return DesktopActionFailure.preDispatchRefusal(
                reason: .requestCancelled,
                message: "Modifier-click was cancelled before exact-window focus dispatch.")
        }
        if let peekabooError = error as? PeekabooError,
           case .permissionDeniedAccessibility = peekabooError,
           sequence.mutationDisposition == .none
        {
            return DesktopActionFailure.preDispatchRefusal(
                reason: .permissionDenied,
                message: "Modifier-click cannot focus its exact window without Accessibility permission.",
                hint: "Grant Accessibility permission before retrying.",
                causeDescription: peekabooError.localizedDescription)
        }
        guard sequence.mutationDisposition.mutationDispatched else { return error }
        let leaf = error as? DesktopActionFailure ?? .preDispatchRefusal(
            reason: .targetUnavailable,
            message: error.localizedDescription)
        return sequence.failure(
            combining: leaf,
            message: "Exact-window focus stopped after a partial foreground dispatch.",
            hint: "Inspect the shared desktop before taking another input action.")
    }

    private static func currentFrontmostProcessIdentity() -> ApplicationProcessIdentity? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let generation = SystemIdentityResolver.processStartIdentity(application.processIdentifier)
        else { return nil }
        return ApplicationProcessIdentity(
            processIdentifier: application.processIdentifier,
            processStartIdentity: generation)
    }

    private static func currentFocusedExactWindow() -> UIAutomationTarget.ExactWindow? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let processStartIdentity = SystemIdentityResolver.processStartIdentity(application.processIdentifier),
              let windowID = WindowIdentityService().focusedWindowID(for: application, timeout: 0.5),
              let identity = SystemIdentityResolver.windowMutationIdentity(windowID: windowID),
              identity.ownerProcessIdentifier == application.processIdentifier,
              identity.ownerProcessStartIdentity == processStartIdentity,
              let bounds = identity.capturedBounds
        else {
            return nil
        }
        return try? UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
    }

    private static func activateAndVerify(
        _ identity: ApplicationProcessIdentity,
        dispatchGuard: FocusDispatchGuard) async throws -> Bool
    {
        guard SystemIdentityResolver.processStartIdentity(identity.processIdentifier) == identity.processStartIdentity,
              let application = NSRunningApplication(processIdentifier: identity.processIdentifier)
        else { return false }
        try dispatchGuard.validate(.applicationActivation)
        guard application.activate() else { return false }
        try dispatchGuard.didAcceptDispatch(.applicationActivation)
        for _ in 0..<20 {
            if self.currentFrontmostProcessIdentity() == identity {
                try dispatchGuard.didCompleteDispatch(.applicationActivation)
                return true
            }
            try dispatchGuard.validate(.applicationActivation)
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }

    private static func postModifierClick(
        point: CGPoint,
        clickType: ClickType,
        modifiers: [PointerModifier]) throws -> DesktopActionOutcome
    {
        try self.prepareModifierClick(
            point: point,
            clickType: clickType,
            modifiers: modifiers)()
    }

    private static func prepareModifierClick(
        point: CGPoint,
        clickType: ClickType,
        modifiers: [PointerModifier]) throws -> ForegroundModifierClickExecutor.PreparedClickExecutor
    {
        guard CGPreflightPostEventAccess() else {
            throw PeekabooError.permissionDeniedEventSynthesizing
        }
        guard let source = CGEventSource(stateID: .privateState) else {
            throw PeekabooError.serviceUnavailable(
                "Modifier-click could not create its private event source")
        }
        let marker = Int64.random(in: 1...Int64.max)
        let events = try self.makeModifierClickEvents(
            point: point,
            clickType: clickType,
            modifiers: modifiers,
            source: source,
            eventSourceUserData: marker)
        let descriptor = self.mouseEventDescriptor(for: clickType)
        let sourceStateID = source.sourceStateID
        // CoreGraphics replaces the `.privateState` creation sentinel with a unique state-table ID.
        // The event counter below is therefore scoped to this source rather than the shared session.
        guard sourceStateID != .privateState else {
            throw PeekabooError.serviceUnavailable(
                "Modifier-click could not establish a private event state table")
        }
        // This source owns a unique state table retained by the prepared closure. AppKit/AX focus and
        // physical HID input advance other tables, so only these retained events can change this baseline.
        let baseline = CGEventSource.counterForEventType(sourceStateID, eventType: descriptor.up)
        return {
            try withExtendedLifetime(source) {
                events.forEach { $0.post(tap: .cghidEventTap) }
                try ModifierClickDispatchBarrier.waitForMouseUps(
                    baseline: baseline,
                    expectedIncrement: UInt32(descriptor.count),
                    deadline: ContinuousClock.now.advanced(by: .milliseconds(500)),
                    counter: { CGEventSource.counterForEventType(sourceStateID, eventType: descriptor.up) },
                    runLoopStep: { CFRunLoopRunInMode(.defaultMode, 0.005, true) })
            }
            return .dispatchedUnverified(
                delivery: .init(mechanism: .globalEvents, mode: .foreground),
                evidence: .deliveryAccepted,
                unitCount: .one)
        }
    }

    static func makeModifierClickEvents(
        point: CGPoint,
        clickType: ClickType,
        modifiers: [PointerModifier],
        source: CGEventSource?,
        eventSourceUserData: Int64? = nil) throws -> [CGEvent]
    {
        let descriptor = self.mouseEventDescriptor(for: clickType)
        let flags = self.flags(for: modifiers)
        var events: [CGEvent] = []
        events.reserveCapacity(descriptor.count * 2)
        for clickState in 1...descriptor.count {
            guard let down = CGEvent(
                mouseEventSource: source,
                mouseType: descriptor.down,
                mouseCursorPosition: point,
                mouseButton: descriptor.button),
                let up = CGEvent(
                    mouseEventSource: source,
                    mouseType: descriptor.up,
                    mouseCursorPosition: point,
                    mouseButton: descriptor.button)
            else {
                throw PeekabooError.invalidInput("Could not create modifier-click mouse events")
            }
            for event in [down, up] {
                event.flags = flags
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                if let eventSourceUserData {
                    event.setIntegerValueField(.eventSourceUserData, value: eventSourceUserData)
                }
                events.append(event)
            }
        }
        return events
    }

    private static func flags(for modifiers: [PointerModifier]) -> CGEventFlags {
        modifiers.reduce(into: CGEventFlags()) { $0.insert(self.flag(for: $1)) }
    }

    private static func flag(for modifier: PointerModifier) -> CGEventFlags {
        switch modifier {
        case .command: .maskCommand
        case .shift: .maskShift
        case .option: .maskAlternate
        case .control: .maskControl
        }
    }

    private static func mouseEventDescriptor(for clickType: ClickType) -> (
        button: CGMouseButton,
        down: CGEventType,
        up: CGEventType,
        count: Int)
    {
        switch clickType {
        case .right:
            (.right, .rightMouseDown, .rightMouseUp, 1)
        case .middle:
            (.center, .otherMouseDown, .otherMouseUp, 1)
        case .double:
            (.left, .leftMouseDown, .leftMouseUp, 2)
        case .triple:
            (.left, .leftMouseDown, .leftMouseUp, 3)
        case .single, .longPress:
            (.left, .leftMouseDown, .leftMouseUp, 1)
        }
    }
}
