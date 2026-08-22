import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
enum ModifierClickDispatchBarrier {
    struct Counters: Equatable {
        let mouseUp: UInt32
        let modifierTransitions: UInt32
    }

    static func waitForCompletion(
        baseline: Counters,
        expectedIncrement: Counters,
        deadline: ContinuousClock.Instant,
        now: () -> ContinuousClock.Instant = { ContinuousClock.now },
        counters: () -> Counters,
        runLoopStep: () -> Void) throws
    {
        while now() < deadline {
            if self.isComplete(
                counters(),
                baseline: baseline,
                expectedIncrement: expectedIncrement)
            {
                return
            }
            runLoopStep()
        }
        if self.isComplete(
            counters(),
            baseline: baseline,
            expectedIncrement: expectedIncrement)
        {
            return
        }
        throw ModifierClickDispatchBarrierFailure(failure: .indeterminate(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Modifier-click mouse-up or modifier key-up delivery did not reach the session.",
            hint: "Inspect the shared desktop state before taking another input action."))
    }

    private static func isComplete(
        _ current: Counters,
        baseline: Counters,
        expectedIncrement: Counters) -> Bool
    {
        current.mouseUp &- baseline.mouseUp >= expectedIncrement.mouseUp &&
            current.modifierTransitions &- baseline.modifierTransitions >= expectedIncrement.modifierTransitions
    }
}

extension UIAutomationService {
    public func foregroundModifierClickWithOutcome(
        _ request: ForegroundModifierClickRequest) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        try await self.withModifierClickSnapshotLease(request) {
            try await self.executeForegroundModifierClickWithOutcome(request)
        }
    }

    func withModifierClickSnapshotLease(
        _ request: ForegroundModifierClickRequest,
        operation: @MainActor () async throws -> UIAutomationActionResult<ForegroundModifierClickResult>) async throws
        -> UIAutomationActionResult<ForegroundModifierClickResult>
    {
        let exactWindow = try UIAutomationTarget.ExactWindow(
            identity: request.windowIdentity,
            bounds: request.windowBounds)
        let targetIdentity = DesktopTargetIdentity(exactWindow: exactWindow)
        let snapshotID = request.snapshotID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !snapshotID.isEmpty, snapshotID == request.snapshotID else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .invalidRequest,
                message: "Modifier-click requires one explicit screenshot snapshot identifier.")
                .attributed(to: targetIdentity.actionTargetReceipt)
        }

        let lease: SnapshotMutationLease
        do {
            lease = try await self.snapshotManager.beginSnapshotMutation(snapshotId: snapshotID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click could not lease its screenshot snapshot.",
                hint: "Observe the exact target again before retrying.",
                causeDescription: error.localizedDescription)
                .attributed(to: targetIdentity.actionTargetReceipt)
        }

        do {
            let authority = try await SnapshotTargetReceiptPlanner(
                snapshots: self.snapshotManager).plan(snapshotID: snapshotID).receipt.requireCoordinateAuthority()
            guard authority.target == exactWindow,
                  authority.sourceBounds.contains(request.point),
                  authority.target.bounds.contains(request.point)
            else {
                throw DesktopTargetIdentityError.coordinateWindowMismatch
            }
        } catch let cancellation as CancellationError {
            try await self.requireModifierClickLeaseFinalization(
                lease,
                requiresFreshObservation: false,
                targetIdentity: targetIdentity,
                priorError: cancellation)
            throw cancellation
        } catch {
            try await self.requireModifierClickLeaseFinalization(
                lease,
                requiresFreshObservation: false,
                targetIdentity: targetIdentity,
                priorError: error)
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "Modifier-click snapshot does not authorize its exact window and point.",
                hint: "Observe the exact target again before retrying.",
                causeDescription: error.localizedDescription)
                .attributed(to: targetIdentity.actionTargetReceipt)
        }

        let result: UIAutomationActionResult<ForegroundModifierClickResult>
        do {
            result = try await operation()
        } catch let failure as DesktopActionFailure {
            try await self.requireModifierClickLeaseFinalization(
                lease,
                requiresFreshObservation: failure.outcome.projection.requiresFreshObservation,
                targetIdentity: targetIdentity,
                outcome: failure.outcome,
                priorError: failure)
            throw failure
        } catch {
            try await self.requireModifierClickLeaseFinalization(
                lease,
                requiresFreshObservation: true,
                targetIdentity: targetIdentity,
                priorError: error)
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .composite, mode: .foreground),
                evidence: .completionUnknown,
                message: "Modifier-click failed without a canonical action outcome.",
                hint: "Observe the exact target before any retry and do not reuse this snapshot.",
                causeDescription: error.localizedDescription)
                .attributed(to: targetIdentity.actionTargetReceipt)
        }

        try await self.requireModifierClickLeaseFinalization(
            lease,
            requiresFreshObservation: result.outcome?.projection.requiresFreshObservation ?? true,
            targetIdentity: targetIdentity,
            outcome: result.outcome)
        return result
    }

    private func requireModifierClickLeaseFinalization(
        _ lease: SnapshotMutationLease,
        requiresFreshObservation: Bool,
        targetIdentity: DesktopTargetIdentity,
        outcome: DesktopActionOutcome? = nil,
        priorError: (any Error)? = nil) async throws
    {
        do {
            try await self.snapshotManager.finishSnapshotMutation(
                lease,
                requiresFreshObservation: requiresFreshObservation)
        } catch {
            let causeDescription = [priorError?.localizedDescription, error.localizedDescription]
                .compactMap(\.self)
                .joined(separator: "; lease finalization: ")
            throw DesktopActionFailure.indeterminate(
                route: outcome?.route ?? .local,
                delivery: outcome?.delivery,
                evidence: .completionUnknown,
                unitCount: outcome?.dispatchState.unitCount,
                message: "Modifier-click ended, but its snapshot mutation lease could not be finalized.",
                hint: "Observe the target before any retry and do not reuse this snapshot.",
                causeDescription: causeDescription)
                .attributed(to: targetIdentity.actionTargetReceipt)
        }
    }

    private func executeForegroundModifierClickWithOutcome(
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
        let activationSettled = try await FocusAcceptedActivationSettlement.wait(
            dispatchGuard: dispatchGuard,
            pollCount: 20,
            interval: .milliseconds(25),
            isSettled: { self.currentFrontmostProcessIdentity() == identity })
        guard activationSettled else {
            return false
        }
        try dispatchGuard.didCompleteDispatch(.applicationActivation)
        return true
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
        let baseline = ModifierClickDispatchBarrier.Counters(
            mouseUp: CGEventSource.counterForEventType(sourceStateID, eventType: descriptor.up),
            modifierTransitions: CGEventSource.counterForEventType(
                sourceStateID,
                eventType: .flagsChanged))
        return {
            try withExtendedLifetime(source) {
                events.forEach { $0.post(tap: .cghidEventTap) }
                try ModifierClickDispatchBarrier.waitForCompletion(
                    baseline: baseline,
                    // Modifier virtual-key down/up events are `.flagsChanged` in CoreGraphics.
                    expectedIncrement: .init(
                        mouseUp: UInt32(descriptor.count),
                        modifierTransitions: UInt32(modifiers.count * 2)),
                    deadline: ContinuousClock.now.advanced(by: .milliseconds(500)),
                    counters: {
                        .init(
                            mouseUp: CGEventSource.counterForEventType(sourceStateID, eventType: descriptor.up),
                            modifierTransitions: CGEventSource.counterForEventType(
                                sourceStateID,
                                eventType: .flagsChanged))
                    },
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
        let modifierKeys = try modifiers.map { try self.modifierKeyDescriptor(for: $0) }
        var events: [CGEvent] = []
        events.reserveCapacity(descriptor.count * 2 + modifierKeys.count * 2)
        var cumulativeFlags = CGEventFlags()
        for modifierKey in modifierKeys {
            guard let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifierKey.keyCode,
                keyDown: true)
            else {
                throw PeekabooError.invalidInput("Could not create modifier key-down event")
            }
            cumulativeFlags.insert(modifierKey.flag)
            keyDown.flags = cumulativeFlags
            if let eventSourceUserData {
                keyDown.setIntegerValueField(.eventSourceUserData, value: eventSourceUserData)
            }
            events.append(keyDown)
        }
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
                event.flags = cumulativeFlags
                event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                if let eventSourceUserData {
                    event.setIntegerValueField(.eventSourceUserData, value: eventSourceUserData)
                }
                events.append(event)
            }
        }
        for modifierKey in modifierKeys.reversed() {
            guard let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: modifierKey.keyCode,
                keyDown: false)
            else {
                throw PeekabooError.invalidInput("Could not create modifier key-up event")
            }
            cumulativeFlags.remove(modifierKey.flag)
            keyUp.flags = cumulativeFlags
            if let eventSourceUserData {
                keyUp.setIntegerValueField(.eventSourceUserData, value: eventSourceUserData)
            }
            events.append(keyUp)
        }
        return events
    }

    private static func modifierKeyDescriptor(for modifier: PointerModifier) throws -> (
        keyCode: CGKeyCode,
        flag: CGEventFlags)
    {
        switch modifier {
        case .command: (0x37, .maskCommand)
        case .shift: (0x38, .maskShift)
        case .option: (0x3A, .maskAlternate)
        case .control:
            throw PeekabooError.invalidInput(
                "Modifier-click does not support Control-click restoration")
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
