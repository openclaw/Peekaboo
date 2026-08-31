import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

private struct ClickCommandOutputContext {
    let clickTarget: ClickTarget
    let waitResult: WaitForElementResult
    let snapshotWindowContext: WindowContext?
    let details: (
        location: CGPoint,
        clickedElement: String?,
        targetPointDiagnostics: InteractionTargetPointDiagnostics?
    )
    let coordinateResolution: InteractionCoordinateResolution?
    let explicitWindowResolution: InteractionWindowResolution?
    let actionResult: UIAutomationActionResult<Void>
    let modifierClickResult: ForegroundModifierClickResult?
    let startTime: Date
}

/// Click on UI elements identified in the current snapshot using intelligent element finding and smart waiting.
@available(macOS 14.0, *)
@MainActor
struct ClickCommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
    @Argument(help: "Element text or query to click")
    var query: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @Option(help: "Opaque element ID copied from current see output")
    var on: String?

    @OptionGroup var target: InteractionTargetOptions

    @Option(
        help: "x,y — target-relative when --app/--window-* given; global otherwise (use --global for explicit global)"
    )
    var at: String?

    @Flag(help: "Treat --at as global screen coordinates even when target options are supplied")
    var global = false

    @Option(help: "Maximum time to wait for an element (bare values are milliseconds)")
    var waitFor: CLIDuration = .seconds(5)

    @Flag(help: "Double-click instead of single click")
    var double = false

    @Flag(help: "Right-click (secondary click)")
    var right = false

    @Flag(help: "Middle-click with the center mouse button")
    var middle = false

    @Flag(help: "Triple-click instead of single click")
    var triple = false

    @Flag(help: "Press and hold for 1.2 seconds at a stationary point (requires --foreground)")
    var longPress = false

    @Option(help: "Modifier keys for an exact foreground click: cmd,shift,option")
    var modifiers: CLIModifierList?

    @OptionGroup var focusOptions: FocusCommandOptions

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var deliveryMode: ClickDeliveryMode {
        if self.focusOptions.backgroundDeliveryExplicitlyRequested {
            return .background
        }
        if self.focusOptions.foreground {
            return .foreground
        }
        return .background
    }

    private var usesBackgroundDelivery: Bool {
        self.deliveryMode == .background
    }

    private var usesModifierClick: Bool {
        self.modifiers != nil
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        let startTime = Date()

        do {
            try validate()

            let clickTarget: ClickTarget
            let waitResult: WaitForElementResult
            var activeSnapshotId: String
            var snapshotWindowContext: WindowContext?
            var coordinateResolution: InteractionCoordinateResolution?,
                explicitWindowResolution: InteractionWindowResolution?

            // Foreground coordinates may be global. Background coordinates must remain bound to
            // one capture-owned exact-window receipt from a named snapshot.
            if let coordString = at {
                guard let point = Self.parseCoordinates(coordString) else {
                    throw Self.invalidCoordinatesRefusal
                }
                let coordinateSnapshotId = self.snapshot?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedCoordinates: InteractionCoordinateResolution
                if self.usesBackgroundDelivery {
                    guard let coordinateSnapshotId, !coordinateSnapshotId.isEmpty else {
                        throw Self.backgroundCoordinateRefusal
                    }
                    resolvedCoordinates = try await self.resolveBackgroundCoordinateReference(
                        point,
                        snapshotId: coordinateSnapshotId
                    )
                    activeSnapshotId = coordinateSnapshotId
                } else {
                    resolvedCoordinates = try await InteractionCoordinateResolver.resolveClickCoordinates(
                        point,
                        target: self.target,
                        services: self.services,
                        forceGlobal: self.global
                    )
                    activeSnapshotId = coordinateSnapshotId ?? ""
                }
                coordinateResolution = resolvedCoordinates
                clickTarget = .coordinates(resolvedCoordinates.screenPoint)
                waitResult = WaitForElementResult(found: true, element: nil, waitTime: 0)
                try await self.focusAndVerifyCoordinateClick(resolvedCoordinates)

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
                if !self.usesBackgroundDelivery, !self.usesModifierClick {
                    self.resolvedRuntime.beginInteractionMutation()
                }
                if !self.usesModifierClick {
                    try await self.focusApplicationIfNeeded(snapshotId: observation.focusSnapshotId(for: self.target))
                }

                // Use whichever element ID parameter was provided
                let elementId = self.on

                if let elementId {
                    if !self.usesBackgroundDelivery, !self.usesModifierClick {
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
                    if self.usesBackgroundDelivery || self.usesModifierClick {
                        let cached = try await cachedElementById(elementId, observation: observation)
                        snapshotWindowContext = cached.windowContext
                        waitResult = WaitForElementResult(found: true, element: cached.element, waitTime: 0)
                    } else {
                        // Click by element ID with auto-wait
                        waitResult = try await AutomationServiceBridge.waitForElement(
                            automation: self.services.automation,
                            target: clickTarget,
                            timeout: self.waitFor.seconds,
                            snapshotId: activeSnapshotId.isEmpty ? nil : activeSnapshotId
                        )

                        if !waitResult.found {
                            throw PeekabooError.elementNotFound(Self.elementNotFoundMessage(elementId))
                        }
                    }

                } else if let searchQuery = query {
                    if !self.usesBackgroundDelivery, !self.usesModifierClick {
                        observation = try await self.refreshObservationIfQueryMissing(observation, query: searchQuery)
                    }
                    activeSnapshotId = observation.snapshotId ?? ""

                    if self.usesBackgroundDelivery || self.usesModifierClick {
                        let cached = try await cachedElementMatching(searchQuery, observation: observation)
                        snapshotWindowContext = cached.windowContext
                        clickTarget = .elementId(cached.element.id)
                        waitResult = WaitForElementResult(found: true, element: cached.element, waitTime: 0)
                    } else {
                        // Find element by query with auto-wait
                        clickTarget = .query(searchQuery)
                        waitResult = try await AutomationServiceBridge.waitForElement(
                            automation: self.services.automation,
                            target: clickTarget,
                            timeout: self.waitFor.seconds,
                            snapshotId: activeSnapshotId.isEmpty ? nil : activeSnapshotId
                        )

                        if !waitResult.found {
                            let message = Self.queryNotFoundMessage(
                                searchQuery,
                                waitFor: self.waitFor.roundedMilliseconds
                            )
                            throw PeekabooError.elementNotFound(message)
                        }
                    }

                } else {
                    // This case should not be reachable due to the validate() method
                    throw ValidationError("No target specified for click.")
                }
            }

            let outputDetails = try await self.clickOutputDetails(
                clickTarget: clickTarget,
                waitResult: waitResult,
                snapshotId: activeSnapshotId,
                coordinateResolution: coordinateResolution
            )
            let dispatchResult = try await self.resolveAndDispatchClick(
                clickTarget,
                snapshotId: activeSnapshotId,
                resolvedElement: waitResult.element,
                coordinateResolution: coordinateResolution,
                explicitWindowResolution: explicitWindowResolution
            )

            try await self.finishClick(ClickCommandOutputContext(
                clickTarget: clickTarget,
                waitResult: waitResult,
                snapshotWindowContext: snapshotWindowContext,
                details: outputDetails,
                coordinateResolution: coordinateResolution,
                explicitWindowResolution: explicitWindowResolution,
                actionResult: dispatchResult.actionResult,
                modifierClickResult: dispatchResult.modifierClickResult,
                startTime: startTime
            ))

        } catch {
            handleError(error)
            throw ExitCode.failure
        }
    }

    private func clickEffect(for target: ClickTarget) -> ActionEffect {
        guard self.usesBackgroundDelivery, self.requestedClickType == .single else { return .unverifiable }
        switch target {
        case .elementId, .query:
            return .confirmed
        case .coordinates:
            return .unverifiable
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

        if self.usesBackgroundDelivery,
           self.target.windowId != nil,
           observation.source == .explicit {
            return try await self.resolveSnapshotBackedWindowSelection(observation: observation)
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
        let snapshotContext = detectionResult.metadata.windowContext
        try InteractionWindowSelectionValidator.validate(
            resolution: resolution,
            snapshotContext: snapshotContext,
            snapshotId: snapshotId
        )
        return InteractionWindowResolution(
            windowInfo: Self.windowInfo(
                resolution.windowInfo,
                captureIdentity: snapshotContext?.windowMutationIdentity,
                captureBounds: snapshotContext?.windowBounds,
                captureProcessIdentifier: snapshotContext?.applicationProcessId
            ),
            targetApplication: resolution.targetApplication
        )
    }

    private static func windowInfo(
        _ window: ServiceWindowInfo,
        captureIdentity: WindowMutationIdentity?,
        captureBounds: CGRect?,
        captureProcessIdentifier: pid_t?
    ) -> ServiceWindowInfo {
        let actionIdentity: WindowMutationIdentity? = if let captureIdentity,
                                                         captureIdentity.windowID == window.windowID,
                                                         captureIdentity.ownerProcessIdentifier ==
                                                         captureProcessIdentifier,
                                                         captureBounds != nil {
            captureIdentity
        } else {
            nil
        }
        return ServiceWindowInfo(
            windowID: window.windowID,
            title: window.title,
            bounds: captureBounds ?? window.bounds,
            isMinimized: window.isMinimized,
            isMainWindow: window.isMainWindow,
            isKeyWindow: window.isKeyWindow,
            isFrontmost: window.isFrontmost,
            subrole: window.subrole,
            windowLevel: window.windowLevel,
            alpha: window.alpha,
            index: window.index,
            spaceID: window.spaceID,
            spaceName: window.spaceName,
            screenIndex: window.screenIndex,
            screenName: window.screenName,
            isOffScreen: window.isOffScreen,
            layer: window.layer,
            isOnScreen: window.isOnScreen,
            sharingState: window.sharingState,
            isExcludedFromWindowsMenu: window.isExcludedFromWindowsMenu,
            observationCapability: window.observationCapability,
            mutationIdentity: actionIdentity
        )
    }

    private func cachedElementById(
        _ elementId: String,
        observation: InteractionObservationContext
    ) async throws -> (element: DetectedElement, windowContext: WindowContext?) {
        let detectionResult = try await observation.requireDetectionResult(using: self.services.snapshots)
        guard let element = detectionResult.elements.findById(elementId) else {
            throw PeekabooError.elementNotFound(Self.elementNotFoundMessage(elementId))
        }
        return (element, detectionResult.metadata.windowContext)
    }

    private func cachedElementMatching(
        _ query: String,
        observation: InteractionObservationContext
    ) async throws -> (element: DetectedElement, windowContext: WindowContext?) {
        let detectionResult = try await observation.requireDetectionResult(using: self.services.snapshots)
        let queryLower = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !queryLower.isEmpty else {
            throw PeekabooError.elementNotFound(
                Self.queryNotFoundMessage(query, waitFor: self.waitFor.roundedMilliseconds)
            )
        }

        let matches = detectionResult.elements.all.filter { element in
            guard element.isEnabled, !element.isOCRSemanticEvidence else { return false }
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
            throw PeekabooError.elementNotFound(
                Self.queryNotFoundMessage(query, waitFor: self.waitFor.roundedMilliseconds)
            )
        }

        return (best, detectionResult.metadata.windowContext)
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
        let backgroundProcessIdentity: ApplicationProcessIdentity?
        let statelessWindowTarget: UIAutomationTarget.ExactWindow?
    }

    private struct ClickDispatchResult {
        let actionResult: UIAutomationActionResult<Void>
        let modifierClickResult: ForegroundModifierClickResult?
    }

    private func resolveAndDispatchClick(
        _ clickTarget: ClickTarget,
        snapshotId: String,
        resolvedElement: DetectedElement?,
        coordinateResolution: InteractionCoordinateResolution?,
        explicitWindowResolution: InteractionWindowResolution?
    ) async throws -> ClickDispatchResult {
        if self.usesModifierClick {
            return try await self.resolveAndDispatchModifierClick(
                clickTarget,
                snapshotId: snapshotId,
                resolvedElement: resolvedElement
            )
        }
        let backgroundProcessIdentity: ApplicationProcessIdentity? = if self.usesBackgroundDelivery {
            try await self.resolveBackgroundClickProcessIdentity(
                snapshotId: snapshotId.isEmpty ? nil : snapshotId,
                coordinateResolution: coordinateResolution,
                explicitWindowResolution: explicitWindowResolution
            )
        } else {
            nil
        }

        let clickType = self.requestedClickType
        let statelessWindowTarget: UIAutomationTarget.ExactWindow? = if self.usesBackgroundDelivery,
                                                                        clickType
                                                                            .requiresStatelessVariantSupport {
            try await self.resolveStatelessClickWindowTarget(
                snapshotId: snapshotId,
                expectedProcessIdentity: backgroundProcessIdentity
            )
        } else {
            nil
        }
        if self.usesBackgroundDelivery, case .coordinates = clickTarget {
            try await self.validateBackgroundCoordinateResolution(
                coordinateResolution,
                snapshotId: snapshotId
            )
        }
        let result = try await SnapshotMutationCoordinator.perform(
            snapshotId: snapshotId,
            snapshots: self.services.snapshots,
            operation: {
                self.resolvedRuntime.beginInteractionMutation()
                return try await self.performClick(
                    clickTarget,
                    clickType: clickType,
                    context: ClickDispatchContext(
                        snapshotId: snapshotId,
                        resolvedElement: resolvedElement,
                        coordinateResolution: coordinateResolution,
                        explicitWindowResolution: explicitWindowResolution,
                        backgroundProcessIdentity: backgroundProcessIdentity,
                        statelessWindowTarget: statelessWindowTarget
                    )
                )
            },
            outcome: { $0.outcome }
        )
        return ClickDispatchResult(actionResult: result, modifierClickResult: nil)
    }

    private func resolveAndDispatchModifierClick(
        _ target: ClickTarget,
        snapshotId: String,
        resolvedElement: DetectedElement?
    ) async throws -> ClickDispatchResult {
        guard let modifiers = self.modifiers?.values.map(Self.pointerModifier),
              !modifiers.contains(where: { $0 == nil })
        else {
            throw ValidationError("--modifiers accepts only cmd, shift, and option")
        }
        let canonicalModifiers = modifiers.compactMap(\.self)
        guard !canonicalModifiers.contains(.control), self.requestedClickType != .right else {
            throw ValidationError("Modifier-click cannot use Control or right-click contextual input")
        }
        let authority = try await Self.modifierClickCoordinateAuthority(
            snapshotID: snapshotId,
            snapshots: self.services.snapshots
        )
        let point: CGPoint
        switch target {
        case let .coordinates(coordinates):
            point = coordinates
        case .elementId, .query:
            guard let resolvedElement else {
                throw ValidationError("Modifier-click target could not be resolved in its snapshot")
            }
            point = try await InteractionTargetPointResolver.elementCenterResolution(
                element: resolvedElement,
                elementId: resolvedElement.id,
                snapshotId: snapshotId,
                snapshots: self.services.snapshots
            ).point
        }
        guard authority.sourceBounds.contains(point), authority.target.bounds.contains(point) else {
            throw ValidationError("Modifier-click point is outside the captured exact window")
        }
        guard let service = self.services.automation as? any ForegroundModifierClickServiceProtocol,
              service.supportsForegroundModifierClick,
              service.supportsForegroundModifierClickSnapshotLease
        else {
            throw ValidationError("This automation host does not support host-leased foreground modifier-click")
        }
        let result: UIAutomationActionResult<ForegroundModifierClickResult>
        do {
            result = try await service.foregroundModifierClickWithOutcome(
                ForegroundModifierClickRequest(
                    point: point,
                    clickType: self.requestedClickType,
                    modifiers: canonicalModifiers,
                    snapshotID: snapshotId,
                    windowIdentity: authority.target.identity,
                    windowBounds: authority.target.bounds
                )
            )
            _ = try UIAutomationActionResultSemantics.requireAcceptedOutcome(
                result,
                policy: .confirmedOrDispatched(requiring: .foreground),
                targetRequirement: .exact(DesktopTargetIdentity(exactWindow: authority.target)),
                operation: "Foreground modifier-click"
            )
            if result.outcome?.dispatchState.mutationDispatched == true {
                self.resolvedRuntime.beginInteractionMutation()
            }
        } catch let failure as DesktopActionFailure {
            if failure.outcome.dispatchState.mutationDispatched {
                self.resolvedRuntime.beginInteractionMutation()
            }
            throw failure
        }
        return ClickDispatchResult(
            actionResult: UIAutomationActionResult(
                payload: (),
                outcome: result.outcome,
                targetIdentity: result.targetIdentity
            ),
            modifierClickResult: result.payload
        )
    }

    static func modifierClickCoordinateAuthority(
        snapshotID: String,
        snapshots: any SnapshotManagerProtocol
    ) async throws -> SnapshotTargetReceipt.CoordinateAuthority {
        do {
            return try await SnapshotTargetReceiptPlanner(
                snapshots: snapshots
            ).plan(snapshotID: snapshotID).receipt.requireCoordinateAuthority()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ValidationError("Modifier-click requires one fresh exact-window screenshot snapshot")
        }
    }

    private static func pointerModifier(_ value: String) -> PointerModifier? {
        switch value {
        case "cmd": .command
        case "shift": .shift
        case "option": .option
        case "ctrl": .control
        default: nil
        }
    }

    private func performClick(
        _ target: ClickTarget,
        clickType: ClickType,
        context: ClickDispatchContext
    ) async throws -> UIAutomationActionResult<Void> {
        let effectiveSnapshotId: String? = if case .coordinates = target, !self.usesBackgroundDelivery {
            nil
        } else {
            context.snapshotId.isEmpty ? nil : context.snapshotId
        }

        if self.usesBackgroundDelivery {
            guard let backgroundProcessIdentity = context.backgroundProcessIdentity else {
                preconditionFailure("Background process identity must be resolved before click delivery")
            }
            let exactWindowInfo = context.explicitWindowResolution?.windowInfo ??
                context.coordinateResolution?.windowInfo
            let targetWindowID = exactWindowInfo?.windowID ?? context.statelessWindowTarget?.identity.windowID
            let expectedWindowIdentity = exactWindowInfo?.mutationIdentity ?? context.statelessWindowTarget?.identity
            let expectedWindowBounds = exactWindowInfo?.bounds ?? context.statelessWindowTarget?.bounds
            if targetWindowID != nil, expectedWindowIdentity == nil {
                throw PeekabooError.snapshotStale(
                    "Exact-window click snapshot has no capture-time process-generation receipt; " +
                        "capture a fresh snapshot before background input"
                )
            }
            return try await AutomationServiceBridge.click(
                automation: self.services.automation,
                target: target,
                clickType: clickType,
                snapshotId: effectiveSnapshotId,
                expectedProcessIdentity: backgroundProcessIdentity,
                targetWindowID: targetWindowID,
                expectedWindowIdentity: expectedWindowIdentity,
                expectedWindowBounds: expectedWindowBounds
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
            return try await AutomationServiceBridge.click(
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

    private func focusAndVerifyCoordinateClick(_ resolution: InteractionCoordinateResolution) async throws {
        guard !self.usesModifierClick else { return }
        if !self.usesBackgroundDelivery {
            self.resolvedRuntime.beginInteractionMutation()
        }
        try await self.focusApplicationIfNeeded(
            snapshotId: nil,
            coordinateResolution: resolution
        )
        if !self.usesBackgroundDelivery {
            try await self.verifyFocusForCoordinateClick(coordinateResolution: resolution)
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
        if self.focusOptions.foreground, self.focusOptions.backgroundDeliveryExplicitlyRequested {
            throw ValidationError("--foreground cannot be combined with --focus-background")
        }

        if self.focusOptions.backgroundDeliveryExplicitlyRequested &&
            self.focusOptions.hasForegroundFocusOverrides {
            throw ValidationError("--focus-background cannot be combined with focus options")
        }

        if !self.focusOptions.foreground, self.focusOptions.hasForegroundFocusOverrides {
            throw ValidationError("Focus options require --foreground for click")
        }
    }

    // Error handling is provided by ErrorHandlingCommand protocol
}

// MARK: - Click result presentation

extension ClickCommand {
    private func outputClickResult(
        _ context: ClickCommandOutputContext,
        targetIdentity: DesktopTargetIdentity?
    ) async throws {
        let coordinateResolution = context.coordinateResolution
        let explicitWindowResolution = context.explicitWindowResolution
        let appName = self.resultApplicationName(
            snapshotContext: context.snapshotWindowContext,
            coordinateResolution: coordinateResolution,
            explicitWindowResolution: explicitWindowResolution,
            targetIdentity: targetIdentity
        )
        try Task.checkCancellation()
        let details = context.details
        let result = ClickResult(
            clickedElement: details.clickedElement,
            clickLocation: details.location,
            waitTime: context.waitResult.waitTime,
            executionTime: Date().timeIntervalSince(context.startTime),
            targetApp: appName,
            targetWindowId: explicitWindowResolution?.windowInfo.windowID ?? coordinateResolution?.targetWindowID ??
                targetIdentity?.exactWindow?.identity.windowID,
            targetWindowTitle: explicitWindowResolution?.windowInfo.title ?? coordinateResolution?.targetWindowTitle,
            coordinateSpace: coordinateResolution?.coordinateSpace.rawValue,
            inputCoordinates: coordinateResolution?.inputPoint,
            screenCoordinates: coordinateResolution?.screenPoint,
            targetPoint: details.targetPointDiagnostics,
            deliveryMode: self.deliveryMode.rawValue,
            clickType: self.requestedClickType.rawValue,
            modifiers: self.modifiers?.values,
            cursorRestoration: context.modifierClickResult?.cursorRestoration.rawValue,
            focusRestoration: context.modifierClickResult?.focusRestoration.rawValue
        )
        self.output(
            result,
            effect: self.clickEffect(for: context.clickTarget),
            outcome: context.actionResult.outcome,
            targetIdentity: targetIdentity
        ) {
            if let actionOutcome = context.actionResult.outcome {
                print(ActionOutcomeHumanRenderer.statusLine(for: actionOutcome, operation: "Click"))
            } else {
                print(self.clickEffect(for: context.clickTarget) == .confirmed
                    ? "✅ Click confirmed by Accessibility"
                    : "⚠️ Click dispatched; application effect is unverifiable")
            }
            self.printClickDetails(result)
        }
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
            // Diagnostics are best effort; dispatch still owns target validation.
            self.logger.debug("Click target diagnostics unavailable: \(error.localizedDescription)")
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

    private func resultApplicationName(
        snapshotContext: WindowContext?,
        coordinateResolution: InteractionCoordinateResolution?,
        explicitWindowResolution: InteractionWindowResolution?,
        targetIdentity: DesktopTargetIdentity?
    ) -> String {
        let boundName = explicitWindowResolution?.targetApplication?.name ??
            coordinateResolution?.targetApplicationName
        if let name = Self.usableApplicationName(boundName) {
            return name
        }

        let processIdentifier = targetIdentity?.processIdentity.processIdentifier ??
            explicitWindowResolution?.windowInfo.mutationIdentity?.ownerProcessIdentifier ??
            coordinateResolution?.targetProcessIdentifier ?? self.target.pid
        if let snapshotContext,
           processIdentifier == nil || snapshotContext.applicationProcessId == processIdentifier,
           let name = Self.usableApplicationName(snapshotContext.applicationName) {
            return name
        }
        if let processIdentifier {
            return "PID \(processIdentifier)"
        }
        if let windowID = explicitWindowResolution?.windowInfo.windowID ?? coordinateResolution?.targetWindowID ??
            self.target.windowId {
            return "window \(windowID)"
        }
        return "Unknown"
    }

    private static func usableApplicationName(_ name: String?) -> String? {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }

    private func printClickDetails(_ result: ClickResult) {
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
        if let modifiers = result.modifiers, !modifiers.isEmpty {
            print("⌨️  Modifiers: \(modifiers.joined(separator: ","))")
        }
        if let cursorRestoration = result.cursorRestoration {
            print("🖱️  Cursor restoration: \(cursorRestoration)")
        }
        if let focusRestoration = result.focusRestoration {
            print("🪟 Focus restoration: \(focusRestoration)")
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

extension ClickCommand {
    private func finishClick(_ context: ClickCommandOutputContext) async throws {
        let actionResult = context.actionResult
        try await withPreservedActionResultOnFailure(
            actionResult,
            targetIdentity: actionResult.targetIdentity,
            operation: "Click"
        ) {
            // Brief delay to ensure click is processed. Cancellation is no longer discardable:
            // once delivery returned, every failure must retain its canonical mutation state.
            try await Task.sleep(nanoseconds: 20_000_000) // 0.02 seconds

            // Advance every host watermark before publishing the bound result.
            await InteractionObservationInvalidator.invalidateAfterClickMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "click",
                through: Date()
            )
            try Task.checkCancellation()
        }

        let targetIdentity: DesktopTargetIdentity? = if self.usesBackgroundDelivery || actionResult.outcome != nil {
            try validatedSuccessfulActionResult(
                actionResult,
                operation: "Click",
                requiresTarget: self.usesBackgroundDelivery
            )
        } else {
            // Older foreground-only providers cannot attest a target or canonical outcome.
            nil
        }

        try await withPreservedActionResultOnFailure(
            actionResult,
            targetIdentity: targetIdentity,
            operation: "Click"
        ) {
            try await self.outputClickResult(context, targetIdentity: targetIdentity)
        }
    }

    private static let backgroundCoordinateRefusal = PreDispatchActionError(
        message: backgroundCoordinateReferenceMessage,
        code: .VALIDATION_ERROR,
        hint: "Use --foreground for explicit global input.",
        reason: .invalidRequest
    )
    static let invalidCoordinatesRefusal = PreDispatchActionError(
        message: "Invalid coordinates format. Use: x,y",
        code: .VALIDATION_ERROR,
        hint: nil,
        reason: .invalidRequest
    )
    private static let backgroundCoordinateReferenceMessage =
        "Background coordinate clicks require --snapshot from a fresh see capture of the exact target window. " +
        "PID-only/app-only coordinates and empty snapshots are refused."

    private func resolveBackgroundClickProcessIdentity(
        snapshotId: String?,
        coordinateResolution: InteractionCoordinateResolution?,
        explicitWindowResolution: InteractionWindowResolution?
    ) async throws -> ApplicationProcessIdentity {
        if self.target.pid != nil, self.target.app != nil {
            throw ValidationError("Background click accepts one process target: use --app or --pid")
        }

        if let identity = explicitWindowResolution?.windowInfo.mutationIdentity {
            return ApplicationProcessIdentity(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity
            )
        }

        let snapshotIdentity = try await self.backgroundClickSnapshotProcessIdentity(snapshotId: snapshotId)
        let selectedIdentity: ApplicationProcessIdentity?
        if let pid = target.pid {
            guard pid > 0 else {
                throw ValidationError("--pid must be greater than 0")
            }
            selectedIdentity = try await self.currentProcessIdentity(identifier: "PID:\(pid)")
        } else if let appIdentifier = target.app?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !appIdentifier.isEmpty {
            selectedIdentity = try await self.currentProcessIdentity(identifier: appIdentifier)
        } else if let identity = coordinateResolution?.windowInfo?.mutationIdentity {
            selectedIdentity = ApplicationProcessIdentity(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity
            )
        } else if let processId = coordinateResolution?.targetProcessIdentifier {
            selectedIdentity = try await self.currentProcessIdentity(identifier: "PID:\(processId)")
        } else {
            selectedIdentity = nil
        }

        if let snapshotIdentity, let selectedIdentity, snapshotIdentity != selectedIdentity {
            throw ValidationError(
                "Background click snapshot belongs to a different process generation; run see again before clicking."
            )
        }
        if let identity = snapshotIdentity ?? selectedIdentity {
            return identity
        }

        throw ValidationError(
            "Background click requires --app, --pid, --window-id, or a snapshot with process metadata; " +
                "use --foreground for foreground screen clicks"
        )
    }

    private func backgroundClickSnapshotProcessIdentity(snapshotId: String?) async throws
    -> ApplicationProcessIdentity? {
        guard let snapshotId else { return nil }
        do {
            let plan = try await SnapshotTargetReceiptPlanner(
                snapshots: self.services.snapshots,
                sourceFailurePolicy: .omitUnavailableSources
            )
            .planProcessIdentity(snapshotID: snapshotId)
            guard plan.hasProcessIdentifierEvidence else {
                throw ValidationError(
                    "Snapshot '\(snapshotId)' does not identify a target process. Run see again before clicking."
                )
            }
            return try plan.receipt.requireIdentity().processIdentity
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Commander.ValidationError {
            throw error
        } catch DesktopTargetIdentityError.missingProcessGeneration,
            DesktopTargetIdentityError.incompleteExactWindow {
            throw ValidationError(
                "Snapshot '\(snapshotId)' has no capture-time process-generation receipt. " +
                    "Run see again before clicking."
            )
        } catch {
            throw ValidationError("Snapshot '\(snapshotId)' has inconsistent process metadata.")
        }
    }

    private func currentProcessIdentity(identifier: String) async throws -> ApplicationProcessIdentity {
        let planner = DesktopTargetPlanning.ApplicationMutationPlanner(
            applications: self.services.applications
        )
        return try await planner.plan(identifier: identifier).processIdentity
    }

    private func resolveBackgroundCoordinateReference(
        _ point: CGPoint,
        snapshotId: String
    ) async throws -> InteractionCoordinateResolution {
        guard let detection = try await self.services.snapshots.getDetectionResult(snapshotId: snapshotId),
              !detection.screenshotPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              detection.metadata.windowContext != nil
        else {
            throw ValidationError(Self.backgroundCoordinateReferenceMessage)
        }
        let coordinateAuthority: SnapshotTargetReceipt.CoordinateAuthority
        do {
            coordinateAuthority = try SnapshotTargetReceiptPlanner.assemble(
                snapshotID: snapshotId,
                detectionResult: detection
            ).receipt.requireCoordinateAuthority()
        } catch {
            throw ValidationError(Self.backgroundCoordinateReferenceMessage)
        }
        let capturedIdentity = coordinateAuthority.target.identity
        let processIdentifier = capturedIdentity.ownerProcessIdentifier
        let windowID = capturedIdentity.windowID
        let capturedBounds = coordinateAuthority.target.bounds

        if let requestedPID = self.target.pid, requestedPID != processIdentifier {
            throw ValidationError(
                "Snapshot '\(snapshotId)' belongs to PID \(processIdentifier), not requested PID \(requestedPID). " +
                    "Run see for the requested process and use that snapshot."
            )
        }
        if let app = self.target.app?.trimmingCharacters(in: .whitespacesAndNewlines), !app.isEmpty {
            let requestedIdentity = try await self.currentProcessIdentity(identifier: app)
            guard requestedIdentity.processIdentifier == processIdentifier else {
                throw ValidationError(
                    "Snapshot '\(snapshotId)' belongs to PID \(processIdentifier), not \(app) " +
                        "(PID \(requestedIdentity.processIdentifier))."
                )
            }
        }
        if let requestedWindowID = self.target.windowId, requestedWindowID != windowID {
            throw ValidationError(
                "Snapshot '\(snapshotId)' belongs to window \(windowID), not requested window \(requestedWindowID)."
            )
        }
        if self.target.windowTitle != nil || self.target.windowIndex != nil {
            let selected = try await InteractionCoordinateResolver.resolveTargetWindow(
                target: self.target,
                services: self.services
            )
            guard selected.windowInfo.windowID == windowID else {
                throw ValidationError(
                    "Snapshot '\(snapshotId)' belongs to window \(windowID), but the selector resolved " +
                        "window \(selected.windowInfo.windowID)."
                )
            }
        }

        let currentWindows = try await self.services.windows.listWindows(target: .windowId(windowID))
        let exactMatches = currentWindows.filter { $0.windowID == windowID }
        guard let currentWindow = exactMatches.first,
              exactMatches.allSatisfy({
                  $0.bounds == capturedBounds && $0.mutationIdentity == capturedIdentity
              })
        else {
            throw ValidationError(
                "Snapshot '\(snapshotId)' is stale: its exact window moved, disappeared, changed owner, or " +
                    "changed process generation. Run see again before clicking."
            )
        }

        let application = try await self.services.applications.findApplication(identifier: "PID:\(processIdentifier)")
        let resolution = try InteractionCoordinateResolver.resolveTargetWindowCoordinates(
            point,
            windowInfo: currentWindow,
            targetApplication: application,
            forceGlobal: self.global
        )
        guard capturedBounds.contains(resolution.screenPoint) else {
            throw ValidationError(
                "Coordinates are outside captured window \(windowID). Run see again and click inside its bounds."
            )
        }
        return resolution
    }

    private func validateBackgroundCoordinateResolution(
        _ resolution: InteractionCoordinateResolution?,
        snapshotId: String
    ) async throws {
        guard !snapshotId.isEmpty,
              let resolution,
              let window = resolution.windowInfo,
              let expectedIdentity = window.mutationIdentity,
              expectedIdentity.windowID == window.windowID,
              expectedIdentity.ownerProcessIdentifier == resolution.targetProcessIdentifier,
              window.bounds.contains(resolution.screenPoint)
        else {
            throw ValidationError(Self.backgroundCoordinateReferenceMessage)
        }
        guard let detection = try await self.services.snapshots.getDetectionResult(snapshotId: snapshotId),
              detection.metadata.windowContext != nil
        else {
            throw ValidationError(Self.backgroundCoordinateReferenceMessage)
        }
        let authority: SnapshotTargetReceipt.CoordinateAuthority
        do {
            authority = try SnapshotTargetReceiptPlanner.assemble(
                snapshotID: snapshotId,
                detectionResult: detection
            ).receipt.requireCoordinateAuthority()
        } catch {
            throw ValidationError(Self.backgroundCoordinateReferenceMessage)
        }
        guard authority.target.identity.hasSameStableReceipt(as: expectedIdentity),
              authority.target.bounds == window.bounds
        else {
            throw ValidationError(Self.backgroundCoordinateReferenceMessage)
        }

        let current = try await self.services.windows.listWindows(target: .windowId(window.windowID))
        let exactMatches = current.filter { $0.windowID == window.windowID }
        guard !exactMatches.isEmpty,
              exactMatches.allSatisfy({
                  $0.bounds == window.bounds && $0.mutationIdentity == expectedIdentity
              })
        else {
            throw ValidationError(
                "Background coordinate snapshot is stale immediately before dispatch. Run see again and retry."
            )
        }
    }
}

private enum ClickDeliveryMode: String {
    case background
    case foreground
}
