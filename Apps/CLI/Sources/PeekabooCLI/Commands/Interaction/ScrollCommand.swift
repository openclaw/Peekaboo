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

    @Option(help: "Number of scroll ticks")
    var amount: Int = 3

    @Option(help: "Element ID to scroll on (from 'see' command)")
    var on: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
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
                smooth: self.smooth,
                delay: self.delay.roundedMilliseconds,
                snapshotId: observation.snapshotId,
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
            let scrollDelivery: DesktopActionOutcome.Delivery? = self.focusOptions.foreground
                ? .init(mechanism: .globalEvents, mode: .foreground)
                : nil
            let receiptlessStep = DesktopActionSequenceAccumulator.Step.dispatched(
                route: actionRoute,
                delivery: scrollDelivery,
                unitCount: nil
            )
            if self.focusOptions.foreground {
                try actionSequence.recordExactTargetLeaf(
                    outcome: actionResult.outcome,
                    targetIdentity: actionResult.targetIdentity,
                    operation: "Scroll",
                    receiptlessStep: receiptlessStep,
                    defaultDispatchedUnitCount: nil
                )
            } else {
                try actionSequence.record(
                    actionResult,
                    operation: "Scroll",
                    receiptlessStep: receiptlessStep,
                    defaultDispatchedUnitCount: nil
                )
            }
            let compositeResult = actionSequence.result(payload: ())
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "scroll"
            )
            AutomationEventLogger.log(
                .scroll,
                "direction=\(self.direction) amount=\(self.amount) smooth=\(self.smooth) "
                    + "target=\(self.on ?? "pointer") snapshot=\(observation.snapshotId ?? "latest")"
            )

            // Keep result reporting aligned with ScrollService.tickConfiguration.
            let totalTicks = self.smooth ? self.amount * 10 : self.amount

            // Determine scroll location for output
            let resultDetection: ElementDetectionResult? = if let snapshotId = observation.snapshotId {
                try await self.services.snapshots.getDetectionResult(snapshotId: snapshotId)
            } else {
                nil
            }
            let scrollResolution: InteractionTargetPointResolution = if let elementId = on {
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
            let scrollLocation = scrollResolution.point

            // Output results
            let outputPayload = ScrollResult(
                direction: direction,
                amount: amount,
                location: ["x": scrollLocation.x, "y": scrollLocation.y],
                totalTicks: totalTicks,
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
                if self.on != nil {
                    print("📍 Location: (\(Int(scrollLocation.x)), \(Int(scrollLocation.y)))")
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

    private func validateDeliveryMode() throws {
        guard self.focusOptions.foreground else {
            if self.on == nil {
                throw PreDispatchActionError(
                    message: "Background scroll requires --on with an Accessibility-scrollable element.",
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

    func validateBeforeRuntime() throws {
        _ = try self.validatedScrollDirection()
    }

    private func validatedScrollDirection() throws -> ScrollDirection {
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
                      peekaboo scroll --direction down --amount 5 --foreground
                      peekaboo scroll --direction right --amount 3 --smooth --foreground

                    DIRECTION:
                      up    - Scroll content up (wheel down)
                      down  - Scroll content down (wheel up)
                      left  - Scroll content left
                      right - Scroll content right

                    AMOUNT:
                      The number of scroll "lines" or "ticks" to perform.
                      Each tick is equivalent to one notch on a physical mouse wheel.
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
        self.snapshot = values.singleOption("snapshot")
        if let delay: CLIDuration = try values.decodeOption("delay", as: CLIDuration.self) {
            self.delay = delay
        }
        self.smooth = values.flag("smooth")
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions()
    }
}
