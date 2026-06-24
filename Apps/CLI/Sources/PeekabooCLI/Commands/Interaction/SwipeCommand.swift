import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Performs swipe gestures using intelligent element finding and service-based architecture.
@available(macOS 14.0, *)
@MainActor
struct SwipeCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Option(help: "Source element ID")
    var from: String?

    @Option(help: "Source coordinates (x,y)")
    var fromCoords: String?

    @Option(help: "Destination element ID")
    var to: String?

    @Option(help: "Destination coordinates (x,y)")
    var toCoords: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @Option(help: "Duration of the swipe in milliseconds")
    var duration: Int?

    @Option(help: "Number of intermediate points for smooth movement")
    var steps: Int?

    @Option(help: "Movement profile (linear or human)")
    var profile: String?

    @OptionGroup var target: InteractionTargetOptions

    @OptionGroup var focusOptions: FocusCommandOptions

    @Flag(help: "Use right mouse button for drag")
    var rightButton = false
    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        guard let runtime else {
            preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
        }
        return runtime
    }

    private var services: any PeekabooServiceProviding {
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

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let startTime = Date()
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            try self.target.validate()
            // Validate inputs
            guard self.from != nil || self.fromCoords != nil, self.to != nil || self.toCoords != nil else {
                throw ValidationError(
                    "Must specify both source (--from or --from-coords) and destination (--to or --to-coords)"
                )
            }

            // Note: Right-button swipe is not supported in the current implementation
            if self.rightButton {
                throw ValidationError(
                    "Right-button swipe is not currently supported. " +
                        "Please use the standard swipe command for right-button gestures."
                )
            }

            if let profileName = self.profile?.lowercased(),
               CursorMovementProfileSelection(rawValue: profileName) == nil {
                throw ValidationError("Invalid profile '\(profileName)'. Use 'linear' or 'human'.")
            }

            let needsSnapshotForElements = self.from != nil || self.to != nil
            var observation = await InteractionObservationContext.resolve(
                explicitSnapshot: self.snapshot,
                fallbackToLatest: needsSnapshotForElements,
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

            if needsSnapshotForElements {
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

            // Get source and destination points
            let sourceResolution = try await resolvePoint(
                elementId: from,
                coords: fromCoords,
                snapshotId: observation.snapshotId,
                description: "from",
                waitTimeout: 5.0
            )

            let destResolution = try await resolvePoint(
                elementId: to,
                coords: toCoords,
                snapshotId: observation.snapshotId,
                description: "to",
                waitTimeout: 5.0
            )
            let sourcePoint = sourceResolution.point
            let destPoint = destResolution.point

            let distance = hypot(destPoint.x - sourcePoint.x, destPoint.y - sourcePoint.y)
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

            // Perform swipe using UIAutomationService
            try await AutomationServiceBridge.swipe(
                automation: self.services.automation,
                request: SwipeRequest(
                    from: sourcePoint,
                    to: destPoint,
                    duration: movement.duration,
                    steps: movement.steps,
                    profile: movement.profile
                )
            )
            let snapshotLabel = observation.snapshotId ?? "latest"
            AutomationEventLogger.log(
                .gesture,
                "swipe from=(\(Int(sourcePoint.x)),\(Int(sourcePoint.y))) to=(\(Int(destPoint.x)),\(Int(destPoint.y))) "
                    + "profile=\(movement.profileName) steps=\(movement.steps) snapshot=\(snapshotLabel)"
            )

            // Small delay to ensure swipe is processed
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "swipe"
            )
            try Task.checkCancellation()

            let outputPayload = SwipeResult(
                success: true,
                fromLocation: ["x": sourcePoint.x, "y": sourcePoint.y],
                toLocation: ["x": destPoint.x, "y": destPoint.y],
                distance: distance,
                duration: movement.duration,
                steps: movement.steps,
                profile: movement.profileName,
                fromTargetPoint: sourceResolution.diagnostics,
                toTargetPoint: destResolution.diagnostics,
                executionTime: Date().timeIntervalSince(startTime)
            )
            output(outputPayload) {
                print("✅ Swipe completed")
                print("📍 From: (\(Int(sourcePoint.x)), \(Int(sourcePoint.y)))")
                print("📍 To: (\(Int(destPoint.x)), \(Int(destPoint.y)))")
                print("📏 Distance: \(Int(distance)) pixels")
                print("🧭 Profile: \(movement.profileName.capitalized)")
                print("⏱️  Duration: \(movement.duration)ms with \(movement.steps) steps")
                print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
            }

        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private func resolvePoint(
        elementId: String?,
        coords: String?,
        snapshotId: String?,
        description: String,
        waitTimeout: TimeInterval
    ) async throws -> InteractionTargetPointResolution {
        try await InteractionTargetPointResolver.elementOrCoordinateResolution(
            InteractionTargetPointRequest(
                elementId: elementId,
                coordinates: coords,
                snapshotId: snapshotId,
                description: description,
                waitTimeout: waitTimeout
            ),
            services: self.services
        )
    }
}

// MARK: - Conformances

@MainActor
extension SwipeCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "swipe",
                abstract: "Perform swipe gestures",
                discussion: """
                Performs a drag/swipe gesture between two points or elements.
                Useful for drag-and-drop operations and gesture-based interactions.

                EXAMPLES:
                  # Swipe between UI elements
                  peekaboo swipe --from "$SOURCE_ID" --to "$TARGET_ID" --snapshot "$SNAPSHOT_ID"

                  # Swipe with coordinates
                  peekaboo swipe --from-coords 100,200 --to-coords 300,400

                  # Mixed mode: element to coordinates
                  peekaboo swipe --from "$SOURCE_ID" --to-coords 500,300 --duration 1000

                  # Slow swipe for precise gesture
                  peekaboo swipe --from-coords 50,50 --to-coords 400,400 --duration 2000

                USAGE:
                  You can specify source and destination using either:
                  - Opaque element IDs copied from current 'see' or 'inspect-ui' output
                  - Direct coordinates
                  - A mix of both

                  The swipe includes a configurable duration to control the
                  speed of the drag gesture.
                """,
                version: "2.0.0",
                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension SwipeCommand: AsyncRuntimeCommand {}

@MainActor
extension SwipeCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.from = values.singleOption("from")
        self.fromCoords = values.singleOption("fromCoords")
        self.to = values.singleOption("to")
        self.toCoords = values.singleOption("toCoords")
        self.snapshot = values.singleOption("snapshot")
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions()
        if let duration: Int = try values.decodeOption("duration", as: Int.self) {
            self.duration = duration
        }
        if let steps: Int = try values.decodeOption("steps", as: Int.self) {
            self.steps = steps
        }
        self.profile = values.singleOption("profile")
        self.rightButton = values.flag("rightButton")
    }
}
