import AppKit
import AXorcist
import Foundation

@MainActor
extension DialogService {
    struct FileDialogElementResolution {
        let element: Element
        let dialogIdentifier: String
        let foundVia: String
        let target: UIAutomationTarget.ExactWindow
    }

    func resolveDialogElement(windowTitle: String?, appName: String?) async throws -> Element {
        if let appName, !appName.isEmpty {
            self.logger.debug("Resolving dialog with app hint: \(appName)")
        }
        if let element = try self.findDialogElementIfAvailable(withTitle: windowTitle, appName: appName) {
            return element
        }

        if windowTitle != nil {
            await self.ensureDialogVisibility(windowTitle: windowTitle, appName: appName)
            if let element = try self.findDialogElementIfAvailable(withTitle: windowTitle, appName: appName) {
                return element
            }

            if let element = await self.findDialogViaApplicationService(windowTitle: windowTitle, appName: appName) {
                return element
            }
        }

        throw DialogError.noActiveDialog
    }

    func resolveFileDialogElementResolution(appName: String?) async throws
    -> FileDialogElementResolution {
        if let appName,
           let fileDialog = self.findActiveFileDialogElement(appName: appName)
        {
            return try await self.fileDialogElementResolution(
                element: fileDialog,
                dialogIdentifier: self.dialogIdentifier(for: fileDialog),
                foundVia: "active_file_dialog")
        }

        let resolved = try await self.resolveDialogElementResolution(windowTitle: nil, appName: appName)
        guard self.isFileDialogElement(resolved.element) else {
            throw DialogError.noFileDialog
        }

        return try await self.fileDialogElementResolution(
            element: resolved.element,
            dialogIdentifier: resolved.dialogIdentifier,
            foundVia: resolved.foundVia)
    }

    private func fileDialogElementResolution(
        element: Element,
        dialogIdentifier: String,
        foundVia: String) async throws -> FileDialogElementResolution
    {
        let target = try await self.exactFileDialogTarget(for: element)
        return FileDialogElementResolution(
            element: element,
            dialogIdentifier: dialogIdentifier,
            foundVia: foundVia,
            target: target)
    }

    private func exactFileDialogTarget(for dialog: Element) async throws -> UIAutomationTarget.ExactWindow {
        guard let processIdentifier = dialog.pid(), processIdentifier > 0,
              let windowID = self.windowIdentityService.getWindowID(
                  from: dialog,
                  messagingTimeout: self.targetedDialogSearchTimeout)
        else {
            throw self.targetUnavailable("File dialog has no exact owning window receipt.")
        }

        let application = try await self.applicationService.findApplication(
            identifier: "PID:\(processIdentifier)")
        guard let processIdentity = application.processIdentity,
              processIdentity.processIdentifier == processIdentifier
        else {
            throw self.targetUnavailable("File dialog owner has no stable process-generation receipt.")
        }

        let response = try await self.applicationService.listWindows(
            for: "PID:\(processIdentifier)",
            timeout: self.targetedDialogSearchTimeout)
        let matches = response.data.windows.filter { $0.windowID == Int(windowID) }
        guard matches.count == 1, let window = matches.first,
              let identity = window.mutationIdentity,
              identity.processIdentity == processIdentity,
              identity.windowID == window.windowID,
              identity.capturedBounds == window.bounds,
              let handle = self.windowIdentityService.findWindow(
                  byID: windowID,
                  messagingTimeout: self.targetedDialogSearchTimeout),
              handle.element.pid() == processIdentifier
        else {
            throw self.targetUnavailable("File dialog owning window receipt is incomplete or ambiguous.")
        }

        let currentDialogs = self.freshDialogElements(in: handle.element)
        let retainedMatches = (currentDialogs.structural + currentDialogs.legacy).filter {
            Self.sameElement($0, dialog)
        }
        guard currentDialogs.readable,
              retainedMatches.count == 1,
              retainedMatches.first.map(self.isFileDialogElement) == true
        else {
            throw self.targetUnavailable("File dialog changed while retaining its exact owning window.")
        }

        let currentApplication = try await self.applicationService.findApplication(
            identifier: "PID:\(processIdentifier)")
        guard currentApplication.processIdentity == processIdentity else {
            throw self.targetUnavailable("File dialog owner changed process generation during planning.")
        }
        return try UIAutomationTarget.ExactWindow(window: window)
    }

    private func findDialogElement(withTitle title: String?, appName: String?) throws -> Element {
        self.logger.debug("Finding dialog element")

        let systemWide = Element.systemWide()

        if let focusedElement = systemWide.attribute(Attribute<Element>("AXFocusedUIElement")),
           let hostingWindow = focusedElement.attribute(Attribute<Element>("AXWindow")),
           let candidate = self.resolveDialogCandidate(in: hostingWindow, matching: title)
        {
            return candidate
        }

        if let focusedWindow = systemWide.attribute(Attribute<Element>("AXFocusedWindow")),
           let focusedCandidate = self.resolveDialogCandidate(in: focusedWindow, matching: title)
        {
            return focusedCandidate
        }

        var focusedAppElement: Element? = systemWide.attribute(Attribute<Element>("AXFocusedApplication")) ?? {
            if let frontmost = NSWorkspace.shared.frontmostApplication {
                return AXApp(frontmost).element
            }
            return nil
        }()

        // Always prefer an explicit app hint over whatever currently has system-wide focus.
        if let appName,
           let targetApp = self.runningApplication(matching: appName)
        {
            focusedAppElement = AXApp(targetApp).element
        }

        guard let focusedApp = focusedAppElement else {
            self.logger.error("No focused application found")
            throw DialogError.noActiveDialog
        }

        let windowSearchTimeout = self.dialogWindowSearchTimeout(title: title, appName: appName)
        let windows = try self.dialogWindowCandidates(in: focusedApp, title: title, appName: appName)
        self.logger.debug("Checking \(windows.count) windows for dialogs")

        for window in windows {
            if let candidate = self.resolveDialogCandidate(in: window, matching: title) {
                return candidate
            }
        }

        if title != nil {
            if let globalWindows = try AXChildWindowMessagingTimeout.performChecked(
                on: systemWide,
                timeout: windowSearchTimeout,
                operation: { $0.windows() })
            {
                for window in globalWindows {
                    if let candidate = self.resolveDialogCandidate(in: window, matching: title) {
                        return candidate
                    }
                }
            }
        }

        if self.scansAllApplicationsForDialogs {
            for app in NSWorkspace.shared.runningApplications {
                let axApp = AXApp(app).element
                let appWindows = try AXChildWindowMessagingTimeout.performChecked(
                    on: axApp,
                    timeout: windowSearchTimeout,
                    operation: { $0.windows() }) ?? []
                for window in appWindows {
                    if let candidate = self.resolveDialogCandidate(in: window, matching: title) {
                        return candidate
                    }
                }
            }
        }

        if title != nil, let cgCandidate = self.findDialogUsingCGWindowList(title: title) {
            return cgCandidate
        }

        throw DialogError.noActiveDialog
    }

    private func dialogWindowSearchTimeout(title: String?, appName: String?) -> Float {
        title != nil || appName != nil ? self.targetedDialogSearchTimeout : self.activeDialogSearchTimeout
    }

    private func dialogWindowCandidates(in app: Element, title: String?, appName: String?) throws -> [Element] {
        let timeout = self.dialogWindowSearchTimeout(title: title, appName: appName)

        // Without a title, an app-scoped command is still looking for the active dialog, not every dialog-like
        // subtree in the app. Checking focused/main windows keeps "no dialog" responses bounded for Electron/Tauri.
        if appName != nil, title == nil {
            return try AXChildWindowMessagingTimeout.performChecked(on: app, timeout: timeout) { boundedApp in
                [
                    boundedApp.focusedWindow(),
                    boundedApp.mainWindow(),
                ].compactMap(\.self)
            }
        }

        return try AXChildWindowMessagingTimeout.performChecked(
            on: app,
            timeout: timeout,
            operation: { $0.windows() }) ?? []
    }

    private func findDialogElementIfAvailable(withTitle title: String?, appName: String?) throws -> Element? {
        do {
            return try self.findDialogElement(withTitle: title, appName: appName)
        } catch DialogError.noActiveDialog {
            return nil
        }
    }

    func dialogIdentifier(for element: Element) -> String {
        let role = element.role() ?? "unknown"
        let subrole = element.subrole() ?? ""
        let title = element.title() ?? "Untitled Dialog"
        let axIdentifier = element.attribute(Attribute<String>("AXIdentifier")) ?? ""

        return [role, subrole, axIdentifier, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "|")
    }

    private func resolveDialogElementResolution(
        windowTitle: String?,
        appName: String?) async throws -> (element: Element, dialogIdentifier: String, foundVia: String)
    {
        if let appName, !appName.isEmpty {
            self.logger.debug("Resolving dialog with app hint: \(appName)")
        }

        if let element = try self.findDialogElementIfAvailable(withTitle: windowTitle, appName: appName) {
            return (
                element: element,
                dialogIdentifier: self.dialogIdentifier(for: element),
                foundVia: "find_dialog_element")
        }

        if windowTitle != nil {
            await self.ensureDialogVisibility(windowTitle: windowTitle, appName: appName)
            if let element = try self.findDialogElementIfAvailable(withTitle: windowTitle, appName: appName) {
                return (
                    element: element,
                    dialogIdentifier: self.dialogIdentifier(for: element),
                    foundVia: "ensure_visibility_then_find")
            }

            if let element = await self.findDialogViaApplicationService(windowTitle: windowTitle, appName: appName) {
                return (
                    element: element,
                    dialogIdentifier: self.dialogIdentifier(for: element),
                    foundVia: "application_service")
            }
        }

        throw DialogError.noActiveDialog
    }

    func resolveDialogCandidate(in element: Element, matching title: String?) -> Element? {
        DialogTraversal.firstUniqueDepthFirst(
            from: element,
            matching: { self.isDialogElement($0, matching: title) },
            children: { current in
                guard title != nil else { return current.sheets() ?? [] }
                return self.sheetFirstTraversalChildren(for: current)
            })
    }
}
