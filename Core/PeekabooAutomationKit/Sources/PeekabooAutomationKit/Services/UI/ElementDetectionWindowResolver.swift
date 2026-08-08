import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// Resolves the application and AX window that should provide detection elements.
@MainActor
struct ElementDetectionWindowResolver {
    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ElementDetectionWindowResolver")
    private let applicationService: ApplicationService
    private let windowIdentityService = WindowIdentityService()
    private let windowManagementService = WindowManagementService()

    init(applicationService: ApplicationService) {
        self.applicationService = applicationService
    }

    func resolveApplication(windowContext: WindowContext?) async throws -> NSRunningApplication {
        if let pid = windowContext?.applicationProcessId {
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                self.logger.debug("Resolved application via PID: \(pid)")
                return runningApp
            }
            self.logger.error("Could not resolve NSRunningApplication for PID: \(pid)")
            throw PeekabooError.appNotFound("PID:\(pid)")
        }

        if let bundleId = windowContext?.applicationBundleId {
            self.logger.debug("Looking for application via bundle ID: \(bundleId)")

            let appInfo = try await self.applicationService.findApplication(identifier: bundleId)

            guard let runningApp = NSRunningApplication(processIdentifier: appInfo.processIdentifier) else {
                self.logger.error("Could not get NSRunningApplication for PID: \(appInfo.processIdentifier)")
                throw PeekabooError.appNotFound(bundleId)
            }

            self.logger.debug("Resolved application: \(runningApp.localizedName ?? "unknown")")
            return runningApp
        }

        if let appName = windowContext?.applicationName {
            self.logger.debug("Looking for application via ApplicationService: \(appName)")

            let appInfo = try await self.applicationService.findApplication(identifier: appName)

            guard let runningApp = NSRunningApplication(processIdentifier: appInfo.processIdentifier) else {
                self.logger.error("Could not get NSRunningApplication for PID: \(appInfo.processIdentifier)")
                throw PeekabooError.appNotFound(appName)
            }

            self.logger.debug("Resolved application: \(runningApp.localizedName ?? "unknown")")
            return runningApp
        }

        guard let frontmost = NSWorkspace.shared.frontmostApplication else {
            self.logger.error("No frontmost application")
            throw PeekabooError.operationError(message: "No frontmost application")
        }
        return frontmost
    }

    func resolveWindow(
        for app: NSRunningApplication,
        context: WindowContext?) async throws -> WindowResolution
    {
        let appElement = AXApp(app).element

        if let windowID = context?.windowID {
            let cgWindowID = CGWindowID(windowID)
            if let handle = self.windowIdentityService.findWindow(byID: cgWindowID, in: app) ??
                self.windowIdentityService.findWindow(byID: cgWindowID)
            {
                let title = handle.element.title() ?? "Untitled"
                let identifier = app.localizedName ?? app.bundleIdentifier ?? "PID:\(app.processIdentifier)"
                self.logger.notice("Resolved window via CGWindowID \(windowID): '\(title)' for \(identifier)")

                let window = handle.element

                let subrole = window.subrole() ?? ""
                let isDialogRole = ["AXDialog", "AXSystemDialog", "AXSheet"].contains(subrole)
                let isFileDialog = self.isFileDialogTitle(window.title() ?? "")
                let isDialog = isDialogRole || isFileDialog

                return WindowResolution(appElement: appElement, window: window, isDialog: isDialog)
            }

            self.logger.warning(
                "Could not resolve window via CGWindowID \(windowID); falling back to title-based selection")
        }

        // Chrome and other multi-process apps occasionally return an empty window list unless we set
        // an explicit AX messaging timeout, so prefer the guarded helper.
        let axWindows = appElement.windowsWithTimeout() ?? []
        self.logger.debug("Found \(axWindows.count) windows for \(app.localizedName ?? "app")")

        let renderableWindows = self.renderableWindows(from: axWindows)
        let candidateWindows = renderableWindows.isEmpty ? axWindows : renderableWindows
        self.logger.notice("Renderable AX windows: \(renderableWindows.count) / \(axWindows.count)")

        let initialWindow = self.selectWindow(allWindows: candidateWindows, title: context?.windowTitle)
        let dialogResolution = self.detectDialogWindow(in: candidateWindows, targetWindow: initialWindow)

        var finalWindow = dialogResolution.window ??
            initialWindow ??
            candidateWindows.first { $0.isMain() == true } ??
            candidateWindows.first

        if finalWindow == nil {
            finalWindow = self.focusedWindowIfMatches(app: app)
        }

        // When AX window enumeration yields nothing, progressively fall back to CG metadata.
        if finalWindow == nil {
            finalWindow = await self.resolveWindowViaCGFallback(for: app, title: context?.windowTitle)
        }

        if finalWindow == nil {
            finalWindow = await self.resolveWindowViaWindowServiceFallback(for: app, title: context?.windowTitle)
        }

        guard let resolvedWindow = finalWindow else {
            try self.handleMissingWindow(app: app, windows: axWindows)
        }

        return WindowResolution(
            appElement: appElement,
            window: resolvedWindow,
            isDialog: dialogResolution.isDialog)
    }

    private func selectWindow(allWindows: [Element], title: String?) -> Element? {
        guard let title else { return nil }
        self.logger.debug("Looking for window with title: \(title)")
        return allWindows.first { window in
            window.title()?.localizedCaseInsensitiveContains(title) == true
        }
    }

    private func detectDialogWindow(in windows: [Element], targetWindow: Element?) -> DialogResolution {
        self.logger.debug("Checking \(windows.count) windows for dialog characteristics")
        for window in windows {
            let title = window.title() ?? ""
            let subrole = window.subrole() ?? ""
            let isFileDialog = self.isFileDialogTitle(title)
            let isDialogRole = ["AXDialog", "AXSystemDialog", "AXSheet"].contains(subrole)

            guard isFileDialog || isDialogRole else { continue }
            if let targetWindow, targetWindow.title() == window.title() {
                self.logger.info("🗨️ Target window is a dialog: '\(title)' (subrole: \(subrole))")
                return DialogResolution(window: targetWindow, isDialog: true)
            }

            self.logger.info("🗨️ Using dialog window: '\(title)' (subrole: \(subrole))")
            return DialogResolution(window: window, isDialog: true)
        }
        return DialogResolution(window: targetWindow, isDialog: false)
    }

    private func isFileDialogTitle(_ title: String) -> Bool {
        ["Open", "Save", "Export", "Import"].contains(title) || title.hasPrefix("Save As")
    }

    private func handleMissingWindow(app: NSRunningApplication, windows: [Element]) throws -> Never {
        let appName = app.localizedName ?? "Unknown app"
        if windows.isEmpty {
            self.logger.error("App '\(appName)' has no windows")
            throw PeekabooError
                .windowNotFound(criteria: "App '\(appName)' is running but has no windows or dialogs")
        }

        self.logger.error("No suitable window found for app '\(appName)'")
        throw PeekabooError.windowNotFound(criteria: "No accessible window found for '\(appName)'")
    }

    private func renderableWindows(from windows: [Element]) -> [Element] {
        windows.filter { window in
            guard
                let frame = window.frame(),
                frame.width >= 50,
                frame.height >= 50,
                window.isMinimized() != true
            else { return false }
            return true
        }
    }

    private func resolveWindowViaCGFallback(for app: NSRunningApplication, title: String?) async -> Element? {
        let cgWindows = self.windowIdentityService.getWindows(for: app)
        guard !cgWindows.isEmpty else {
            self.logger.notice("CG fallback found 0 windows for \(app.localizedName ?? "app")")
            return nil
        }

        let renderable = cgWindows.filter(\.isRenderable)
        let orderedWindows = (renderable.isEmpty ? cgWindows : renderable)
            .sorted { $0.bounds.size.area > $1.bounds.size.area }
        self.logger.notice("CG fallback renderable windows: \(renderable.count) / \(cgWindows.count)")

        if let title {
            if let matching = orderedWindows.first(where: {
                $0.title?.localizedCaseInsensitiveContains(title) == true
            }), let element = self.windowIdentityService.findWindow(byID: matching.windowID)?.element {
                let fallbackTarget = app.localizedName ?? "app"
                let fallbackTitle = matching.title ?? "Untitled"
                self.logger.info("Using CG fallback window '\(fallbackTitle)' for \(fallbackTarget)")
                return element
            }
        }

        for info in orderedWindows {
            if let element = self.windowIdentityService.findWindow(byID: info.windowID)?.element {
                let fallbackTarget = app.localizedName ?? "app"
                let fallbackTitle = info.title ?? "Untitled"
                self.logger.info("Using CG fallback window '\(fallbackTitle)' for \(fallbackTarget)")
                return element
            }
        }

        return nil
    }

    /// Fallback #3: ask the window-management service, which already talks to CG+AX, for candidates.
    private func resolveWindowViaWindowServiceFallback(
        for app: NSRunningApplication,
        title: String?) async -> Element?
    {
        let identifier = app.localizedName ?? app.bundleIdentifier ?? "PID:\(app.processIdentifier)"
        do {
            let windows = try await self.windowManagementService.listWindows(target: .application(identifier))
            guard !windows.isEmpty else {
                self.logger.notice("Window service fallback found 0 windows for \(identifier)")
                return nil
            }

            self.logger.notice("Window service fallback inspecting \(windows.count) windows for \(identifier)")

            let ordered = windows.sorted { lhs, rhs in
                let lArea = lhs.bounds.size.area
                let rArea = rhs.bounds.size.area
                return lArea > rArea
            }

            let targetWindowInfo: ServiceWindowInfo? = if let title,
                                                          let match = ordered
                                                              .first(where: {
                                                                  $0.title.localizedCaseInsensitiveContains(title)
                                                              })
            {
                match
            } else {
                ordered.first
            }

            guard let windowInfo = targetWindowInfo,
                  let element = self.windowIdentityService.findWindow(byID: CGWindowID(windowInfo.windowID))?.element
            else {
                self.logger.warning("Window service fallback could not resolve AX window for \(identifier)")
                return nil
            }

            self.logger.notice("Using window service fallback window '\(windowInfo.title)' for \(identifier)")
            return element
        } catch {
            self.logger.error("Window service fallback failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func focusedWindowIfMatches(app: NSRunningApplication) -> Element? {
        let systemWide = Element.systemWide()
        guard let focusedWindow = systemWide.focusedWindow(),
              let pid = focusedWindow.pid()
        else {
            return nil
        }

        if pid != app.processIdentifier {
            guard
                let ownerApp = NSRunningApplication(processIdentifier: pid),
                ownerApp.bundleIdentifier == app.bundleIdentifier
            else {
                return nil
            }
        }

        self.logger.notice("Using focused window fallback for \(app.localizedName ?? "app")")
        return focusedWindow
    }
}

struct WindowResolution {
    let appElement: Element
    let window: Element
    let isDialog: Bool

    var windowTypeDescription: String {
        self.isDialog ? "dialog" : "window"
    }
}

private struct DialogResolution {
    let window: Element?
    let isDialog: Bool
}

extension CGSize {
    fileprivate var area: CGFloat {
        width * height
    }
}
