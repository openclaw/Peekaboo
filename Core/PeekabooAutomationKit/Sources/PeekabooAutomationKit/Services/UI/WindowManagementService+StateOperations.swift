import AppKit
@preconcurrency import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension WindowManagementService {
    public func closeWindow(target: WindowTarget) async throws {
        try await self.closeWindow(target: target, allowForegroundFallback: false)
    }

    public func closeWindow(target: WindowTarget, allowForegroundFallback: Bool) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.closeWindow(
            target: pinned.target,
            expectedIdentity: pinned.identity,
            allowForegroundFallback: allowForegroundFallback)
    }

    public func closeWindow(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws
    {
        _ = try await self.closeWindowActionResult(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: allowForegroundFallback)
    }

    public func closeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.closeWindowResult(
            target: target,
            expectedIdentity: expectedIdentity,
            allowForegroundFallback: false).outcome
    }

    public func closeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity,
        allowForegroundFallback: Bool) async throws -> DesktopActionResult<Void>
    {
        if allowForegroundFallback {
            return try await self.closeWindowWithForegroundFallbackResult(
                target: target,
                expectedIdentity: expectedIdentity)
        }
        let outcome = try await WindowManagementActionOutcome.perform(action: "close window") {
            try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                let trackedWindowID = expectedIdentity.windowID
                try Task.checkCancellation()
                let windowServerInfo = self.windowIdentityService
                    .getWindowServerInfo(windowID: CGWindowID(trackedWindowID))
                guard hasSufficientMetadataForPinnedClose(
                    hasWindowServerMetadata: windowServerInfo != nil,
                    expectedMinimized: expectedIdentity.isMinimized == true)
                else {
                    throw PeekabooError.windowNotFound(criteria: "windowId \(trackedWindowID)")
                }
                if minimizedCloseRequiresForegroundFallback(isMinimized: expectedIdentity.isMinimized == true) {
                    throw DesktopActionFailure.refused(
                        reason: .foregroundConsentRequired,
                        message: "A minimized window cannot be closed with a verified background-only route",
                        hint: "Restore the same exact window first, or retry with explicit foreground consent.")
                }

                let attempt = try await self.attemptPinnedBackgroundClose(expectedIdentity)
                guard attempt.dispatched else {
                    throw OperationError.interactionFailed(
                        action: "close window",
                        reason: "Window close operation failed")
                }
                guard attempt.disappeared else {
                    throw WindowManagementActionOutcome.suspectedNoop(
                        action: "close window",
                        delivery: WindowManagementActionOutcome.backgroundActionDelivery,
                        dispatchCount: attempt.dispatchCount)
                }
                return WindowManagementActionOutcome.confirmedChange(
                    delivery: WindowManagementActionOutcome.backgroundActionDelivery,
                    dispatchCount: attempt.dispatchCount)
            }
        }
        return DesktopActionResult(outcome: outcome)
    }

    public func minimizeWindow(target: WindowTarget) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.minimizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func minimizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.minimizeWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func minimizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.minimizeWindowResult(target: target, expectedIdentity: expectedIdentity).outcome
    }

    public func minimizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await WindowManagementActionOutcome.perform(action: "minimize window") {
            try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                let window = try await self.element(for: target)
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)
                if window.isMinimized() == true {
                    return WindowManagementActionOutcome.confirmedNoChange
                }
                guard window.setMinimized(true) == .success else {
                    throw OperationError.interactionFailed(
                        action: "minimize window",
                        reason: "Window minimize operation failed")
                }
                do {
                    guard try await self.waitForPinnedWindowMinimized(
                        window,
                        expectedIdentity: expectedIdentity)
                    else {
                        throw WindowManagementActionOutcome.suspectedNoop(
                            action: "minimize window",
                            delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                            dispatchCount: 1)
                    }
                } catch let failure as DesktopActionFailure {
                    throw failure
                } catch {
                    throw WindowManagementActionOutcome.dispatchedUnverified(
                        action: "minimize window",
                        delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                        dispatchCount: 1,
                        cause: error)
                }
                return WindowManagementActionOutcome.confirmedChange(
                    delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                    dispatchCount: 1)
            }
        }
        return DesktopActionResult(outcome: outcome)
    }

    public func restoreWindow(target: WindowTarget) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.restoreWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.restoreWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func restoreWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.restoreWindowResult(target: target, expectedIdentity: expectedIdentity).outcome
    }

    public func restoreWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await WindowManagementActionOutcome.perform(action: "restore window") {
            try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                if expectedIdentity.isMinimized == true {
                    var dispatchAccepted = false
                    do {
                        _ = try await completePinnedMinimizedWindowRestore(
                            expectedIdentity: expectedIdentity,
                            dispatch: {
                                dispatchAccepted = await BoundedBackgroundWindowAX.dispatchMinimizedRestore(
                                    expectedIdentity: expectedIdentity)
                                return dispatchAccepted
                            },
                            repin: { identity, expectedBounds in
                                try await self.waitForRepinnedWindowMutation(
                                    identity,
                                    expectedBounds: expectedBounds)
                            })
                    } catch let failure as DesktopActionFailure {
                        throw failure
                    } catch {
                        guard dispatchAccepted else { throw error }
                        throw WindowManagementActionOutcome.dispatchedUnverified(
                            action: "restore window",
                            delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                            dispatchCount: 1,
                            cause: error)
                    }
                    return WindowManagementActionOutcome.confirmedChange(
                        delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                        dispatchCount: 1)
                }
                let window = try await self.element(for: target)
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)

                if window.isMinimized() == false {
                    guard SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity) else {
                        throw PeekabooError.commandFailed(
                            "Window \(expectedIdentity.windowID) changed identity before restore completion")
                    }
                    return WindowManagementActionOutcome.confirmedNoChange
                }

                guard window.unminimizeWindow() else {
                    throw OperationError.interactionFailed(
                        action: "restore window",
                        reason: "Window restore operation failed")
                }
                do {
                    guard try await self.waitForPinnedWindowRestored(window, expectedIdentity: expectedIdentity) else {
                        throw WindowManagementActionOutcome.suspectedNoop(
                            action: "restore window",
                            delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                            dispatchCount: 1)
                    }
                } catch let failure as DesktopActionFailure {
                    throw failure
                } catch {
                    throw WindowManagementActionOutcome.dispatchedUnverified(
                        action: "restore window",
                        delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                        dispatchCount: 1,
                        cause: error)
                }
                return WindowManagementActionOutcome.confirmedChange(
                    delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                    dispatchCount: 1)
            }
        }
        return DesktopActionResult(outcome: outcome)
    }

    func restorePinnedMinimizedWindow(
        _ expectedIdentity: WindowMutationIdentity,
        onDispatchAccepted: (() -> Void)? = nil) async throws -> WindowMutationIdentity
    {
        try await completePinnedMinimizedWindowRestore(
            expectedIdentity: expectedIdentity,
            dispatch: {
                let accepted = await BoundedBackgroundWindowAX.dispatchMinimizedRestore(
                    expectedIdentity: expectedIdentity)
                if accepted {
                    onDispatchAccepted?()
                }
                return accepted
            },
            repin: { identity, expectedBounds in
                try await self.waitForRepinnedWindowMutation(identity, expectedBounds: expectedBounds)
            })
    }

    public func maximizeWindow(target: WindowTarget) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.maximizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        _ = try await self.maximizeWindowResult(target: target, expectedIdentity: expectedIdentity)
    }

    public func maximizeWindowWithOutcome(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionOutcome?
    {
        try await self.maximizeWindowResult(target: target, expectedIdentity: expectedIdentity).outcome
    }

    public func maximizeWindowActionResult(
        target: WindowTarget,
        expectedIdentity: WindowMutationIdentity) async throws -> DesktopActionResult<Void>
    {
        let outcome = try await WindowManagementActionOutcome.perform(action: "maximize window") {
            try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                guard let windowInfo = try await self.listWindows(target: target).first else {
                    throw PeekabooError.windowNotFound(
                        criteria: "No exact window identity was available for maximize")
                }
                try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
                let desiredBounds = try self.maximizedBounds(for: windowInfo.bounds)

                if WindowMutationGeometryPostcondition.boundsMatch(
                    windowInfo.bounds,
                    desiredBounds)
                {
                    return WindowManagementActionOutcome.confirmedNoChange
                }

                guard self.windowIdentityService
                    .getWindowServerInfo(windowID: CGWindowID(windowInfo.windowID)) != nil
                else {
                    throw PeekabooError.windowNotFound(criteria: "windowId \(windowInfo.windowID)")
                }
                let dispatch = await BoundedBackgroundWindowAX.setBounds(
                    expectedIdentity: expectedIdentity,
                    bounds: desiredBounds)
                guard dispatch.dispatchCount > 0 else {
                    throw OperationError.interactionFailed(
                        action: "maximize window",
                        reason: "The bounded background geometry request failed before dispatch")
                }
                guard dispatch.identityRemainedPinned else {
                    throw WindowManagementActionOutcome.dispatchedUnverified(
                        action: "maximize window",
                        delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                        dispatchCount: dispatch.dispatchCount,
                        cause: PeekabooError.commandFailed(
                            "Window identity changed during bounded background geometry dispatch"))
                }

                do {
                    guard try await self.waitForWindowBounds(
                        windowID: windowInfo.windowID,
                        expectedIdentity: expectedIdentity,
                        expected: desiredBounds,
                        timeoutSeconds: 2)
                    else {
                        let achieved = self.windowIdentityService
                            .getWindowServerInfo(windowID: CGWindowID(windowInfo.windowID))?.bounds
                        let cause = OperationError.interactionFailed(
                            action: "maximize window",
                            reason: "The window did not reach the target screen's visible bounds within 2 seconds " +
                                "(requested: \(desiredBounds), achieved: \(String(describing: achieved)))")
                        if WindowMutationGeometryPostcondition.boundsMatch(
                            windowInfo.bounds,
                            achieved ?? .null)
                        {
                            throw WindowManagementActionOutcome.suspectedNoop(
                                action: "maximize window",
                                delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                                dispatchCount: dispatch.dispatchCount,
                                cause: cause)
                        }
                        throw WindowManagementActionOutcome.dispatchedUnverified(
                            action: "maximize window",
                            delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                            dispatchCount: dispatch.dispatchCount,
                            cause: cause)
                    }
                } catch let failure as DesktopActionFailure {
                    throw failure
                } catch {
                    throw WindowManagementActionOutcome.dispatchedUnverified(
                        action: "maximize window",
                        delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                        dispatchCount: dispatch.dispatchCount,
                        cause: error)
                }
                return WindowManagementActionOutcome.confirmedChange(
                    delivery: WindowManagementActionOutcome.backgroundValueDelivery,
                    dispatchCount: dispatch.dispatchCount)
            }
        }
        return DesktopActionResult(outcome: outcome)
    }

    private func maximizedBounds(for windowBounds: CGRect) throws -> CGRect {
        guard let target = WindowMutationGeometryPostcondition.currentMaximizedVisibleWorkArea(
            for: windowBounds)
        else {
            throw PeekabooError.commandFailed("No display is available for window maximize")
        }
        return target
    }

    private func waitForWindowBounds(
        windowID: Int,
        expectedIdentity: WindowMutationIdentity,
        expected: CGRect,
        timeoutSeconds: TimeInterval) async throws -> Bool
    {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while clock.now < deadline {
            try Task.checkCancellation()
            if let info = self.windowIdentityService
                .getWindowServerInfo(windowID: CGWindowID(windowID)),
                info.ownerPID == expectedIdentity.ownerProcessIdentifier,
                SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
                WindowMutationGeometryPostcondition.boundsMatch(
                    info.bounds,
                    expected),
                SystemIdentityResolver.repinWindowMutationIdentity(
                    expectedIdentity,
                    expectedBounds: expected) != nil
            {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func attemptPinnedBackgroundClose(
        _ expectedIdentity: WindowMutationIdentity) async throws -> PinnedWindowCloseAttemptResult
    {
        let primaryDispatched = await BoundedBackgroundWindowAX.dispatchClose(
            expectedIdentity: expectedIdentity,
            action: .windowClose)
        if primaryDispatched {
            do {
                switch try await pinnedWindowCloseAttemptDisposition(
                    for: self.verifyPinnedWindowClose(expectedIdentity))
                {
                case .disappeared:
                    return PinnedWindowCloseAttemptResult(dispatchCount: 1, disappeared: true)
                case .remained:
                    break
                case .unverifiable:
                    throw PeekabooError.commandFailed(
                        "The exact window close result could not be verified")
                }
            } catch {
                throw WindowManagementActionOutcome.dispatchedUnverified(
                    action: "close window",
                    delivery: WindowManagementActionOutcome.backgroundActionDelivery,
                    dispatchCount: 1,
                    cause: error)
            }
        }

        try Task.checkCancellation()
        let fallbackDispatched = await BoundedBackgroundWindowAX.dispatchClose(
            expectedIdentity: expectedIdentity,
            action: .closeButton)
        let dispatchCount = (primaryDispatched ? 1 : 0) + (fallbackDispatched ? 1 : 0)
        guard dispatchCount > 0 else {
            return PinnedWindowCloseAttemptResult(dispatchCount: 0, disappeared: false)
        }

        do {
            let disposition = try await pinnedWindowCloseAttemptDisposition(
                for: self.verifyPinnedWindowClose(expectedIdentity))
            guard disposition != .unverifiable else {
                throw PeekabooError.commandFailed(
                    "The exact window close result could not be verified")
            }
            return PinnedWindowCloseAttemptResult(
                dispatchCount: dispatchCount,
                disappeared: disposition == .disappeared)
        } catch {
            throw WindowManagementActionOutcome.dispatchedUnverified(
                action: "close window",
                delivery: WindowManagementActionOutcome.backgroundActionDelivery,
                dispatchCount: dispatchCount,
                cause: error)
        }
    }

    private func verifyPinnedWindowClose(
        _ expectedIdentity: WindowMutationIdentity) async throws -> PinnedWindowCloseVerificationDecision
    {
        let clock = ContinuousClock()
        let startedAt = clock.now
        let deadline = startedAt.advanced(by: .seconds(4.2))
        var verification = PinnedWindowCloseVerification()
        while clock.now < deadline {
            try Task.checkCancellation()
            let windowServerIdentity = SystemIdentityResolver.windowIdentity(CGWindowID(expectedIdentity.windowID))
            let ownerGenerationMatches = windowServerIdentity.map {
                $0.ownerProcessIdentifier == expectedIdentity.ownerProcessIdentifier &&
                    SystemIdentityResolver.processStartIdentity($0.ownerProcessIdentifier) ==
                    expectedIdentity.ownerProcessStartIdentity
            } ?? true
            guard ownerGenerationMatches else {
                throw PeekabooError.commandFailed(
                    "Window \(expectedIdentity.windowID) changed owner identity during close")
            }
            let windowServerMatchesReceipt = windowServerIdentity.map { identity in
                identity.ownerProcessIdentifier == expectedIdentity.ownerProcessIdentifier &&
                    identity.bounds == expectedIdentity.capturedBounds
            }
            let axWindowPresence: PinnedMinimizedWindowAXPresence? = if windowServerMatchesReceipt != true {
                await BoundedBackgroundWindowAX.windowPresence(expectedIdentity: expectedIdentity)
            } else {
                nil
            }
            let disposition = pinnedWindowClosePresenceDisposition(
                windowServerEntryPresent: windowServerIdentity != nil,
                windowServerEntryMatchesReceipt: windowServerMatchesReceipt,
                minimizedAXPresence: axWindowPresence,
                expectedMinimized: expectedIdentity.isMinimized == true)
            if disposition == .replacement {
                throw PeekabooError.commandFailed(
                    "Window \(expectedIdentity.windowID) changed identity during close")
            }

            let decision = verification.observe(
                disposition,
                elapsed: startedAt.duration(to: clock.now))
            switch decision {
            case .pending:
                break
            case .succeeded, .retryClose:
                return decision
            case .unverifiable:
                throw PeekabooError.commandFailed(
                    "Could not verify minimized window \(expectedIdentity.windowID) after close")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return .retryClose
    }

    func pinnedWindowDisappeared(_ expectedIdentity: WindowMutationIdentity) async throws -> Bool {
        try await self.verifyPinnedWindowClose(expectedIdentity) == .succeeded
    }

    func requirePinnedForegroundCloseReadiness(
        _ expectedIdentity: WindowMutationIdentity,
        focusSucceeded: Bool) async throws
    {
        guard focusSucceeded else {
            throw OperationError.interactionFailed(
                action: "close window",
                reason: "The exact target window refused focus; no global close shortcut was sent")
        }

        let deadline = ContinuousClock.now.advanced(by: .milliseconds(750))
        var lastReadiness: PinnedForegroundCloseReadiness = .keyWindowUnavailable
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let targetProcessIdentifier = expectedIdentity.ownerProcessIdentifier
            lastReadiness = await readPinnedForegroundCloseReadiness(
                focusSucceeded: focusSucceeded,
                expectedIdentity: expectedIdentity,
                keyWindowReader: {
                    await Task.detached(priority: .userInitiated) {
                        DetachedExactWindowFocusReader.readKeyWindow(
                            processIdentifier: targetProcessIdentifier)
                    }.value
                },
                processStartIdentityReader: {
                    SystemIdentityResolver.processStartIdentity(expectedIdentity.ownerProcessIdentifier)
                },
                frontmostProcessIdentifierReader: {
                    NSWorkspace.shared.frontmostApplication?.processIdentifier
                },
                windowIdentityValidator: {
                    SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity)
                })
            switch lastReadiness {
            case .ready:
                return
            case .focusFailed, .processGenerationMismatch, .windowIdentityMismatch, .sheetPresented:
                break
            case .appNotFrontmost, .keyWindowUnavailable, .wrongKeyWindow:
                try await Task.sleep(for: .milliseconds(50))
                continue
            }
            break
        }

        throw OperationError.interactionFailed(
            action: "close window",
            reason: lastReadiness.failureReason(windowID: expectedIdentity.windowID))
    }

    private func waitForPinnedWindowMinimized(
        _ window: Element,
        expectedIdentity: WindowMutationIdentity) async throws -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let currentProcessStartIdentity = SystemIdentityResolver.processStartIdentity(
                expectedIdentity.ownerProcessIdentifier)
            let currentWindowID = self.windowIdentityService.getWindowID(from: window).map(Int.init)
            let currentBounds = window.position().flatMap { position in
                window.size().map { size in CGRect(origin: position, size: size) }
            }
            let minimized = window.isMinimized()
            let windowServerIdentityMatches = minimized == true &&
                SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity)
            guard pinnedWindowMinimizeIdentityMatches(
                expectedIdentity: expectedIdentity,
                currentProcessStartIdentity: currentProcessStartIdentity,
                currentWindowID: currentWindowID,
                currentBounds: currentBounds,
                windowServerIdentityMatches: windowServerIdentityMatches)
            else {
                throw PeekabooError.commandFailed(
                    "Window \(expectedIdentity.windowID) changed owner/process generation during minimize")
            }
            if minimized == true {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func waitForPinnedWindowRestored(
        _ window: Element,
        expectedIdentity: WindowMutationIdentity) async throws -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let currentProcessStartIdentity = SystemIdentityResolver.processStartIdentity(
                expectedIdentity.ownerProcessIdentifier)
            let currentWindowID = self.windowIdentityService.getWindowID(from: window).map(Int.init)
            let currentBounds = window.position().map { position in
                CGRect(origin: position, size: window.size() ?? .zero)
            }
            guard pinnedWindowRestoreIdentityMatches(
                expectedIdentity: expectedIdentity,
                currentProcessStartIdentity: currentProcessStartIdentity,
                currentWindowID: currentWindowID,
                currentBounds: currentBounds)
            else {
                throw PeekabooError.commandFailed(
                    "Window \(expectedIdentity.windowID) changed identity during restore")
            }
            if window.isMinimized() == false,
               SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity)
            {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func focusFailureDescription(for target: WindowTarget) -> String {
        switch target {
        case .frontmost:
            "frontmost window"
        case let .application(app):
            "window for app '\(app)'"
        case let .title(title):
            "window with title containing '\(title)'"
        case let .index(app, index):
            "window at index \(index) for app '\(app)'"
        case let .applicationAndTitle(app, title):
            "window with title '\(title)' for app '\(app)'"
        case let .windowId(id):
            "window with ID \(id)"
        }
    }
}

enum PinnedWindowClosePresenceDisposition: Equatable {
    case present
    case missing
    case replacement
    case unverifiable
}

enum PinnedMinimizedWindowAXPresence: Equatable {
    case present
    case missing
    case replacement
    case unverifiable
}

struct PinnedMinimizedWindowAXScan: Equatable {
    let matchingWindowBounds: [CGRect?]
    let isComplete: Bool
}

enum PinnedWindowCloseVerificationDecision: Equatable {
    case pending
    case succeeded
    case retryClose
    case unverifiable
}

enum PinnedWindowCloseAttemptDisposition: Equatable {
    case disappeared
    case remained
    case unverifiable
}

func pinnedWindowCloseAttemptDisposition(
    for decision: PinnedWindowCloseVerificationDecision) -> PinnedWindowCloseAttemptDisposition
{
    switch decision {
    case .succeeded:
        .disappeared
    case .retryClose:
        .remained
    case .pending, .unverifiable:
        .unverifiable
    }
}

struct PinnedWindowCloseVerification {
    private let successHorizon: Duration
    private let disappearanceStability: Duration
    private let presentStability: Duration
    private var missingSince: Duration?
    private var presentSince: Duration?

    init(
        successHorizon: Duration = .seconds(4),
        disappearanceStability: Duration = .seconds(2),
        presentStability: Duration = .milliseconds(750))
    {
        self.successHorizon = successHorizon
        self.disappearanceStability = disappearanceStability
        self.presentStability = presentStability
    }

    mutating func observe(
        _ disposition: PinnedWindowClosePresenceDisposition,
        elapsed: Duration) -> PinnedWindowCloseVerificationDecision
    {
        switch disposition {
        case .missing:
            self.missingSince = self.missingSince ?? elapsed
            self.presentSince = nil
            guard let missingSince = self.missingSince,
                  elapsed >= self.successHorizon,
                  elapsed - missingSince >= self.disappearanceStability
            else {
                return .pending
            }
            return .succeeded
        case .present:
            self.missingSince = nil
            self.presentSince = self.presentSince ?? elapsed
            guard let presentSince = self.presentSince,
                  elapsed - presentSince >= self.presentStability
            else {
                return .pending
            }
            return .retryClose
        case .replacement, .unverifiable:
            return .unverifiable
        }
    }
}

enum PinnedForegroundCloseReadiness: Equatable {
    case ready
    case focusFailed
    case processGenerationMismatch
    case windowIdentityMismatch
    case appNotFrontmost
    case keyWindowUnavailable
    case wrongKeyWindow(actualWindowID: Int?)
    case sheetPresented

    func failureReason(windowID: Int) -> String {
        switch self {
        case .ready:
            "The exact target window was ready"
        case .focusFailed:
            "The exact target window refused focus; no global close shortcut was sent"
        case .processGenerationMismatch:
            "The target process generation changed before the global close shortcut"
        case .windowIdentityMismatch:
            "The target window identity changed before the global close shortcut"
        case .appNotFrontmost:
            "The target application did not become frontmost; no global close shortcut was sent"
        case .keyWindowUnavailable:
            "The target application's key window could not be verified; no global close shortcut was sent"
        case let .wrongKeyWindow(actualWindowID):
            "Window \(actualWindowID.map(String.init) ?? "unknown") became key instead of pinned window " +
                "\(windowID); no global close shortcut was sent"
        case .sheetPresented:
            "Pinned window \(windowID) presented a sheet; refusing a broader global close shortcut"
        }
    }
}

@MainActor
func readPinnedForegroundCloseReadiness(
    focusSucceeded: Bool,
    expectedIdentity: WindowMutationIdentity,
    keyWindowReader: @MainActor () async -> ExactKeyWindowSnapshot?,
    processStartIdentityReader: @MainActor () -> UInt64?,
    frontmostProcessIdentifierReader: @MainActor () -> pid_t?,
    windowIdentityValidator: @MainActor () -> Bool = { true }) async -> PinnedForegroundCloseReadiness
{
    guard focusSucceeded else { return .focusFailed }
    let keyWindow = await keyWindowReader()

    // AX messaging can block long enough for the user to switch applications or for the target
    // process to restart. Revalidate the capture receipt, then sample both ownership signals only
    // after that read, with no suspension before the policy can authorize a global shortcut.
    guard windowIdentityValidator() else { return .windowIdentityMismatch }
    let currentProcessStartIdentity = processStartIdentityReader()
    let frontmostProcessIdentifier = frontmostProcessIdentifierReader()
    return pinnedForegroundCloseReadiness(
        focusSucceeded: true,
        expectedIdentity: expectedIdentity,
        currentProcessStartIdentity: currentProcessStartIdentity,
        frontmostProcessIdentifier: frontmostProcessIdentifier,
        keyWindow: keyWindow)
}

func pinnedForegroundCloseReadiness(
    focusSucceeded: Bool,
    expectedIdentity: WindowMutationIdentity,
    currentProcessStartIdentity: UInt64?,
    frontmostProcessIdentifier: pid_t?,
    keyWindow: ExactKeyWindowSnapshot?) -> PinnedForegroundCloseReadiness
{
    guard focusSucceeded else { return .focusFailed }
    guard currentProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity else {
        return .processGenerationMismatch
    }
    guard frontmostProcessIdentifier == expectedIdentity.ownerProcessIdentifier else {
        return .appNotFrontmost
    }
    guard let keyWindow,
          keyWindow.processIdentifier == expectedIdentity.ownerProcessIdentifier
    else {
        return .keyWindowUnavailable
    }
    guard keyWindow.windowID == expectedIdentity.windowID else {
        return .wrongKeyWindow(actualWindowID: keyWindow.windowID)
    }
    guard !keyWindow.hasSheet else { return .sheetPresented }
    return .ready
}

func withMinimizedWindowFailureRecovery<T>(
    wasMinimized: Bool,
    restore: () async -> Bool,
    operation: () async throws -> T) async throws -> T
{
    do {
        return try await operation()
    } catch {
        if wasMinimized {
            _ = await restore()
        }
        throw error
    }
}

struct PinnedWindowCloseAttemptResult {
    let dispatchCount: Int
    let disappeared: Bool

    var dispatched: Bool {
        self.dispatchCount > 0
    }
}

func hasSufficientMetadataForPinnedClose(
    hasWindowServerMetadata: Bool,
    expectedMinimized: Bool) -> Bool
{
    hasWindowServerMetadata || expectedMinimized
}

func shouldRestoreMinimizedWindowAfterCloseFailure(
    wasMinimized: Bool,
    closeCompleted: Bool) -> Bool
{
    wasMinimized && !closeCompleted
}

func shouldAttemptUnminimizedClose(isEdited: Bool?) -> Bool {
    isEdited != true
}

func minimizedCloseRequiresForegroundFallback(isMinimized: Bool) -> Bool {
    isMinimized
}

func pinnedWindowClosePresenceDisposition(
    windowServerEntryPresent: Bool,
    windowServerEntryMatchesReceipt: Bool? = nil,
    minimizedAXPresence: PinnedMinimizedWindowAXPresence?,
    expectedMinimized: Bool) -> PinnedWindowClosePresenceDisposition
{
    if windowServerEntryPresent, windowServerEntryMatchesReceipt != false {
        return .present
    }
    if let minimizedAXPresence {
        return switch minimizedAXPresence {
        case .present: .present
        case .missing: .missing
        case .replacement: .replacement
        case .unverifiable: .unverifiable
        }
    }
    guard expectedMinimized || windowServerEntryPresent else {
        return .missing
    }
    return .unverifiable
}

func pinnedMinimizedWindowAXPresence(
    expectedIdentity: WindowMutationIdentity,
    processStartIdentityBeforeScan: UInt64?,
    processStartIdentityAfterScan: UInt64?,
    scan: PinnedMinimizedWindowAXScan) -> PinnedMinimizedWindowAXPresence
{
    guard processStartIdentityBeforeScan == expectedIdentity.ownerProcessStartIdentity,
          processStartIdentityAfterScan == expectedIdentity.ownerProcessStartIdentity
    else {
        return .replacement
    }
    guard let capturedBounds = expectedIdentity.capturedBounds else {
        return .unverifiable
    }

    if scan.matchingWindowBounds.contains(where: { $0 == capturedBounds }) {
        return .present
    }
    if scan.matchingWindowBounds.contains(where: { $0 != nil }) {
        return .replacement
    }
    if !scan.matchingWindowBounds.isEmpty {
        return .unverifiable
    }
    return scan.isComplete ? .missing : .unverifiable
}

func pinnedWindowMinimizeIdentityMatches(
    expectedIdentity: WindowMutationIdentity,
    currentProcessStartIdentity: UInt64?,
    currentWindowID: Int?,
    currentBounds: CGRect?,
    windowServerIdentityMatches: Bool = false) -> Bool
{
    guard currentProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity else { return false }
    if currentWindowID == expectedIdentity.windowID {
        return currentBounds == expectedIdentity.capturedBounds
    }
    return currentWindowID == nil && windowServerIdentityMatches
}

func pinnedWindowRestoreIdentityMatches(
    expectedIdentity: WindowMutationIdentity,
    currentProcessStartIdentity: UInt64?,
    currentWindowID: Int?,
    currentBounds: CGRect?) -> Bool
{
    currentProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity &&
        currentWindowID == expectedIdentity.windowID &&
        currentBounds == expectedIdentity.capturedBounds
}

@MainActor
func completePinnedMinimizedWindowRestore(
    expectedIdentity: WindowMutationIdentity,
    dispatch: @MainActor () async -> Bool,
    repin: @MainActor (WindowMutationIdentity, CGRect) async throws -> WindowMutationIdentity) async throws
    -> WindowMutationIdentity
{
    guard expectedIdentity.isMinimized == true,
          let capturedBounds = expectedIdentity.capturedBounds
    else {
        throw PeekabooError.commandFailed(
            "Window \(expectedIdentity.windowID) restore receipt lacks minimized state or capture-time bounds")
    }
    guard await dispatch() else {
        throw OperationError.interactionFailed(
            action: "restore window",
            reason: "Window restore operation failed or the exact minimized receipt became ambiguous")
    }

    let restoredIdentity = try await repin(expectedIdentity, capturedBounds)
    guard restoredIdentity.windowID == expectedIdentity.windowID,
          restoredIdentity.ownerProcessIdentifier == expectedIdentity.ownerProcessIdentifier,
          restoredIdentity.ownerProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity,
          restoredIdentity.capturedBounds == capturedBounds,
          restoredIdentity.isMinimized == false
    else {
        throw PeekabooError.commandFailed(
            "Window \(expectedIdentity.windowID) became ambiguous after restore dispatch")
    }
    return restoredIdentity
}

func exactWindowIDForStateMutation(
    target: WindowTarget,
    resolvedWindows: [ServiceWindowInfo]) throws -> Int
{
    if case let .windowId(windowID) = target {
        guard windowID > 0 else {
            throw PeekabooError.invalidInput("Window ID must be greater than 0")
        }
        return windowID
    }
    guard let windowID = resolvedWindows.first?.windowID, windowID > 0 else {
        throw PeekabooError.windowNotFound(criteria: "No exact window identity was available for state mutation")
    }
    return windowID
}

func validateBackgroundCloseOutcome(
    dispatchSucceeded: Bool,
    disappeared: Bool) throws
{
    guard dispatchSucceeded else {
        throw OperationError.interactionFailed(
            action: "close window",
            reason: "Window close operation failed")
    }
    guard disappeared else {
        throw OperationError.interactionFailed(
            action: "close window",
            reason: "AX close completed but the window remained visible; retry with foreground fallback enabled")
    }
}

func verifyBackgroundClose(
    dispatchSucceeded: Bool,
    disappearanceCheck: () async throws -> Bool) async throws
{
    guard dispatchSucceeded else {
        try validateBackgroundCloseOutcome(dispatchSucceeded: false, disappeared: false)
        return
    }
    let disappeared = try await disappearanceCheck()
    try validateBackgroundCloseOutcome(dispatchSucceeded: true, disappeared: disappeared)
}

func maximizedVisibleFrame(
    windowBounds: CGRect,
    screenVisibleFramesTopLeft: [CGRect]) -> CGRect?
{
    WindowMutationGeometryPostcondition.maximizedVisibleWorkArea(
        for: windowBounds,
        screenVisibleWorkAreas: screenVisibleFramesTopLeft)
}

func backgroundGeometryDispatchRemainsPinned(
    expectedIdentity: WindowMutationIdentity,
    positionSetSucceeded: Bool,
    sizeSetSucceeded: Bool,
    liveProcessStartIdentity: UInt64?,
    candidateWindowID: Int?) -> Bool
{
    positionSetSucceeded &&
        sizeSetSucceeded &&
        liveProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity &&
        candidateWindowID == expectedIdentity.windowID
}

private struct BackgroundWindowGeometryDispatchResult {
    let acceptance: WindowGeometryDispatchAcceptance
    let identityRemainedPinned: Bool

    static let notDispatched = Self(
        acceptance: WindowGeometryDispatchAcceptance(
            positionAccepted: false,
            sizeAccepted: false),
        identityRemainedPinned: false)

    var dispatchCount: Int {
        self.acceptance.dispatchCount
    }
}

extension CGRect {
    private var area: CGFloat {
        guard !self.isNull, !self.isInfinite else { return 0 }
        return max(0, self.width) * max(0, self.height)
    }

    private var center: CGPoint {
        CGPoint(x: self.midX, y: self.midY)
    }
}

extension CGPoint {
    private func squaredDistance(to other: CGPoint) -> CGFloat {
        let deltaX = self.x - other.x
        let deltaY = self.y - other.y
        return deltaX * deltaX + deltaY * deltaY
    }
}

/// Runs the only blocking AX calls used by background close/maximize away from MainActor and
/// applies a per-element messaging deadline. Cancellation of the caller cannot stop a synchronous
/// Accessibility message already in the kernel, so the native AX deadline is the hard safety bound.
private enum BoundedBackgroundWindowAX {
    private static let messagingTimeout: Float = 0.75

    static func windowPresence(expectedIdentity: WindowMutationIdentity) async -> PinnedMinimizedWindowAXPresence {
        await Task.detached(priority: .userInitiated) {
            let processStartIdentityBeforeScan = SystemIdentityResolver.processStartIdentity(
                expectedIdentity.ownerProcessIdentifier)
            guard SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
                  let windowID = CGWindowID(exactly: expectedIdentity.windowID)
            else {
                return .replacement
            }
            let scan = self.windowPresenceScan(
                windowID: windowID,
                ownerPID: expectedIdentity.ownerProcessIdentifier)
            let processStartIdentityAfterScan = SystemIdentityResolver.processStartIdentity(
                expectedIdentity.ownerProcessIdentifier)
            return pinnedMinimizedWindowAXPresence(
                expectedIdentity: expectedIdentity,
                processStartIdentityBeforeScan: processStartIdentityBeforeScan,
                processStartIdentityAfterScan: processStartIdentityAfterScan,
                scan: scan)
        }.value
    }

    static func dispatchMinimizedRestore(expectedIdentity: WindowMutationIdentity) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard expectedIdentity.isMinimized == true,
                  let windowID = CGWindowID(exactly: expectedIdentity.windowID),
                  SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
                  self.windowServerAllowsExactMinimizedRestore(
                      expectedIdentity: expectedIdentity,
                      windowID: windowID),
                  let rawWindow = self.exactWindow(
                      windowID: windowID,
                      ownerPID: expectedIdentity.ownerProcessIdentifier)
            else {
                return false
            }
            return AXChildWindowMessagingTimeout.perform(
                on: rawWindow,
                timeout: self.messagingTimeout)
            { childWindow in
                var candidateID: CGWindowID = 0
                guard AXWindowIDResolver.copyWindowID(childWindow, into: &candidateID) == .success,
                      exactMinimizedRestoreCandidateIsValid(
                          expectedIdentity: expectedIdentity,
                          liveProcessStartIdentity: SystemIdentityResolver.processStartIdentity(
                              expectedIdentity.ownerProcessIdentifier),
                          candidateWindowID: candidateID,
                          candidateBounds: self.bounds(of: childWindow),
                          candidateIsMinimized: self.boolAttribute(
                              kAXMinimizedAttribute as String,
                              of: childWindow))
                else {
                    return false
                }
                // AX state readback can lag a successful write. The caller verifies completion by
                // repinning the exact WindowServer ID, owner generation, and captured bounds.
                return AXUIElementSetAttributeValue(
                    childWindow,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse) == .success
            }
        }.value
    }

    static func dispatchClose(
        expectedIdentity: WindowMutationIdentity,
        action: BoundedBackgroundWindowCloseAction) async -> Bool
    {
        await Task.detached(priority: .userInitiated) {
            guard SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity),
                  let capturedBounds = expectedIdentity.capturedBounds,
                  let windowID = CGWindowID(exactly: expectedIdentity.windowID),
                  let rawWindow = self.exactWindow(
                      windowID: windowID,
                      ownerPID: expectedIdentity.ownerProcessIdentifier)
            else {
                return false
            }
            return AXChildWindowMessagingTimeout.perform(
                on: rawWindow,
                timeout: self.messagingTimeout)
            { childWindow in
                guard SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
                      self.bounds(of: childWindow) == capturedBounds
                else {
                    return false
                }
                if expectedIdentity.isMinimized == true {
                    guard shouldAttemptUnminimizedClose(
                        isEdited: self.boolAttribute("AXEdited", of: childWindow))
                    else {
                        return false
                    }
                }

                guard SystemIdentityResolver.processStartIdentity(expectedIdentity.ownerProcessIdentifier) ==
                    expectedIdentity.ownerProcessStartIdentity
                else {
                    return false
                }
                switch action {
                case .windowClose:
                    return AXUIElementPerformAction(childWindow, "AXClose" as CFString) == .success
                case .closeButton:
                    var closeButtonValue: CFTypeRef?
                    guard AXUIElementCopyAttributeValue(
                        childWindow,
                        kAXCloseButtonAttribute as CFString,
                        &closeButtonValue) == .success,
                        let closeButtonValue,
                        CFGetTypeID(closeButtonValue) == AXUIElementGetTypeID()
                    else {
                        return false
                    }
                    let closeButton = unsafeDowncast(closeButtonValue, to: AXUIElement.self)
                    return AXChildWindowMessagingTimeout.perform(
                        on: closeButton,
                        timeout: self.messagingTimeout)
                    { button in
                        AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
                    }
                }
            }
        }.value
    }

    static func setBounds(
        expectedIdentity: WindowMutationIdentity,
        bounds: CGRect) async -> BackgroundWindowGeometryDispatchResult
    {
        await Task.detached(priority: .userInitiated) {
            guard SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity),
                  let capturedBounds = expectedIdentity.capturedBounds,
                  let windowID = CGWindowID(exactly: expectedIdentity.windowID),
                  let rawWindow = self.exactWindow(
                      windowID: windowID,
                      ownerPID: expectedIdentity.ownerProcessIdentifier)
            else {
                return .notDispatched
            }
            return AXChildWindowMessagingTimeout.perform(
                on: rawWindow,
                timeout: self.messagingTimeout)
            { childWindow in
                guard SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
                      self.bounds(of: childWindow) == capturedBounds
                else {
                    return .notDispatched
                }

                var origin = bounds.origin
                var size = bounds.size
                guard let originValue = AXValueCreate(.cgPoint, &origin),
                      let sizeValue = AXValueCreate(.cgSize, &size)
                else {
                    return .notDispatched
                }

                let positionResult = AXUIElementSetAttributeValue(
                    childWindow,
                    kAXPositionAttribute as CFString,
                    originValue)
                let sizeResult = AXUIElementSetAttributeValue(
                    childWindow,
                    kAXSizeAttribute as CFString,
                    sizeValue)
                var candidateWindowID: CGWindowID = 0
                let windowIDResult = AXWindowIDResolver.copyWindowID(
                    childWindow,
                    into: &candidateWindowID)
                let positionAccepted = positionResult == .success
                let sizeAccepted = sizeResult == .success
                let liveProcessStartIdentity = SystemIdentityResolver.processStartIdentity(
                    expectedIdentity.ownerProcessIdentifier)
                let resolvedCandidateWindowID = windowIDResult == .success ? Int(candidateWindowID) : nil
                return BackgroundWindowGeometryDispatchResult(
                    acceptance: WindowGeometryDispatchAcceptance(
                        positionAccepted: positionAccepted,
                        sizeAccepted: sizeAccepted),
                    identityRemainedPinned: liveProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity &&
                        resolvedCandidateWindowID == expectedIdentity.windowID)
            }
        }.value
    }

    private static func exactWindow(windowID: CGWindowID, ownerPID: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(application, self.messagingTimeout)
        defer { AXUIElementSetMessagingTimeout(application, 0) }

        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue) == .success,
            let windows = windowsValue as? [AXUIElement]
        else {
            return nil
        }

        for window in windows {
            let matches = AXChildWindowMessagingTimeout.perform(
                on: window,
                timeout: self.messagingTimeout)
            { childWindow in
                var candidateID: CGWindowID = 0
                return AXWindowIDResolver.copyWindowID(childWindow, into: &candidateID) == .success &&
                    candidateID == windowID
            }
            if matches {
                return window
            }
        }
        return nil
    }

    private static func windowServerAllowsExactMinimizedRestore(
        expectedIdentity: WindowMutationIdentity,
        windowID: CGWindowID) -> Bool
    {
        if SystemIdentityResolver.windowIdentity(windowID) == nil {
            return true
        }
        return SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity)
    }

    private static func windowPresenceScan(
        windowID: CGWindowID,
        ownerPID: pid_t) -> PinnedMinimizedWindowAXScan
    {
        let application = AXUIElementCreateApplication(ownerPID)
        AXUIElementSetMessagingTimeout(application, self.messagingTimeout)
        defer { AXUIElementSetMessagingTimeout(application, 0) }
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &windowsValue) == .success,
            let windows = windowsValue as? [AXUIElement]
        else {
            return PinnedMinimizedWindowAXScan(matchingWindowBounds: [], isComplete: false)
        }
        var matchingWindowBounds: [CGRect?] = []
        var isComplete = true
        for window in windows {
            let observation = AXChildWindowMessagingTimeout.perform(
                on: window,
                timeout: self.messagingTimeout)
            { childWindow -> (windowID: CGWindowID?, bounds: CGRect?) in
                var candidateID: CGWindowID = 0
                guard AXWindowIDResolver.copyWindowID(childWindow, into: &candidateID) == .success else {
                    return (nil, nil)
                }
                return (candidateID, candidateID == windowID ? self.bounds(of: childWindow) : nil)
            }
            guard let candidateID = observation.windowID else {
                isComplete = false
                continue
            }
            guard candidateID == windowID else { continue }
            matchingWindowBounds.append(observation.bounds)
            isComplete = isComplete && observation.bounds != nil
        }
        return PinnedMinimizedWindowAXScan(
            matchingWindowBounds: matchingWindowBounds,
            isComplete: isComplete)
    }

    private static func bounds(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue) == .success,
            AXUIElementCopyAttributeValue(
                element,
                kAXSizeAttribute as CFString,
                &sizeValue) == .success,
            let position = self.pointValue(positionValue),
            let size = self.sizeValue(sizeValue)
        else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func pointValue(_ rawValue: CFTypeRef?) -> CGPoint? {
        guard let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgPoint else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func sizeValue(_ rawValue: CFTypeRef?) -> CGSize? {
        guard let rawValue,
              CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = unsafeDowncast(rawValue, to: AXValue.self)
        guard AXValueGetType(value) == .cgSize else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func boolAttribute(_ name: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}

func exactMinimizedRestoreCandidateIsValid(
    expectedIdentity: WindowMutationIdentity,
    liveProcessStartIdentity: UInt64?,
    candidateWindowID: CGWindowID?,
    candidateBounds: CGRect?,
    candidateIsMinimized: Bool?) -> Bool
{
    guard expectedIdentity.isMinimized == true,
          let expectedBounds = expectedIdentity.capturedBounds,
          liveProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity,
          candidateWindowID.map(Int.init) == expectedIdentity.windowID,
          candidateBounds == expectedBounds,
          candidateIsMinimized == true
    else {
        return false
    }
    return true
}

private enum BoundedBackgroundWindowCloseAction: Sendable {
    case windowClose
    case closeButton
}
