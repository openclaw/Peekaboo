import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Click on UI elements identified in the current snapshot using intelligent element finding and smart waiting.
@available(macOS 14.0, *)
@MainActor
struct ClickCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Argument(help: "Element text or query to click")
    var query: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @Option(help: "Opaque element ID copied from current see or inspect-ui output")
    var on: String?

    @Option(name: .customLong("id"), help: "Element ID to click (alias for --on)")
    var id: String?

    @OptionGroup var target: InteractionTargetOptions

    @Option(help: "Click at coordinates (x,y)")
    var coords: String?

    @Flag(help: "Treat --coords as global screen coordinates even when target options are supplied")
    var globalCoords = false

    @Option(help: "Maximum milliseconds to wait for element")
    var waitFor: Int = 5000

    @Flag(help: "Double-click instead of single click")
    var double = false

    @Flag(help: "Right-click (secondary click)")
    var right = false

    @Flag(help: "Press and hold for 1.2 seconds at a stationary point")
    var longPress = false

    @Flag(help: "Focus target and send a foreground mouse click")
    var foreground = false

    @OptionGroup var focusOptions: FocusCommandOptions

    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    var services: any PeekabooServiceProviding {
        self.resolvedRuntime.services
    }

    private var logger: Logger {
        self.resolvedRuntime.logger
    }

    var outputLogger: Logger {
        self.logger
    }

    var jsonOutput: Bool {
        self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
    }

    private var deliveryMode: ClickDeliveryMode {
        if self.focusOptions.backgroundDeliveryExplicitlyRequested {
            return .background
        }
        if self.foreground || self.longPress || self.focusOptions.hasForegroundFocusOverrides {
            return .foreground
        }
        return .background
    }

    private var usesBackgroundDelivery: Bool {
        self.deliveryMode == .background
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        let startTime = Date()

        do {
            try validate()

            // Determine click target first to check if we need a snapshot
            let clickTarget: ClickTarget
            let waitResult: WaitForElementResult
            var activeSnapshotId: String
            var coordinateResolution: InteractionCoordinateResolution?
            var explicitWindowResolution: InteractionWindowResolution?

            // Check if we're clicking by coordinates (doesn't need snapshot)
            if let coordString = coords {
                // Click by coordinates (no snapshot needed)
                guard let point = Self.parseCoordinates(coordString) else {
                    throw ValidationError("Invalid coordinates format. Use: x,y")
                }
                let resolvedCoordinates = try await InteractionCoordinateResolver.resolveClickCoordinates(
                    point,
                    target: self.target,
                    services: self.services,
                    forceGlobal: self.globalCoords
                )
                coordinateResolution = resolvedCoordinates
                clickTarget = .coordinates(resolvedCoordinates.screenPoint)
                waitResult = WaitForElementResult(found: true, element: nil, waitTime: 0)
                activeSnapshotId = "" // Not needed for coordinate clicks
                if !self.usesBackgroundDelivery {
                    self.resolvedRuntime.beginInteractionMutation()
                }
                try await self.focusApplicationIfNeeded(
                    snapshotId: nil,
                    coordinateResolution: resolvedCoordinates
                )

                // Verify the resolved target is actually frontmost after focus attempt.
                // InputDriver.click() sends a CGEvent at screen-absolute coordinates,
                // so if the target window is not frontmost, the click will land on
                // whatever window is at that position (see #90).
                if !self.usesBackgroundDelivery {
                    try await verifyFocusForCoordinateClick(coordinateResolution: resolvedCoordinates)
                }

            } else {
                // `click` keeps using the latest observation for element lookup even when
                // a target app is supplied; only focus skips the snapshot for explicit targets.
                var observation = await InteractionObservationContext.resolve(
                    explicitSnapshot: self.snapshot,
                    fallbackToLatest: true,
                    snapshots: self.services.snapshots
                )
                try await observation.validateIfExplicit(using: self.services.snapshots)

                explicitWindowResolution = try await self.resolveExplicitWindowSelection(
                    observation: observation
                )
                if !self.usesBackgroundDelivery {
                    self.resolvedRuntime.beginInteractionMutation()
                }
                try await self.focusApplicationIfNeeded(snapshotId: observation.focusSnapshotId(for: self.target))

                // Use whichever element ID parameter was provided
                let elementId = self.on ?? self.id

                if let elementId {
                    if !self.usesBackgroundDelivery {
                        let refreshRuntime = self.resolvedRuntime
                        observation = try await InteractionObservationRefresher.refreshForMissingElementsIfNeeded(
                            observation,
                            elementIds: [elementId],
                            target: self.target,
                            services: self.services,
                            logger: self.logger,
                            beforeRefresh: { startedAt in
                                refreshRuntime.beginInteractionMutation(at: startedAt)
                            }
                        )
                    }
                    activeSnapshotId = observation.snapshotId ?? ""

                    clickTarget = .elementId(elementId)
                    if self.usesBackgroundDelivery {
                        let element = try await cachedElementById(elementId, observation: observation)
                        waitResult = WaitForElementResult(found: true, element: element, waitTime: 0)
                    } else {
                        // Click by element ID with auto-wait
                        waitResult = try await AutomationServiceBridge.waitForElement(
                            automation: self.services.automation,
                            target: clickTarget,
                            timeout: TimeInterval(self.waitFor) / 1000.0,
                            snapshotId: activeSnapshotId.isEmpty ? nil : activeSnapshotId
                        )

                        if !waitResult.found {
                            throw PeekabooError.elementNotFound(Self.elementNotFoundMessage(elementId))
                        }
                    }

                } else if let searchQuery = query {
                    if !self.usesBackgroundDelivery {
                        observation = try await self.refreshObservationIfQueryMissing(observation, query: searchQuery)
                    }
                    activeSnapshotId = observation.snapshotId ?? ""

                    if self.usesBackgroundDelivery {
                        let element = try await cachedElementMatching(searchQuery, observation: observation)
                        clickTarget = .elementId(element.id)
                        waitResult = WaitForElementResult(found: true, element: element, waitTime: 0)
                    } else {
                        // Find element by query with auto-wait
                        clickTarget = .query(searchQuery)
                        waitResult = try await AutomationServiceBridge.waitForElement(
                            automation: self.services.automation,
                            target: clickTarget,
                            timeout: TimeInterval(self.waitFor) / 1000.0,
                            snapshotId: activeSnapshotId.isEmpty ? nil : activeSnapshotId
                        )

                        if !waitResult.found {
                            let message = Self.queryNotFoundMessage(
                                searchQuery,
                                waitFor: self.waitFor
                            )
                            throw PeekabooError.elementNotFound(message)
                        }
                    }

                } else {
                    // This case should not be reachable due to the validate() method
                    throw ValidationError("No target specified for click.")
                }
            }

            try await self.resolveAndDispatchClick(
                clickTarget,
                snapshotId: activeSnapshotId,
                resolvedElement: waitResult.element,
                coordinateResolution: coordinateResolution,
                explicitWindowResolution: explicitWindowResolution
            )

            // Brief delay to ensure click is processed
            try? await Task.sleep(nanoseconds: 20_000_000) // 0.02 seconds
            // Result formatting can await bridge lookups. Freeze the mutation boundary first so
            // observations created after the click remain eligible as the next implicit latest.
            let snapshotInvalidationCutoff = Date()

            // The click already happened. Advance every host watermark before diagnostics that can
            // fail if the action closed, moved, or resized its target window.
            await InteractionObservationInvalidator.invalidateAfterClickMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "click",
                through: snapshotInvalidationCutoff
            )
            try Task.checkCancellation()

            try await self.outputClickResult(
                clickTarget: clickTarget,
                waitResult: waitResult,
                snapshotId: activeSnapshotId,
                resolutions: (coordinateResolution, explicitWindowResolution),
                startTime: startTime
            )

        } catch {
            handleError(error)
            throw ExitCode.failure
        }
    }

    private func outputClickResult(
        clickTarget: ClickTarget,
        waitResult: WaitForElementResult,
        snapshotId: String,
        resolutions: (coordinate: InteractionCoordinateResolution?, window: InteractionWindowResolution?),
        startTime: Date
    ) async throws {
        let coordinateResolution = resolutions.coordinate
        let explicitWindowResolution = resolutions.window
        let appName = await resultApplicationName(
            snapshotId: snapshotId,
            coordinateResolution: coordinateResolution
        )
        let details = try await clickOutputDetails(
            clickTarget: clickTarget,
            waitResult: waitResult,
            snapshotId: snapshotId,
            coordinateResolution: coordinateResolution
        )
        let result = ClickResult(
            success: true,
            clickedElement: details.clickedElement,
            clickLocation: details.location,
            waitTime: waitResult.waitTime,
            executionTime: Date().timeIntervalSince(startTime),
            targetApp: appName,
            targetWindowId: explicitWindowResolution?.windowInfo.windowID ?? coordinateResolution?.targetWindowID,
            targetWindowTitle: explicitWindowResolution?.windowInfo.title ?? coordinateResolution?.targetWindowTitle,
            coordinateSpace: coordinateResolution?.coordinateSpace.rawValue,
            inputCoordinates: coordinateResolution?.inputPoint,
            screenCoordinates: coordinateResolution?.screenPoint,
            targetPoint: details.targetPointDiagnostics,
            deliveryMode: self.deliveryMode.rawValue
        )
        self.outputSuccess(result)
    }

    private func clickOutputDetails(
        clickTarget: ClickTarget,
        waitResult: WaitForElementResult,
        snapshotId: String,
        coordinateResolution: InteractionCoordinateResolution?
    ) async throws
    -> (location: CGPoint, clickedElement: String?, targetPointDiagnostics: InteractionTargetPointDiagnostics?) {
        switch clickTarget {
        case let .elementId(id):
            guard let element = waitResult.element else {
                return (.zero, "Element ID: \(id)", nil)
            }
            return try await self.elementOutputDetails(
                element: element,
                elementId: id,
                snapshotId: snapshotId
            )

        case let .coordinates(point):
            let diagnostics = if let coordinateResolution {
                InteractionTargetPointDiagnostics(
                    source: InteractionTargetPointSource.coordinates.rawValue,
                    elementId: nil,
                    snapshotId: nil,
                    original: InteractionPoint(coordinateResolution.inputPoint),
                    resolved: InteractionPoint(coordinateResolution.screenPoint),
                    windowAdjustment: nil,
                    coordinate: coordinateResolution.diagnostics
                )
            } else {
                InteractionTargetPointResolver.coordinate(point, source: .coordinates).diagnostics
            }
            return (point, nil, diagnostics)

        case let .query(query):
            guard let element = waitResult.element else {
                return (.zero, "Element matching: \(query)", nil)
            }
            return try await self.elementOutputDetails(
                element: element,
                elementId: element.id,
                snapshotId: snapshotId
            )
        }
    }

    private func elementOutputDetails(
        element: DetectedElement,
        elementId: String,
        snapshotId: String
    ) async throws
    -> (location: CGPoint, clickedElement: String?, targetPointDiagnostics: InteractionTargetPointDiagnostics?) {
        let resolvedSnapshotId = snapshotId.isEmpty ? nil : snapshotId
        do {
            let resolution = try await InteractionTargetPointResolver.elementCenterResolution(
                element: element,
                elementId: elementId,
                snapshotId: resolvedSnapshotId,
                snapshots: self.services.snapshots
            )
            return (resolution.point, formatElementInfo(element), resolution.diagnostics)
        } catch let error as CancellationError {
            throw error
        } catch {
            // The click already succeeded; its target may have closed or moved before result formatting.
            self.logger.debug("Post-click target diagnostics unavailable: \(error.localizedDescription)")
            let point = CGPoint(x: element.bounds.midX, y: element.bounds.midY)
            let diagnostics = InteractionTargetPointDiagnostics(
                source: InteractionTargetPointSource.element.rawValue,
                elementId: elementId,
                snapshotId: resolvedSnapshotId,
                original: InteractionPoint(point),
                resolved: InteractionPoint(point),
                windowAdjustment: nil
            )
            return (point, formatElementInfo(element), diagnostics)
        }
    }

    private func frontmostApplicationName() async -> String {
        await (try? self.services.applications.getFrontmostApplication().name) ?? "Unknown"
    }

    private func resultApplicationName(
        snapshotId: String,
        coordinateResolution: InteractionCoordinateResolution? = nil
    ) async -> String {
        if let targetApplicationName = coordinateResolution?.targetApplicationName {
            return targetApplicationName
        }
        if let processIdentifier = coordinateResolution?.targetProcessIdentifier {
            return await applicationName(processIdentifier: processIdentifier) ?? "PID \(processIdentifier)"
        }
        if let windowID = coordinateResolution?.targetWindowID {
            return "window \(windowID)"
        }

        guard self.usesBackgroundDelivery else {
            return await self.frontmostApplicationName()
        }

        if let pid = target.pid {
            return await applicationName(processIdentifier: pid) ?? "PID \(pid)"
        }

        if let appIdentifier = target.app?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appIdentifier.isEmpty {
            return await (try? self.services.applications.findApplication(identifier: appIdentifier).name) ??
                appIdentifier
        }

        guard !snapshotId.isEmpty,
              let snapshot = try? await services.snapshots.getUIAutomationSnapshot(snapshotId: snapshotId)
        else {
            if let detectionResult = try? await services.snapshots.getDetectionResult(snapshotId: snapshotId) {
                if let applicationName = detectionResult.metadata.windowContext?.applicationName {
                    return applicationName
                }
                if let processId = detectionResult.metadata.windowContext?.applicationProcessId {
                    return await applicationName(processIdentifier: processId) ?? "PID \(processId)"
                }
            }
            return await self.frontmostApplicationName()
        }

        if let applicationName = snapshot.applicationName {
            return applicationName
        }

        if let processId = snapshot.applicationProcessId {
            return await applicationName(processIdentifier: processId) ?? "PID \(processId)"
        }

        return await self.frontmostApplicationName()
    }

    private func applicationName(processIdentifier: Int32) async -> String? {
        guard let output = try? await services.applications.listApplications() else {
            return nil
        }
        return output.data.applications.first { $0.processIdentifier == processIdentifier }?.name
    }

    private func outputSuccess(_ result: ClickResult) {
        output(result) {
            print("✅ Click successful")
            print("🎯 App: \(result.targetApp)")
            if let deliveryMode = result.deliveryMode {
                print("🎯 Mode: \(deliveryMode)")
            }
            if let coordinateSpace = result.coordinateSpace {
                print("🎯 Coordinate space: \(coordinateSpace)")
            }
            if let windowID = result.targetWindowId {
                if let title = result.targetWindowTitle, !title.isEmpty {
                    print("🪟 Window: \(windowID) (\(title))")
                } else {
                    print("🪟 Window: \(windowID)")
                }
            }
            if let info = result.clickedElement {
                print("📱 Clicked: \(info)")
            }
            let x = result.clickLocation["x"] ?? 0
            let y = result.clickLocation["y"] ?? 0
            print("📍 Location: (\(Int(x)), \(Int(y)))")
            if result.waitTime > 0 {
                print("⏳ Waited: \(String(format: "%.1f", result.waitTime))s")
            }
            print("⏱️  Completed in \(String(format: "%.2f", result.executionTime))s")
        }
    }

    private func refreshObservationIfQueryMissing(
        _ observation: InteractionObservationContext,
        query: String
    ) async throws -> InteractionObservationContext {
        try await InteractionObservationRefresher.refreshForMissingQueryIfNeeded(
            observation,
            query: query,
            target: self.target,
            services: self.services,
            logger: self.logger,
            beforeRefresh: { startedAt in
                self.resolvedRuntime.beginInteractionMutation(at: startedAt)
            }
        )
    }

    private func resolveExplicitWindowSelection(
        observation: InteractionObservationContext
    ) async throws -> InteractionWindowResolution? {
        guard self.target.windowId != nil || self.target.windowTitle != nil || self.target.windowIndex != nil else {
            return nil
        }

        let resolution = try await InteractionCoordinateResolver.resolveTargetWindow(
            target: self.target,
            services: self.services
        )
        guard self.usesBackgroundDelivery else {
            return resolution
        }
        let snapshotId = try observation.requireSnapshot()
        let detectionResult = try await observation.requireDetectionResult(using: self.services.snapshots)
        try InteractionWindowSelectionValidator.validate(
            resolution: resolution,
            snapshotContext: detectionResult.metadata.windowContext,
            snapshotId: snapshotId
        )
        return resolution
    }

    private func cachedElementById(
        _ elementId: String,
        observation: InteractionObservationContext
    ) async throws -> DetectedElement {
        let detectionResult = try await observation.requireDetectionResult(using: self.services.snapshots)
        guard let element = detectionResult.elements.findById(elementId) else {
            throw PeekabooError.elementNotFound(Self.elementNotFoundMessage(elementId))
        }
        return element
    }

    private func cachedElementMatching(
        _ query: String,
        observation: InteractionObservationContext
    ) async throws -> DetectedElement {
        let detectionResult = try await observation.requireDetectionResult(using: self.services.snapshots)
        let queryLower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !queryLower.isEmpty else {
            throw PeekabooError.elementNotFound(Self.queryNotFoundMessage(query, waitFor: self.waitFor))
        }

        let matches = detectionResult.elements.all.filter { element in
            guard element.isEnabled else { return false }
            let candidates = [
                element.id,
                element.label,
                element.value,
                element.attributes["identifier"],
                element.attributes["title"],
                element.attributes["description"],
                element.attributes["role"],
                element.type.rawValue,
            ].compactMap { $0?.lowercased() }
            return candidates.contains { $0.contains(queryLower) }
        }

        guard let best = matches.max(by: { lhs, rhs in
            Self.cachedQueryScore(lhs, queryLower: queryLower) < Self.cachedQueryScore(rhs, queryLower: queryLower)
        }) else {
            throw PeekabooError.elementNotFound(Self.queryNotFoundMessage(query, waitFor: self.waitFor))
        }

        return best
    }

    private static func cachedQueryScore(_ element: DetectedElement, queryLower: String) -> Int {
        let label = element.label?.lowercased()
        let value = element.value?.lowercased()
        let identifier = element.attributes["identifier"]?.lowercased()
        let title = element.attributes["title"]?.lowercased()
        var score = 0
        if identifier == queryLower {
            score += 400
        }
        if label == queryLower {
            score += 350
        }
        if title == queryLower {
            score += 300
        }
        if value == queryLower {
            score += 200
        }
        if identifier?.contains(queryLower) == true {
            score += 200
        }
        if label?.contains(queryLower) == true {
            score += 160
        }
        if title?.contains(queryLower) == true {
            score += 120
        }
        if value?.contains(queryLower) == true {
            score += 80
        }
        if element.type == .button {
            score += 20
        }
        return score
    }

    private struct ClickDispatchContext {
        let snapshotId: String
        let resolvedElement: DetectedElement?
        let coordinateResolution: InteractionCoordinateResolution?
        let explicitWindowResolution: InteractionWindowResolution?
        let backgroundProcessIdentifier: pid_t?
    }

    private func resolveAndDispatchClick(
        _ clickTarget: ClickTarget,
        snapshotId: String,
        resolvedElement: DetectedElement?,
        coordinateResolution: InteractionCoordinateResolution?,
        explicitWindowResolution: InteractionWindowResolution?
    ) async throws {
        let backgroundProcessIdentifier: pid_t? = if self.usesBackgroundDelivery {
            try await self.resolveBackgroundClickProcessIdentifier(
                snapshotId: snapshotId.isEmpty ? nil : snapshotId,
                coordinateResolution: coordinateResolution,
                explicitWindowResolution: explicitWindowResolution
            )
        } else {
            nil
        }

        let clickType: ClickType = if self.longPress {
            .longPress
        } else if self.right {
            .right
        } else if self.double {
            .double
        } else {
            .single
        }
        self.resolvedRuntime.beginInteractionMutation()
        try await self.performClick(
            clickTarget,
            clickType: clickType,
            context: ClickDispatchContext(
                snapshotId: snapshotId,
                resolvedElement: resolvedElement,
                coordinateResolution: coordinateResolution,
                explicitWindowResolution: explicitWindowResolution,
                backgroundProcessIdentifier: backgroundProcessIdentifier
            )
        )
    }

    private func performClick(
        _ target: ClickTarget,
        clickType: ClickType,
        context: ClickDispatchContext
    ) async throws {
        let effectiveSnapshotId: String? = if case .coordinates = target {
            nil
        } else {
            context.snapshotId.isEmpty ? nil : context.snapshotId
        }

        if self.usesBackgroundDelivery {
            guard let backgroundProcessIdentifier = context.backgroundProcessIdentifier else {
                preconditionFailure("Background process identifier must be resolved before click delivery")
            }
            try await AutomationServiceBridge.click(
                automation: self.services.automation,
                target: target,
                clickType: clickType,
                snapshotId: effectiveSnapshotId,
                targetProcessIdentifier: backgroundProcessIdentifier,
                targetWindowID: context.explicitWindowResolution?.windowInfo.windowID
                    ?? context.coordinateResolution?.targetWindowID
            )
        } else {
            // Foreground delivery is documented as "focus target and send a foreground mouse
            // click". Element/query targets are resolved to their adjusted screen point and
            // dispatched as a real coordinate click so double/right-click semantics hold,
            // instead of silently degrading to an AX press.
            let resolvedPoint = try await self.foregroundMousePoint(
                for: target,
                resolvedElement: context.resolvedElement,
                snapshotId: effectiveSnapshotId
            )
            let foregroundTarget = Self.foregroundMouseTarget(for: target, resolvedPoint: resolvedPoint)
            if resolvedPoint != nil {
                // The synthetic click lands wherever the frontmost window is; enforce that the
                // focus step actually brought the snapshot's app to the front (see #90).
                try await self.verifyFocusForElementClick(snapshotId: effectiveSnapshotId)
            }
            let foregroundSnapshotId: String? = if case .coordinates = foregroundTarget {
                nil
            } else {
                effectiveSnapshotId
            }
            try await AutomationServiceBridge.click(
                automation: self.services.automation,
                target: foregroundTarget,
                clickType: clickType,
                snapshotId: foregroundSnapshotId
            )
        }
    }

    /// Converts an element/query target into a coordinate target once its point is resolved.
    /// Coordinate targets and unresolved elements pass through unchanged.
    static func foregroundMouseTarget(for target: ClickTarget, resolvedPoint: CGPoint?) -> ClickTarget {
        switch target {
        case .coordinates:
            return target
        case .elementId, .query:
            guard let resolvedPoint else { return target }
            return .coordinates(resolvedPoint)
        }
    }

    private func foregroundMousePoint(
        for target: ClickTarget,
        resolvedElement: DetectedElement?,
        snapshotId: String?
    ) async throws -> CGPoint? {
        if case .coordinates = target {
            return nil
        }
        guard let resolvedElement else {
            return nil
        }
        do {
            let resolution = try await InteractionTargetPointResolver.elementCenterResolution(
                element: resolvedElement,
                elementId: resolvedElement.id,
                snapshotId: snapshotId,
                snapshots: self.services.snapshots
            )
            return resolution.point
        } catch let error as CancellationError {
            // A cancelled interaction must abort, not fall back to stale bounds and still click.
            throw error
        } catch let error as PeekabooError where Self.isUnsafeForegroundPointFallback(error) {
            // The captured window moved, disappeared, resized, or changed owner. Falling back to the
            // snapshot midpoint would synthesize a coordinate click at stale screen coordinates in
            // whatever app is frontmost, so abort instead.
            throw error
        } catch {
            self.logger.debug("Foreground click point resolution fell back to bounds: \(error.localizedDescription)")
            return CGPoint(x: resolvedElement.bounds.midX, y: resolvedElement.bounds.midY)
        }
    }

    /// Point-resolution failures that make a coordinate fallback unsafe: the resolved point can no
    /// longer be trusted, so a foreground coordinate click must abort rather than click stale bounds.
    private static func isUnsafeForegroundPointFallback(_ error: PeekabooError) -> Bool {
        switch error {
        case .snapshotStale:
            true
        default:
            false
        }
    }

    /// Foreground element clicks are synthesized at screen coordinates; fail loudly when the
    /// snapshot's application is not frontmost so the click cannot land in another app.
    private func verifyFocusForElementClick(snapshotId: String?) async throws {
        guard self.focusOptions.autoFocus else {
            return
        }
        guard let snapshotId,
              let detectionResult = try? await services.snapshots.getDetectionResult(snapshotId: snapshotId),
              let windowContext = detectionResult.metadata.windowContext
        else {
            return
        }

        let targetApp = windowContext.applicationBundleId ?? windowContext.applicationName
        let targetPID = windowContext.applicationProcessId
        guard targetApp != nil || targetPID != nil else {
            return
        }

        let frontmostInfo = try? await self.services.applications.getFrontmostApplication()
        let frontmost = FrontmostApplicationIdentity(application: frontmostInfo)
        if let message = CoordinateClickFocusVerifier.mismatchMessage(
            targetApp: targetApp,
            targetPID: targetPID,
            frontmost: frontmost
        ) {
            self.outputLogger.warn(
                "Foreground element click focus mismatch. Frontmost is \(frontmost.displayDescription)."
            )
            throw PeekabooError.clickFailed(message)
        }
    }

    private func focusApplicationIfNeeded(
        snapshotId: String?,
        coordinateResolution: InteractionCoordinateResolution? = nil
    ) async throws {
        if self.usesBackgroundDelivery {
            try self.validateBackgroundClickOptions()
            return
        }

        guard self.focusOptions.autoFocus else {
            return
        }

        if snapshotId == nil, !self.target.hasAnyTarget {
            return
        }

        if let targetWindowID = coordinateResolution?.targetWindowID {
            try await ensureFocused(
                windowID: CGWindowID(targetWindowID),
                applicationName: coordinateResolution?.targetApplicationIdentifier,
                windowTitle: coordinateResolution?.targetWindowTitle,
                options: self.focusOptions,
                services: self.services
            )
            try await Task.sleep(nanoseconds: 100_000_000)
            return
        }

        try await ensureFocused(
            snapshotId: snapshotId,
            target: self.target,
            options: self.focusOptions,
            services: self.services
        )

        // Brief delay to ensure focus is complete before interacting
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func validateBackgroundClickOptions() throws {
        if self.foreground, self.focusOptions.backgroundDeliveryExplicitlyRequested {
            throw ValidationError("--foreground cannot be combined with --focus-background")
        }

        if self.focusOptions.backgroundDeliveryExplicitlyRequested &&
            self.focusOptions.hasForegroundFocusOverrides {
            throw ValidationError("--focus-background cannot be combined with focus options")
        }
    }

    private func resolveBackgroundClickProcessIdentifier(
        snapshotId: String?,
        coordinateResolution: InteractionCoordinateResolution?,
        explicitWindowResolution: InteractionWindowResolution?
    ) async throws -> pid_t {
        if self.target.pid != nil, self.target.app != nil {
            throw ValidationError("Background click accepts one process target: use --app or --pid")
        }

        if let processId = explicitWindowResolution?.targetProcessIdentifier {
            return pid_t(processId)
        }

        if let pid = target.pid {
            guard pid > 0 else {
                throw ValidationError("--pid must be greater than 0")
            }
            return pid_t(pid)
        }

        if let appIdentifier = target.app?.trimmingCharacters(in: .whitespacesAndNewlines),
           !appIdentifier.isEmpty {
            let app = try await services.applications.findApplication(identifier: appIdentifier)
            return pid_t(app.processIdentifier)
        }

        if let processId = coordinateResolution?.targetProcessIdentifier {
            return pid_t(processId)
        }

        if let snapshotId,
           let snapshot = try? await services.snapshots.getUIAutomationSnapshot(snapshotId: snapshotId),
           let processId = snapshot.applicationProcessId {
            return pid_t(processId)
        }

        if let snapshotId,
           let detectionResult = try? await services.snapshots.getDetectionResult(snapshotId: snapshotId),
           let processId = detectionResult.metadata.windowContext?.applicationProcessId {
            return pid_t(processId)
        }

        throw ValidationError(
            "Background click requires --app, --pid, --window-id, or a snapshot with process metadata; " +
                "use --foreground for foreground screen clicks"
        )
    }

    // Error handling is provided by ErrorHandlingCommand protocol
}

private enum ClickDeliveryMode: String {
    case background
    case foreground
}
