import AppKit
@preconcurrency import AXorcist
import CoreGraphics
import Foundation
import os.log
import PeekabooFoundation

/// Resolves the application and AX window that should provide detection elements.
@MainActor
struct ElementDetectionWindowResolver {
    enum ApplicationIdentifierSource: String, Equatable, Sendable {
        case bundlePath = "bundle path"
        case executablePath = "executable path"
        case bundleIdentifier = "bundle ID"
        case applicationName = "application selector"
    }

    enum ApplicationResolutionAuthority: Equatable, Sendable {
        case processIdentifier(pid_t)
        case exactWindow(Int)
        case identifier(String, source: ApplicationIdentifierSource)
        case frontmost
    }

    private let logger = Logger(subsystem: "boo.peekaboo.core", category: "ElementDetectionWindowResolver")
    private let applicationService: ApplicationService
    private let windowIdentityService = WindowIdentityService()
    private let windowManagementService = WindowManagementService()
    private let exactWindowIdentityProvider: (CGWindowID) -> SystemWindowIdentity?
    private let processStartIdentityProvider: (pid_t) -> UInt64?

    init(
        applicationService: ApplicationService,
        exactWindowIdentityProvider: @escaping (CGWindowID) -> SystemWindowIdentity? =
            SystemIdentityResolver.windowIdentity,
        processStartIdentityProvider: @escaping (pid_t) -> UInt64? =
            SystemIdentityResolver.processStartIdentity)
    {
        self.applicationService = applicationService
        self.exactWindowIdentityProvider = exactWindowIdentityProvider
        self.processStartIdentityProvider = processStartIdentityProvider
    }

    func resolveApplication(windowContext: WindowContext?) async throws -> NSRunningApplication {
        let runningApplication: NSRunningApplication
        switch Self.applicationResolutionAuthority(for: windowContext) {
        case let .processIdentifier(pid):
            if let runningApp = NSRunningApplication(processIdentifier: pid) {
                self.logger.debug("Resolved application via PID: \(pid)")
                runningApplication = runningApp
            } else {
                self.logger.error("Could not resolve NSRunningApplication for PID: \(pid)")
                throw PeekabooError.appNotFound("PID:\(pid)")
            }
        case let .exactWindow(windowID):
            guard let processIdentifier = Self.stableExactWindowOwner(
                windowID: windowID,
                receipt: windowContext?.windowMutationIdentity,
                windowIdentityProvider: self.exactWindowIdentityProvider,
                processStartIdentityProvider: self.processStartIdentityProvider),
                let runningApp = NSRunningApplication(processIdentifier: processIdentifier)
            else {
                throw PeekabooError.windowNotFound(criteria: "live owner for exact window id \(windowID)")
            }
            self.logger.debug("Resolved application via exact window \(windowID), PID: \(processIdentifier)")
            runningApplication = runningApp
        case let .identifier(identifier, source):
            runningApplication = try await self.resolveRunningApplication(
                identifier: identifier,
                source: source.rawValue)
        case .frontmost:
            guard let frontmost = NSWorkspace.shared.frontmostApplication else {
                self.logger.error("No frontmost application")
                throw PeekabooError.operationError(message: "No frontmost application")
            }
            runningApplication = frontmost
        }

        let candidate = ApplicationIdentifierMatcher.Candidate(
            processIdentifier: runningApplication.processIdentifier,
            bundleIdentifier: runningApplication.bundleIdentifier,
            name: runningApplication.localizedName ?? runningApplication.bundleIdentifier ?? "Unknown",
            bundlePath: runningApplication.bundleURL?.standardizedFileURL.path,
            executablePath: runningApplication.executableURL?.standardizedFileURL.path,
            allowsFuzzyMatching: runningApplication.activationPolicy != .prohibited,
            isRegularApplication: runningApplication.activationPolicy == .regular)
        if let mismatch = Self.applicationConstraintMismatch(candidate: candidate, context: windowContext) {
            throw PeekabooError.invalidInput(field: "windowContext", reason: mismatch)
        }
        return runningApplication
    }

    nonisolated static func applicationResolutionAuthority(
        for context: WindowContext?) -> ApplicationResolutionAuthority
    {
        guard let context else { return .frontmost }
        if let processIdentifier = context.applicationProcessId {
            return .processIdentifier(processIdentifier)
        }
        if let windowID = context.windowID {
            return .exactWindow(windowID)
        }
        if let bundlePath = context.applicationBundlePath {
            return .identifier(bundlePath, source: .bundlePath)
        }
        if let executablePath = context.applicationExecutablePath {
            return .identifier(executablePath, source: .executablePath)
        }
        if let bundleIdentifier = context.applicationBundleId {
            return .identifier(bundleIdentifier, source: .bundleIdentifier)
        }
        if let applicationName = context.applicationName {
            return .identifier(applicationName, source: .applicationName)
        }
        return .frontmost
    }

    private func resolveRunningApplication(identifier: String, source: String) async throws -> NSRunningApplication {
        self.logger.debug("Looking for application via \(source): \(identifier)")
        let appInfo = try await self.applicationService.findApplication(identifier: identifier)
        guard let runningApplication = NSRunningApplication(processIdentifier: appInfo.processIdentifier) else {
            self.logger.error("Could not get NSRunningApplication for PID: \(appInfo.processIdentifier)")
            throw PeekabooError.appNotFound(identifier)
        }
        self.logger.debug("Resolved application: \(runningApplication.localizedName ?? "unknown")")
        return runningApplication
    }

    nonisolated static func applicationConstraintMismatch(
        candidate: ApplicationIdentifierMatcher.Candidate,
        context: WindowContext?) -> String?
    {
        guard let context else { return nil }
        if let processIdentifier = context.applicationProcessId,
           processIdentifier != candidate.processIdentifier
        {
            return "applicationProcessId contradicts the resolved application"
        }
        if let bundleIdentifier = context.applicationBundleId,
           bundleIdentifier != candidate.bundleIdentifier
        {
            return "applicationBundleId contradicts the resolved application"
        }
        if let applicationName = context.applicationName,
           !ApplicationIdentifierMatcher.matches(candidate, identifier: applicationName)
        {
            return "applicationName contradicts the resolved application"
        }
        if let bundlePath = context.applicationBundlePath,
           bundlePath != candidate.bundlePath
        {
            return "applicationBundlePath contradicts the resolved application"
        }
        if let executablePath = context.applicationExecutablePath,
           executablePath != candidate.executablePath
        {
            return "applicationExecutablePath contradicts the resolved application"
        }
        return nil
    }

    nonisolated static func stableExactWindowOwner(
        windowID: Int,
        receipt: WindowMutationIdentity?,
        windowIdentityProvider: (CGWindowID) -> SystemWindowIdentity?,
        processStartIdentityProvider: (pid_t) -> UInt64?) -> pid_t?
    {
        guard windowID > 0,
              let cgWindowID = CGWindowID(exactly: windowID),
              let before = windowIdentityProvider(cgWindowID),
              let beforeGeneration = processStartIdentityProvider(before.ownerProcessIdentifier),
              let after = windowIdentityProvider(cgWindowID),
              let afterGeneration = processStartIdentityProvider(after.ownerProcessIdentifier),
              before.windowID == cgWindowID,
              after.windowID == cgWindowID,
              before.ownerProcessIdentifier == after.ownerProcessIdentifier,
              before.bounds == after.bounds,
              beforeGeneration == afterGeneration
        else {
            return nil
        }
        if let receipt {
            guard receipt.windowID == windowID,
                  receipt.ownerProcessIdentifier == before.ownerProcessIdentifier,
                  receipt.ownerProcessStartIdentity == beforeGeneration,
                  receipt.capturedBounds == nil || receipt.capturedBounds == before.bounds
            else {
                return nil
            }
        }
        return before.ownerProcessIdentifier
    }

    func resolveWindow(
        for app: NSRunningApplication,
        context: WindowContext?) async throws -> WindowResolution
    {
        let appElement = AXApp(app).element

        if let windowID = context?.windowID {
            guard windowID > 0, let cgWindowID = CGWindowID(exactly: windowID) else {
                throw PeekabooError.invalidInput(
                    field: "windowID",
                    reason: "windowID must be a positive UInt32 value")
            }
            let identifier = app.localizedName ?? app.bundleIdentifier ?? "PID:\(app.processIdentifier)"
            guard SystemIdentityResolver.windowOwnerProcessIdentifier(cgWindowID) == app.processIdentifier else {
                throw PeekabooError.windowNotFound(criteria: "window id \(windowID) owned by \(identifier)")
            }

            let timeout = Float(min(max(context?.accessibilityTimeoutSeconds ?? 1, 0.05), 1))
            appElement.setMessagingTimeout(timeout)
            defer { appElement.setMessagingTimeout(0) }
            let matchingWindow = appElement.windowsWithTimeout(timeout: timeout)?.first { window in
                self.windowIdentityService.getWindowID(
                    from: window,
                    messagingTimeout: min(timeout, 0.25)) == cgWindowID
            }
            if let window = matchingWindow {
                window.setMessagingTimeout(min(timeout, 0.25))
                defer { window.setMessagingTimeout(0) }
                let title = window.title() ?? "Untitled"
                let identifier = app.localizedName ?? app.bundleIdentifier ?? "PID:\(app.processIdentifier)"
                self.logger.notice("Resolved window via CGWindowID \(windowID): '\(title)' for \(identifier)")

                let isDialog = DialogElementClassifier.isObservationDialog(
                    DialogElementClassifier.evidence(for: window))

                return WindowResolution(appElement: appElement, window: window, isDialog: isDialog)
            }

            throw PeekabooError.windowNotFound(criteria: "window id \(windowID) owned by \(identifier)")
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
            let evidence = DialogElementClassifier.evidence(for: window)

            guard DialogElementClassifier.isObservationDialog(evidence) else { continue }
            if let targetWindow, targetWindow.title() == window.title() {
                self.logger.info("🗨️ Target window is dialog-active: '\(title)' (subrole: \(evidence.subrole))")
                return DialogResolution(window: targetWindow, isDialog: true)
            }

            self.logger.info("🗨️ Using dialog-active window: '\(title)' (subrole: \(evidence.subrole))")
            return DialogResolution(window: window, isDialog: true)
        }
        return DialogResolution(window: targetWindow, isDialog: false)
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
