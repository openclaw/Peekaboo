import AppKit
import AXorcist
import Foundation

@MainActor
extension DialogService {
    func resolveDialogElement(windowTitle: String?, appName: String?) async throws -> Element {
        if let appName, !appName.isEmpty {
            self.logger.debug("Resolving dialog with app hint: \(appName)")
        }
        if let element = try? self.findDialogElement(withTitle: windowTitle, appName: appName) {
            return element
        }

        if windowTitle != nil {
            await self.ensureDialogVisibility(windowTitle: windowTitle, appName: appName)
            if let element = try? self.findDialogElement(withTitle: windowTitle, appName: appName) {
                return element
            }

            if let element = await self.findDialogViaApplicationService(windowTitle: windowTitle, appName: appName) {
                return element
            }
        }

        throw DialogError.noActiveDialog
    }

    func resolveFileDialogElementResolution(appName: String?) async throws
    -> (element: Element, dialogIdentifier: String, foundVia: String) {
        if let appName,
           let fileDialog = self.findActiveFileDialogElement(appName: appName)
        {
            return (
                element: fileDialog,
                dialogIdentifier: self.dialogIdentifier(for: fileDialog),
                foundVia: "active_file_dialog")
        }

        let resolved = try await self.resolveDialogElementResolution(windowTitle: nil, appName: appName)
        guard self.isFileDialogElement(resolved.element) else {
            throw DialogError.noFileDialog
        }

        return resolved
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
        let windows = self.dialogWindowCandidates(in: focusedApp, title: title, appName: appName)
        self.logger.debug("Checking \(windows.count) windows for dialogs")

        for window in windows {
            if let candidate = self.resolveDialogCandidate(in: window, matching: title) {
                return candidate
            }
        }

        if title != nil {
            if let globalWindows = systemWide.windows() {
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
                let appWindows = axApp.windowsWithTimeout(timeout: windowSearchTimeout) ?? []
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

    private func dialogWindowCandidates(in app: Element, title: String?, appName: String?) -> [Element] {
        let timeout = self.dialogWindowSearchTimeout(title: title, appName: appName)

        // Without a title, an app-scoped command is still looking for the active dialog, not every dialog-like
        // subtree in the app. Checking focused/main windows keeps "no dialog" responses bounded for Electron/Tauri.
        if appName != nil, title == nil {
            app.setMessagingTimeout(timeout)
            defer { app.setMessagingTimeout(0) }
            return [
                app.focusedWindow(),
                app.mainWindow(),
            ].compactMap(\.self)
        }

        return app.windowsWithTimeout(timeout: timeout) ?? []
    }

    private func dialogIdentifier(for element: Element) -> String {
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

        if let element = try? self.findDialogElement(withTitle: windowTitle, appName: appName) {
            return (
                element: element,
                dialogIdentifier: self.dialogIdentifier(for: element),
                foundVia: "find_dialog_element")
        }

        if windowTitle != nil {
            await self.ensureDialogVisibility(windowTitle: windowTitle, appName: appName)
            if let element = try? self.findDialogElement(withTitle: windowTitle, appName: appName) {
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
