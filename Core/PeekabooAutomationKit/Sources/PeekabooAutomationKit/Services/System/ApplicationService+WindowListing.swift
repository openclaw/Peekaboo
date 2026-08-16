import AppKit
import Foundation
import os.log
import PeekabooFoundation

@MainActor
extension ApplicationService {
    public func listWindows(
        for appIdentifier: String,
        timeout: Float? = nil) async throws -> UnifiedToolOutput<ServiceWindowListData>
    {
        let startTime = Date()
        self.logger.info("Listing windows for application: \(appIdentifier)")
        let app = try await findApplication(identifier: appIdentifier)
        guard let processIdentity = app.processIdentity,
              self.processStartIdentityProvider(processIdentity.processIdentifier) ==
              processIdentity.processStartIdentity
        else {
            throw PeekabooError.snapshotStale(
                "Application \(app.name) has no stable process generation for window listing")
        }
        let hasScreenRecording = self.permissions.checkScreenRecordingPermission()

        let context = WindowEnumerationContext(
            service: self,
            app: app,
            startTime: startTime,
            axTimeout: timeout ?? Self.windowAXEnrichmentTimeout,
            hasScreenRecording: hasScreenRecording,
            logger: self.logger,
            processIdentity: processIdentity)
        return try await context.run()
    }

    static func normalizeWindowIndices(_ windows: [ServiceWindowInfo]) -> [ServiceWindowInfo] {
        // Deduplicate by windowID before assigning indexes: a duplicate entry (e.g. from merged
        // CG/AX enumeration) would otherwise consume an index slot and shift --window-index targets.
        var seenWindowIDs = Set<Int>()
        let uniqueWindows = windows.filter { seenWindowIDs.insert($0.windowID).inserted }
        return uniqueWindows.enumerated().map { index, window in
            ServiceWindowInfo(
                windowID: window.windowID,
                title: window.title,
                bounds: window.bounds,
                isMinimized: window.isMinimized,
                isMainWindow: window.isMainWindow,
                isKeyWindow: window.isKeyWindow,
                isFrontmost: window.isFrontmost,
                subrole: window.subrole,
                windowLevel: window.windowLevel,
                alpha: window.alpha,
                index: index,
                spaceID: window.spaceID,
                spaceName: window.spaceName,
                screenIndex: window.screenIndex,
                screenName: window.screenName,
                isOffScreen: window.isOffScreen,
                layer: window.layer,
                isOnScreen: window.isOnScreen,
                sharingState: window.sharingState,
                isExcludedFromWindowsMenu: window.isExcludedFromWindowsMenu,
                mutationIdentity: window.mutationIdentity)
        }
    }

    func createWindowInfo(
        from descriptor: WindowEnumerationContext.AXWindowDescriptor,
        index: Int,
        expectedProcessIdentity: ApplicationProcessIdentity) -> ServiceWindowInfo?
    {
        guard let bounds = descriptor.bounds,
              !descriptor.title.isEmpty,
              let resolvedID = descriptor.windowID ?? self.matchWindowID(
                  pid: expectedProcessIdentity.processIdentifier,
                  title: descriptor.title,
                  bounds: bounds),
              let windowID = CGWindowID(exactly: resolvedID),
              let mutationIdentity = descriptor.mutationIdentity ??
              SystemIdentityResolver.axWindowMutationIdentity(
                  snapshot: SystemIdentityResolver.WindowMutationSnapshot(
                      windowID: windowID,
                      ownerProcessIdentifier: expectedProcessIdentity.processIdentifier,
                      ownerProcessStartIdentity: expectedProcessIdentity.processStartIdentity,
                      bounds: bounds,
                      isMinimized: descriptor.isMinimized),
                  processStartIdentityProvider: SystemIdentityResolver.processStartIdentity,
                  windowIdentityProvider: SystemIdentityResolver.windowIdentity)
        else {
            return nil
        }

        let screen = self.screenInfo(for: bounds)
        let spaces = self.spaceInfo(for: windowID)
        let level = self.windowLevel(for: windowID)

        let minimized = descriptor.isMinimized ?? false
        return ServiceWindowInfo(
            windowID: resolvedID,
            title: descriptor.title,
            bounds: bounds,
            isMinimized: minimized,
            isMainWindow: descriptor.isMainWindow,
            isKeyWindow: descriptor.isKeyWindow,
            isFrontmost: descriptor.isFrontmost,
            subrole: descriptor.subrole,
            windowLevel: level,
            index: index,
            spaceID: spaces.spaceID,
            spaceName: spaces.spaceName,
            screenIndex: screen.index,
            screenName: screen.name,
            isOffScreen: minimized || screen.index == nil,
            layer: 0,
            isOnScreen: !minimized,
            mutationIdentity: mutationIdentity)
    }

    private func screenInfo(for bounds: CGRect) -> (index: Int?, name: String?) {
        let screenService = ScreenService()
        let screenInfo = screenService.screenContainingWindow(bounds: bounds)
        return (screenInfo?.index, screenInfo?.name)
    }

    private func matchWindowID(pid: pid_t, title: String, bounds: CGRect) -> Int? {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidates = windowList.compactMap(Self.windowIDInferenceCandidate)
        return Self.uniqueMatchingWindowID(pid: pid, title: title, bounds: bounds, candidates: candidates)
    }

    struct WindowIDInferenceCandidate: Equatable, Sendable {
        let windowID: Int
        let ownerProcessIdentifier: pid_t
        let title: String
        let bounds: CGRect
    }

    static func uniqueMatchingWindowID(
        pid: pid_t,
        title: String,
        bounds: CGRect,
        candidates: [WindowIDInferenceCandidate]) -> Int?
    {
        let matches = candidates.filter { candidate in
            candidate.ownerProcessIdentifier == pid &&
                candidate.title == title &&
                abs(candidate.bounds.origin.x - bounds.origin.x) < 5 &&
                abs(candidate.bounds.origin.y - bounds.origin.y) < 5 &&
                abs(candidate.bounds.size.width - bounds.size.width) < 5 &&
                abs(candidate.bounds.size.height - bounds.size.height) < 5
        }
        guard matches.count == 1 else { return nil }
        return matches[0].windowID
    }

    private static func windowIDInferenceCandidate(
        _ windowInfo: [String: Any]) -> WindowIDInferenceCandidate?
    {
        guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
              let windowTitle = windowInfo[kCGWindowName as String] as? String,
              let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let width = boundsDict["Width"] as? CGFloat,
              let height = boundsDict["Height"] as? CGFloat,
              let windowNumber = windowInfo[kCGWindowNumber as String] as? Int
        else {
            return nil
        }
        return WindowIDInferenceCandidate(
            windowID: windowNumber,
            ownerProcessIdentifier: ownerPID,
            title: windowTitle,
            bounds: CGRect(x: x, y: y, width: width, height: height))
    }

    private func spaceInfo(for windowID: CGWindowID) -> (spaceID: UInt64?, spaceName: String?) {
        let spaceService = SpaceManagementService()
        let spaces = spaceService.getSpacesForWindow(windowID: windowID)
        guard let firstSpace = spaces.first else {
            return (nil, nil)
        }
        return (firstSpace.id, firstSpace.name)
    }

    private func windowLevel(for windowID: CGWindowID) -> Int {
        let spaceService = SpaceManagementService()
        return spaceService.getWindowLevel(windowID: windowID).map { Int($0) } ?? 0
    }

    func buildWindowListOutput(
        windows: [ServiceWindowInfo],
        app: ServiceApplicationInfo,
        startTime: Date,
        warnings: [String],
        additionalHints: [String] = []) -> UnifiedToolOutput<ServiceWindowListData>
    {
        let normalizedWindows = ApplicationService.normalizeWindowIndices(windows)
        let processedCount = normalizedWindows.count

        // Build highlights
        var highlights: [UnifiedToolOutput<ServiceWindowListData>.Summary.Highlight] = []
        let minimizedCount = normalizedWindows.count(where: { $0.isMinimized })
        let offScreenCount = normalizedWindows.count(where: { $0.isOffScreen })

        if minimizedCount > 0 {
            highlights.append(.init(
                label: "Minimized",
                value: "\(minimizedCount) window\(minimizedCount == 1 ? "" : "s")",
                kind: .info))
        }

        if offScreenCount > 0 {
            highlights.append(.init(
                label: "Off-screen",
                value: "\(offScreenCount) window\(offScreenCount == 1 ? "" : "s")",
                kind: .warning))
        }

        return UnifiedToolOutput(
            data: ServiceWindowListData(windows: normalizedWindows, targetApplication: app),
            summary: UnifiedToolOutput.Summary(
                brief: "Found \(processedCount) window\(processedCount == 1 ? "" : "s") for \(app.name)",
                status: warnings.isEmpty ? .success : .partial,
                counts: [
                    "windows": processedCount,
                    "minimized": minimizedCount,
                    "offScreen": offScreenCount,
                ],
                highlights: highlights),
            metadata: UnifiedToolOutput.Metadata(
                duration: Date().timeIntervalSince(startTime),
                warnings: warnings,
                hints: ["Use window title or index to target specific window"] + additionalHints))
    }
}
