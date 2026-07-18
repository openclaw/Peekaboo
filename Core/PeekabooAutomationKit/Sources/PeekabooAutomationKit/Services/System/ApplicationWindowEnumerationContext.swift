import AppKit
import AXorcist
import Foundation
import os.log
import PeekabooFoundation

@MainActor
struct WindowEnumerationContext {
    struct CGSnapshot {
        let windows: [ServiceWindowInfo]
    }

    struct AXWindowResult {
        let windows: [Element]
        let timedOut: Bool
        let focusedWindowID: Int?
    }

    /// Plain, testable description of an AX window used to enrich or extend the CG snapshot.
    ///
    /// AX windows are associated with CG windows by `CGWindowID` (resolved via `_AXUIElementGetWindow`)
    /// and, as a fallback, by matching bounds. Title is deliberately *not* an association key: two
    /// windows of the same app can share a title, and keying by title collapses them onto a single
    /// CG entry, reordering the enumeration and mis-aligning `--window-index` targets.
    struct AXWindowDescriptor: Sendable {
        /// Resolved CGWindowID, when AX could expose one.
        let windowID: Int?
        /// AX window title (may be empty).
        let title: String
        /// AX-reported bounds, used only as a fallback matcher when `windowID` is unavailable.
        let bounds: CGRect?
        /// Fully materialized record for a genuine AX-only window. Set only when `windowID` is a
        /// reliable resolved CGWindowID absent from the CG snapshot, so appending it cannot introduce
        /// a phantom entry; nil for CG-matched windows and for windows AX could not resolve to an ID.
        let standaloneInfo: ServiceWindowInfo?

        let isMainWindow: Bool
        let isKeyWindow: Bool?
        let isFrontmost: Bool?
        let subrole: String?

        init(
            windowID: Int?,
            title: String,
            bounds: CGRect?,
            standaloneInfo: ServiceWindowInfo?,
            isMainWindow: Bool = false,
            isKeyWindow: Bool? = nil,
            isFrontmost: Bool? = nil,
            subrole: String? = nil)
        {
            self.windowID = windowID
            self.title = title
            self.bounds = bounds
            self.standaloneInfo = standaloneInfo
            self.isMainWindow = isMainWindow
            self.isKeyWindow = isKeyWindow
            self.isFrontmost = isFrontmost
            self.subrole = subrole
        }
    }

    unowned let service: ApplicationService
    let app: ServiceApplicationInfo
    let startTime: Date
    let axTimeout: Float
    let hasScreenRecording: Bool
    let logger: Logger

    func run() async -> UnifiedToolOutput<ServiceWindowListData> {
        let snapshot = self.hasScreenRecording ? self.collectCGSnapshot() : nil
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
            if windowInfo.title.isEmpty {
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
        return CGSnapshot(windows: windows)
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
            isMainWindow: false,
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
            return AXWindowResult(windows: [], timedOut: false, focusedWindowID: nil)
        }
        let appElement = AXApp(runningApp).element
        appElement.setMessagingTimeout(self.axTimeout)
        defer { appElement.setMessagingTimeout(0) }

        let windowStartTime = Date()
        let windows = appElement.windowsWithTimeout(timeout: self.axTimeout) ?? []
        let timedOut = Date().timeIntervalSince(windowStartTime) >= Double(self.axTimeout)
        let focusedWindowID = appElement.focusedWindow()
            .flatMap { WindowIdentityService().getWindowID(from: $0) }
            .map(Int.init)
        return AXWindowResult(windows: windows, timedOut: timedOut, focusedWindowID: focusedWindowID)
    }

    private func mergeWithSnapshot(
        _ snapshot: CGSnapshot,
        axResult: AXWindowResult) async -> UnifiedToolOutput<ServiceWindowListData>
    {
        var warnings: [String] = []
        let descriptors = await self.collectAXDescriptors(
            axResult: axResult,
            cgWindowIDs: Set(snapshot.windows.map(\.windowID)),
            warnings: &warnings)

        let merged = Self.mergeWindows(cgWindows: snapshot.windows, axDescriptors: descriptors)

        if axResult.timedOut {
            warnings.append("Window enumeration timed out after \(self.axTimeout)s, results may be incomplete")
        }

        return self.service.buildWindowListOutput(
            windows: merged,
            app: self.app,
            startTime: self.startTime,
            warnings: warnings)
    }

    /// Resolve each AX window into a plain descriptor: CGWindowID (via `_AXUIElementGetWindow`),
    /// title, and bounds.
    ///
    /// A `standaloneInfo` record is materialized only for AX windows that resolve to a *reliable*
    /// CGWindowID which CGWindowList did not report — those are genuine AX-only windows we can list
    /// with a stable identity. AX windows whose CGWindowID cannot be resolved are used solely to
    /// title an untitled CG window by bounds; they are never appended as their own entry, because
    /// `createWindowInfo` would fall back to a synthetic index-based ID and produce exactly the
    /// phantom / duplicate / index-shifting entries this change fixes.
    private func collectAXDescriptors(
        axResult: AXWindowResult,
        cgWindowIDs: Set<Int>,
        warnings: inout [String]) async -> [AXWindowDescriptor]
    {
        let windowIdentityService = WindowIdentityService()
        var descriptors: [AXWindowDescriptor] = []
        descriptors.reserveCapacity(axResult.windows.count)

        for (index, axWindow) in axResult.windows.indexed() {
            if Date().timeIntervalSince(self.startTime) > Double(self.axTimeout * 2) {
                warnings.append("Stopped enrichment after timeout")
                break
            }

            let title = axWindow.title() ?? ""
            let resolvedID = windowIdentityService.getWindowID(from: axWindow).map(Int.init)
            let bounds: CGRect? = axWindow.position().map { position in
                CGRect(origin: position, size: axWindow.size() ?? .zero)
            }

            var standaloneInfo: ServiceWindowInfo?
            if let resolvedID, !cgWindowIDs.contains(resolvedID), !title.isEmpty {
                let focusMetadata = Self.focusMetadata(
                    windowID: resolvedID,
                    focusedWindowID: axResult.focusedWindowID,
                    appIsActive: self.app.isActive)
                standaloneInfo = await self.service.createWindowInfo(
                    from: axWindow,
                    index: index,
                    isKeyWindow: focusMetadata.isKey,
                    isFrontmost: focusMetadata.isFrontmost)
            }

            let focusMetadata = Self.focusMetadata(
                windowID: resolvedID,
                focusedWindowID: axResult.focusedWindowID,
                appIsActive: self.app.isActive)

            descriptors.append(AXWindowDescriptor(
                windowID: resolvedID,
                title: title,
                bounds: bounds,
                standaloneInfo: standaloneInfo,
                isMainWindow: axWindow.isMain() ?? false,
                isKeyWindow: focusMetadata.isKey,
                isFrontmost: focusMetadata.isFrontmost,
                subrole: axWindow.subrole()))
        }

        return descriptors
    }

    /// Merge CG and AX windows preserving CGWindowList enumeration order.
    ///
    /// - CG windows are emitted first, in CGWindowList order, deduplicated by `CGWindowID`. An
    ///   untitled CG entry borrows a title from the AX window with the same `CGWindowID`, or, when AX
    ///   could not expose a `CGWindowID`, from a bounds-matched AX window (consumed once).
    /// - AX-only windows that resolved to a reliable `CGWindowID` absent from the snapshot append last.
    ///
    /// Every decision uses only reliable signals — an exact `CGWindowID`, or a CG-snapshot
    /// title+bounds — never a synthesized ID, so same-titled windows keep distinct positions and
    /// `--window-index` stays aligned with the printed list.
    nonisolated static func mergeWindows(
        cgWindows: [ServiceWindowInfo],
        axDescriptors: [AXWindowDescriptor]) -> [ServiceWindowInfo]
    {
        // Exact CGWindowID → title is one-to-one (CG windows are deduplicated by ID): an unambiguous
        // enrichment source for the untitled CG window carrying that id.
        var axTitleByID: [Int: String] = [:]
        var axDescriptorByID: [Int: AXWindowDescriptor] = [:]
        for descriptor in axDescriptors {
            guard let id = descriptor.windowID else { continue }
            if axDescriptorByID[id] == nil {
                axDescriptorByID[id] = descriptor
            }
            if !descriptor.title.isEmpty, axTitleByID[id] == nil {
                axTitleByID[id] = descriptor.title
            }
        }

        // Titled AX windows AX could not resolve to a CGWindowID: a best-effort title source for an
        // untitled CG window, matched by bounds and consumed at most once so identically framed
        // windows are not all relabeled.
        let boundsFallbackIndices = axDescriptors.indices.filter { index in
            let descriptor = axDescriptors[index]
            return descriptor.windowID == nil && !descriptor.title.isEmpty && descriptor.bounds != nil
        }
        var consumedFallbacks = Set<Int>()

        var merged: [ServiceWindowInfo] = []
        merged.reserveCapacity(cgWindows.count + axDescriptors.count)
        var seenWindowIDs = Set<Int>()

        for cgWindow in cgWindows where seenWindowIDs.insert(cgWindow.windowID).inserted {
            var enrichedWindow = cgWindow
            if let descriptor = axDescriptorByID[cgWindow.windowID] {
                enrichedWindow = enrichedWindow.withAXMetadata(
                    isMainWindow: descriptor.isMainWindow,
                    isKeyWindow: descriptor.isKeyWindow,
                    isFrontmost: descriptor.isFrontmost,
                    subrole: descriptor.subrole)
            }

            guard enrichedWindow.title.isEmpty else {
                merged.append(enrichedWindow)
                continue
            }

            if let title = axTitleByID[cgWindow.windowID] {
                merged.append(enrichedWindow.withTitle(title))
                continue
            }

            if let descriptorIndex = boundsFallbackIndices.first(where: { index in
                guard !consumedFallbacks.contains(index), let bounds = axDescriptors[index].bounds else {
                    return false
                }
                guard Self.boundsMatch(bounds, cgWindow.bounds) else { return false }
                // Do not hijack: if this AX title+frame already belongs to a different CG window, that
                // window is the real owner, so leave this untitled entry alone.
                return !Self.boundsOwnedByOtherWindow(
                    title: axDescriptors[index].title,
                    bounds: bounds,
                    excluding: cgWindow.windowID,
                    in: cgWindows)
            }) {
                consumedFallbacks.insert(descriptorIndex)
                merged.append(enrichedWindow.withTitle(axDescriptors[descriptorIndex].title))
                continue
            }

            merged.append(enrichedWindow)
        }

        // Append AX-only windows that resolved to a reliable CGWindowID absent from the CG snapshot.
        for descriptor in axDescriptors {
            guard let info = descriptor.standaloneInfo, seenWindowIDs.insert(info.windowID).inserted else {
                continue
            }
            merged.append(info)
        }

        return merged
    }

    /// Whether a titled CG window other than `windowID` already claims this AX title at these bounds,
    /// i.e. that window is the AX record's real owner and this untitled entry must not borrow its title.
    private nonisolated static func boundsOwnedByOtherWindow(
        title: String,
        bounds: CGRect,
        excluding windowID: Int,
        in cgWindows: [ServiceWindowInfo]) -> Bool
    {
        cgWindows.contains { window in
            window.windowID != windowID &&
                !window.title.isEmpty &&
                window.title == title &&
                Self.boundsMatch(window.bounds, bounds)
        }
    }

    private nonisolated static func boundsMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < tolerance &&
            abs(lhs.origin.y - rhs.origin.y) < tolerance &&
            abs(lhs.size.width - rhs.size.width) < tolerance &&
            abs(lhs.size.height - rhs.size.height) < tolerance
    }

    nonisolated static func focusMetadata(
        windowID: Int?,
        focusedWindowID: Int?,
        appIsActive: Bool) -> (isKey: Bool?, isFrontmost: Bool?)
    {
        guard let windowID, let focusedWindowID else {
            return (nil, nil)
        }
        let isKey = windowID == focusedWindowID
        return (isKey, appIsActive && isKey)
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

            let windowID = WindowIdentityService().getWindowID(from: window).map(Int.init)
            let focusMetadata = Self.focusMetadata(
                windowID: windowID,
                focusedWindowID: axResult.focusedWindowID,
                appIsActive: self.app.isActive)
            if let windowInfo = await self.service.createWindowInfo(
                from: window,
                index: index,
                isKeyWindow: focusMetadata.isKey,
                isFrontmost: focusMetadata.isFrontmost)
            {
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

extension ServiceWindowInfo {
    /// Returns a copy of this window with a replacement title, preserving every other field.
    fileprivate func withTitle(_ newTitle: String) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: self.windowID,
            title: newTitle,
            bounds: self.bounds,
            isMinimized: self.isMinimized,
            isMainWindow: self.isMainWindow,
            isKeyWindow: self.isKeyWindow,
            isFrontmost: self.isFrontmost,
            subrole: self.subrole,
            windowLevel: self.windowLevel,
            alpha: self.alpha,
            index: self.index,
            spaceID: self.spaceID,
            spaceName: self.spaceName,
            screenIndex: self.screenIndex,
            screenName: self.screenName,
            isOffScreen: self.isOffScreen,
            layer: self.layer,
            isOnScreen: self.isOnScreen,
            sharingState: self.sharingState,
            isExcludedFromWindowsMenu: self.isExcludedFromWindowsMenu)
    }

    fileprivate func withAXMetadata(
        isMainWindow: Bool,
        isKeyWindow: Bool?,
        isFrontmost: Bool?,
        subrole: String?) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: self.windowID,
            title: self.title,
            bounds: self.bounds,
            isMinimized: self.isMinimized,
            isMainWindow: isMainWindow,
            isKeyWindow: isKeyWindow,
            isFrontmost: isFrontmost,
            subrole: subrole,
            windowLevel: self.windowLevel,
            alpha: self.alpha,
            index: self.index,
            spaceID: self.spaceID,
            spaceName: self.spaceName,
            screenIndex: self.screenIndex,
            screenName: self.screenName,
            isOffScreen: self.isOffScreen,
            layer: self.layer,
            isOnScreen: self.isOnScreen,
            sharingState: self.sharingState,
            isExcludedFromWindowsMenu: self.isExcludedFromWindowsMenu)
    }
}
