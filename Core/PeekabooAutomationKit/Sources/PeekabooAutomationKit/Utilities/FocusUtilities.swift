// Window Focus Management Utilities
//
// This file provides comprehensive window focus management with support for:
// - Automatic window focusing before interactions
// - Space (virtual desktop) switching
// - Window movement between Spaces
// - Focus verification with retries
//
// ## Architecture
//
// The focus system has three layers:
//
// 1. **FocusOptions**: Command-line argument parsing for focus configuration
// 2. **FocusManagementService**: Core focus logic with Space support
// 3. **Integration**: Automatic focus in click, type, and menu commands
//
// ## Key Features
//
// 1. **Auto-Focus**: Automatically focus windows before interactions
// 2. **Space Switching**: Switch to window's Space if on different desktop
// 3. **Window Movement**: Bring windows to current Space
// 4. **Focus Verification**: Verify focus with configurable retries
// 5. **Snapshot Integration**: Store window IDs for fast refocusing
//
// ## Usage Examples
//
// ```swift
// // Command-line usage
// peekaboo click button --focus-timeout 3.0 --space-switch
// peekaboo type "Hello" --no-auto-focus
// peekaboo window focus --app Safari --move-here
//
// // Programmatic usage
// let service = FocusManagementService()
// let options = FocusManagementService.FocusOptions(
//     timeout: 5.0,
//     retryCount: 3,
//     switchSpace: true
// )
// try await service.focusWindow(windowID: 1234, options: options)
// ```
//

import AppKit
import ApplicationServices
import AXorcist
import Foundation

private struct AttachedDialogFocusReceipt {
    let parentIdentity: WindowMutationIdentity
    let parentBounds: CGRect
    let dialog: Element
}

struct AttachedDialogFocusObservation: Sendable {
    let currentProcessStartIdentity: UInt64?
    let focusedWindowPID: pid_t?
    let frontmostPID: pid_t?
    let focusedWindowMatchesPreparedDialog: Bool
    let preparedDialogIsStructural: Bool
    let preparedDialogAttachedToParent: Bool
}

struct DialogDispatchFocusObservation: Sendable {
    let currentProcessStartIdentity: UInt64?
    let focusedWindowPID: pid_t?
    let frontmostPID: pid_t?
    let focusedWindowID: Int?
    let retainedParentMatches: Bool
    let focusedWindowMatchesPreparedDialog: Bool
    let preparedDialogIsStructural: Bool
    let preparedDialogAttachedToParent: Bool
    let focusedElementPID: pid_t?
    let focusedElementMatchesRetainedField: Bool
    let retainedFieldAttachedToDialog: Bool
}

// MARK: - Focus Options Protocol

public protocol FocusOptionsProtocol {
    var autoFocus: Bool { get }
    var focusTimeout: TimeInterval? { get }
    var focusRetryCount: Int? { get }
    var spaceSwitch: Bool { get }
    var bringToCurrentSpace: Bool { get }
}

// MARK: - Focus Options Value Type

public struct FocusOptions: FocusOptionsProtocol {
    public let autoFocus: Bool
    public let focusTimeout: TimeInterval?
    public let focusRetryCount: Int?
    public let spaceSwitch: Bool
    public let bringToCurrentSpace: Bool

    public init(
        autoFocus: Bool = true,
        focusTimeout: TimeInterval? = nil,
        focusRetryCount: Int? = nil,
        spaceSwitch: Bool = false,
        bringToCurrentSpace: Bool = false)
    {
        self.autoFocus = autoFocus
        self.focusTimeout = focusTimeout
        self.focusRetryCount = focusRetryCount
        self.spaceSwitch = spaceSwitch
        self.bringToCurrentSpace = bringToCurrentSpace
    }
}

// MARK: - Focus Command Extension

// MARK: - Focus Management Service

@MainActor
public final class FocusManagementService {
    private let windowIdentityService = WindowIdentityService()
    private let spaceService = SpaceManagementService()
    private let applications: any ApplicationServiceProtocol
    private let operationLaneCoordinator: DesktopOperationLaneCoordinator

    public init(
        applications: (any ApplicationServiceProtocol)? = nil,
        operationLaneCoordinator: DesktopOperationLaneCoordinator = .shared)
    {
        self.applications = applications ?? ApplicationService()
        self.operationLaneCoordinator = operationLaneCoordinator
    }

    public struct FocusOptions {
        public let timeout: TimeInterval
        public let retryCount: Int
        public let switchSpace: Bool
        public let bringToCurrentSpace: Bool

        public init(
            timeout: TimeInterval = 5.0,
            retryCount: Int = 3,
            switchSpace: Bool = true,
            bringToCurrentSpace: Bool = false)
        {
            self.timeout = timeout
            self.retryCount = retryCount
            self.switchSpace = switchSpace
            self.bringToCurrentSpace = bringToCurrentSpace
        }
    }

    // MARK: - Window Finding

    /// Find the best window match for the given criteria
    public func findBestWindow(
        applicationName: String,
        windowTitle: String? = nil) async throws -> CGWindowID?
    {
        // Find the application
        let appInfo = try await self.applications.findApplication(identifier: applicationName)

        guard let app = NSRunningApplication(processIdentifier: appInfo.processIdentifier) else {
            throw FocusError.applicationNotRunning(applicationName)
        }

        // Get all windows for the app
        let windows = self.windowIdentityService.getWindows(for: app)

        guard !windows.isEmpty else {
            throw FocusError.noWindowsFound(applicationName)
        }

        let prioritizedWindows = self.prioritizeWindows(windows)

        // If window title specified, try to find a match
        if let title = windowTitle {
            if let matchingWindow = prioritizedWindows.first(where: { self.matchesWindow($0, title: title) })
                ?? windows.first(where: { self.matchesWindow($0, title: title) })
            {
                return matchingWindow.windowID
            }
            // If no match found, fall through to get frontmost
        }

        // Return the frontmost window (first in list)
        return prioritizedWindows.first?.windowID ?? windows.first?.windowID
    }

    // MARK: - Focus Operations

    /// Focus a window by its CGWindowID
    public func focusWindow(windowID: CGWindowID, options: FocusOptions = FocusOptions()) async throws {
        try await self.operationLaneCoordinator.run(scope: .global, access: .write) {
            try await self.focusWindowWithOwnedLane(windowID: windowID, options: options)
        }
    }

    func focusWindowWithOwnedLane(windowID: CGWindowID, options: FocusOptions = FocusOptions()) async throws {
        try await self.focusWindowWithOwnedLane(
            windowID: windowID,
            options: options,
            attachedDialog: nil)
    }

    /// Focus an exact parent window while accepting only its already-prepared modal descendant.
    ///
    /// Sheets frequently become the application's AX focused window even though callers selected
    /// the owning document window by its WindowServer ID. This overload is deliberately internal
    /// and dialog-specific so ordinary coordinate/keyboard focus never broadens to another window
    /// in the process.
    func focusDialogWindowWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        dialog: Element,
        options: FocusOptions = FocusOptions()) async throws
    {
        try await self.focusWindowWithOwnedLane(
            windowID: CGWindowID(target.identity.windowID),
            options: options,
            attachedDialog: AttachedDialogFocusReceipt(
                parentIdentity: target.identity,
                parentBounds: target.bounds,
                dialog: dialog))
    }

    /// Verify an already-focused exact dialog without activating, raising, or changing Spaces.
    func requireDialogWindowFocusWithOwnedLane(
        target: UIAutomationTarget.ExactWindow,
        dialog: Element,
        timeout: TimeInterval) async throws
    {
        let windowID = CGWindowID(target.identity.windowID)
        guard self.windowIdentityService.windowExists(windowID: windowID),
              SystemIdentityResolver.validateWindowMutationIdentity(
                  target.identity,
                  expectedBounds: target.bounds),
              let handle = self.windowIdentityService.findWindow(
                  byID: windowID,
                  messagingTimeout: Float(min(timeout, 0.5)))
        else {
            throw FocusError.windowNotFound(windowID)
        }
        try await self.verifyWindowFocus(
            handle.element,
            windowID: windowID,
            timeout: timeout,
            attachedDialog: AttachedDialogFocusReceipt(
                parentIdentity: target.identity,
                parentBounds: target.bounds,
                dialog: dialog))
    }

    /// Perform the final non-mutating focus check immediately before global keyboard delivery.
    func requireDialogDispatchFocus(
        target: UIAutomationTarget.ExactWindow,
        retainedWindow: Element,
        dialog: Element,
        field: Element) throws
    {
        let windowID = CGWindowID(target.identity.windowID)
        guard SystemIdentityResolver.validateWindowMutationIdentity(
            target.identity,
            expectedBounds: target.bounds),
            let currentWindow = self.windowIdentityService.findWindow(
                byID: windowID,
                messagingTimeout: 0.1),
            let ownerPID = currentWindow.element.pid(),
            ownerPID == target.identity.ownerProcessIdentifier,
            let runningApp = NSRunningApplication(processIdentifier: ownerPID),
            let focusedWindow = self.focusedWindow(for: runningApp, timeout: 0.1),
            let focusedElement = self.focusedElement(for: runningApp, timeout: 0.1)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
        let focusedWindowID = self.windowIdentityService.getWindowID(
            from: focusedWindow,
            messagingTimeout: 0.1)
        let observation = DialogDispatchFocusObservation(
            currentProcessStartIdentity: SystemIdentityResolver.processStartIdentity(ownerPID),
            focusedWindowPID: focusedWindow.pid(),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focusedWindowID: focusedWindowID.map(Int.init),
            retainedParentMatches: DialogService.sameElement(currentWindow.element, retainedWindow),
            focusedWindowMatchesPreparedDialog: DialogService.sameElement(focusedWindow, dialog),
            preparedDialogIsStructural: DialogElementClassifier.isStructuralDialog(
                DialogElementClassifier.evidence(for: dialog)),
            preparedDialogAttachedToParent: DialogService.rawElementPresence(
                dialog,
                in: currentWindow.element) == .present,
            focusedElementPID: focusedElement.pid(),
            focusedElementMatchesRetainedField: DialogService.sameElement(focusedElement, field),
            retainedFieldAttachedToDialog: DialogService.rawElementPresence(
                field,
                in: dialog) == .present)
        guard Self.isVerifiedDialogDispatchFocus(
            expectedParent: target.identity,
            observation: observation)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
    }

    /// Perform the final synchronous focus proof immediately before a global dialog key event.
    /// Callers must not suspend between this check and dispatch.
    func requireDialogGlobalKeyboardFocus(
        target: UIAutomationTarget.ExactWindow,
        retainedWindow: Element,
        dialog: Element) throws
    {
        let windowID = CGWindowID(target.identity.windowID)
        guard SystemIdentityResolver.validateWindowMutationIdentity(
            target.identity,
            expectedBounds: target.bounds),
            let currentWindow = self.windowIdentityService.findWindow(
                byID: windowID,
                messagingTimeout: 0.1),
            DialogService.sameElement(currentWindow.element, retainedWindow),
            let ownerPID = currentWindow.element.pid(),
            ownerPID == target.identity.ownerProcessIdentifier,
            let runningApp = NSRunningApplication(processIdentifier: ownerPID),
            let focusedWindow = self.focusedWindow(for: runningApp, timeout: 0.1)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
        let observation = AttachedDialogFocusObservation(
            currentProcessStartIdentity: SystemIdentityResolver.processStartIdentity(ownerPID),
            focusedWindowPID: focusedWindow.pid(),
            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            focusedWindowMatchesPreparedDialog: DialogService.sameElement(focusedWindow, dialog),
            preparedDialogIsStructural: DialogElementClassifier.isStructuralDialog(
                DialogElementClassifier.evidence(for: dialog)),
            preparedDialogAttachedToParent: DialogService.rawElementPresence(
                dialog,
                in: currentWindow.element) == .present)
        guard Self.isVerifiedAttachedDialogFocus(
            expectedParent: target.identity,
            observation: observation)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
    }

    private func focusWindowWithOwnedLane(
        windowID: CGWindowID,
        options: FocusOptions,
        attachedDialog: AttachedDialogFocusReceipt?) async throws
    {
        // Verify window exists before any focus work starts.
        guard self.windowIdentityService.windowExists(windowID: windowID) else {
            throw FocusError.windowNotFound(windowID)
        }

        if let attachedDialog,
           !SystemIdentityResolver.validateWindowMutationIdentity(
               attachedDialog.parentIdentity,
               expectedBounds: attachedDialog.parentBounds)
        {
            throw FocusError.focusVerificationFailed(windowID)
        }

        // Handle Space switching if needed.
        if options.switchSpace || options.bringToCurrentSpace {
            try await self.handleSpaceFocus(windowID: windowID, bringToCurrentSpace: options.bringToCurrentSpace)
        }

        // Resolve once to identify the owning app; AX handles can go stale after activation.
        guard let initialHandle = self.windowIdentityService.findWindow(byID: windowID) else {
            throw FocusError.axElementNotFound(windowID)
        }

        let runningApp = initialHandle.app.application

        if !runningApp.isActive {
            _ = runningApp.activate()
        }

        try await self.waitForCondition(
            timeout: 3.0,
            interval: 0.1,
            condition: {
                runningApp.isActive ||
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == runningApp.processIdentifier
            })

        guard let refreshedHandle = self.windowIdentityService.findWindow(byID: windowID, in: runningApp) ??
            self.windowIdentityService.findWindow(byID: windowID)
        else {
            throw FocusError.axElementNotFound(windowID)
        }

        if attachedDialog != nil {
            do {
                try await self.verifyWindowFocus(
                    refreshedHandle.element,
                    windowID: windowID,
                    timeout: min(options.timeout, 0.15),
                    attachedDialog: attachedDialog)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The prepared dialog is not focused yet; foreground consent permits the normal raise path.
            }
        }

        try await self.focusWindowElement(
            refreshedHandle.element,
            windowID: windowID,
            options: options,
            attachedDialog: attachedDialog)
    }

    // MARK: - Private Helpers

    private func handleSpaceFocus(windowID: CGWindowID, bringToCurrentSpace: Bool) async throws {
        if bringToCurrentSpace {
            // Move window to current Space
            try self.spaceService.moveWindowToCurrentSpace(windowID: windowID)
        } else {
            // Switch to window's Space
            try await self.spaceService.switchToWindowSpace(windowID: windowID)
        }

        // Give macOS time to complete the Space transition
        try await Task.sleep(nanoseconds: 500_000_000) // 0.5s
    }

    private func focusWindowElement(
        _ windowElement: Element,
        windowID: CGWindowID,
        options: FocusOptions,
        attachedDialog: AttachedDialogFocusReceipt?) async throws
    {
        var lastError: (any Error)?

        for attempt in 1...options.retryCount {
            // Chrome and other multi-window apps can raise a window without updating AXFocusedWindow.
            // Ask AX to make it main as well, then require both AX and Workspace to confirm the result.
            _ = windowElement.setValue(true, forAttribute: AXAttributeNames.kAXMainAttribute)
            do {
                try windowElement.performAction(.raise)
            } catch {
                // If raise action fails, try to make it main
                // Note: Setting main window through AX API requires finding parent app
                // This is handled by the activate() call above
            }

            // Verify focus
            do {
                try await self.verifyWindowFocus(
                    windowElement,
                    windowID: windowID,
                    timeout: options.timeout,
                    attachedDialog: attachedDialog)

                // Successfully focused window
                return
            } catch {
                lastError = error
                // Focus attempt failed: \(error.localizedDescription)

                if attempt < options.retryCount {
                    try await Task.sleep(nanoseconds: 500_000_000) // 0.5s between retries
                }
            }
        }

        throw lastError ?? FocusError.focusVerificationFailed(windowID)
    }

    private func verifyWindowFocus(
        _ windowElement: Element,
        windowID: CGWindowID,
        timeout: TimeInterval,
        attachedDialog: AttachedDialogFocusReceipt?) async throws
    {
        guard let ownerPID = Self.processIdentifier(for: windowElement.underlyingElement),
              let runningApp = NSRunningApplication(processIdentifier: ownerPID)
        else {
            throw FocusError.focusVerificationFailed(windowID)
        }
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let remainingTimeout = timeout - Date().timeIntervalSince(startTime)
            let isMinimized = windowElement.isMinimized() ?? false
            let focusedWindow = self.focusedWindow(
                for: runningApp,
                timeout: min(0.1, remainingTimeout))
            let focusedWindowID = focusedWindow.flatMap {
                self.windowIdentityService.getWindowID(
                    from: $0,
                    messagingTimeout: Float(min(0.1, remainingTimeout)))
            }
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let preparedGenerationMatches = attachedDialog.map {
                SystemIdentityResolver.processStartIdentity(ownerPID) == $0.parentIdentity.ownerProcessStartIdentity
            } ?? true

            if !isMinimized, preparedGenerationMatches, Self.isVerifiedParentWindowFocus(
                targetWindowID: windowID,
                ownerPID: ownerPID,
                focusedWindowID: focusedWindowID,
                frontmostPID: frontmostPID,
                hasAttachedDialog: attachedDialog != nil)
            {
                return
            }

            if !isMinimized,
               let attachedDialog,
               let focusedWindow,
               Self.isVerifiedAttachedDialogFocus(
                   expectedParent: attachedDialog.parentIdentity,
                   observation: AttachedDialogFocusObservation(
                       currentProcessStartIdentity: SystemIdentityResolver.processStartIdentity(ownerPID),
                       focusedWindowPID: focusedWindow.pid(),
                       frontmostPID: frontmostPID,
                       focusedWindowMatchesPreparedDialog: DialogService.sameElement(
                           focusedWindow,
                           attachedDialog.dialog),
                       preparedDialogIsStructural: DialogElementClassifier.isStructuralDialog(
                           DialogElementClassifier.evidence(for: attachedDialog.dialog)),
                       preparedDialogAttachedToParent: DialogService.rawElementPresence(
                           attachedDialog.dialog,
                           in: windowElement) == .present))
            {
                return
            }

            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        throw FocusError.focusVerificationTimeout(windowID)
    }

    nonisolated static func isVerifiedFocus(
        targetWindowID: CGWindowID,
        ownerPID: pid_t,
        focusedWindowID: CGWindowID?,
        frontmostPID: pid_t?) -> Bool
    {
        focusedWindowID == targetWindowID && frontmostPID == ownerPID
    }

    nonisolated static func isVerifiedParentWindowFocus(
        targetWindowID: CGWindowID,
        ownerPID: pid_t,
        focusedWindowID: CGWindowID?,
        frontmostPID: pid_t?,
        hasAttachedDialog: Bool) -> Bool
    {
        !hasAttachedDialog && self.isVerifiedFocus(
            targetWindowID: targetWindowID,
            ownerPID: ownerPID,
            focusedWindowID: focusedWindowID,
            frontmostPID: frontmostPID)
    }

    nonisolated static func isVerifiedAttachedDialogFocus(
        expectedParent: WindowMutationIdentity,
        observation: AttachedDialogFocusObservation) -> Bool
    {
        observation.currentProcessStartIdentity == expectedParent.ownerProcessStartIdentity &&
            observation.focusedWindowPID == expectedParent.ownerProcessIdentifier &&
            observation.frontmostPID == expectedParent.ownerProcessIdentifier &&
            observation.focusedWindowMatchesPreparedDialog &&
            observation.preparedDialogIsStructural &&
            observation.preparedDialogAttachedToParent
    }

    nonisolated static func isVerifiedDialogDispatchFocus(
        expectedParent: WindowMutationIdentity,
        observation: DialogDispatchFocusObservation) -> Bool
    {
        observation.currentProcessStartIdentity == expectedParent.ownerProcessStartIdentity &&
            observation.focusedWindowPID == expectedParent.ownerProcessIdentifier &&
            observation.frontmostPID == expectedParent.ownerProcessIdentifier &&
            observation.retainedParentMatches &&
            observation.preparedDialogIsStructural &&
            observation.preparedDialogAttachedToParent &&
            observation.focusedElementPID == expectedParent.ownerProcessIdentifier &&
            observation.focusedElementMatchesRetainedField &&
            observation.retainedFieldAttachedToDialog &&
            (observation.focusedWindowID == expectedParent.windowID ||
                observation.focusedWindowMatchesPreparedDialog)
    }

    private func focusedWindow(for app: NSRunningApplication, timeout: TimeInterval) -> Element? {
        guard timeout > 0 else { return nil }
        let axApp = AXApp(app)
        return try? AXChildWindowMessagingTimeout.performChecked(
            on: axApp.element,
            timeout: Float(timeout),
            operation: { _ in axApp.focusedWindow() })
    }

    private func focusedElement(for app: NSRunningApplication, timeout: TimeInterval) -> Element? {
        guard timeout > 0 else { return nil }
        let axApp = AXApp(app)
        return try? AXChildWindowMessagingTimeout.performChecked(
            on: axApp.element,
            timeout: Float(timeout),
            operation: { $0.focusedUIElement() })
    }

    nonisolated static func processIdentifier(for element: AXUIElement) -> pid_t? {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(element, &processIdentifier) == .success,
              processIdentifier > 0
        else {
            return nil
        }
        return processIdentifier
    }

    private func prioritizeWindows(_ windows: [WindowIdentityInfo]) -> [WindowIdentityInfo] {
        let renderable = windows.filter(\.isRenderable)
        if !renderable.isEmpty {
            return renderable
        }
        return windows
    }

    private func matchesWindow(_ window: WindowIdentityInfo, title: String) -> Bool {
        guard let windowTitle = window.title, !windowTitle.isEmpty else { return false }
        return windowTitle.localizedCaseInsensitiveContains(title)
    }

    private func waitForCondition(
        timeout: TimeInterval,
        interval: TimeInterval,
        condition: () -> Bool) async throws
    {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if condition() {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        throw FocusError.timeoutWaitingForCondition
    }
}

// MARK: - Focus Errors

public enum FocusError: LocalizedError {
    case applicationNotRunning(String)
    case noWindowsFound(String)
    case windowNotFound(CGWindowID)
    case axElementNotFound(CGWindowID)
    case focusVerificationFailed(CGWindowID)
    case focusVerificationTimeout(CGWindowID)
    case timeoutWaitingForCondition

    public var errorDescription: String? {
        switch self {
        case let .applicationNotRunning(name):
            "Application '\(name)' is not running"
        case let .noWindowsFound(name):
            "No windows found for application '\(name)'"
        case let .windowNotFound(id):
            "Window with ID \(id) not found"
        case let .axElementNotFound(id):
            "Could not find accessibility element for window ID \(id)"
        case let .focusVerificationFailed(id):
            "Failed to verify focus for window ID \(id)"
        case let .focusVerificationTimeout(id):
            "Timeout while verifying focus for window ID \(id)"
        case .timeoutWaitingForCondition:
            "Timeout while waiting for condition"
        }
    }
}
