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

    @Option(help: "Explicit fresh exact-window snapshot for background drag; foreground may use 'latest'")
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
            if self.focusOptions.foreground {
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
            }
            if needsSnapshot {
                _ = try await observation.requireDetectionResult(using: self.services.snapshots)
            } else {
                try await observation.validateIfExplicit(using: self.services.snapshots)
            }

            self.resolvedRuntime.beginInteractionMutation()
            let focusResult = try await self.setupFocus(observation: observation)

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
            let actionResult: UIAutomationActionResult<Void> = if self.focusOptions.foreground {
                try await self.performDrag(dragRequest, setupFocus: focusResult)
            } else {
                try await self.performBackgroundDrag(
                    dragRequest,
                    snapshotID: observation.requireSnapshot()
                )
            }
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

    private func setupFocus(observation: InteractionObservationContext) async throws -> UIAutomationActionResult<Void> {
        guard self.focusOptions.foreground else { return UIAutomationActionResult(payload: (), outcome: nil) }
        return try await ensureConfirmedForegroundFocus(
            snapshotId: observation.focusSnapshotId(for: self.target),
            target: self.target,
            options: self.focusOptions,
            services: self.services,
            operation: "Drag setup focus"
        ) ?? UIAutomationActionResult(payload: (), outcome: nil)
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

    private func performBackgroundDrag(
        _ drag: DragRequest,
        snapshotID: String
    ) async throws -> UIAutomationActionResult<Void> {
        guard let service = self.services.automation as? any ExactWindowDragServiceProtocol,
              service.supportsExactWindowDrag,
              let exactWindow = try await SnapshotTargetReceiptPlanner(snapshots: self.services.snapshots)
                  .planForMutation(snapshotID: snapshotID).receipt.requireIdentity().exactWindow
        else {
            throw ValidationError("Background drag requires a capable host and a fresh exact-window snapshot")
        }
        let request = ExactWindowDragRequest(
            snapshotID: snapshotID,
            target: exactWindow,
            from: drag.from,
            to: drag.to,
            durationMilliseconds: drag.duration,
            steps: drag.steps,
            button: drag.button == .right ? .right : .left
        )
        try request.validate()
        return try await self.services.snapshots.withSnapshotMutation(
            snapshotId: snapshotID,
            targetIdentity: DesktopTargetIdentity(exactWindow: exactWindow),
            operation: { try await service.dragExactWindow(request, boundTo: nil) },
            outcome: { $0.outcome }
        )
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
        if !self.focusOptions.foreground {
            guard let snapshot = self.snapshot, SnapshotReference(rawValue: snapshot) != nil else {
                throw ValidationError("Background drag requires one explicit fresh --snapshot ID")
            }
            guard !self.target.hasAnyTarget, self.toApp == nil else {
                throw ValidationError(
                    "Background drag uses only the snapshot window; target selectors and --to-app require --foreground"
                )
            }
            guard self.modifiers == nil, (self.profile ?? "linear").lowercased() == "linear",
                  !self.focusOptions.hasForegroundFocusOverrides
            else {
                throw ValidationError("Modifiers, human movement, and focus options require --foreground")
            }
            guard ExactWindowDragRequest.durationMillisecondsRange.contains(self.duration?.roundedMilliseconds ?? 500),
                  ExactWindowDragRequest.sampleCountRange.contains(self.steps ?? 20)
            else { throw ValidationError("Background drag accepts 1...10000ms and 1...96 steps") }
        }
        if self.focusOptions.foreground, self.focusOptions.focusBackground {
            throw ValidationError("--foreground cannot be combined with --focus-background")
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
        if !self.focusOptions.foreground, let elementId {
            guard let snapshotId else { throw ValidationError("Background drag requires an explicit snapshot") }
            let detection = try await SnapshotValidation.requireDetectionResult(
                snapshotId: snapshotId,
                snapshots: self.services.snapshots
            )
            guard let element = detection.elements.findById(elementId) else {
                throw self.preDispatchActionError(
                    for: PeekabooError.elementNotFound("Element with ID '\(elementId)' not found in the drag snapshot"),
                    reason: .targetUnavailable
                )
            }
            return try await InteractionTargetPointResolver.elementCenterResolution(
                element: element,
                elementId: elementId,
                snapshotId: snapshotId,
                snapshots: self.services.snapshots
            )
        }
        return try await InteractionTargetPointResolver.elementOrCoordinateResolution(
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
                  peekaboo drag --from "100,200" --to "400,300" --snapshot "$SNAPSHOT_ID"
                  peekaboo drag --from "$SOURCE_ID" --to "$TARGET_ID" --foreground
                  peekaboo drag --from "100,200" --to "400,300" --foreground
                  peekaboo drag --from "$SOURCE_ID" --to-app Trash --foreground
                  peekaboo drag --from "$SOURCE_ID" --to "500,250" --duration 2s --foreground
                  peekaboo drag --from "$SOURCE_ID" --to "$TARGET_ID" --modifiers shift --foreground
                  peekaboo drag --from "100,200" --to "400,300" --button right --foreground

                Background drag requires a fresh --snapshot and a bounded linear path inside that one window.
                Coordinates are global logical points. Cross-window/app drops, modifiers, human profiles,
                and shared physical cursor input require explicit --foreground.
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
