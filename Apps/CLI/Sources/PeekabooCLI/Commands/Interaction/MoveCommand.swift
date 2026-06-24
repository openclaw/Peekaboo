import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Moves the mouse cursor to specific coordinates or UI elements.
@available(macOS 14.0, *)
@MainActor
struct MoveCommand: ErrorHandlingCommand, OutputFormattable {
    @Argument(help: "Coordinates as x,y (e.g., 100,200)")
    var coordinates: String?

    @Option(name: .customLong("coords"), help: "Coordinates as x,y (alias for the positional argument)")
    var coords: String?

    @Option(help: "Move to element by text/label")
    var to: String?

    @Option(help: "Opaque element ID copied from current see or inspect-ui output")
    var on: String?

    @Option(name: .customLong("id"), help: "Element ID to move to (alias for --on)")
    var id: String?

    @OptionGroup var target: InteractionTargetOptions
    @OptionGroup var focusOptions: FocusCommandOptions

    @Flag(help: "Move to screen center")
    var center = false

    @Flag(help: "Use smooth movement animation")
    var smooth = false

    @Option(help: "Movement duration in milliseconds (default: 500 for smooth, 0 for instant)")
    var duration: Int?

    @Option(help: "Number of steps for smooth movement (default: 20)")
    var steps: Int = 20

    @Option(help: "Movement profile: linear (default) or human.")
    var profile: String?

    @Option(help: "Snapshot ID for element resolution, or 'latest'")
    var snapshot: String?
    @RuntimeStorage private var runtime: CommandRuntime?

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
        self.resolvedRuntime.configuration.jsonOutput
    }

    private var resolvedCoordinates: String? {
        self.coordinates ?? self.coords
    }

    mutating func validate() throws {
        try self.target.validate()
        let targetCount = [
            self.center ? 1 : 0,
            self.resolvedCoordinates == nil ? 0 : 1,
            self.to == nil ? 0 : 1,
            self.on == nil ? 0 : 1,
            self.id == nil ? 0 : 1,
        ].reduce(0, +)

        guard targetCount >= 1 else {
            throw ValidationError("Specify coordinates, --coords, --to, --on/--id, or --center")
        }

        guard targetCount == 1 else {
            throw ValidationError("Specify exactly one target: coordinates, --coords, --to, --on/--id, or --center")
        }

        // Validate coordinates format if provided
        if let coordString = self.resolvedCoordinates {
            let parts = coordString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2,
                  Double(parts[0]) != nil,
                  Double(parts[1]) != nil else {
                throw ValidationError("Invalid coordinates format. Use: x,y")
            }
        }

        if let profileName = self.profile?.lowercased(),
           MovementProfileSelection(rawValue: profileName) == nil {
            throw ValidationError("Invalid profile '\(profileName)'. Use 'linear' or 'human'.")
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
        if self.center {
            try await self.focusForCoordinateTarget()
            guard let mainScreen = self.services.screens.primaryScreen else {
                throw ValidationError("No main screen found")
            }
            let screenFrame = mainScreen.frame
            let location = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
            return MoveTargetResolution(
                location: location,
                description: "Screen center",
                diagnostics: InteractionTargetPointResolver.coordinate(
                    location,
                    source: .screenCenter
                ).diagnostics
            )
        }

        if let coordString = self.resolvedCoordinates {
            try await self.focusForCoordinateTarget()
            let parts = coordString.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let x = Double(parts[0])!
            let y = Double(parts[1])!
            let location = CGPoint(x: x, y: y)
            return MoveTargetResolution(
                location: location,
                description: "Coordinates (\(Int(x)), \(Int(y)))",
                diagnostics: InteractionTargetPointResolver.coordinate(
                    location,
                    source: .coordinates
                ).diagnostics
            )
        }

        if let elementId = on ?? id {
            return try await self.resolveElementTarget(elementId: elementId)
        }

        if let query = to {
            return try await self.resolveQueryTarget(query: query)
        }

        throw ValidationError("Specify coordinates, --coords, --to, --on/--id, or --center")
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

    private func resolveQueryTarget(query: String) async throws -> MoveTargetResolution {
        var observation = await InteractionObservationContext.resolve(
            explicitSnapshot: self.snapshot,
            fallbackToLatest: true,
            snapshots: self.services.snapshots
        )
        observation = try await InteractionObservationRefresher.refreshForMissingQueryIfNeeded(
            observation,
            query: query,
            target: self.target,
            services: self.services,
            logger: self.logger,
            beforeRefresh: { startedAt in
                self.resolvedRuntime.beginInteractionMutation(at: startedAt)
            }
        )
        let activeSnapshotId = try observation.requireSnapshot()
        self.resolvedRuntime.beginInteractionMutation()
        try await ensureFocused(
            snapshotId: observation.focusSnapshotId(for: self.target),
            target: self.target,
            options: self.focusOptions,
            services: self.services
        )

        try await observation.validateIfExplicit(using: self.services.snapshots)

        let waitResult = try await AutomationServiceBridge.waitForElement(
            automation: self.services.automation,
            target: .query(query),
            timeout: 5.0,
            snapshotId: activeSnapshotId
        )

        guard waitResult.found, let element = waitResult.element else {
            throw PeekabooError.elementNotFound("No element found matching '\(query)'")
        }

        let resolution = try await InteractionTargetPointResolver.elementCenterResolution(
            element: element,
            elementId: element.id,
            snapshotId: activeSnapshotId,
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
