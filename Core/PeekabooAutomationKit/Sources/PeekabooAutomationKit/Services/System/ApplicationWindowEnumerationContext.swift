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
        /// Fully materialized record for an AX window that has no CG counterpart. Nil when the AX
        /// window matched a CG entry (the CG entry is authoritative and only borrows the title).
        let standaloneInfo: ServiceWindowInfo?
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
    /// title, and bounds. A full `standaloneInfo` record is materialized for every titled AX window
    /// that is *not* an exact CGWindowID match, so no AX-only window can be lost; the merge step then
    /// decides whether that record enriches an untitled CG window or is appended standalone.
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

            // An exact CGWindowID match means this AX window is already in the CG snapshot, so it only
            // supplies a title. Otherwise materialize a full record: the merge appends it (deduping by
            // the resolved ID) unless it is consumed to title an untitled CG window by bounds. Building
            // it here — rather than suppressing on a loose bounds match — guarantees the window is
            // never silently dropped, even when its CGWindowID cannot be resolved.
            let hasExactCGMatch = resolvedID.map(cgWindowIDs.contains) ?? false
            var standaloneInfo: ServiceWindowInfo?
            if !hasExactCGMatch, !title.isEmpty {
                standaloneInfo = await self.service.createWindowInfo(from: axWindow, index: index)
            }

            descriptors.append(AXWindowDescriptor(
                windowID: resolvedID,
                title: title,
                bounds: bounds,
                standaloneInfo: standaloneInfo))
        }

        return descriptors
    }

    /// Merge CG and AX windows preserving CGWindowList enumeration order.
    ///
    /// - CG windows are emitted first, in CGWindowList order, deduplicated by `CGWindowID`. Untitled
    ///   CG entries borrow a title from the AX window with the same `CGWindowID` (or matching bounds).
    /// - AX-only windows (a resolved `CGWindowID` that CGWindowList never reported) are appended last.
    ///
    /// Association is by `CGWindowID`/bounds, never by title, so same-titled windows keep distinct
    /// positions and `--window-index` continues to line up with the printed list.
    nonisolated static func mergeWindows(
        cgWindows: [ServiceWindowInfo],
        axDescriptors: [AXWindowDescriptor]) -> [ServiceWindowInfo]
    {
        // CGWindowID → title is inherently one-to-one (CG windows are deduplicated by ID), so it is
        // an unambiguous enrichment source for untitled CG windows.
        var axTitleByID: [Int: String] = [:]
        for descriptor in axDescriptors {
            guard let id = descriptor.windowID, !descriptor.title.isEmpty else { continue }
            if axTitleByID[id] == nil {
                axTitleByID[id] = descriptor.title
            }
        }

        // Titled AX windows AX could not resolve to a CGWindowID: eligible to title an untitled CG
        // window by bounds. Each descriptor is consumed at most once, and a descriptor used for
        // enrichment is never also appended standalone — so identically framed windows are not all
        // relabeled, nothing is double-counted, and nothing is dropped.
        let boundsFallbackIndices = axDescriptors.indices.filter { index in
            let descriptor = axDescriptors[index]
            return descriptor.windowID == nil && !descriptor.title.isEmpty && descriptor.bounds != nil
        }
        var consumedDescriptors = Set<Int>()

        var merged: [ServiceWindowInfo] = []
        merged.reserveCapacity(cgWindows.count + axDescriptors.count)
        var seenWindowIDs = Set<Int>()

        for cgWindow in cgWindows where seenWindowIDs.insert(cgWindow.windowID).inserted {
            guard cgWindow.title.isEmpty else {
                merged.append(cgWindow)
                continue
            }

            if let title = axTitleByID[cgWindow.windowID] {
                merged.append(cgWindow.withTitle(title))
                continue
            }

            if let descriptorIndex = boundsFallbackIndices.first(where: { index in
                guard !consumedDescriptors.contains(index), let bounds = axDescriptors[index].bounds else {
                    return false
                }
                return Self.boundsMatch(bounds, cgWindow.bounds)
            }) {
                consumedDescriptors.insert(descriptorIndex)
                merged.append(cgWindow.withTitle(axDescriptors[descriptorIndex].title))
                continue
            }

            merged.append(cgWindow)
        }

        // Append AX-only windows CGWindowList never reported, in AX order. Skip descriptors already
        // consumed to title a CG window and any whose ID is already present.
        for (index, descriptor) in axDescriptors.enumerated() {
            guard let info = descriptor.standaloneInfo,
                  !consumedDescriptors.contains(index),
                  seenWindowIDs.insert(info.windowID).inserted
            else {
                continue
            }
            merged.append(info)
        }

        return merged
    }

    private nonisolated static func boundsMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < tolerance &&
            abs(lhs.origin.y - rhs.origin.y) < tolerance &&
            abs(lhs.size.width - rhs.size.width) < tolerance &&
            abs(lhs.size.height - rhs.size.height) < tolerance
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

extension ServiceWindowInfo {
    /// Returns a copy of this window with a replacement title, preserving every other field.
    fileprivate func withTitle(_ newTitle: String) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: self.windowID,
            title: newTitle,
            bounds: self.bounds,
            isMinimized: self.isMinimized,
            isMainWindow: self.isMainWindow,
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
