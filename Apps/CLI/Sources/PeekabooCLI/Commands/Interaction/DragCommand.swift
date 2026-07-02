import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Perform drag and drop operations using intelligent element finding
@available(macOS 14.0, *)
@MainActor
struct DragCommand: ErrorHandlingCommand, OutputFormattable {
    @OptionGroup var target: InteractionTargetOptions

    @Option(help: "Starting element ID from snapshot")
    var from: String?

    @Option(help: "Starting coordinates as 'x,y'")
    var fromCoords: String?

    @Option(help: "Target element ID from snapshot")
    var to: String?

    @Option(help: "Target coordinates as 'x,y'")
    var toCoords: String?

    @Option(help: "Target application (e.g., 'Trash', 'Finder')")
    var toApp: String?

    @Option(help: "Snapshot ID for element resolution, or 'latest'")
    var snapshot: String?

    @Option(help: "Duration of drag in milliseconds (default: 500)")
    var duration: Int?

    @Option(help: "Number of intermediate steps (default: 20)")
    var steps: Int?

    @Option(help: "Modifier keys to hold during drag (comma-separated: cmd,shift,option,ctrl)")
    var modifiers: String?

    @Option(help: "Movement profile (linear or human)")
    var profile: String?
    @OptionGroup var focusOptions: FocusCommandOptions
    @RuntimeStorage private var runtime: CommandRuntime?

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
        self.resolvedRuntime.configuration.jsonOutput
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)
        let startTime = Date()

        do {
            try self.validateInputs()

            let needsSnapshot = self.from != nil || self.to != nil
            var observation = await InteractionObservationContext.resolve(
                explicitSnapshot: self.snapshot,
                fallbackToLatest: needsSnapshot,
                snapshots: self.services.snapshots
            )
            let refreshRuntime = self.resolvedRuntime
            observation = try await InteractionObservationRefresher.refreshForMissingElementsIfNeeded(
                observation,
                elementIds: [self.from, self.to],
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
            try await ensureFocused(
                snapshotId: observation.focusSnapshotId(for: self.target),
                target: self.target,
                options: self.focusOptions,
                services: self.services
            )

            let startResolution = try await self.resolvePoint(
                elementId: self.from,
                coords: self.fromCoords,
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
                    elementId: self.to,
                    coords: self.toCoords,
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
                    durationOverride: self.duration,
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
                modifiers: self.modifiers,
                profile: movement.profile
            )
            try await AutomationServiceBridge.drag(automation: self.services.automation, request: dragRequest)
            AutomationEventLogger.log(
                .drag,
                "drag from=(\(Int(startPoint.x)),\(Int(startPoint.y))) to=(\(Int(endPoint.x)),\(Int(endPoint.y))) "
                    + "modifiers=\(self.modifiers ?? "none") snapshot=\(observation.snapshotId ?? "latest") "
                    + "profile=\(movement.profileName)"
            )

            try? await Task.sleep(nanoseconds: 100_000_000)
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "drag"
            )
            try Task.checkCancellation()

            let result = DragResult(
                success: true,
                from: ["x": Int(startPoint.x), "y": Int(startPoint.y)],
                to: ["x": Int(endPoint.x), "y": Int(endPoint.y)],
                duration: movement.duration,
                steps: movement.steps,
                profile: movement.profileName,
                modifiers: self.modifiers ?? "none",
                fromTargetPoint: startResolution.diagnostics,
                toTargetPoint: endResolution.diagnostics,
                executionTime: Date().timeIntervalSince(startTime)
            )

            output(result) {
                print("✅ Drag successful")
                print("📍 From: (\(Int(startPoint.x)), \(Int(startPoint.y)))")
                print("📍 To: (\(Int(endPoint.x)), \(Int(endPoint.y)))")
                print("🧭 Profile: \(movement.profileName.capitalized)")
                print("⏱️  Duration: \(movement.duration)ms with \(movement.steps) steps")
                if let mods = modifiers {
                    print("⌨️  Modifiers: \(mods)")
                }
                print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
            }
        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    /// Validate user input combinations
    private mutating func validateInputs() throws {
        try self.target.validate()
        guard self.from != nil || self.fromCoords != nil else {
            throw ValidationError("Must specify either --from or --from-coords")
        }

        guard self.to != nil || self.toCoords != nil || self.toApp != nil else {
            throw ValidationError("Must specify either --to, --to-coords, or --to-app")
        }

        if self.to != nil || self.toCoords != nil {
            guard (self.to != nil) != (self.toCoords != nil) else {
                throw ValidationError("Specify only one of --to or --to-coords")
            }
        }

        if self.from != nil && self.fromCoords != nil {
            throw ValidationError("Specify only one of --from or --from-coords")
        }

        if let profileName = self.profile?.lowercased(),
           CursorMovementProfileSelection(rawValue: profileName) == nil {
            throw ValidationError("Invalid profile '\(profileName)'. Use 'linear' or 'human'.")
        }
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
                  peekaboo drag --from "$SOURCE_ID" --to "$TARGET_ID"
                  peekaboo drag --from-coords "100,200" --to-coords "400,300"
                  peekaboo drag --from "$SOURCE_ID" --to-app Trash
                  peekaboo drag --from "$SOURCE_ID" --to-coords "500,250" --duration 2000
                  peekaboo drag --from "$SOURCE_ID" --to "$TARGET_ID" --modifiers shift
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
        self.fromCoords = values.singleOption("fromCoords")
        self.to = values.singleOption("to")
        self.toCoords = values.singleOption("toCoords")
        self.toApp = values.singleOption("toApp")
        self.snapshot = values.singleOption("snapshot")
        if let duration: Int = try values.decodeOption("duration", as: Int.self) {
            self.duration = duration
        }
        if let steps: Int = try values.decodeOption("steps", as: Int.self) {
            self.steps = steps
        }
        self.modifiers = values.singleOption("modifiers")
        self.profile = values.singleOption("profile")
        self.focusOptions = try values.makeFocusOptions()
    }
}

extension DragCommand: ApplicationResolver {}
