import AppKit
import AXorcist
import CoreGraphics
import Foundation
import PeekabooFoundation

@MainActor
extension WindowManagementService {
    public func listWindows(target: WindowTarget) async throws -> [ServiceWindowInfo] {
        switch target {
        case let .application(appIdentifier):
            return try await self.windows(for: appIdentifier)

        case let .title(titleSubstring):
            return try await self.windowsWithTitleSubstring(titleSubstring)

        case let .applicationAndTitle(appIdentifier, titleSubstring):
            return try await self.windows(for: appIdentifier)
                .filter { $0.title.localizedCaseInsensitiveContains(titleSubstring) }

        case let .index(app, index):
            let windows = try await self.windows(for: app)
            guard index >= 0, index < windows.count else {
                throw PeekabooError.invalidInput(
                    "windowIndex: Index \(index) is out of range. Available windows: 0-\(windows.count - 1)")
            }
            return [windows[index]]

        case .frontmost:
            let frontmostApp = try await self.applicationService.getFrontmostApplication()
            let windows = try await self.windows(for: frontmostApp.name)
            return ObservationTargetResolver.bestWindow(from: windows).map { [$0] } ?? []

        case let .windowId(id):
            return try await self.windowById(id)
        }
    }

    public func getFocusedWindow() async throws -> ServiceWindowInfo? {
        let frontmostApp = try await self.applicationService.getFrontmostApplication()
        let windows = try await self.windows(for: frontmostApp.name)
        guard let runningApp = NSRunningApplication(processIdentifier: frontmostApp.processIdentifier) else {
            return ObservationTargetResolver.bestWindow(from: windows)
        }

        let focusedWindowID = self.windowIdentityService.focusedWindowID(for: runningApp, timeout: 1)
            .map(Int.init)
        if let focusedWindowID,
           let focusedWindow = windows.first(where: { $0.windowID == focusedWindowID })
        {
            return focusedWindow
        }

        return ObservationTargetResolver.bestWindow(from: windows)
    }
}
