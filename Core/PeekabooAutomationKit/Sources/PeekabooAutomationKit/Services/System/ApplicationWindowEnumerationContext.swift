import AppKit
import Foundation
import os.log
import PeekabooFoundation

@MainActor
struct WindowEnumerationContext {
    typealias AXEnumerator = @Sendable (
        _ processIdentity: ApplicationProcessIdentity,
        _ timeoutSeconds: TimeInterval) async throws -> AXWindowResult

    struct CGSnapshot {
        let windows: [ServiceWindowInfo]
        let omittedOwnerRowCount: Int

        init(windows: [ServiceWindowInfo], omittedOwnerRowCount: Int = 0) {
            self.windows = windows
            self.omittedOwnerRowCount = omittedOwnerRowCount
        }
    }

    /// MainActor-owned descriptor used by the existing CG/AX merge contract. Detached workers return
    /// raw descriptors; process/window receipts and AX-only records are materialized here.
    struct AXWindowDescriptor: Sendable {
        let windowID: Int?
        let title: String
        let bounds: CGRect?
        let standaloneInfo: ServiceWindowInfo?
        let isMainWindow: Bool
        let isKeyWindow: Bool?
        let isFrontmost: Bool?
        let subrole: String?
        let isMinimized: Bool?
        let mutationIdentity: WindowMutationIdentity?

        init(
            windowID: Int?,
            title: String,
            bounds: CGRect?,
            standaloneInfo: ServiceWindowInfo?,
            isMainWindow: Bool = false,
            isKeyWindow: Bool? = nil,
            isFrontmost: Bool? = nil,
            subrole: String? = nil,
            isMinimized: Bool? = nil,
            mutationIdentity: WindowMutationIdentity? = nil)
        {
            self.windowID = windowID
            self.title = title
            self.bounds = bounds
            self.standaloneInfo = standaloneInfo
            self.isMainWindow = isMainWindow
            self.isKeyWindow = isKeyWindow
            self.isFrontmost = isFrontmost
            self.subrole = subrole
            self.isMinimized = isMinimized
            self.mutationIdentity = mutationIdentity
        }
    }

    typealias AXWindowResult = DetachedAXWindowEnumerationResult

    unowned let service: ApplicationService
    let app: ServiceApplicationInfo
    let startTime: Date
    let axTimeout: Float
    let hasScreenRecording: Bool
    let logger: Logger
    let processIdentity: ApplicationProcessIdentity
    let cgSnapshotProvider: (@MainActor () -> CGSnapshot?)?
    let applicationRunningProvider: (@MainActor () -> Bool)?
    let axEnumerator: AXEnumerator

    init(
        service: ApplicationService,
        app: ServiceApplicationInfo,
        startTime: Date,
        axTimeout: Float,
        hasScreenRecording: Bool,
        logger: Logger,
        processIdentity: ApplicationProcessIdentity,
        cgSnapshotProvider: (@MainActor () -> CGSnapshot?)? = nil,
        applicationRunningProvider: (@MainActor () -> Bool)? = nil,
        axEnumerator: AXEnumerator? = nil)
    {
        self.service = service
        self.app = app
        self.startTime = startTime
        self.axTimeout = axTimeout
        self.hasScreenRecording = hasScreenRecording
        self.logger = logger
        self.processIdentity = processIdentity
        self.cgSnapshotProvider = cgSnapshotProvider
        self.applicationRunningProvider = applicationRunningProvider
        self.axEnumerator = axEnumerator ?? { processIdentity, timeoutSeconds in
            try await DetachedAXWindowEnumerationCoordinator.run(
                processIdentifier: processIdentity.processIdentifier,
                processStartIdentity: processIdentity.processStartIdentity,
                timeoutSeconds: timeoutSeconds)
        }
    }

    func run() async throws -> UnifiedToolOutput<ServiceWindowListData> {
        try self.validateProcessIdentity()
        let snapshot: CGSnapshot? = if self.hasScreenRecording {
            if let cgSnapshotProvider {
                cgSnapshotProvider()
            } else {
                self.collectCGSnapshot()
            }
        } else {
            nil
        }
        guard self.isApplicationRunning else {
            return self.terminatedOutput()
        }

        let axWindows = try await self.fetchAXWindows()
        try Task.checkCancellation()
        try self.validateProcessIdentity()
        if let snapshot {
            return await self.mergeWithSnapshot(snapshot, axResult: axWindows)
        }

        return self.buildAXOnlyResult(from: axWindows)
    }

    private var isApplicationRunning: Bool {
        if let applicationRunningProvider {
            return applicationRunningProvider()
        }
        return NSRunningApplication(processIdentifier: self.app.processIdentifier)?.isTerminated == false
    }

    private func validateProcessIdentity() throws {
        guard self.service.processStartIdentityProvider(self.processIdentity.processIdentifier) ==
            self.processIdentity.processStartIdentity
        else {
            throw PeekabooError.snapshotStale(
                "Target PID \(self.processIdentity.processIdentifier) changed process generation during window listing")
        }
    }

    private func collectCGSnapshot() -> CGSnapshot? {
        self.logger.debug("Using hybrid approach: CGWindowList + selective AX enrichment")
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var windowIndex = 0
        var windows: [ServiceWindowInfo] = []
        var ownerRowCount = 0
        var omittedOwnerRowCount = 0
        let screenService = ScreenService()
        let spaceService = SpaceManagementService()

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == self.app.processIdentifier
            else {
                continue
            }
            ownerRowCount += 1

            guard let windowInfo = self.snapshotWindowInfo(
                from: windowInfo,
                index: windowIndex,
                screenService: screenService,
                spaceService: spaceService)
            else {
                omittedOwnerRowCount += 1
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

        guard ownerRowCount > 0 else {
            return nil
        }

        self.logger.debug("CGWindowList found \(windows.count) windows for \(self.app.name)")
        return CGSnapshot(windows: windows, omittedOwnerRowCount: omittedOwnerRowCount)
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
        guard let windowIDValue = windowInfo[kCGWindowNumber as String] as? Int,
              let windowID = CGWindowID(exactly: windowIDValue),
              let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
              ownerPID == self.processIdentity.processIdentifier
        else {
            return nil
        }
        let windowLevel = windowInfo[kCGWindowLayer as String] as? Int ?? 0
        let alpha = windowInfo[kCGWindowAlpha as String] as? CGFloat ?? 1.0
        let sharingRaw = windowInfo[kCGWindowSharingState as String] as? Int
        let sharingState = sharingRaw.flatMap { WindowSharingState(rawValue: $0) }
        let windowTitle = (windowInfo[kCGWindowName as String] as? String) ?? ""
        let isMinimized = bounds.origin.x < -10000 || bounds.origin.y < -10000
        let isOnScreen = windowInfo[kCGWindowIsOnscreen as String] as? Bool ?? !isMinimized
        guard let mutationIdentity = SystemIdentityResolver.windowMutationIdentity(
            windowID: windowID,
            expectedOwnerProcessIdentifier: ownerPID,
            expectedOwnerProcessStartIdentity: self.processIdentity.processStartIdentity,
            expectedBounds: bounds,
            isMinimized: isMinimized)
        else {
            return nil
        }
        let spaces = spaceService.getSpacesForWindow(windowID: windowID)
        let (spaceID, spaceName) = spaces.first.map { ($0.id, $0.name) } ?? (nil, nil)
        let screenInfo = screenService.screenContainingWindow(bounds: bounds)
        let excludedFromMenu: Bool = if ownerPID == getpid(),
                                        let window = NSApp.window(withWindowNumber: windowIDValue)
        {
            window.isExcludedFromWindowsMenu
        } else {
            false
        }

        return ServiceWindowInfo(
            windowID: windowIDValue,
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
            isExcludedFromWindowsMenu: excludedFromMenu,
            mutationIdentity: mutationIdentity)
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

    private func fetchAXWindows() async throws -> AXWindowResult {
        do {
            return try await self.axEnumerator(
                self.processIdentity,
                TimeInterval(self.axTimeout))
        } catch let CaptureError.detectionTimedOut(seconds) {
            self.logger.warning("AX window enrichment escaped its \(seconds)s hard deadline")
            return AXWindowResult(
                descriptors: [],
                focusedWindowID: nil,
                timedOut: true,
                incomplete: true,
                reportedWindowCount: 0)
        }
    }

    private func mergeWithSnapshot(
        _ snapshot: CGSnapshot,
        axResult: AXWindowResult) async -> UnifiedToolOutput<ServiceWindowListData>
    {
        var warnings: [String] = []
        let descriptors = self.materializeStandaloneWindows(
            axResult: axResult,
            cgWindowIDs: Set(snapshot.windows.map(\.windowID)))

        let merge = Self.mergeWindowInventory(cgWindows: snapshot.windows, axDescriptors: descriptors)

        if axResult.timedOut {
            warnings.append("Window enumeration timed out after \(self.axTimeout)s, results may be incomplete")
        }
        if axResult.incomplete {
            warnings.append("Accessibility window enrichment was incomplete; returning verified CG inventory")
        }
        if axResult.reportedWindowCount > descriptors.count {
            warnings.append(
                "Accessibility reported \(axResult.reportedWindowCount) windows; " +
                    "enriched \(descriptors.count) before the bounded deadline")
        }
        if snapshot.omittedOwnerRowCount > 0 {
            warnings.append(
                "CoreGraphics omitted \(snapshot.omittedOwnerRowCount) owner window " +
                    "row\(snapshot.omittedOwnerRowCount == 1 ? "" : "s") without complete identity evidence")
        }
        if merge.unmaterializedAXDescriptorCount > 0 {
            warnings.append(
                "Accessibility omitted \(merge.unmaterializedAXDescriptorCount) unmatched window " +
                    "row\(merge.unmaterializedAXDescriptorCount == 1 ? "" : "s") without stable identity")
        }

        return self.service.buildWindowListOutput(
            windows: merge.windows,
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
    private func materializeStandaloneWindows(
        axResult: AXWindowResult,
        cgWindowIDs: Set<Int>) -> [AXWindowDescriptor]
    {
        axResult.descriptors.enumerated().map { index, raw in
            let focus = Self.focusMetadata(
                windowID: raw.windowID,
                focusedWindowID: axResult.focusedWindowID,
                appIsActive: self.app.isActive)
            let mutationIdentity: WindowMutationIdentity? = if let resolvedID = raw.windowID,
                                                               let windowID = CGWindowID(exactly: resolvedID),
                                                               let bounds = raw.bounds
            {
                SystemIdentityResolver.axWindowMutationIdentity(
                    snapshot: SystemIdentityResolver.WindowMutationSnapshot(
                        windowID: windowID,
                        ownerProcessIdentifier: self.processIdentity.processIdentifier,
                        ownerProcessStartIdentity: self.processIdentity.processStartIdentity,
                        bounds: bounds,
                        isMinimized: raw.isMinimized),
                    processStartIdentityProvider: SystemIdentityResolver.processStartIdentity,
                    windowIdentityProvider: SystemIdentityResolver.windowIdentity)
            } else {
                nil
            }
            let candidate = AXWindowDescriptor(
                windowID: raw.windowID,
                title: raw.title,
                bounds: raw.bounds,
                standaloneInfo: nil,
                isMainWindow: raw.isMainWindow,
                isKeyWindow: focus.isKey,
                isFrontmost: focus.isFrontmost,
                subrole: raw.subrole,
                isMinimized: raw.isMinimized,
                mutationIdentity: mutationIdentity)
            let shouldMaterializeStandalone = !raw.title.isEmpty &&
                raw.windowID.map { !cgWindowIDs.contains($0) } != false
            let standaloneInfo: ServiceWindowInfo? = if shouldMaterializeStandalone {
                self.service.createWindowInfo(
                    from: candidate,
                    index: index,
                    expectedProcessIdentity: self.processIdentity)
            } else {
                nil
            }
            return AXWindowDescriptor(
                windowID: candidate.windowID,
                title: candidate.title,
                bounds: candidate.bounds,
                standaloneInfo: standaloneInfo,
                isMainWindow: candidate.isMainWindow,
                isKeyWindow: candidate.isKeyWindow,
                isFrontmost: candidate.isFrontmost,
                subrole: candidate.subrole,
                isMinimized: candidate.isMinimized,
                mutationIdentity: candidate.mutationIdentity)
        }
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
    struct WindowMergeResult: Sendable {
        let windows: [ServiceWindowInfo]
        let unmaterializedAXDescriptorCount: Int
    }

    nonisolated static func mergeWindows(
        cgWindows: [ServiceWindowInfo],
        axDescriptors: [AXWindowDescriptor]) -> [ServiceWindowInfo]
    {
        self.mergeWindowInventory(cgWindows: cgWindows, axDescriptors: axDescriptors).windows
    }

    nonisolated static func mergeWindowInventory(
        cgWindows: [ServiceWindowInfo],
        axDescriptors: [AXWindowDescriptor]) -> WindowMergeResult
    {
        // Exact CGWindowID → title is one-to-one (CG windows are deduplicated by ID): an unambiguous
        // enrichment source for the untitled CG window carrying that id.
        var axTitleByID: [Int: String] = [:]
        var axDescriptorByID: [Int: AXWindowDescriptor] = [:]
        let cgWindowIDs = Set(cgWindows.map(\.windowID))
        var coveredDescriptorIndices = Set<Int>()
        var claimedDescriptorWindowIDs = Set<Int>()
        for (index, descriptor) in axDescriptors.enumerated() {
            guard let id = descriptor.windowID else { continue }
            if cgWindowIDs.contains(id) || descriptor.standaloneInfo != nil,
               claimedDescriptorWindowIDs.insert(id).inserted
            {
                coveredDescriptorIndices.insert(index)
            }
            if axDescriptorByID[id] == nil {
                axDescriptorByID[id] = descriptor
            }
            if !descriptor.title.isEmpty, axTitleByID[id] == nil {
                axTitleByID[id] = descriptor.title
            }
        }
        var claimedExactCGWindowIDs = Set(axDescriptors.compactMap { descriptor -> Int? in
            guard let windowID = descriptor.windowID, cgWindowIDs.contains(windowID) else { return nil }
            return windowID
        })
        for (index, descriptor) in axDescriptors.enumerated()
            where descriptor.windowID == nil && !descriptor.title.isEmpty
        {
            guard let bounds = descriptor.bounds else { continue }
            let exactRows = cgWindows.filter {
                !claimedExactCGWindowIDs.contains($0.windowID) &&
                    $0.title == descriptor.title && Self.boundsMatch($0.bounds, bounds)
            }
            if exactRows.count == 1, let matched = exactRows.first {
                claimedExactCGWindowIDs.insert(matched.windowID)
                coveredDescriptorIndices.insert(index)
            }
        }

        // Titled AX windows AX could not resolve to a CGWindowID: a best-effort title source for an
        // untitled CG window, matched by bounds and consumed at most once so identically framed
        // windows are not all relabeled.
        let boundsFallbackIndices = axDescriptors.indices.filter { index in
            let descriptor = axDescriptors[index]
            return descriptor.windowID == nil && !descriptor.title.isEmpty && descriptor.bounds != nil
        }
        var fallbackDescriptorIndicesByCGWindowID: [Int: [Int]] = [:]
        for descriptorIndex in boundsFallbackIndices {
            let descriptor = axDescriptors[descriptorIndex]
            guard let bounds = descriptor.bounds else { continue }
            let candidateWindowIDs = Set(cgWindows.compactMap { window -> Int? in
                guard window.title.isEmpty,
                      !claimedExactCGWindowIDs.contains(window.windowID),
                      Self.boundsMatch(bounds, window.bounds),
                      !Self.boundsOwnedByOtherWindow(
                          title: descriptor.title,
                          bounds: bounds,
                          excluding: window.windowID,
                          in: cgWindows)
                else { return nil }
                return window.windowID
            })
            guard candidateWindowIDs.count == 1, let windowID = candidateWindowIDs.first else { continue }
            fallbackDescriptorIndicesByCGWindowID[windowID, default: []].append(descriptorIndex)
        }
        let uniqueFallbackDescriptorByCGWindowID = fallbackDescriptorIndicesByCGWindowID.compactMapValues {
            $0.count == 1 ? $0[0] : nil
        }

        var merged: [ServiceWindowInfo] = []
        merged.reserveCapacity(cgWindows.count + axDescriptors.count)
        var seenWindowIDs = Set<Int>()

        for cgWindow in cgWindows where seenWindowIDs.insert(cgWindow.windowID).inserted {
            var enrichedWindow = cgWindow
            if let descriptor = axDescriptorByID[cgWindow.windowID] {
                enrichedWindow = enrichedWindow.withAXMetadata(descriptor)
            }

            guard enrichedWindow.title.isEmpty else {
                merged.append(enrichedWindow)
                continue
            }

            if let title = axTitleByID[cgWindow.windowID] {
                merged.append(enrichedWindow.withTitle(title))
                continue
            }

            if let descriptorIndex = uniqueFallbackDescriptorByCGWindowID[cgWindow.windowID] {
                coveredDescriptorIndices.insert(descriptorIndex)
                merged.append(enrichedWindow.withTitle(axDescriptors[descriptorIndex].title))
                continue
            }

            merged.append(enrichedWindow)
        }

        // Append AX-only windows that resolved to a reliable CGWindowID absent from the CG snapshot.
        for (index, descriptor) in axDescriptors.enumerated() {
            guard let info = descriptor.standaloneInfo, seenWindowIDs.insert(info.windowID).inserted else {
                continue
            }
            coveredDescriptorIndices.insert(index)
            merged.append(info)
        }

        return WindowMergeResult(
            windows: merged,
            unmaterializedAXDescriptorCount: axDescriptors.count - coveredDescriptorIndices.count)
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

    private func buildAXOnlyResult(from axResult: AXWindowResult) -> UnifiedToolOutput<ServiceWindowListData> {
        self.logger.debug("Using pure AX approach (no screen recording permission)")
        var warnings: [String] = []
        let descriptors = self.materializeStandaloneWindows(axResult: axResult, cgWindowIDs: [])
        let windowInfos = descriptors.compactMap(\.standaloneInfo)
        let unmaterializedDescriptorCount = descriptors.count - windowInfos.count

        if axResult.timedOut {
            warnings.append("Window enumeration timed out, results may be incomplete")
        }
        if axResult.incomplete {
            warnings.append("Accessibility window enumeration was incomplete")
        }
        if axResult.reportedWindowCount > descriptors.count {
            warnings.append(
                "Only processed \(descriptors.count) of \(axResult.reportedWindowCount) accessible windows")
        }
        if unmaterializedDescriptorCount > 0 {
            warnings.append(
                "Accessibility omitted \(unmaterializedDescriptorCount) window " +
                    "row\(unmaterializedDescriptorCount == 1 ? "" : "s") without stable window identity")
        }

        let additionalHints = self.hasScreenRecording
            ? []
            : ["Screen recording permission not granted - window listing may be slower"]

        return self.service.buildWindowListOutput(
            windows: windowInfos,
            app: self.app,
            startTime: self.startTime,
            warnings: warnings,
            additionalHints: additionalHints)
    }
}

extension ServiceWindowInfo {
    func withMutationIdentity(_ mutationIdentity: WindowMutationIdentity) -> ServiceWindowInfo {
        ServiceWindowInfo(
            windowID: self.windowID,
            title: self.title,
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
            isExcludedFromWindowsMenu: self.isExcludedFromWindowsMenu,
            mutationIdentity: mutationIdentity)
    }

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
            isExcludedFromWindowsMenu: self.isExcludedFromWindowsMenu,
            mutationIdentity: self.mutationIdentity)
    }

    fileprivate func withAXMetadata(
        _ descriptor: WindowEnumerationContext.AXWindowDescriptor) -> ServiceWindowInfo
    {
        ServiceWindowInfo(
            windowID: self.windowID,
            title: self.title,
            bounds: self.bounds,
            isMinimized: descriptor.isMinimized ?? self.isMinimized,
            isMainWindow: descriptor.isMainWindow,
            isKeyWindow: descriptor.isKeyWindow,
            isFrontmost: descriptor.isFrontmost,
            subrole: descriptor.subrole,
            windowLevel: self.windowLevel,
            alpha: self.alpha,
            index: self.index,
            spaceID: self.spaceID,
            spaceName: self.spaceName,
            screenIndex: self.screenIndex,
            screenName: self.screenName,
            isOffScreen: (descriptor.isMinimized ?? self.isMinimized) || self.isOffScreen,
            layer: self.layer,
            isOnScreen: (descriptor.isMinimized ?? self.isMinimized) ? false : self.isOnScreen,
            sharingState: self.sharingState,
            isExcludedFromWindowsMenu: self.isExcludedFromWindowsMenu,
            mutationIdentity: self.mutationIdentity?
                .withMinimizedState(descriptor.isMinimized ?? self.isMinimized) ?? descriptor.mutationIdentity)
    }
}
