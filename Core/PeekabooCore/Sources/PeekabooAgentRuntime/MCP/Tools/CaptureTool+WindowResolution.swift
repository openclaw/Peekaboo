import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation

enum CaptureToolWindowResolver {
    static func scope(
        app: String?,
        pid: Int?,
        windowTitle: String?,
        windowIndex: Int?,
        windows: any WindowManagementServiceProtocol) async throws -> CaptureScope
    {
        let appIdentifier = CaptureToolArgumentResolver.applicationIdentifier(app: app, pid: pid)
        let title = self.normalizedTitle(windowTitle)

        guard let selectedWindow = try await self.selectWindow(
            appIdentifier: appIdentifier,
            hasExplicitApp: self.hasExplicitApplication(app: app, pid: pid),
            title: title,
            index: windowIndex,
            windows: windows)
        else {
            if let title {
                throw PeekabooError.windowNotFound(criteria: "window title '\(title)'")
            }
            throw PeekabooError.windowNotFound(criteria: "window index \(windowIndex ?? 0) for \(appIdentifier)")
        }

        guard let identity = selectedWindow.mutationIdentity,
              identity.windowID == selectedWindow.windowID,
              identity.capturedBounds == selectedWindow.bounds,
              let windowID = UInt32(exactly: selectedWindow.windowID)
        else {
            throw PeekabooError.windowNotFound(
                criteria: "capture target has no exact process-generation and bounds receipt")
        }

        // The watch loop captures repeatedly; resolve every selector, including automatic app selection,
        // exactly once and retain the process generation plus immutable bounds beside the WindowServer ID.
        return CaptureScope(
            kind: .window,
            windowId: windowID,
            windowMutationIdentity: identity,
            applicationIdentifier: appIdentifier,
            windowIndex: selectedWindow.index)
    }

    private static func selectWindow(
        appIdentifier: String,
        hasExplicitApp: Bool,
        title: String?,
        index: Int?,
        windows: any WindowManagementServiceProtocol) async throws -> ServiceWindowInfo?
    {
        if let title, hasExplicitApp {
            let candidates = try await self.captureCandidates(
                target: .application(appIdentifier),
                windows: windows)
            return try self.selectExactWindow(
                from: candidates,
                selection: .title(title),
                operation: "Capture window selection")
        }

        if let title {
            let candidates = try await self.captureCandidates(
                target: .title(title),
                windows: windows)
            return try self.selectExactWindow(
                from: candidates,
                selection: .title(title),
                operation: "Capture window selection")
        }

        if index != nil, !hasExplicitApp {
            return nil
        }
        let target: WindowTarget = hasExplicitApp ? .application(appIdentifier) : .frontmost
        let candidates = try await self.captureCandidates(target: target, windows: windows)
        let selection = index.map(ExactWindowSelectorResolver.Selection.index) ?? .automatic
        return try self.selectExactWindow(from: candidates, selection: selection, operation: "Capture window selection")
    }

    private static func selectExactWindow(
        from windows: [ServiceWindowInfo],
        selection: ExactWindowSelectorResolver.Selection,
        operation: String) throws -> ServiceWindowInfo
    {
        do {
            return try ExactWindowSelectorResolver.select(
                from: windows,
                selection: selection,
                operation: operation)
        } catch {
            throw PeekabooError.windowNotFound(criteria: error.localizedDescription)
        }
    }

    private static func captureCandidates(
        target: WindowTarget,
        windows: any WindowManagementServiceProtocol) async throws -> [ServiceWindowInfo]
    {
        let listed = try await windows.listWindows(target: target)
        return ObservationTargetResolver.captureCandidates(from: listed)
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func hasExplicitApplication(app: String?, pid: Int?) -> Bool {
        if pid != nil {
            return true
        }
        return !(app?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
}
