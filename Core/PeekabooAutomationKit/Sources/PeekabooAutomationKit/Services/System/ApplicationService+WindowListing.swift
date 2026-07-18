import AppKit
import AXorcist
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
        let hasScreenRecording = self.permissions.checkScreenRecordingPermission()

        let context = WindowEnumerationContext(
            service: self,
            app: app,
            startTime: startTime,
            axTimeout: timeout ?? Self.axTimeout,
            hasScreenRecording: hasScreenRecording,
            logger: self.logger)
        return await context.run()
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
                isExcludedFromWindowsMenu: window.isExcludedFromWindowsMenu)
        }
    }

    func createWindowInfo(
        from window: Element,
        index: Int,
        isKeyWindow: Bool? = nil,
        isFrontmost: Bool? = nil) async -> ServiceWindowInfo?
    {
        guard let title = window.title() else { return nil }

        let bounds = self.windowBounds(for: window)
        let screen = self.screenInfo(for: bounds)
        let windowID = self.resolveWindowID(for: window, title: title, bounds: bounds, fallbackIndex: index)
        let spaces = self.spaceInfo(for: windowID)
        let level = self.windowLevel(for: windowID)

        return ServiceWindowInfo(
            windowID: Int(windowID),
            title: title,
            bounds: bounds,
            isMinimized: window.isMinimized() ?? false,
            isMainWindow: window.isMain() ?? false,
            isKeyWindow: isKeyWindow,
            isFrontmost: isFrontmost,
            subrole: window.subrole(),
            windowLevel: level,
            index: index,
            spaceID: spaces.spaceID,
            spaceName: spaces.spaceName,
            screenIndex: screen.index,
            screenName: screen.name,
            isOffScreen: screen.index == nil,
            layer: 0,
            isOnScreen: true)
    }

    private func windowBounds(for window: Element) -> CGRect {
        let position = window.position() ?? .zero
        let size = window.size() ?? .zero
        return CGRect(origin: position, size: size)
    }

    private func screenInfo(for bounds: CGRect) -> (index: Int?, name: String?) {
        let screenService = ScreenService()
        let screenInfo = screenService.screenContainingWindow(bounds: bounds)
        return (screenInfo?.index, screenInfo?.name)
    }

    private func resolveWindowID(for window: Element, title: String, bounds: CGRect, fallbackIndex: Int) -> CGWindowID {
        let windowIdentityService = WindowIdentityService()
        if let identifier = windowIdentityService.getWindowID(from: window) {
            return identifier
        }

        if let pid = window.pid(), let matched = matchWindowID(pid: pid, title: title, bounds: bounds) {
            return matched
        }

        let missingIdentifierMessage =
            "Failed to get actual window ID for window '\(title)', using index \(fallbackIndex) as fallback"
        self.logger.warning("\(missingIdentifierMessage)")
        return CGWindowID(fallbackIndex)
    }

    private func matchWindowID(pid: pid_t, title: String, bounds: CGRect) -> CGWindowID? {
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

            let cgBounds = CGRect(x: x, y: y, width: width, height: height)

            let withinTolerance = abs(cgBounds.origin.x - bounds.origin.x) < 5 &&
                abs(cgBounds.origin.y - bounds.origin.y) < 5 &&
                abs(cgBounds.size.width - bounds.size.width) < 5 &&
                abs(cgBounds.size.height - bounds.size.height) < 5

            if withinTolerance, let windowNumber = windowInfo[kCGWindowNumber as String] as? Int {
                self.logger.debug("Found window ID \(windowNumber) via CGWindowList for '\(title)'")
                return CGWindowID(windowNumber)
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
                status: .success,
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
