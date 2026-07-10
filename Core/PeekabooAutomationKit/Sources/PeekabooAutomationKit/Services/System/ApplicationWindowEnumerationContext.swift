import AppKit
import AXorcist
import Foundation
import os.log
import PeekabooFoundation

@MainActor
struct WindowEnumerationContext {
    struct CGSnapshot {
        let windows: [ServiceWindowInfo]
        let windowsByTitle: [String: ServiceWindowInfo]
    }

    struct AXWindowResult {
        let windows: [Element]
        let timedOut: Bool
    }

    unowned let service: ApplicationService
    let app: ServiceApplicationInfo
    let startTime: Date
    let axTimeout: Float
    let hasScreenRecording: Bool
    let logger: Logger

    func run() async -> UnifiedToolOutput<ServiceWindowListData> {
        let snapshot = self.hasScreenRecording ? self.collectCGSnapshot() : nil
        if let snapshot, let fast = self.fastPath(using: snapshot) {
            return fast
        }

        guard self.isApplicationRunning else {
            return self.terminatedOutput()
        }

        let axWindows = self.fetchAXWindows()
        if let snapshot {
            return await self.mergeWithSnapshot(snapshot, axResult: axWindows)
        }

        return await self.buildAXOnlyResult(from: axWindows)
    }

    private var isApplicationRunning: Bool {
        NSRunningApplication(processIdentifier: self.app.processIdentifier)?.isTerminated == false
    }

    private func collectCGSnapshot() -> CGSnapshot? {
        self.logger.debug("Using hybrid approach: CGWindowList + selective AX enrichment")
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var windowIndex = 0
        var windows: [ServiceWindowInfo] = []
        var windowsByTitle: [String: ServiceWindowInfo] = [:]
        let screenService = ScreenService()
        let spaceService = SpaceManagementService()

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == self.app.processIdentifier
            else {
                continue
            }

            guard let windowInfo = self.snapshotWindowInfo(
                from: windowInfo,
                index: windowIndex,
                screenService: screenService,
                spaceService: spaceService)
            else {
                continue
            }

            windows.append(windowInfo)
            if !windowInfo.title.isEmpty {
                windowsByTitle[windowInfo.title] = windowInfo
            } else {
                let missingTitleMessage =
                    "Window \(windowInfo.windowID) has no title in CGWindowList, will need AX enrichment"
                self.logger.debug("\(missingTitleMessage)")
            }
            windowIndex += 1
        }

        guard !windows.isEmpty else {
            return nil
        }

        self.logger.debug("CGWindowList found \(windows.count) windows for \(self.app.name)")
        return CGSnapshot(windows: windows, windowsByTitle: windowsByTitle)
    }

    private func snapshotWindowInfo(
        from windowInfo: [String: Any],
        index: Int,
        screenService: ScreenService,
        spaceService: SpaceManagementService) -> ServiceWindowInfo?
    {
        guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let x = boundsDict["X"] as? CGFloat,
              let y = boundsDict["Y"] as? CGFloat,
              let width = boundsDict["Width"] as? CGFloat,
              let height = boundsDict["Height"] as? CGFloat
        else {
            return nil
        }

        let bounds = CGRect(x: x, y: y, width: width, height: height)
        let windowID = windowInfo[kCGWindowNumber as String] as? Int ?? index
        let windowLevel = windowInfo[kCGWindowLayer as String] as? Int ?? 0
        let alpha = windowInfo[kCGWindowAlpha as String] as? CGFloat ?? 1.0
        let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? true
        let sharingRaw = windowInfo[kCGWindowSharingState as String] as? Int
        let sharingState = sharingRaw.flatMap { WindowSharingState(rawValue: $0) }
        let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t
        let windowTitle = (windowInfo[kCGWindowName as String] as? String) ?? ""
        let isMinimized = bounds.origin.x < -10000 || bounds.origin.y < -10000
        let spaces = spaceService.getSpacesForWindow(windowID: CGWindowID(windowID))
        let (spaceID, spaceName) = spaces.first.map { ($0.id, $0.name) } ?? (nil, nil)
        let screenInfo = screenService.screenContainingWindow(bounds: bounds)
        let excludedFromMenu: Bool = if ownerPID == getpid(),
                                        let window = NSApp.window(withWindowNumber: windowID)
        {
            window.isExcludedFromWindowsMenu
        } else {
            false
        }

        return ServiceWindowInfo(
            windowID: windowID,
            title: windowTitle,
            bounds: bounds,
            isMinimized: isMinimized,
            isMainWindow: index == 0,
            windowLevel: windowLevel,
            alpha: alpha,
            index: index,
            spaceID: spaceID,
            spaceName: spaceName,
            screenIndex: screenInfo?.index,
            screenName: screenInfo?.name,
            isOffScreen: screenInfo == nil,
            layer: windowLevel,
            isOnScreen: isOnScreen,
            sharingState: sharingState,
            isExcludedFromWindowsMenu: excludedFromMenu)
    }

    private func fastPath(using snapshot: CGSnapshot) -> UnifiedToolOutput<ServiceWindowListData>? {
        guard snapshot.windows.allSatisfy({ !$0.title.isEmpty }) else {
            return nil
        }

        self.logger.debug("All windows have titles from CGWindowList, using fast path")
        return self.service.buildWindowListOutput(
            windows: snapshot.windows,
            app: self.app,
            startTime: self.startTime,
            warnings: [])
    }

    private func terminatedOutput() -> UnifiedToolOutput<ServiceWindowListData> {
        self.logger.warning("Application \(self.app.name) appears to have terminated")
        return UnifiedToolOutput(
            data: ServiceWindowListData(windows: [], targetApplication: self.app),
            summary: UnifiedToolOutput.Summary(
                brief: "Application \(self.app.name) has no windows (app terminated)",
                status: .failed,
                counts: ["windows": 0]),
            metadata: UnifiedToolOutput.Metadata(
                duration: Date().timeIntervalSince(self.startTime),
                warnings: ["Application appears to have terminated"]))
    }

    private func fetchAXWindows() -> AXWindowResult {
        guard let runningApp = NSRunningApplication(processIdentifier: self.app.processIdentifier) else {
            return AXWindowResult(windows: [], timedOut: false)
        }
        let appElement = AXApp(runningApp).element
        appElement.setMessagingTimeout(self.axTimeout)
        defer { appElement.setMessagingTimeout(0) }

        let windowStartTime = Date()
        let windows = appElement.windowsWithTimeout(timeout: self.axTimeout) ?? []
        let timedOut = Date().timeIntervalSince(windowStartTime) >= Double(self.axTimeout)
        return AXWindowResult(windows: windows, timedOut: timedOut)
    }

    private func mergeWithSnapshot(
        _ snapshot: CGSnapshot,
        axResult: AXWindowResult) async -> UnifiedToolOutput<ServiceWindowListData>
    {
        var enrichedWindows: [ServiceWindowInfo] = []
        // windowsByTitle is keyed by title only, so two AX windows sharing a title resolve to the
        // same CG snapshot entry. Guard every append by windowID or the same window is listed twice.
        var seenWindowIDs = Set<Int>()
        var warnings: [String] = []

        func appendIfNew(_ window: ServiceWindowInfo) {
            guard seenWindowIDs.insert(window.windowID).inserted else {
                self.logger.debug("Skipping duplicate window id \(window.windowID) ('\(window.title)')")
                return
            }
            enrichedWindows.append(window)
        }

        for (index, axWindow) in axResult.windows.indexed() {
            if Date().timeIntervalSince(self.startTime) > Double(self.axTimeout * 2) {
                warnings.append("Stopped enrichment after timeout")
                break
            }

            guard let axTitle = axWindow.title(), !axTitle.isEmpty else {
                continue
            }

            if let cgWindow = snapshot.windowsByTitle[axTitle] {
                appendIfNew(cgWindow)
            } else if let windowInfo = await self.service.createWindowInfo(from: axWindow, index: index) {
                appendIfNew(windowInfo)
            }
        }

        for cgWindow in snapshot.windows where !seenWindowIDs.contains(cgWindow.windowID) {
            if cgWindow.title.isEmpty {
                self.logger.debug("CGWindow \(cgWindow.windowID) has no title, including as-is")
            }
            appendIfNew(cgWindow)
        }

        if axResult.timedOut {
            warnings.append("Window enumeration timed out after \(self.axTimeout)s, results may be incomplete")
        }

        return self.service.buildWindowListOutput(
            windows: enrichedWindows,
            app: self.app,
            startTime: self.startTime,
            warnings: warnings)
    }

    private func buildAXOnlyResult(from axResult: AXWindowResult) async -> UnifiedToolOutput<ServiceWindowListData> {
        self.logger.debug("Using pure AX approach (no screen recording permission)")
        var warnings: [String] = []
        var windowInfos: [ServiceWindowInfo] = []
        let maxWindowsToProcess = 100
        let limitedWindows = Array(axResult.windows.prefix(maxWindowsToProcess))

        if axResult.windows.count > maxWindowsToProcess {
            let warning =
                "Application \(self.app.name) has \(axResult.windows.count) windows, " +
                "processing only first \(maxWindowsToProcess)"
            self.logger.warning("\(warning)")
        }

        for (index, window) in limitedWindows.indexed() {
            if Date().timeIntervalSince(self.startTime) > Double(self.axTimeout) {
                warnings.append("Stopped processing after \(self.axTimeout)s timeout")
                break
            }

            if let windowInfo = await self.service.createWindowInfo(from: window, index: index) {
                windowInfos.append(windowInfo)
            }
        }

        if axResult.timedOut {
            warnings.append("Window enumeration timed out, results may be incomplete")
        }

        if axResult.windows.count > maxWindowsToProcess {
            let processedWarning =
                "Only processed first \(maxWindowsToProcess) of \(axResult.windows.count) windows"
            warnings.append(processedWarning)
        }

        if !self.hasScreenRecording {
            warnings.append("Screen recording permission not granted - window listing may be slower")
        }

        return self.service.buildWindowListOutput(
            windows: windowInfos,
            app: self.app,
            startTime: self.startTime,
            warnings: warnings)
    }
}
