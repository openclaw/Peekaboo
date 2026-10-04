import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Scrolls the mouse wheel in a specified direction.
/// Supports scrolling on specific elements or at the current mouse position.
@available(macOS 14.0, *)
@MainActor
struct ScrollCommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable, PreRuntimeValidatingCommand,
RuntimeBackedCommand {
    @Option(help: "Scroll direction: up, down, left, or right")
    var direction: String

    @Option(help: "Number of native scroll units or wheel ticks")
    var amount: Int = 3

    @Option(help: "Element ID to scroll on (from 'see' command)")
    var on: String?

    @Option(help: "Background coordinates x,y relative to the captured window; mutually exclusive with --on")
    var at: String?

    @Flag(help: "Interpret --at as global display points instead of window-relative points")
    var global = false

    @Option(help: "Explicit fresh screenshot snapshot required with --at; --on may use 'latest' or omit it")
    var snapshot: String?

    @Option(help: "Delay between scroll ticks (bare values are milliseconds)")
    var delay: CLIDuration = .milliseconds(0)

    @Flag(help: "Use smooth scrolling with smaller increments")
    var smooth = false

    @OptionGroup var target: InteractionTargetOptions

    @OptionGroup var focusOptions: FocusCommandOptions
    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let startTime = Date()
        self.logger.setJsonOutputMode(self.jsonOutput)
        let actionSequence = CommandActionSequenceAccumulator()
        let actionRoute = commandActionRoute(for: runtime.services)

        do {
            let scrollDirection = try self.validatedScrollDirection()

            var observation = await InteractionObservationContext.resolve(
                explicitSnapshot: self.snapshot,
                fallbackToLatest: self.on != nil,
                snapshots: self.services.snapshots
            )

            if let elementId = self.on {
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
                _ = try await observation.requireDetectionResult(using: self.services.snapshots)
            } else {
                try await observation.validateIfExplicit(using: self.services.snapshots)
            }

            let expectedWindow = try await self.expectedBackgroundWindow(observation: observation)
            let coordinateResolution = try await self.resolveCoordinateScroll(
                self.coordinatePoint(), expectedWindow: expectedWindow, observation: observation
            )

            self.resolvedRuntime.beginInteractionMutation()
            try await self.recordSetupFocus(
                observation: observation,
                sequence: actionSequence
            )

            // Perform scroll using the service
            let scrollRequest = ScrollRequest(
                direction: scrollDirection,
                amount: self.amount,
                target: self.on,
                point: coordinateResolution?.screenPoint,
                smooth: self.smooth,
                delay: self.delay.roundedMilliseconds,
                snapshotId: observation.snapshotId,
                expectedWindow: expectedWindow,
                foreground: self.focusOptions.foreground
            )
            let actionResult = try await SnapshotMutationCoordinator.perform(
                snapshotId: observation.snapshotId,
                snapshots: self.services.snapshots,
                operation: {
                    try await AutomationServiceBridge.scroll(
                        automation: self.services.automation,
                        request: scrollRequest
                    )
                },
                outcome: { $0.outcome }
            )
            try self.recordScrollResult(actionResult, sequence: actionSequence, route: actionRoute)
            let compositeResult = actionSequence.result(payload: ())
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "scroll"
            )
            let logTarget = coordinateResolution != nil ? "coordinates" : (self.on ?? "pointer")
            AutomationEventLogger.log(
                .scroll,
                "direction=\(self.direction) amount=\(self.amount) smooth=\(self.smooth) "
                    + "target=\(logTarget) snapshot=\(observation.snapshotId ?? "latest")"
            )

            // Keep result reporting aligned with ScrollService.tickConfiguration.

            // Determine scroll location for output
            let resultDetection: ElementDetectionResult? = if let snapshotId = observation.snapshotId {
                try await self.services.snapshots.getDetectionResult(snapshotId: snapshotId)
            } else {
                nil
            }
            let scrollResolution: InteractionTargetPointResolution = if let coordinateResolution {
                InteractionTargetPointResolver.coordinate(coordinateResolution.screenPoint, source: .coordinates)
            } else if let elementId = on {
                if let snapshotId = observation.snapshotId,
                   let detectionResult = resultDetection,
                   let element = detectionResult.elements.findById(elementId) {
                    try await InteractionTargetPointResolver.elementCenterResolution(
                        element: element,
                        elementId: elementId,
                        snapshotId: snapshotId,
                        snapshots: self.services.snapshots
                    )
                } else {
                    InteractionTargetPointResolver.coordinate(.zero, source: .element)
                }
            } else {
                InteractionTargetPointResolver.coordinate(
                    self.services.automation.currentMouseLocation() ?? .zero,
                    source: .pointer
                )
            }
            // Output results
            let outputPayload = ScrollResult(
                direction: direction,
                amount: amount,
                location: ["x": scrollResolution.point.x, "y": scrollResolution.point.y],
                totalTicks: self.smooth ? self.amount * 10 : self.amount,
                targetPoint: scrollResolution.diagnostics,
                targetReceipt: ScrollTargetReceipt(
                    snapshotId: observation.snapshotId,
                    detectionResult: resultDetection
                ),
                executionTime: Date().timeIntervalSince(startTime)
            )
            output(
                outputPayload,
                effect: .unverifiable,
                outcome: compositeResult.outcome,
                targetIdentity: compositeResult.targetIdentity
            ) {
                if let outcome = compositeResult.outcome {
                    print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Scroll"))
                } else {
                    print("✅ Scroll completed")
                }
                print("🎯 Direction: \(self.direction)")
                print("📊 Amount: \(self.amount) ticks")
                if self.on != nil || self.at != nil {
                    print("📍 Location: (\(Int(scrollResolution.point.x)), \(Int(scrollResolution.point.y)))")
                }
                print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
            }

        } catch {
            // ScrollService converts every post-dispatch failure into DesktopActionFailure. Raw
            // stale/unsupported background errors therefore prove that no scroll unit was emitted.
            let presentedError: any Error = if let peekabooError = error as? PeekabooError {
                switch peekabooError {
                case .snapshotStale:
                    self.preDispatchActionError(for: peekabooError, reason: .targetUnavailable)
                case .invalidInput where !self.focusOptions.foreground:
                    self.preDispatchActionError(for: peekabooError, reason: .operationUnsupported)
                default:
                    error
                }
            } else {
                error
            }
            let preservedError = actionSequence.preservingFailure(
                presentedError,
                fallbackRoute: actionRoute,
                message: "Scroll failed after foreground focus may have changed desktop state.",
                hint: "Observe the exact target before deciding whether to retry scrolling."
            )
            self.handleError(preservedError)
            throw ExitCode.failure
        }
    }

    private func resolveCoordinateScroll(
        _ inputPoint: CGPoint?,
        expectedWindow: UIAutomationTarget.ExactWindow?,
        observation: InteractionObservationContext
    ) async throws -> InteractionCoordinateResolution? {
        guard let inputPoint, let expectedWindow else { return nil }
        guard (self.services.automation as? any UIAutomationActionOutcomeProviding)?
            .supportsBackgroundCoordinateScroll == true
        else {
            throw PreDispatchActionError(
                message: "This execution host does not support background coordinate scroll.",
                code: .INTERACTION_FAILED,
                hint: "Update the execution host before retrying coordinate scroll.",
                reason: .runtimeIncompatible
            )
        }
        let globalPoint = self.global ? inputPoint : CGPoint(
            x: expectedWindow.bounds.minX + inputPoint.x,
            y: expectedWindow.bounds.minY + inputPoint.y
        )
        guard expectedWindow.bounds.contains(globalPoint) else {
            throw PreDispatchActionError(
                message: "Scroll coordinates are outside the captured target window.",
                code: .INVALID_INPUT,
                hint: "Use an in-window --at point; --global changes the coordinate basis, not the target.",
                reason: .invalidRequest
            )
        }
        do {
            return try await InteractionCoordinateResolver.resolveBackgroundSnapshotCoordinates(
                inputPoint,
                snapshotId: observation.requireSnapshot(),
                target: self.target,
                services: self.services,
                options: .init(
                    forceGlobal: self.global,
                    referenceMessage: "Coordinate scroll requires a fresh pixel-backed exact-window snapshot.",
                    operation: "scroll"
                )
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PreDispatchActionError(
                message: error.localizedDescription,
                code: .SNAPSHOT_STALE,
                hint: "Run see for the exact window and use its fresh snapshot.",
                reason: .targetUnavailable
            )
        }
    }

    private func recordScrollResult(
        _ actionResult: UIAutomationActionResult<Void>,
        sequence: CommandActionSequenceAccumulator,
        route: DesktopActionOutcome.Route
    ) throws {
        let scrollDelivery: DesktopActionOutcome.Delivery? = self.focusOptions.foreground
            ? .init(mechanism: .globalEvents, mode: .foreground)
            : nil
        let receiptlessStep = DesktopActionSequenceAccumulator.Step.dispatched(
            route: route,
            delivery: scrollDelivery,
            unitCount: nil
        )
        if self.focusOptions.foreground {
            try sequence.recordExactTargetLeaf(
                outcome: actionResult.outcome,
                targetIdentity: actionResult.targetIdentity,
                operation: "Scroll",
                receiptlessStep: receiptlessStep,
                defaultDispatchedUnitCount: nil
            )
        } else {
            try sequence.record(
                actionResult,
                operation: "Scroll",
                receiptlessStep: receiptlessStep,
                defaultDispatchedUnitCount: nil
            )
        }
    }

    private func recordSetupFocus(
        observation: InteractionObservationContext,
        sequence: CommandActionSequenceAccumulator
    ) async throws {
        guard self.focusOptions.foreground else { return }
        let focusSnapshotID = observation.focusSnapshotId(for: self.target)
        guard let focusResult = try await ensureConfirmedForegroundFocus(
            snapshotId: focusSnapshotID,
            target: self.target,
            options: self.focusOptions,
            services: self.services,
            operation: "Scroll setup focus"
        ) else { return }
        try sequence.record(focusResult, operation: "Scroll setup focus")
    }

    private func expectedBackgroundWindow(
        observation: InteractionObservationContext
    ) async throws -> UIAutomationTarget.ExactWindow? {
        guard !self.focusOptions.foreground, self.on != nil || self.at != nil else { return nil }
        let snapshotID = try observation.requireSnapshot()
        do {
            guard let exactWindow = try await SnapshotTargetReceiptPlanner(snapshots: self.services.snapshots)
                .plan(snapshotID: snapshotID)
                .receipt
                .requireIdentity()
                .exactWindow
            else {
                throw DesktopTargetIdentityError.incompleteExactWindow
            }
            return exactWindow
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw PreDispatchActionError(
                message: "Background scroll requires a complete capture-owned exact-window receipt.",
                code: .SNAPSHOT_STALE,
                hint: "Run see for the exact window and retry with its fresh snapshot.",
                reason: .targetUnavailable
            )
        }
    }

    private func validateDeliveryMode() throws {
        if self.at != nil {
            guard self.on == nil else { throw ValidationError("--at and --on are mutually exclusive.") }
            guard !self.focusOptions.foreground else {
                throw ValidationError("Coordinate scroll does not support --foreground; use background --at.")
            }
            guard !self.smooth, self.delay.milliseconds == 0 else {
                throw ValidationError("Coordinate scroll supports neither --smooth nor a nonzero --delay.")
            }
            guard InteractionSnapshotReference.isConcrete(self.snapshot) else {
                throw PreDispatchActionError(
                    message: "Background coordinate scroll requires an explicit exact-window --snapshot from see.",
                    code: .SNAPSHOT_STALE,
                    hint: "Capture the exact window with see, then use --at with its returned snapshot.",
                    reason: .targetUnavailable
                )
            }
            _ = try self.coordinatePoint()
        } else if self.global {
            throw ValidationError("--global requires --at.")
        }
        guard self.focusOptions.foreground else {
            if self.on == nil, self.at == nil {
                throw PreDispatchActionError(
                    message: "Background scroll requires --on or --at with a fresh exact-window snapshot.",
                    code: .VALIDATION_ERROR,
                    hint: "Add --foreground to scroll at the physical pointer.",
                    reason: .invalidRequest
                )
            }
            if self.smooth || self.delay.milliseconds > 0 {
                throw ValidationError(
                    "--smooth and a nonzero --delay require --foreground because they synthesize wheel events."
                )
            }
            if self.focusOptions.hasForegroundFocusOverrides {
                throw ValidationError("Focus options require --foreground for scroll.")
            }
            return
        }
    }

    private func coordinatePoint() throws -> CGPoint? {
        guard let at else { return nil }
        let parts = at.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              x.isFinite, y.isFinite
        else { throw ValidationError("Invalid --at coordinates; use two finite numbers: x,y.") }
        return CGPoint(x: x, y: y)
    }

    func validateBeforeRuntime() throws {
        _ = try self.validatedScrollDirection()
    }

    private func validatedScrollDirection() throws -> ScrollDirection {
        do {
            try ScrollRequest.validateAmount(self.amount, smooth: self.smooth)
        } catch {
            throw ValidationError(error.localizedDescription)
        }
        try self.target.validate()
        try self.validateDeliveryMode()
        guard let scrollDirection = ScrollDirection(rawValue: self.direction.lowercased()) else {
            throw ValidationError("Invalid direction. Use: up, down, left, or right")
        }
        return scrollDirection
    }

    // Error handling is provided by ErrorHandlingCommand protocol
}

struct ScrollResult: Codable {
    let direction: String
    let amount: Int
    let location: [String: Double]
    let totalTicks: Int
    let targetPoint: InteractionTargetPointDiagnostics?
    let targetReceipt: ScrollTargetReceipt?
    let executionTime: TimeInterval

    init(
        direction: String,
        amount: Int,
        location: [String: Double],
        totalTicks: Int,
        targetPoint: InteractionTargetPointDiagnostics? = nil,
        targetReceipt: ScrollTargetReceipt? = nil,
        executionTime: TimeInterval
    ) {
        self.direction = direction
        self.amount = amount
        self.location = location
        self.totalTicks = totalTicks
        self.targetPoint = targetPoint
        self.targetReceipt = targetReceipt
        self.executionTime = executionTime
    }
}

struct ScrollTargetReceipt: Codable, Equatable {
    let snapshotId: String
    let processIdentifier: Int32
    let processStartIdentityDecimal: String
    let windowId: Int
    let windowBounds: CGRect

    init?(snapshotId: String?, detectionResult: ElementDetectionResult?) {
        guard let snapshotId,
              let context = detectionResult?.metadata.windowContext,
              let processIdentifier = context.applicationProcessId,
              let windowId = context.windowID,
              let windowBounds = context.windowBounds,
              let identity = context.windowMutationIdentity,
              identity.ownerProcessIdentifier == processIdentifier,
              identity.windowID == windowId,
              identity.capturedBounds == nil || identity.capturedBounds == windowBounds
        else {
            return nil
        }
        self.snapshotId = snapshotId
        self.processIdentifier = processIdentifier
        self.processStartIdentityDecimal = String(identity.ownerProcessStartIdentity)
        self.windowId = windowId
        self.windowBounds = windowBounds
    }
}

// MARK: - Conformances

@MainActor
extension ScrollCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "scroll",
                abstract: "Scroll the mouse wheel in any direction",
                discussion: """
                    The 'scroll' command keeps a fresh target in the background. It prefers
                    Accessibility and can use exact-window wheel routing for opaque visible WebKit
                    surfaces. Add --foreground to focus the target and use the physical pointer.

                    EXAMPLES:
                      peekaboo scroll --direction up --amount 10 --on element_42
                      peekaboo scroll --direction down --at 200,150 --snapshot "$SNAPSHOT_ID"
                      peekaboo scroll --direction down --amount 5 --foreground
                      peekaboo scroll --direction right --amount 3 --smooth --foreground

                    DIRECTION:
                      up    - Scroll content up (wheel down)
                      down  - Scroll content down (wheel up)
                      left  - Scroll content left
                      right - Scroll content right

                    AMOUNT:
                      The number of route-dependent scroll units to perform.
                      Numeric scrollbars use AXValueIncrement or one tenth of their range per unit.
                      Other native actions use page/increment units; wheel routes use wheel ticks.
                      Distance depends on the selected route; observe the result after scrolling.
                """,

                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension ScrollCommand: AsyncRuntimeCommand {}

@MainActor
extension ScrollCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.direction = try values.requireOption("direction", as: String.self)
        if let amount: Int = try values.decodeOption("amount", as: Int.self) {
            self.amount = amount
        }
        self.on = values.singleOption("on")
        self.at = values.singleOption("at")
        self.global = values.flag("global")
        self.snapshot = values.singleOption("snapshot")
        if let delay: CLIDuration = try values.decodeOption("delay", as: CLIDuration.self) {
            self.delay = delay
        }
        self.smooth = values.flag("smooth")
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions()
    }
}
