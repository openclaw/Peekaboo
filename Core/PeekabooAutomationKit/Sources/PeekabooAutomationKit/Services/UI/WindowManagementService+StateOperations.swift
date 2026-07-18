import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension WindowManagementService {
    public func closeWindow(target: WindowTarget) async throws {
        let trackedWindowID = try? await self.listWindows(target: target).first?.windowID
        try Task.checkCancellation()
        let trackedAppIdentifier = self.appIdentifierForPresenceTracking(target)
        var windowBounds: CGRect?
        var closeButtonFrame: CGRect?

        let success = try await performWindowOperation(target: target) { window in
            if let closeButton = window.closeButton() {
                closeButtonFrame = closeButton.frame()
            }

            if let position = window.position(), let size = window.size() {
                windowBounds = CGRect(origin: position, size: size)
            }

            let result = window.closeWindow()
            self.showWindowOperation(.close, bounds: windowBounds)
            return result
        }
        try Task.checkCancellation()

        if !success {
            throw OperationError.interactionFailed(
                action: "close window",
                reason: "Window close operation failed")
        }

        guard let trackedWindowID else { return }

        if try await self.windowDisappeared(windowID: trackedWindowID, appIdentifier: trackedAppIdentifier) {
            return
        }

        try Task.checkCancellation()
        self.logger
            .warning("Close succeeded but window still exists; trying hotkey fallbacks. windowID=\(trackedWindowID)")

        // Make the target key before Cmd-W fallbacks; otherwise the frontmost window may close.
        try Task.checkCancellation()
        _ = try? await self.performWindowOperation(target: target) { window in
            _ = window.focusWindow()
            return ()
        }

        try Task.checkCancellation()
        try? InputDriver.hotkey(keys: ["cmd", "w"], holdDuration: 0.05)
        if try await self.windowDisappeared(windowID: trackedWindowID, appIdentifier: trackedAppIdentifier) {
            return
        }

        try Task.checkCancellation()
        try? InputDriver.hotkey(keys: ["cmd", "shift", "w"], holdDuration: 0.05)
        if try await self.windowDisappeared(windowID: trackedWindowID, appIdentifier: trackedAppIdentifier) {
            return
        }

        if let closeButtonFrame {
            try Task.checkCancellation()
            self.logger.warning(
                "Hotkey fallbacks failed; clicking close button frame as final fallback. windowID=\(trackedWindowID)")
            try Task.checkCancellation()
            try? InputDriver.click(at: CGPoint(x: closeButtonFrame.midX, y: closeButtonFrame.midY))

            if try await self.windowDisappeared(windowID: trackedWindowID, appIdentifier: trackedAppIdentifier) {
                return
            }
        }

        throw OperationError.interactionFailed(
            action: "close window",
            reason: "Close action completed but window remained visible (windowID=\(trackedWindowID))")
    }

    public func minimizeWindow(target: WindowTarget) async throws {
        var windowBounds: CGRect?

        let success = try await performWindowOperation(target: target) { window in
            if let position = window.position(), let size = window.size() {
                windowBounds = CGRect(origin: position, size: size)
            }

            let result = window.minimizeWindow()
            self.showWindowOperation(.minimize, bounds: windowBounds)
            return result
        }

        if !success {
            throw OperationError.interactionFailed(
                action: "minimize window",
                reason: "Window minimize operation failed")
        }
    }

    public func maximizeWindow(target: WindowTarget) async throws {
        var windowBounds: CGRect?

        let success = try await performWindowOperation(target: target) { window in
            if let position = window.position(), let size = window.size() {
                windowBounds = CGRect(origin: position, size: size)
            }

            let result = window.maximizeWindow()
            self.showWindowOperation(.maximize, bounds: windowBounds)
            return result
        }

        if !success {
            throw OperationError.interactionFailed(
                action: "maximize window",
                reason: "Window maximize operation failed")
        }
    }

    public func focusWindow(target: WindowTarget) async throws {
        self.logger.info("Attempting to focus window with target: \(target)")
        self.logger.debug("WindowManagementService.focusWindow called with target: \(target)")

        let window = try await self.element(for: target)
        let windowBounds = window.position().map { position in
            CGRect(origin: position, size: window.size() ?? .zero)
        }

        let success: Bool
        if let windowID = self.windowIdentityService.getWindowID(from: window) {
            let focusService = FocusManagementService(applications: self.applicationService)
            try await focusService.focusWindow(windowID: windowID)
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
                "The window may be minimized, on another Space, or the app may not be responding to focus requests.",
            ].joined(separator: " ")
            throw OperationError.interactionFailed(action: "focus window", reason: reason)
        }
    }

    func showWindowOperation(_ operation: WindowOperationKind, bounds: CGRect?) {
        guard let bounds else { return }

        Task {
            _ = await self.feedbackClient.showWindowOperation(operation, windowRect: bounds, duration: 0.5)
        }
    }

    private func appIdentifierForPresenceTracking(_ target: WindowTarget) -> String? {
        switch target {
        case let .application(appIdentifier),
             let .applicationAndTitle(appIdentifier, _),
             let .index(appIdentifier, _):
            appIdentifier
        default:
            nil
        }
    }

    private func windowDisappeared(windowID: Int, appIdentifier: String?) async throws -> Bool {
        try await self.waitForWindowToDisappear(
            windowID: windowID,
            appIdentifier: appIdentifier,
            timeoutSeconds: 3.0)
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
