import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Perform drag and drop operations using intelligent element finding
@available(macOS 14.0, *)
@MainActor
struct DragCommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable, InjectedRuntimeBackedCommand {
    @OptionGroup var target: InteractionTargetOptions

    @Option(help: "Starting element ID or coordinates as 'x,y'")
    var from: String?

    @Option(help: "Target element ID or coordinates as 'x,y'")
    var to: String?

    @Option(help: "Target application (e.g., 'Trash', 'Finder')")
    var toApp: String?

    @Option(help: "Snapshot ID for element resolution, or 'latest'")
    var snapshot: String?

    @Option(help: "Duration of drag (bare values are milliseconds; default: 500ms)")
    var duration: CLIDuration?

    @Option(help: "Number of intermediate steps (default: 20)")
    var steps: Int?

    @Option(help: "Modifier keys to hold (comma-separated: cmd,shift,option,ctrl,fn)")
    var modifiers: CLIModifierList?

    @Option(help: "Mouse button to hold during drag (left or right)")
    var button = "left"

    @Option(help: "Movement profile (linear or human)")
    var profile: String?
    @OptionGroup var focusOptions: FocusCommandOptions

    @RuntimeStorage var runtime: CommandRuntime?

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        let startTime = Date()

        do {
            try self.validateInputs()

            let fromInput = self.splitTarget(self.from)
            let toInput = self.splitTarget(self.to)
            let needsSnapshot = fromInput.element != nil || toInput.element != nil
            var observation = await InteractionObservationContext.resolve(
                explicitSnapshot: self.snapshot,
                fallbackToLatest: needsSnapshot,
                snapshots: self.services.snapshots
            )
            let refreshRuntime = self.resolvedRuntime
            observation = try await InteractionObservationRefresher.refreshForMissingElementsIfNeeded(
                observation,
                elementIds: [fromInput.element, toInput.element],
                target: self.target,
                services: self.services,
                logger: self.logger,
                beforeRefresh: { startedAt in
                    refreshRuntime.beginInteractionMutation(at: startedAt)
                }
            )
            if needsSnapshot {
                _ = try await observation.requireDetectionResult(using: self.services.snapshots)
            } else {
                try await observation.validateIfExplicit(using: self.services.snapshots)
            }

            self.resolvedRuntime.beginInteractionMutation()
            let focusResult = try await ensureConfirmedForegroundFocus(
                snapshotId: observation.focusSnapshotId(for: self.target),
                target: self.target,
                options: self.focusOptions,
                services: self.services,
                operation: "Drag setup focus"
            ) ?? UIAutomationActionResult(payload: (), outcome: nil)

            let startResolution = try await self.resolvePoint(
                elementId: fromInput.element,
                coords: fromInput.coordinates,
                snapshotId: observation.snapshotId,
                description: "from"
            )

            let endResolution: InteractionTargetPointResolution = if let targetApp = toApp {
                try await InteractionTargetPointResolver.coordinate(
                    DragDestinationResolver(services: self.services).destinationPoint(
                        forApplicationNamed: targetApp
                    ),
                    source: .application
                )
            } else {
                try await self.resolvePoint(
                    elementId: toInput.element,
                    coords: toInput.coordinates,
                    snapshotId: observation.snapshotId,
                    description: "to"
                )
            }
            let startPoint = startResolution.point
            let endPoint = endResolution.point

            let distance = hypot(endPoint.x - startPoint.x, endPoint.y - startPoint.y)
            let profileSelection = CursorMovementProfileSelection(
                rawValue: (self.profile ?? "linear").lowercased()
            ) ?? .linear
            let movement = CursorMovementResolver.resolve(
                CursorMovementResolutionRequest(
                    selection: profileSelection,
                    durationOverride: self.duration?.roundedMilliseconds,
                    stepsOverride: self.steps,
                    baseSmooth: true,
                    distance: distance,
                    defaultDuration: 500,
                    defaultSteps: 20
                )
            )

            let dragRequest = DragRequest(
                from: startPoint,
                to: endPoint,
                duration: movement.duration,
                steps: movement.steps,
                modifiers: self.modifiers?.description,
                button: self.resolvedButton ?? .left,
                profile: movement.profile
            )
            let actionResult = try await self.performDrag(dragRequest, setupFocus: focusResult)
            AutomationEventLogger.log(
                .drag,
                "drag from=(\(Int(startPoint.x)),\(Int(startPoint.y))) to=(\(Int(endPoint.x)),\(Int(endPoint.y))) "
                    + "modifiers=\(self.modifiers?.description ?? "none") "
                    + "snapshot=\(observation.snapshotId ?? "latest") "
                    + "profile=\(movement.profileName)"
            )

            try await withPreservedActionResultOnFailure(
                actionResult,
                targetIdentity: actionResult.targetIdentity,
                operation: "Drag"
            ) {
                try? await Task.sleep(nanoseconds: 100_000_000)
                await InteractionObservationInvalidator.invalidateAfterMutation(
                    targets: self.resolvedRuntime.interactionMutationTargets,
                    logger: self.logger,
                    reason: "drag"
                )
                try Task.checkCancellation()

                let result = DragResult(
                    from: ["x": Int(startPoint.x), "y": Int(startPoint.y)],
                    to: ["x": Int(endPoint.x), "y": Int(endPoint.y)],
                    duration: movement.duration,
                    steps: movement.steps,
                    profile: movement.profileName,
                    modifiers: self.modifiers?.description ?? "none",
                    button: self.button.lowercased(),
                    fromTargetPoint: startResolution.diagnostics,
                    toTargetPoint: endResolution.diagnostics,
                    executionTime: Date().timeIntervalSince(startTime)
                )

                output(
                    result,
                    outcome: actionResult.outcome,
                    targetIdentity: actionResult.targetIdentity
                ) {
                    if let outcome = actionResult.outcome {
                        print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Drag"))
                    } else {
                        print("✅ Drag successful")
                    }
                    print("📍 From: (\(Int(startPoint.x)), \(Int(startPoint.y)))")
                    print("📍 To: (\(Int(endPoint.x)), \(Int(endPoint.y)))")
                    print("🧭 Profile: \(movement.profileName.capitalized)")
                    print("⏱️  Duration: \(movement.duration)ms with \(movement.steps) steps")
                    if let mods = self.modifiers {
                        print("⌨️  Modifiers: \(mods)")
                    }
                    print("🖱️  Button: \(self.button.lowercased())")
                    print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
                }
            }
        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private func performDrag(
        _ request: DragRequest,
        setupFocus: UIAutomationActionResult<Void>
    ) async throws -> UIAutomationActionResult<Void> {
        let pointerAction = try await AutomationServiceBridge.drag(
            automation: self.services.automation,
            request: request
        )
        return try withPreservedActionResultOnFailure(
            pointerAction,
            targetIdentity: pointerAction.targetIdentity,
            operation: "Drag"
        ) {
            try AutomationServiceBridge.composeGlobalPointerResult(
                setupFocus: setupFocus,
                pointerAction: pointerAction,
                operation: "Drag",
                route: commandActionRoute(for: self.services)
            )
        }
    }

    /// Validate user input combinations
    private mutating func validateInputs() throws {
        try self.target.validate()
        guard self.from != nil else {
            throw ValidationError("Must specify --from as an element ID or x,y coordinates")
        }

        guard self.to != nil || self.toApp != nil else {
            throw ValidationError("Must specify --to as an element ID or x,y coordinates, or use --to-app")
        }

        if self.to != nil, self.toApp != nil {
            throw ValidationError("Specify only one of --to or --to-app")
        }
        guard self.focusOptions.foreground else {
            throw PreDispatchActionError(
                message: "drag changes the physical cursor and requires explicit consent.",
                code: .VALIDATION_ERROR,
                hint: "Use --foreground to provide explicit consent.",
                reason: .foregroundConsentRequired
            )
        }
        guard self.resolvedButton != nil else {
            throw ValidationError("--button must be either 'left' or 'right'")
        }

        if let profileName = self.profile?.lowercased(),
           CursorMovementProfileSelection(rawValue: profileName) == nil {
            throw ValidationError("Invalid profile '\(profileName)'. Use 'linear' or 'human'.")
        }
    }

    var resolvedButton: DragButton? {
        switch self.button.lowercased() {
        case "left": .left
        case "right": .right
        default: nil
        }
    }

    func splitTarget(_ value: String?) -> (element: String?, coordinates: String?) {
        guard let value else { return (nil, nil) }
        if Self.isCoordinateTarget(value) {
            return (nil, value)
        }
        return (value, nil)
    }

    static func isCoordinateTarget(_ value: String?) -> Bool {
        guard let value else { return false }
        let pieces = value.split(separator: ",", omittingEmptySubsequences: false)
        if pieces.count == 2,
           Double(pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)) != nil,
           Double(pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
            return true
        }
        return false
    }

    private func resolvePoint(
        elementId: String?,
        coords: String?,
        snapshotId: String?,
        description: String
    ) async throws -> InteractionTargetPointResolution {
        try await InteractionTargetPointResolver.elementOrCoordinateResolution(
            InteractionTargetPointRequest(
                elementId: elementId,
                coordinates: coords,
                snapshotId: snapshotId,
                description: description,
                waitTimeout: 5.0
            ),
            services: self.services
        )
    }
}

// MARK: - Conformances

extension DragCommand: PreRuntimeValidatingCommand {
    func validateBeforeRuntime() throws {
        var command = self
        try command.validateInputs()
    }
}

@MainActor
extension DragCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "drag",
                abstract: "Perform drag and drop operations",
                discussion: """
                Execute click-and-drag operations for moving elements, selecting text, or dragging files.

                EXAMPLES:
                  peekaboo drag --from "$SOURCE_ID" --to "$TARGET_ID" --foreground
                  peekaboo drag --from "100,200" --to "400,300" --foreground
                  peekaboo drag --from "$SOURCE_ID" --to-app Trash --foreground
                  peekaboo drag --from "$SOURCE_ID" --to "500,250" --duration 2s --foreground
                  peekaboo drag --from "$SOURCE_ID" --to "$TARGET_ID" --modifiers shift --foreground
                  peekaboo drag --from "100,200" --to "400,300" --button right --foreground

                Drag always changes the shared physical cursor and requires --foreground.
                """,
                version: "2.0.0",
                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension DragCommand: AsyncRuntimeCommand {}

@MainActor
extension DragCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.target = try values.makeInteractionTargetOptions()
        self.from = values.singleOption("from")
        self.to = values.singleOption("to")
        self.toApp = values.singleOption("toApp")
        self.snapshot = values.singleOption("snapshot")
        if let duration: CLIDuration = try values.decodeOption("duration", as: CLIDuration.self) {
            self.duration = duration
        }
        if let steps: Int = try values.decodeOption("steps", as: Int.self) {
            self.steps = steps
        }
        self.modifiers = try values.decodeOption("modifiers", as: CLIModifierList.self)
        self.button = values.singleOption("button") ?? "left"
        self.profile = values.singleOption("profile")
        self.focusOptions = try values.makeFocusOptions()
    }
}

extension DragCommand: ApplicationResolver {}
