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

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == pid,
                  let windowTitle = windowInfo[kCGWindowName as String] as? String,
                  windowTitle == title,
                  let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let width = boundsDict["Width"] as? CGFloat,
                  let height = boundsDict["Height"] as? CGFloat
            else {
                continue
            }
            let candidateBounds = CGRect(x: x, y: y, width: width, height: height)
            let matchesBounds = abs(candidateBounds.origin.x - bounds.origin.x) < 5 &&
                abs(candidateBounds.origin.y - bounds.origin.y) < 5 &&
                abs(candidateBounds.size.width - bounds.size.width) < 5 &&
                abs(candidateBounds.size.height - bounds.size.height) < 5
            if matchesBounds, let windowNumber = windowInfo[kCGWindowNumber as String] as? Int {
                return windowNumber
            }
        }
        return nil
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
        warnings: [String]) -> UnifiedToolOutput<ServiceWindowListData>
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
                hints: ["Use window title or index to target specific window"]))
    }
}
