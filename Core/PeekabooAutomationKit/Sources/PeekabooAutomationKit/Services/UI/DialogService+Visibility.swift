import AppKit
import AXorcist
import CoreGraphics
import Foundation

@MainActor
extension DialogService {
    func ensureDialogVisibility(windowTitle: String?, appName: String?) async {
        guard windowTitle != nil || appName != nil else {
            return
        }

        do {
            let applications = try await self.applicationService.listApplications()
            for app in applications.data.applications
                where app.isUsableForBroadAutomationDiscovery
            {
                if let appName,
                   app.name.caseInsensitiveCompare(appName) != .orderedSame,
                   app.bundleIdentifier?.caseInsensitiveCompare(appName) != .orderedSame
                {
                    continue
                }

                let windowsOutput = try await self.applicationService.listWindows(for: app.name, timeout: nil)
                if let window = windowsOutput.data.windows.first(where: {
                    self.matchesDialogWindowTitle($0.title, expectedTitle: windowTitle)
                }) {
                    self.logger.info("Focusing dialog candidate '\(window.title)' from \(app.name)")
                    try await self.focusService.focusWindowWithOwnedLane(
                        windowID: CGWindowID(window.windowID),
                        options: FocusManagementService.FocusOptions(
                            timeout: 1.0,
                            retryCount: 1,
                            switchSpace: true,
                            bringToCurrentSpace: true),
                        expectedIdentity: window.mutationIdentity)
                    try await Task.sleep(nanoseconds: 200_000_000)
                    return
                }
            }
        } catch {
            self.logger.debug("Dialog visibility assist failed: \(String(describing: error))")
        }
    }

    func findDialogViaApplicationService(windowTitle: String?, appName: String?) async -> Element? {
        guard let applications = try? await self.applicationService.listApplications() else {
            return nil
        }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostBundle = frontmostApp?.bundleIdentifier?.lowercased()
        let frontmostName = frontmostApp?.localizedName?.lowercased()

        for app in applications.data.applications
            where app.isUsableForBroadAutomationDiscovery
        {
            if let appName,
               app.name.caseInsensitiveCompare(appName) != .orderedSame,
               app.bundleIdentifier?.caseInsensitiveCompare(appName) != .orderedSame
            {
                continue
            }

            if let bundle = frontmostBundle,
               let candidateBundle = app.bundleIdentifier?.lowercased(),
               candidateBundle != bundle
            {
                continue
            }

            if frontmostBundle == nil,
               let name = frontmostName,
               app.name.lowercased() != name
            {
                continue
            }

            guard let windowsOutput = try? await self.applicationService.listWindows(for: app.name, timeout: nil) else {
                continue
            }

            guard let windowInfo = windowsOutput.data.windows.first(where: {
                self.matchesDialogWindowTitle($0.title, expectedTitle: windowTitle)
            }) else {
                continue
            }

            if let windowHandle = self.windowIdentityService.findWindow(byID: CGWindowID(windowInfo.windowID)),
               let candidate = self.resolveDialogCandidate(
                   in: windowHandle.element,
                   matching: windowTitle ?? windowInfo.title)
            {
                return candidate
            }

            guard let runningApp = NSRunningApplication(processIdentifier: app.processIdentifier) else { continue }
            let axApp = AXApp(runningApp).element
            guard let appWindows = axApp.windowsWithTimeout(timeout: 0.5) else { continue }

            if let match = appWindows.first(where: {
                let title = $0.title() ?? ""
                return title == windowInfo.title ||
                    self.matchesDialogWindowTitle(title, expectedTitle: windowTitle)
            }) {
                return match
            }
        }

        return nil
    }

    func matchesDialogWindowTitle(_ title: String, expectedTitle: String?) -> Bool {
        if let expectedTitle, !expectedTitle.isEmpty {
            return title.localizedCaseInsensitiveContains(expectedTitle)
        }
        return self.dialogTitleHints.contains { title.localizedCaseInsensitiveContains($0) }
    }
}
