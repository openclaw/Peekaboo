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
        let operationScope: DesktopOperationScope = allowForegroundFallback ? .global : .window(expectedIdentity)
        try await self.operationLaneCoordinator.run(scope: operationScope, access: .write) {
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            let trackedWindowID = expectedIdentity.windowID
            try Task.checkCancellation()
            let exactTarget = WindowTarget.windowId(trackedWindowID)
            let windowServerInfo = self.windowIdentityService
                .getWindowServerInfo(windowID: CGWindowID(trackedWindowID))
            guard hasSufficientMetadataForPinnedClose(
                hasWindowServerMetadata: windowServerInfo != nil,
                expectedMinimized: expectedIdentity.isMinimized == true)
            else {
                throw PeekabooError.windowNotFound(criteria: "windowId \(trackedWindowID)")
            }
            let windowBounds = windowServerInfo?.bounds

            if minimizedCloseRequiresForegroundFallback(isMinimized: expectedIdentity.isMinimized == true),
               !allowForegroundFallback
            {
                throw OperationError.interactionFailed(
                    action: "close window",
                    reason: "A minimized window cannot be closed with a verified background-only route; " +
                        "run `peekaboo window restore` for the same exact target first, or retry with --foreground")
            }

            let backgroundAttempt: PinnedWindowCloseAttemptResult
            if expectedIdentity.isMinimized == true {
                backgroundAttempt = PinnedWindowCloseAttemptResult(dispatched: false, disappeared: false)
            } else {
                do {
                    backgroundAttempt = try await self.attemptPinnedBackgroundClose(expectedIdentity)
                } catch {
                    throw error
                }
            }
            if Self.shouldShowWindowOperationFeedback(
                operation: .close,
                hasForegroundConsent: allowForegroundFallback)
            {
                self.showWindowOperation(.close, bounds: windowBounds)
            }
            try Task.checkCancellation()

            if !allowForegroundFallback {
                do {
                    try validateBackgroundCloseOutcome(
                        dispatchSucceeded: backgroundAttempt.dispatched,
                        disappeared: backgroundAttempt.disappeared)
                } catch {
                    if shouldRestoreMinimizedWindowAfterCloseFailure(
                        wasMinimized: expectedIdentity.isMinimized == true,
                        closeCompleted: false)
                    {
                        _ = await BoundedBackgroundWindowAX.restoreMinimizedState(expectedIdentity: expectedIdentity)
                    }
                    throw error
                }
                return
            }

            if backgroundAttempt.disappeared {
                return
            }

            try Task.checkCancellation()
            self.logger
                .warning(
                    "Close succeeded but window still exists; trying hotkey fallbacks. windowID=\(trackedWindowID)")

            try await withMinimizedWindowFailureRecovery(
                wasMinimized: expectedIdentity.isMinimized == true,
                restore: {
                    let restored = await BoundedBackgroundWindowAX.restoreMinimizedState(
                        expectedIdentity: expectedIdentity)
                    if !restored {
                        let message = "Could not restore minimized state after foreground close failure. " +
                            "windowID=\(trackedWindowID)"
                        self.logger.error("\(message, privacy: .public)")
                    }
                    return restored
                },
                operation: {
                    // Make the exact target key before global shortcuts; a same-process sibling must
                    // never inherit Cmd-W just because the requested focus call returned.
                    try Task.checkCancellation()
                    let window = try await self.element(for: exactTarget)
                    try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)
                    let focusSucceeded = window.focusWindow()
                    try await self.requirePinnedForegroundCloseReadiness(
                        expectedIdentity,
                        focusSucceeded: focusSucceeded)

                    try Task.checkCancellation()
                    try InputDriver.hotkey(keys: ["cmd", "w"], holdDuration: 0.05)
                    if try await self.pinnedWindowDisappeared(expectedIdentity) {
                        return
                    }

                    // Cmd-W may surface a sheet or move key status to a sibling. Re-prove the exact
                    // target immediately before the broader Cmd-Shift-W fallback.
                    try await self.requirePinnedForegroundCloseReadiness(
                        expectedIdentity,
                        focusSucceeded: true)
                    try Task.checkCancellation()
                    try InputDriver.hotkey(keys: ["cmd", "shift", "w"], holdDuration: 0.05)
                    if try await self.pinnedWindowDisappeared(expectedIdentity) {
                        return
                    }

                    throw OperationError.interactionFailed(
                        action: "close window",
                        reason: "Foreground close completed but window remained visible " +
                            "(windowID=\(trackedWindowID))")
                })
        }
    }

    public func minimizeWindow(target: WindowTarget) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.minimizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func minimizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            let window = try await self.element(for: target)
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)
            let success = window.minimizeWindow()

            if !success {
                throw OperationError.interactionFailed(
                    action: "minimize window",
                    reason: "Window minimize operation failed")
            }
            guard try await self.waitForPinnedWindowMinimized(window, expectedIdentity: expectedIdentity) else {
                throw PeekabooError.commandFailed(
                    "Window \(expectedIdentity.windowID) did not reach verified minimized state")
            }
        }
    }

    public func restoreWindow(target: WindowTarget) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.restoreWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func restoreWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            if expectedIdentity.isMinimized == true {
                guard await BoundedBackgroundWindowAX.restoreMinimizedState(expectedIdentity: expectedIdentity) else {
                    throw OperationError.interactionFailed(
                        action: "restore window",
                        reason: "Window restore operation failed or the exact minimized receipt became ambiguous")
                }
                guard let capturedBounds = expectedIdentity.capturedBounds else {
                    throw PeekabooError.commandFailed(
                        "Window \(expectedIdentity.windowID) restore receipt lacks capture-time bounds")
                }
                _ = try await self.waitForRepinnedWindowMutation(
                    expectedIdentity,
                    expectedBounds: capturedBounds)
                return
            }
            let window = try await self.element(for: target)
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            try self.validatePinnedWindowElement(window, expectedIdentity: expectedIdentity)

            if window.isMinimized() == false {
                guard SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity) else {
                    throw PeekabooError.commandFailed(
                        "Window \(expectedIdentity.windowID) changed identity before restore completion")
                }
                return
            }

            guard window.unminimizeWindow() else {
                throw OperationError.interactionFailed(
                    action: "restore window",
                    reason: "Window restore operation failed")
            }
            guard try await self.waitForPinnedWindowRestored(window, expectedIdentity: expectedIdentity) else {
                throw PeekabooError.commandFailed(
                    "Window \(expectedIdentity.windowID) did not reach verified restored state")
            }
        }
    }

    public func maximizeWindow(target: WindowTarget) async throws {
        let pinned = try await self.pinnedWindowMutation(for: target)
        try await self.maximizeWindow(target: pinned.target, expectedIdentity: pinned.identity)
    }

    public func maximizeWindow(target: WindowTarget, expectedIdentity: WindowMutationIdentity) async throws {
        try await self.operationLaneCoordinator.run(scope: .window(expectedIdentity), access: .write) {
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            guard let windowInfo = try await self.listWindows(target: target).first else {
                throw PeekabooError.windowNotFound(criteria: "No exact window identity was available for maximize")
            }
            try self.validatePinnedWindowMutation(target: target, expectedIdentity: expectedIdentity)
            let desiredBounds = try self.maximizedBounds(for: windowInfo.bounds)

            if Self.windowBoundsMatch(windowInfo.bounds, desiredBounds, tolerance: 4) {
                return
            }

            guard self.windowIdentityService
                .getWindowServerInfo(windowID: CGWindowID(windowInfo.windowID)) != nil
            else {
                throw PeekabooError.windowNotFound(criteria: "windowId \(windowInfo.windowID)")
            }
            let success = await BoundedBackgroundWindowAX.setBounds(
                expectedIdentity: expectedIdentity,
                bounds: desiredBounds)

            if !success {
                throw OperationError.interactionFailed(
                    action: "maximize window",
                    reason: "The bounded background geometry request failed")
            }

            guard try await self.waitForWindowBounds(
                windowID: windowInfo.windowID,
                expectedIdentity: expectedIdentity,
                expected: desiredBounds,
                timeoutSeconds: 2)
            else {
                let achieved = self.windowIdentityService
                    .getWindowServerInfo(windowID: CGWindowID(windowInfo.windowID))?.bounds
                throw OperationError.interactionFailed(
                    action: "maximize window",
                    reason: "The window did not reach the target screen's visible bounds within 2 seconds " +
                        "(requested: \(desiredBounds), achieved: \(String(describing: achieved)))")
            }
        }
    }

    private func maximizedBounds(for windowBounds: CGRect) throws -> CGRect {
        let primaryDisplayHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
            ?? NSScreen.main)?.frame.height ?? 0
        let visibleFrames = NSScreen.screens.map { screen in
            CGRect(
                x: screen.visibleFrame.origin.x,
                y: primaryDisplayHeight - screen.visibleFrame.origin.y - screen.visibleFrame.height,
                width: screen.visibleFrame.width,
                height: screen.visibleFrame.height)
        }
        guard !visibleFrames.isEmpty else {
            throw PeekabooError.commandFailed("No display is available for window maximize")
        }

        guard let target = maximizedVisibleFrame(
            windowBounds: windowBounds,
            screenVisibleFramesTopLeft: visibleFrames)
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
                Self.windowBoundsMatch(info.bounds, expected, tolerance: 4),
                SystemIdentityResolver.repinWindowMutationIdentity(
                    expectedIdentity,
                    expectedBounds: expected,
                    tolerance: 4) != nil
            {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func windowBoundsMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance &&
            abs(lhs.minY - rhs.minY) <= tolerance &&
            abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }

    public func focusWindow(target: WindowTarget) async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            self.logger.info("Attempting to focus window with target: \(target)")
            self.logger.debug("WindowManagementService.focusWindow called with target: \(target)")

            let window = try await self.element(for: target)
            let windowBounds = window.position().map { position in
                CGRect(origin: position, size: window.size() ?? .zero)
            }

            let success: Bool
            if let windowID = self.windowIdentityService.getWindowID(from: window) {
                let focusService = FocusManagementService(
                    applications: self.applicationService,
                    operationLaneCoordinator: self.operationLaneCoordinator)
                try await focusService.focusWindowWithOwnedLane(windowID: windowID)
                success = true
            } else {
                self.logger.debug("Falling back to AXorcist focus without a CGWindowID")
                success = window.focusWindow()
            }
            self.showWindowOperation(.focus, bounds: windowBounds)

            guard success else {
                let windowInfo = self.focusFailureDescription(for: target)
                self.logger.error("Focus window failed for: \(windowInfo)")

                let reason = [
                    "Failed to focus \(windowInfo).",
                    "The window may be minimized, on another Space, " +
                        "or the app may not be responding to focus requests.",
                ].joined(separator: " ")
                throw OperationError.interactionFailed(action: "focus window", reason: reason)
            }
        }
    }

    func showWindowOperation(_ operation: WindowOperationKind, bounds: CGRect?) {
        guard let bounds else { return }

        Task {
            _ = await self.feedbackClient.showWindowOperation(operation, windowRect: bounds, duration: 0.5)
        }
    }

    static func shouldShowWindowOperationFeedback(
        operation: WindowOperationKind,
        hasForegroundConsent: Bool) -> Bool
    {
        operation == .focus || hasForegroundConsent
    }

    private func windowDisappeared(windowID: Int, appIdentifier: String?) async throws -> Bool {
        try await self.waitForWindowToDisappear(
            windowID: windowID,
            appIdentifier: appIdentifier,
            timeoutSeconds: 3.0)
    }

    private func attemptPinnedBackgroundClose(
        _ expectedIdentity: WindowMutationIdentity) async throws -> PinnedWindowCloseAttemptResult
    {
        let primaryDispatched = await BoundedBackgroundWindowAX.dispatchClose(
            expectedIdentity: expectedIdentity,
            action: .windowClose)
        if primaryDispatched {
            switch try await self.verifyPinnedWindowClose(expectedIdentity) {
            case .succeeded:
                return PinnedWindowCloseAttemptResult(dispatched: true, disappeared: true)
            case .pending, .retryClose, .unverifiable:
                break
            }
        }

        try Task.checkCancellation()
        let fallbackDispatched = await BoundedBackgroundWindowAX.dispatchClose(
            expectedIdentity: expectedIdentity,
            action: .closeButton)
        let anyDispatched = primaryDispatched || fallbackDispatched
        guard anyDispatched else {
            return PinnedWindowCloseAttemptResult(dispatched: false, disappeared: false)
        }

        let fallbackDecision = try await self.verifyPinnedWindowClose(expectedIdentity)
        return PinnedWindowCloseAttemptResult(
            dispatched: true,
            disappeared: fallbackDecision == .succeeded)
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
                    "Window \(expectedIdentity.windowID) was recycled during close")
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
                    "Window \(expectedIdentity.windowID) was recycled during close")
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

    private func pinnedWindowDisappeared(_ expectedIdentity: WindowMutationIdentity) async throws -> Bool {
        try await self.verifyPinnedWindowClose(expectedIdentity) == .succeeded
    }

    private func requirePinnedForegroundCloseReadiness(
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
            let minimized = window.isMinimized()
            guard pinnedWindowMinimizeIdentityMatches(
                expectedIdentity: expectedIdentity,
                currentProcessStartIdentity: currentProcessStartIdentity,
                currentWindowID: currentWindowID)
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

private struct PinnedWindowCloseAttemptResult {
    let dispatched: Bool
    let disappeared: Bool
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
    currentWindowID: Int?) -> Bool
{
    currentProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity &&
        currentWindowID == expectedIdentity.windowID
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
    guard let greatestOverlap = screenVisibleFramesTopLeft.max(by: { lhs, rhs in
        lhs.intersection(windowBounds).area < rhs.intersection(windowBounds).area
    }) else {
        return nil
    }
    if greatestOverlap.intersection(windowBounds).area > 0 {
        return greatestOverlap
    }

    let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
    return screenVisibleFramesTopLeft.min { lhs, rhs in
        lhs.center.squaredDistance(to: center) < rhs.center.squaredDistance(to: center)
    }
}

extension CGRect {
    fileprivate var area: CGFloat {
        guard !self.isNull, !self.isInfinite else { return 0 }
        return max(0, self.width) * max(0, self.height)
    }

    fileprivate var center: CGPoint {
        CGPoint(x: self.midX, y: self.midY)
    }
}

extension CGPoint {
    fileprivate func squaredDistance(to other: CGPoint) -> CGFloat {
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

    @_silgen_name("_AXUIElementGetWindow")
    private static func copyWindowID(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

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

    static func restoreMinimizedState(expectedIdentity: WindowMutationIdentity) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            guard expectedIdentity.isMinimized == true,
                  SystemIdentityResolver.validateWindowMutationIdentity(expectedIdentity),
                  let capturedBounds = expectedIdentity.capturedBounds,
                  let windowID = CGWindowID(exactly: expectedIdentity.windowID),
                  let rawWindow = self.exactWindow(
                      windowID: windowID,
                      ownerPID: expectedIdentity.ownerProcessIdentifier) ?? self.uniqueWindow(
                      ownerPID: expectedIdentity.ownerProcessIdentifier,
                      bounds: capturedBounds)
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
                guard AXUIElementSetAttributeValue(
                    childWindow,
                    kAXMinimizedAttribute as CFString,
                    kCFBooleanFalse) == .success,
                    SystemIdentityResolver.validateWindowMutationOwnerGeneration(expectedIdentity),
                    self.bounds(of: childWindow) == capturedBounds
                else {
                    return false
                }
                return true
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

    static func setBounds(expectedIdentity: WindowMutationIdentity, bounds: CGRect) async -> Bool {
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

                var origin = bounds.origin
                var size = bounds.size
                guard let originValue = AXValueCreate(.cgPoint, &origin),
                      let sizeValue = AXValueCreate(.cgSize, &size)
                else {
                    return false
                }

                let positionResult = AXUIElementSetAttributeValue(
                    childWindow,
                    kAXPositionAttribute as CFString,
                    originValue)
                let sizeResult = AXUIElementSetAttributeValue(
                    childWindow,
                    kAXSizeAttribute as CFString,
                    sizeValue)
                return positionResult == .success && sizeResult == .success &&
                    SystemIdentityResolver.repinWindowMutationIdentity(
                        expectedIdentity,
                        expectedBounds: bounds) != nil
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
                return self.copyWindowID(childWindow, &candidateID) == .success && candidateID == windowID
            }
            if matches {
                return window
            }
        }
        return nil
    }

    private static func uniqueWindow(ownerPID: pid_t, bounds: CGRect) -> AXUIElement? {
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
        let matches = windows.filter { window in
            AXChildWindowMessagingTimeout.perform(
                on: window,
                timeout: self.messagingTimeout)
            { childWindow in
                self.bounds(of: childWindow) == bounds &&
                    self.boolAttribute(kAXMinimizedAttribute as String, of: childWindow) == true
            }
        }
        return matches.count == 1 ? matches[0] : nil
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
                guard self.copyWindowID(childWindow, &candidateID) == .success else {
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

private enum BoundedBackgroundWindowCloseAction: Sendable {
    case windowClose
    case closeButton
}
