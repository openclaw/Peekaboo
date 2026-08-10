import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Moves the mouse cursor to specific coordinates or UI elements.
@available(macOS 14.0, *)
@MainActor
struct MoveCommand: ErrorHandlingCommand, OutputFormattable, InjectedRuntimeBackedCommand {
    @Option(
        help: "x,y — target-relative when --app/--window-* given; global otherwise (use --global for explicit global)"
    )
    var at: String?

    @Option(help: "Opaque element ID copied from current see output")
    var on: String?

    @OptionGroup var target: InteractionTargetOptions
    @OptionGroup var focusOptions: FocusCommandOptions

    @Flag(help: "Treat --at as global screen coordinates even when target options are supplied")
    var global = false

    @Flag(help: "Use natural smooth movement (equivalent to --profile human)")
    var smooth = false

    @Option(help: "Movement duration (bare values are milliseconds; enables natural movement)")
    var duration: CLIDuration?

    @Option(help: "Number of movement samples (automatic for human, default: 20 for linear)")
    var steps: Int?

    @Option(help: "Movement profile: human or linear (default: human for animated moves, otherwise linear)")
    var profile: String?

    @Option(help: "Snapshot ID for element resolution, or 'latest'")
    var snapshot: String?
    @RuntimeStorage var runtime: CommandRuntime?

    mutating func validate() throws {
        try self.target.validate()
        guard self.focusOptions.foreground else {
            throw ValidationError(
                "move changes the physical cursor and requires explicit --foreground consent."
            )
        }
        let targetCount = [
            self.at == nil ? 0 : 1,
            self.on == nil ? 0 : 1,
        ].reduce(0, +)

        guard targetCount >= 1 else {
            throw ValidationError("Specify --at or --on")
        }

        guard targetCount == 1 else {
            throw ValidationError("Specify exactly one target: --at or --on")
        }

        // Validate coordinates format if provided
        if let coordString = self.at {
            let parts = coordString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  Double(parts[0]) != nil,
                  Double(parts[1]) != nil else {
                throw ValidationError("Invalid coordinates format. Use: x,y")
            }
        }

        if let profileName = self.profile?.lowercased(),
           CursorMovementProfileSelection(rawValue: profileName) == nil {
            throw ValidationError("Invalid profile '\(profileName)'. Use 'linear' or 'human'.")
        }

        if let steps, steps < 1 {
            throw ValidationError("--steps must be at least 1")
        }
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let startTime = Date()
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            try self.validate()
            let resolvedTarget = try await self.resolveTarget()
            let targetLocation = resolvedTarget.location
            let targetDescription = resolvedTarget.description

            let currentLocation = self.services.automation.currentMouseLocation() ?? .zero
            let distance = hypot(
                targetLocation.x - currentLocation.x,
                targetLocation.y - currentLocation.y
            )

            let movement = self.resolveMovementParameters(
                profileSelection: self.selectedProfile,
                distance: distance
            )

            // Perform the movement
            self.resolvedRuntime.beginInteractionMutation()
            try await AutomationServiceBridge.moveMouse(
                automation: self.services.automation,
                to: targetLocation,
                duration: movement.duration,
                steps: movement.steps,
                profile: movement.profile
            )
            AutomationEventLogger.log(
                .cursor,
                "move target=\(targetDescription) duration=\(movement.duration)ms steps=\(movement.steps) "
                    + "profile=\(movement.profileName)"
            )

            // Output results
            let result = MoveResult(
                success: true,
                targetLocation: targetLocation,
                targetDescription: targetDescription,
                fromLocation: currentLocation,
                distance: distance,
                duration: movement.duration,
                smooth: movement.smooth,
                profile: movement.profileName,
                targetPoint: resolvedTarget.diagnostics,
                executionTime: Date().timeIntervalSince(startTime)
            )
            output(result) {
                print("✅ Mouse moved successfully")
                print("🎯 Target: \(targetDescription)")
                print("📍 Location: (\(Int(targetLocation.x)), \(Int(targetLocation.y)))")
                print("📏 Distance: \(Int(distance)) pixels")
                print("🧭 Profile: \(movement.profileName.capitalized)")
                if movement.smooth {
                    print("🎬 Animation: \(movement.duration)ms with \(movement.steps) steps")
                }
                print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
            }

        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private func resolveTarget() async throws -> MoveTargetResolution {
        if let coordString = self.at {
            try await self.focusForCoordinateTarget()
            let parts = coordString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let x = Double(parts[0])!
            let y = Double(parts[1])!
            let inputPoint = CGPoint(x: x, y: y)
            let resolution = try await InteractionCoordinateResolver.resolveClickCoordinates(
                inputPoint,
                target: self.target,
                services: self.services,
                forceGlobal: self.global
            )
            let location = resolution.screenPoint
            return MoveTargetResolution(
                location: location,
                description: "Coordinates (\(Int(x)), \(Int(y)))",
                diagnostics: InteractionTargetPointResolver.coordinate(
                    location,
                    source: .coordinates
                ).diagnostics
            )
        }

        if let elementId = on {
            return try await self.resolveElementTarget(elementId: elementId)
        }

        throw ValidationError("Specify --at or --on")
    }

    private func focusForCoordinateTarget() async throws {
        self.resolvedRuntime.beginInteractionMutation()
        try await ensureFocused(
            snapshotId: nil,
            target: self.target,
            options: self.focusOptions,
            services: self.services
        )
    }

    private func resolveElementTarget(elementId: String) async throws -> MoveTargetResolution {
        var observation = await InteractionObservationContext.resolve(
            explicitSnapshot: self.snapshot,
            fallbackToLatest: true,
            snapshots: self.services.snapshots
        )
        observation = try await InteractionObservationRefresher.refreshForMissingElementsIfNeeded(
            observation,
            elementIds: [elementId],
            target: self.target,
            services: self.services,
            logger: self.logger,
            beforeRefresh: { startedAt in
                self.resolvedRuntime.beginInteractionMutation(at: startedAt)
            }
        )
        self.resolvedRuntime.beginInteractionMutation()
        try await ensureFocused(
            snapshotId: observation.focusSnapshotId(for: self.target),
            target: self.target,
            options: self.focusOptions,
            services: self.services
        )

        let detectionResult = try await observation.requireDetectionResult(using: self.services.snapshots)
        guard let element = detectionResult.elements.findById(elementId) else {
            throw PeekabooError.elementNotFound("Element with ID '\(elementId)' not found")
        }

        let resolution = try await InteractionTargetPointResolver.elementCenterResolution(
            element: element,
            elementId: elementId,
            snapshotId: observation.snapshotId,
            snapshots: self.services.snapshots
        )
        return MoveTargetResolution(
            location: resolution.point,
            description: self.formatElementInfo(element),
            diagnostics: resolution.diagnostics
        )
    }

    private func formatElementInfo(_ element: DetectedElement) -> String {
        let roleDescription = element.type.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        let label = element.label ?? element.value ?? element.id
        return "\(roleDescription): \(label)"
    }
}
