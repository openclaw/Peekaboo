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

// MARK: - Focus Options Protocol

public protocol FocusOptionsProtocol {
    var autoFocus: Bool { get }
    var focusTimeout: TimeInterval? { get }
    var focusRetryCount: Int? { get }
    var spaceSwitch: Bool { get }
    var bringToCurrentSpace: Bool { get }
}

// MARK: - Default Focus Options

public struct DefaultFocusOptions: FocusOptionsProtocol {
    public let autoFocus: Bool = true
    public let focusTimeout: TimeInterval? = 5.0
    public let focusRetryCount: Int? = 3
    public let spaceSwitch: Bool = true
    public let bringToCurrentSpace: Bool = false

    public init() {}
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

    public init(applications: (any ApplicationServiceProtocol)? = nil) {
        self.applications = applications ?? ApplicationService()
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
        // Verify window exists before any focus work starts.
        guard self.windowIdentityService.windowExists(windowID: windowID) else {
            throw FocusError.windowNotFound(windowID)
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

        if let appIdentifier = runningApp.bundleIdentifier ?? runningApp.localizedName {
            try? await self.applications.activateApplication(identifier: appIdentifier)
        }

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

        try await self.focusWindowElement(refreshedHandle.element, windowID: windowID, options: options)
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
        options: FocusOptions) async throws
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
                try await self.verifyWindowFocus(windowElement, windowID: windowID, timeout: options.timeout)

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
        timeout: TimeInterval) async throws
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
            let focusedWindowID = self.windowIdentityService.focusedWindowID(
                for: runningApp,
                timeout: min(0.1, remainingTimeout))
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

            if !isMinimized, Self.isVerifiedFocus(
                targetWindowID: windowID,
                ownerPID: ownerPID,
                focusedWindowID: focusedWindowID,
                frontmostPID: frontmostPID)
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
