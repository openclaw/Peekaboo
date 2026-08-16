import Algorithms
import AppKit
import CoreGraphics
import Foundation
import PeekabooFoundation
@preconcurrency import ScreenCaptureKit

@MainActor
extension ScreenCaptureKitOperator {
    final class ExactWindowCapturePlan {
        let key: ScreenCaptureKitWindowPlanCache<ExactWindowCapturePlan>.Key
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let expectedPixelSize: (width: Int, height: Int)
        let displayID: CGDirectDisplayID
        let scalePlan: ScreenCaptureScaleResolver.Plan
        let receipt: ScreenCaptureWindowPlanReceipt
        let topology: ScreenCaptureDisplayTopology
        let generation: UInt64

        init(
            key: ScreenCaptureKitWindowPlanCache<ExactWindowCapturePlan>.Key,
            filter: SCContentFilter,
            configuration: SCStreamConfiguration,
            expectedPixelSize: (width: Int, height: Int),
            displayID: CGDirectDisplayID,
            scalePlan: ScreenCaptureScaleResolver.Plan,
            receipt: ScreenCaptureWindowPlanReceipt,
            topology: ScreenCaptureDisplayTopology,
            generation: UInt64)
        {
            self.key = key
            self.filter = filter
            self.configuration = configuration
            self.expectedPixelSize = expectedPixelSize
            self.displayID = displayID
            self.scalePlan = scalePlan
            self.receipt = receipt
            self.topology = topology
            self.generation = generation
        }
    }

    private struct ExactWindowCaptureOutput {
        let image: CGImage
        let metadataContext: WindowMetadataContext
    }

    private struct WindowMetadataIdentity {
        let windowID: CGWindowID
        let title: String
        let bounds: CGRect
        let isOnScreen: Bool
        let layer: Int
        let alpha: CGFloat
        let sharingState: WindowSharingState?

        init(_ window: SCWindow) {
            self.windowID = window.windowID
            self.title = window.title ?? ""
            self.bounds = window.frame
            self.isOnScreen = window.isOnScreen
            self.layer = window.windowLayer
            self.alpha = 1
            self.sharingState = nil
        }

        init(_ identity: SystemWindowIdentity) {
            self.windowID = identity.windowID
            self.title = identity.title
            self.bounds = identity.bounds
            self.isOnScreen = identity.isOnScreen
            self.layer = identity.layer
            self.alpha = identity.alpha
            self.sharingState = identity.sharingState
        }
    }

    private struct DisplayMetadataIdentity {
        let displayID: CGDirectDisplayID
        let bounds: CGRect

        init(_ display: SCDisplay) {
            self.displayID = display.displayID
            self.bounds = display.frame
        }

        init(_ display: ScreenCaptureDisplayTopology.Display) {
            self.displayID = display.displayID
            self.bounds = display.bounds
        }
    }

    private struct WindowCaptureResources {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let expectedPixelSize: (width: Int, height: Int)
    }

    private struct WindowMetadataContext {
        let mode: CaptureMode
        let applicationInfo: ServiceApplicationInfo?
        let window: WindowMetadataIdentity
        let windowIndex: Int
        let display: DisplayMetadataIdentity
        let displayIndex: Int
        let scalePlan: ScreenCaptureScaleResolver.Plan
        let mutationIdentity: WindowMutationIdentity?
        let selectorResolutionProofs: [SelectorResolutionProof]?
        let windowPlanCacheStatus: CaptureWindowPlanCacheStatus?
        let windowPlanCacheGeneration: UInt64?

        init(
            mode: CaptureMode,
            applicationInfo: ServiceApplicationInfo?,
            window: WindowMetadataIdentity,
            windowIndex: Int,
            display: DisplayMetadataIdentity,
            displayIndex: Int,
            scalePlan: ScreenCaptureScaleResolver.Plan,
            mutationIdentity: WindowMutationIdentity?,
            selectorResolutionProofs: [SelectorResolutionProof]? = nil,
            windowPlanCacheStatus: CaptureWindowPlanCacheStatus? = nil,
            windowPlanCacheGeneration: UInt64? = nil)
        {
            self.mode = mode
            self.applicationInfo = applicationInfo
            self.window = window
            self.windowIndex = windowIndex
            self.display = display
            self.displayIndex = displayIndex
            self.scalePlan = scalePlan
            self.mutationIdentity = mutationIdentity
            self.selectorResolutionProofs = selectorResolutionProofs
            self.windowPlanCacheStatus = windowPlanCacheStatus
            self.windowPlanCacheGeneration = windowPlanCacheGeneration
        }
    }

    func captureWindowImpl(
        app: ServiceApplicationInfo,
        windowIndex: Int?,
        correlationId: String,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        let content = try await ScreenCaptureKitCaptureGate.shareableContent(
            excludingDesktopWindows: false,
            onScreenWindowsOnly: false)

        let appWindows = content.windows.filter { window in
            window.owningApplication?.processID == app.processIdentifier
        }

        self.logger.debug(
            "Found windows for application",
            metadata: ["count": appWindows.count],
            correlationId: correlationId)
        guard !appWindows.isEmpty else {
            self.logger.error(
                "No windows found for application",
                metadata: ["appName": app.name],
                correlationId: correlationId)
            throw NotFoundError.window(app: app.name)
        }

        let resolvedIndex = try self.resolveWindowIndex(
            requestedIndex: windowIndex,
            windows: appWindows,
            appName: app.name,
            correlationId: correlationId)
        let targetWindow = appWindows[resolvedIndex]
        let mutationSnapshot = Self.windowMutationSnapshot(for: targetWindow)

        self.logger.debug(
            "Capturing window",
            metadata: [
                "title": targetWindow.title ?? "untitled",
                "windowID": targetWindow.windowID,
            ],
            correlationId: correlationId)

        guard let resolution = self.resolveDisplayForWindow(targetWindow, displays: content.displays) else {
            throw OperationError.captureFailed(reason: "No displays available for window capture")
        }
        let targetDisplay = resolution.display
        if !resolution.isMapped {
            self.logger.warning(
                "Window does not map to any enumerated display; using desktop-independent capture filter",
                metadata: [
                    "windowID": targetWindow.windowID,
                    "windowFrame": "\(targetWindow.frame)",
                    "displayCount": content.displays.count,
                ],
                correlationId: correlationId)
        }
        let scalePlan = self.scalePlan(for: targetDisplay, preference: scale)
        let image = try await self.captureWindowImage(
            targetWindow,
            scale: scale,
            scalePlan: scalePlan)
        let imageData = try image.pngData()
        let mutationIdentity: WindowMutationIdentity? = mutationSnapshot.flatMap { snapshot in
            guard snapshot.ownerProcessStartIdentity == app.processStartIdentity else { return nil }
            return Self.validatedMutationIdentity(snapshot)
        }
        let selectorResolutionProofs = try self.selectorResolutionProofs(
            app: app,
            windows: appWindows,
            selectedIndex: resolvedIndex,
            requestedIndex: windowIndex,
            selectedIdentity: mutationIdentity)

        self.logger.debug(
            "Screenshot created",
            metadata: [
                "imageSize": "\(image.width)x\(image.height)",
                "dataSize": imageData.count,
            ],
            correlationId: correlationId)

        await self.emitVisualizer(mode: visualizerMode, rect: targetWindow.frame)

        let metadata = self.windowMetadata(
            image: image,
            context: WindowMetadataContext(
                mode: .window,
                applicationInfo: app,
                window: WindowMetadataIdentity(targetWindow),
                windowIndex: resolvedIndex,
                display: DisplayMetadataIdentity(targetDisplay),
                displayIndex: content.displays.firstIndex(where: { $0.displayID == targetDisplay.displayID }) ?? 0,
                scalePlan: scalePlan,
                mutationIdentity: mutationIdentity,
                selectorResolutionProofs: selectorResolutionProofs))

        return CaptureResult(imageData: imageData, metadata: metadata)
    }

    func captureWindowImpl(
        windowID: CGWindowID,
        correlationId: String,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        let output: ExactWindowCaptureOutput
        do {
            output = try await self.captureExactWindow(
                windowID: windowID,
                scale: scale,
                correlationId: correlationId)
        } catch is ScreenCaptureWindowPlanCacheUnavailableError {
            return try await self.captureExactWindowFresh(
                windowID: windowID,
                correlationId: correlationId,
                visualizerMode: visualizerMode,
                scale: scale)
        }

        self.logger.debug(
            "Capturing window by id",
            metadata: [
                "title": output.metadataContext.window.title,
                "windowID": output.metadataContext.window.windowID,
            ],
            correlationId: correlationId)

        let imageData = try output.image.pngData()

        await self.emitVisualizer(mode: visualizerMode, rect: output.metadataContext.window.bounds)

        let metadata = self.windowMetadata(
            image: output.image,
            context: output.metadataContext)

        return CaptureResult(imageData: imageData, metadata: metadata)
    }

    func resolveWindowIndex(
        requestedIndex: Int?,
        windows: [SCWindow],
        appName: String,
        correlationId: String) throws -> Int
    {
        if let requestedIndex {
            guard requestedIndex >= 0, requestedIndex < windows.count else {
                let message = Self.windowIndexError(
                    requestedIndex: requestedIndex,
                    totalWindows: windows.count)
                throw PeekabooError.invalidInput(message)
            }
            return requestedIndex
        }

        if let candidateIndex = Self.firstRenderableWindowIndex(in: windows) {
            if candidateIndex != 0 {
                self.logger.debug(
                    "Auto-selected visible SCWindow",
                    metadata: ["index": candidateIndex],
                    correlationId: correlationId)
            }
            return candidateIndex
        }

        self.logger.warning(
            "Falling back to first SCWindow; no renderable windows detected",
            metadata: ["app": appName],
            correlationId: correlationId)
        return 0
    }

    func captureWindowImage(
        _ window: SCWindow,
        scale: CaptureScalePreference,
        scalePlan: ScreenCaptureScaleResolver.Plan) async throws -> CGImage
    {
        try await RetryHandler.withRetry(policy: .standard) {
            try await self.createScreenshot(
                of: window,
                scale: scale,
                targetScale: scalePlan.nativeScale)
        }
    }

    private func captureExactWindow(
        windowID: CGWindowID,
        scale: CaptureScalePreference,
        correlationId: String) async throws -> ExactWindowCaptureOutput
    {
        let key = ScreenCaptureKitWindowPlanCache<ExactWindowCapturePlan>.Key(
            windowID: windowID,
            usesNativeScale: scale == .native)
        let result = try await ScreenCaptureWindowPlanExecutor.execute(
            cachedPlan: {
                let cached = self.exactWindowPlanCache.value(for: key)
                if cached != nil {
                    self.logger.debug(
                        "Reusing warm ScreenCaptureKit exact-window plan",
                        metadata: ["windowID": windowID],
                        correlationId: correlationId)
                }
                return cached
            },
            buildPlan: {
                try await self.buildExactWindowPlan(
                    key: key,
                    scale: scale,
                    correlationId: correlationId)
            },
            capture: { plan, cacheStatus in
                let image = try await self.captureImage(
                    filter: plan.filter,
                    configuration: plan.configuration,
                    expectedPixelSize: plan.expectedPixelSize,
                    retrySafeStalePlanOnPixelMismatch: true)
                return try self.exactWindowCaptureOutput(
                    image: image,
                    plan: plan,
                    cacheStatus: cacheStatus)
            },
            validation: { self.validation(of: $0) },
            evict: { self.exactWindowPlanCache.removeValue(for: $0.key, ifSameAs: $0) })
        return result.output
    }

    private func buildExactWindowPlan(
        key: ScreenCaptureKitWindowPlanCache<ExactWindowCapturePlan>.Key,
        scale: CaptureScalePreference,
        correlationId: String) async throws -> ExactWindowCapturePlan
    {
        guard let receipt = ScreenCaptureWindowPlanReceipt.current(windowID: key.windowID),
              let topology = ScreenCaptureDisplayTopology.current()
        else {
            throw ScreenCaptureWindowPlanCacheUnavailableError()
        }

        let content = try await ScreenCaptureKitCaptureGate.shareableContent(
            excludingDesktopWindows: false,
            onScreenWindowsOnly: false)
        guard let targetWindow = content.windows.first(where: { $0.windowID == key.windowID }) else {
            throw PeekabooError.windowNotFound(criteria: "window_id \(key.windowID)")
        }
        guard self.matches(targetWindow, receipt: receipt) else {
            throw RetrySafeStaleWindowPlanError(terminalError: OperationError.captureFailed(
                reason: "Exact window changed while ScreenCaptureKit prepared its capture plan"))
        }
        guard let resolution = self.resolveDisplayForWindow(targetWindow, displays: content.displays) else {
            throw OperationError.captureFailed(reason: "No displays available for window capture")
        }
        let targetDisplay = resolution.display
        guard topology.containsScreenCaptureKitDisplay(
            displayID: targetDisplay.displayID,
            bounds: targetDisplay.frame,
            width: targetDisplay.width,
            height: targetDisplay.height),
            let topologyDisplay = topology.display(withID: targetDisplay.displayID)
        else {
            throw RetrySafeStaleWindowPlanError(terminalError: OperationError.captureFailed(
                reason: "ScreenCaptureKit display metadata disagreed with the active display topology"))
        }
        if !resolution.isMapped {
            self.logger.warning(
                "Window does not map to any enumerated display; using desktop-independent capture filter",
                metadata: [
                    "windowID": targetWindow.windowID,
                    "windowFrame": "\(targetWindow.frame)",
                    "displayCount": content.displays.count,
                ],
                correlationId: correlationId)
        }

        let scalePlan = self.scalePlan(for: topologyDisplay, preference: scale)
        let resources = self.windowCaptureResources(
            for: targetWindow,
            scale: scale,
            targetScale: scalePlan.nativeScale)
        let currentTopology = ScreenCaptureDisplayTopology.current()
        let currentScalePlan = currentTopology?.display(withID: targetDisplay.displayID).map {
            self.scalePlan(for: $0, preference: scale)
        }
        switch ScreenCaptureWindowPlanValidation.result(
            expectedReceipt: receipt,
            expectedTopology: topology,
            currentReceipt: ScreenCaptureWindowPlanReceipt.current(windowID: key.windowID),
            currentTopology: currentTopology,
            expectedScalePlan: scalePlan,
            currentScalePlan: currentScalePlan)
        {
        case .matched:
            break
        case .unavailable:
            throw ScreenCaptureWindowPlanCacheUnavailableError()
        case .changed:
            throw RetrySafeStaleWindowPlanError(terminalError: OperationError.captureFailed(
                reason: "Exact window or display topology changed while building its capture plan"))
        }

        let plan = ExactWindowCapturePlan(
            key: key,
            filter: resources.filter,
            configuration: resources.configuration,
            expectedPixelSize: resources.expectedPixelSize,
            displayID: targetDisplay.displayID,
            scalePlan: scalePlan,
            receipt: receipt,
            topology: topology,
            generation: self.allocateExactWindowPlanGeneration())
        self.logger.debug(
            "Building cold ScreenCaptureKit exact-window plan",
            metadata: [
                "windowID": key.windowID,
                "planGeneration": plan.generation,
            ],
            correlationId: correlationId)
        self.exactWindowPlanCache.insert(plan, for: key)
        return plan
    }

    private func validation(of plan: ExactWindowCapturePlan) -> ScreenCaptureWindowPlanValidation.Result {
        guard let currentTopology = ScreenCaptureDisplayTopology.current() else { return .unavailable }
        let preference: CaptureScalePreference = plan.key.usesNativeScale ? .native : .logical1x
        let currentScalePlan = currentTopology.display(withID: plan.displayID).map {
            self.scalePlan(for: $0, preference: preference)
        }
        return ScreenCaptureWindowPlanValidation.result(
            expectedReceipt: plan.receipt,
            expectedTopology: plan.topology,
            currentReceipt: ScreenCaptureWindowPlanReceipt.current(windowID: plan.key.windowID),
            currentTopology: currentTopology,
            expectedScalePlan: plan.scalePlan,
            currentScalePlan: currentScalePlan)
    }

    private func exactWindowCaptureOutput(
        image: CGImage,
        plan: ExactWindowCapturePlan,
        cacheStatus: CaptureWindowPlanCacheStatus) throws -> ExactWindowCaptureOutput
    {
        guard let identity = SystemIdentityResolver.stableWindowIdentity(plan.key.windowID),
              let currentReceipt = ScreenCaptureWindowPlanReceipt.make(identity: identity)
        else {
            throw ScreenCaptureWindowPlanCacheUnavailableError()
        }
        guard currentReceipt == plan.receipt else {
            throw RetrySafeStaleWindowPlanError(terminalError: .captureFailed(
                "Exact window changed while ScreenCaptureKit prepared capture metadata"))
        }

        let appWindows = SystemIdentityResolver.windowIdentities(
            ownerProcessIdentifier: plan.receipt.ownerProcessIdentifier)
        guard !appWindows.isEmpty,
              let windowIndex = appWindows.firstIndex(where: { $0.windowID == plan.key.windowID }),
              let listedReceipt = ScreenCaptureWindowPlanReceipt.make(identity: appWindows[windowIndex])
        else {
            throw ScreenCaptureWindowPlanCacheUnavailableError()
        }
        guard listedReceipt == plan.receipt else {
            throw RetrySafeStaleWindowPlanError(terminalError: .captureFailed(
                "Exact window changed while ScreenCaptureKit resolved capture metadata"))
        }

        guard let topology = ScreenCaptureDisplayTopology.current() else {
            throw ScreenCaptureWindowPlanCacheUnavailableError()
        }
        guard topology == plan.topology,
              let display = topology.display(withID: plan.displayID)
        else {
            throw RetrySafeStaleWindowPlanError(terminalError: .captureFailed(
                "Display topology changed while ScreenCaptureKit resolved capture metadata"))
        }
        let preference: CaptureScalePreference = plan.key.usesNativeScale ? .native : .logical1x
        guard self.scalePlan(for: display, preference: preference) == plan.scalePlan else {
            throw RetrySafeStaleWindowPlanError(terminalError: .captureFailed(
                "Display scale changed while ScreenCaptureKit resolved capture metadata"))
        }
        guard SystemIdentityResolver.processStartIdentity(plan.receipt.ownerProcessIdentifier) ==
            plan.receipt.ownerProcessStartIdentity
        else {
            throw RetrySafeStaleWindowPlanError(terminalError: .captureFailed(
                "Window owner process generation changed while resolving capture metadata"))
        }

        return ExactWindowCaptureOutput(
            image: image,
            metadataContext: WindowMetadataContext(
                mode: .window,
                applicationInfo: self.applicationInfo(
                    for: plan.receipt.ownerProcessIdentifier,
                    processStartIdentity: plan.receipt.ownerProcessStartIdentity,
                    windowCount: appWindows.count),
                window: WindowMetadataIdentity(appWindows[windowIndex]),
                windowIndex: windowIndex,
                display: DisplayMetadataIdentity(display),
                displayIndex: topology.displays.firstIndex(where: { $0.displayID == display.displayID }) ?? 0,
                scalePlan: plan.scalePlan,
                mutationIdentity: plan.receipt.mutationIdentity,
                windowPlanCacheStatus: cacheStatus,
                windowPlanCacheGeneration: plan.generation))
    }

    private func matches(_ window: SCWindow, receipt: ScreenCaptureWindowPlanReceipt) -> Bool {
        window.windowID == receipt.windowID &&
            window.owningApplication?.processID == receipt.ownerProcessIdentifier &&
            window.windowLayer == receipt.layer &&
            window.frame == receipt.bounds &&
            window.isOnScreen == receipt.isOnScreen
    }

    private func allocateExactWindowPlanGeneration() -> UInt64 {
        let generation = self.nextExactWindowPlanGeneration
        self.nextExactWindowPlanGeneration &+= 1
        return generation
    }

    /// Capture a window screenshot.
    ///
    /// Window capture uses ScreenCaptureKit's desktop-independent filter. A display-bound filter describes a
    /// display canvas with selected windows composited into it; on macOS 27 that path can return a display-sized
    /// transparent surface or fail to invoke the screenshot callback. The desktop-independent contract instead
    /// returns only the requested window while display resolution remains available for scale and metadata.
    func createScreenshot(
        of window: SCWindow,
        scale: CaptureScalePreference,
        targetScale: CGFloat) async throws -> CGImage
    {
        let resources = self.windowCaptureResources(for: window, scale: scale, targetScale: targetScale)
        return try await self.captureImage(
            filter: resources.filter,
            configuration: resources.configuration,
            expectedPixelSize: resources.expectedPixelSize,
            retrySafeStalePlanOnPixelMismatch: false)
    }

    private func windowCaptureResources(
        for window: SCWindow,
        scale: CaptureScalePreference,
        targetScale: CGFloat) -> WindowCaptureResources
    {
        let configuration = SCStreamConfiguration()
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.scalesToFit = true
        if #available(macOS 14.2, *) {
            configuration.includeChildWindows = false
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let expectedPixelSize = ScreenCapturePlanner.desktopIndependentWindowPixelSize(
            filterContentRect: filter.contentRect,
            fallbackWindowFrame: window.frame,
            pointPixelScale: CGFloat(filter.pointPixelScale),
            fallbackNativeScale: targetScale,
            useNativeScale: scale == .native)
        configuration.width = expectedPixelSize.width
        configuration.height = expectedPixelSize.height
        return WindowCaptureResources(
            filter: filter,
            configuration: configuration,
            expectedPixelSize: expectedPixelSize)
    }

    private func captureImage(
        filter: SCContentFilter,
        configuration: SCStreamConfiguration,
        expectedPixelSize: (width: Int, height: Int),
        retrySafeStalePlanOnPixelMismatch: Bool) async throws -> CGImage
    {
        let image = try await ScreenCaptureKitCaptureGate.captureImage(
            contentFilter: filter,
            configuration: configuration)
        guard ScreenCapturePlanner.matchesExpectedWindowPixelSize(
            imageWidth: image.width,
            imageHeight: image.height,
            expected: expectedPixelSize)
        else {
            let error = OperationError.captureFailed(
                reason: "ScreenCaptureKit returned \(image.width)x\(image.height) for a " +
                    "\(expectedPixelSize.width)x\(expectedPixelSize.height) window capture")
            if retrySafeStalePlanOnPixelMismatch {
                throw RetrySafeStaleWindowPlanError(terminalError: error)
            }
            throw error
        }
        return image
    }

    private func captureExactWindowFresh(
        windowID: CGWindowID,
        correlationId: String,
        visualizerMode: CaptureVisualizerMode,
        scale: CaptureScalePreference) async throws -> CaptureResult
    {
        let content = try await ScreenCaptureKitCaptureGate.shareableContent(
            excludingDesktopWindows: false,
            onScreenWindowsOnly: false)
        guard let targetWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw PeekabooError.windowNotFound(criteria: "window_id \(windowID)")
        }

        let owningPID = targetWindow.owningApplication?.processID
        let appWindows = owningPID.map { owner in
            content.windows.filter { $0.owningApplication?.processID == owner }
        } ?? [targetWindow]
        let resolvedIndex = appWindows.firstIndex(where: { $0.windowID == windowID }) ?? 0
        let mutationSnapshot = Self.windowMutationSnapshot(for: targetWindow)
        guard let resolution = self.resolveDisplayForWindow(targetWindow, displays: content.displays) else {
            throw OperationError.captureFailed(reason: "No displays available for window capture")
        }
        let targetDisplay = resolution.display
        let scalePlan = self.scalePlan(for: targetDisplay, preference: scale)
        let image = try await self.captureWindowImage(
            targetWindow,
            scale: scale,
            scalePlan: scalePlan)
        let mutationIdentity = mutationSnapshot.flatMap(Self.validatedMutationIdentity)
        let imageData = try image.pngData()

        self.logger.debug(
            "Exact-window cache preflight unavailable; used one fresh ScreenCaptureKit plan",
            metadata: ["windowID": windowID],
            correlationId: correlationId)
        await self.emitVisualizer(mode: visualizerMode, rect: targetWindow.frame)

        return CaptureResult(
            imageData: imageData,
            metadata: self.windowMetadata(
                image: image,
                context: WindowMetadataContext(
                    mode: .window,
                    applicationInfo: self.applicationInfo(
                        for: owningPID,
                        processStartIdentity: mutationIdentity?.ownerProcessStartIdentity,
                        windowCount: appWindows.count),
                    window: WindowMetadataIdentity(targetWindow),
                    windowIndex: resolvedIndex,
                    display: DisplayMetadataIdentity(targetDisplay),
                    displayIndex: content.displays.firstIndex(where: {
                        $0.displayID == targetDisplay.displayID
                    }) ?? 0,
                    scalePlan: scalePlan,
                    mutationIdentity: mutationIdentity)))
    }

    private func windowMetadata(
        image: CGImage,
        context: WindowMetadataContext) -> CaptureMetadata
    {
        CaptureMetadata(
            size: CGSize(width: image.width, height: image.height),
            mode: context.mode,
            applicationInfo: context.applicationInfo,
            windowInfo: ServiceWindowInfo(
                windowID: Int(context.window.windowID),
                title: context.window.title,
                bounds: context.window.bounds,
                isMinimized: false,
                isMainWindow: context.window.isOnScreen,
                windowLevel: 0,
                alpha: context.window.alpha,
                index: context.windowIndex,
                isOffScreen: !context.window.isOnScreen,
                layer: context.window.layer,
                isOnScreen: context.window.isOnScreen,
                sharingState: context.window.sharingState,
                mutationIdentity: context.mutationIdentity),
            displayInfo: DisplayInfo(
                index: context.displayIndex,
                name: context.display.displayID.description,
                bounds: context.display.bounds,
                scaleFactor: context.scalePlan.outputScale),
            diagnostics: ScreenCaptureScaleResolver.diagnostics(
                plan: context.scalePlan,
                finalPixelSize: CGSize(width: image.width, height: image.height),
                windowPlanCacheStatus: context.windowPlanCacheStatus,
                windowPlanCacheGeneration: context.windowPlanCacheGeneration),
            selectorResolutionProofs: context.selectorResolutionProofs)
    }

    private func selectorResolutionProofs(
        app: ServiceApplicationInfo,
        windows: [SCWindow],
        selectedIndex: Int,
        requestedIndex: Int?,
        selectedIdentity: WindowMutationIdentity?) throws -> [SelectorResolutionProof]?
    {
        guard let processIdentity = app.processIdentity,
              let selectedIdentity,
              selectedIdentity.processIdentity == processIdentity
        else {
            return app.selectorResolutionProofs
        }
        let candidates = windows.enumerated().map { index, window in
            ServiceWindowInfo(
                windowID: Int(window.windowID),
                title: window.title ?? "",
                bounds: window.frame,
                index: index,
                mutationIdentity: index == selectedIndex ? selectedIdentity : nil)
        }
        let selection = requestedIndex.map(WindowSelection.index) ?? .automatic
        let windowProof = try WindowSelectorResolutionProof.make(
            selection: selection,
            candidates: candidates,
            selected: candidates[selectedIndex],
            processIdentity: processIdentity)
        return (app.selectorResolutionProofs ?? []).map {
            $0.selecting(windowIdentity: selectedIdentity)
        } + [windowProof]
    }

    func applicationInfo(
        for processID: pid_t?,
        processStartIdentity: UInt64?,
        windowCount: Int) -> ServiceApplicationInfo?
    {
        guard let processID else { return nil }
        if let processStartIdentity,
           SystemIdentityResolver.processStartIdentity(processID) != processStartIdentity
        {
            return nil
        }
        guard let runningApplication = NSRunningApplication(processIdentifier: processID),
              runningApplication.processIdentifier == processID
        else {
            return nil
        }
        let applicationInfo = ServiceApplicationInfo(
            processIdentifier: runningApplication.processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: runningApplication.bundleIdentifier,
            name: runningApplication.localizedName ?? runningApplication.bundleIdentifier ?? "Unknown",
            bundlePath: runningApplication.bundleURL?.path,
            isActive: runningApplication.isActive,
            isHidden: runningApplication.isHidden,
            windowCount: windowCount)
        if let processStartIdentity,
           SystemIdentityResolver.processStartIdentity(processID) != processStartIdentity
        {
            return nil
        }
        return applicationInfo
    }

    private nonisolated static func windowMutationSnapshot(
        for window: SCWindow) -> SystemIdentityResolver.WindowMutationSnapshot?
    {
        guard let ownerProcessIdentifier = window.owningApplication?.processID,
              let processStartIdentity = SystemIdentityResolver.processStartIdentity(ownerProcessIdentifier)
        else {
            return nil
        }
        return SystemIdentityResolver.WindowMutationSnapshot(
            windowID: window.windowID,
            ownerProcessIdentifier: ownerProcessIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            bounds: window.frame,
            isMinimized: !window.isOnScreen)
    }

    private nonisolated static func validatedMutationIdentity(
        _ snapshot: SystemIdentityResolver.WindowMutationSnapshot) -> WindowMutationIdentity?
    {
        SystemIdentityResolver.windowMutationIdentity(
            windowID: snapshot.windowID,
            expectedOwnerProcessIdentifier: snapshot.ownerProcessIdentifier,
            expectedOwnerProcessStartIdentity: snapshot.ownerProcessStartIdentity,
            expectedBounds: snapshot.bounds,
            isMinimized: snapshot.isMinimized)
    }

    nonisolated static func firstRenderableWindowIndex(in windows: [SCWindow]) -> Int? {
        for (index, window) in windows.indexed() {
            guard let info = self.makeFilteringInfo(from: window, index: index) else { continue }
            guard WindowFiltering.isRenderable(info) else { continue }
            return index
        }
        return nil
    }

    nonisolated static func makeFilteringInfo(from window: SCWindow, index: Int) -> ServiceWindowInfo? {
        ServiceWindowInfo(
            windowID: Int(window.windowID),
            title: window.title ?? "",
            bounds: window.frame,
            isMinimized: false,
            isMainWindow: window.isOnScreen,
            windowLevel: 0,
            alpha: 1.0,
            index: index,
            isOffScreen: !window.isOnScreen,
            layer: 0,
            isOnScreen: window.isOnScreen)
    }
}
