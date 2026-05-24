import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Scrolls the mouse wheel in a specified direction.
/// Supports scrolling on specific elements or at the current mouse position.
@available(macOS 14.0, *)
@MainActor
struct ScrollCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Option(help: "Scroll direction: up, down, left, or right")
    var direction: String

    @Option(help: "Number of scroll ticks")
    var amount: Int = 3

    @Option(help: "Element ID to scroll on (from 'see' command)")
    var on: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @Option(help: "Delay between scroll ticks in milliseconds")
    var delay: Int = 2

    @Flag(help: "Use smooth scrolling with smaller increments")
    var smooth = false

    @OptionGroup var target: InteractionTargetOptions

    @OptionGroup var focusOptions: FocusCommandOptions
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
            // Parse direction
            guard let scrollDirection = ScrollDirection(rawValue: direction.lowercased()) else {
                throw ValidationError("Invalid direction. Use: up, down, left, or right")
            }

            var observation = await InteractionObservationContext.resolve(
                explicitSnapshot: self.snapshot,
                fallbackToLatest: self.on != nil,
                snapshots: self.services.snapshots
            )

            if let elementId = self.on {
                observation = try await InteractionObservationRefresher.refreshForMissingElementsIfNeeded(
                    observation,
                    elementIds: [elementId],
                    target: self.target,
                    services: self.services,
                    logger: self.logger
                )
                _ = try await observation.requireDetectionResult(using: self.services.snapshots)
            } else {
                try await observation.validateIfExplicit(using: self.services.snapshots)
            }

            // Ensure window is focused before scrolling
            try await ensureFocused(
                snapshotId: observation.focusSnapshotId(for: self.target),
                target: self.target,
                options: self.focusOptions,
                services: self.services
            )

            // Perform scroll using the service
            let scrollRequest = ScrollRequest(
                direction: scrollDirection,
                amount: self.amount,
                target: self.on,
                smooth: self.smooth,
                delay: self.delay,
                snapshotId: observation.snapshotId
            )
            try await AutomationServiceBridge.scroll(
                automation: self.services.automation,
                request: scrollRequest
            )
            AutomationEventLogger.log(
                .scroll,
                "direction=\(self.direction) amount=\(self.amount) smooth=\(self.smooth) "
                    + "target=\(self.on ?? "pointer") snapshot=\(observation.snapshotId ?? "latest")"
            )

            // Keep result reporting aligned with ScrollService.tickConfiguration.
            let totalTicks = self.smooth ? self.amount * 10 : self.amount

            // Determine scroll location for output
            let scrollResolution: InteractionTargetPointResolution = if let elementId = on {
                if let snapshotId = observation.snapshotId,
                   let detectionResult = try await self.services.snapshots.getDetectionResult(snapshotId: snapshotId),
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

            await InteractionObservationInvalidator.invalidateAfterMutation(
                observation,
                snapshots: self.services.snapshots,
                logger: self.logger,
                reason: "scroll"
            )

            // Output results
            let outputPayload = ScrollResult(
                success: true,
                direction: direction,
                amount: amount,
                location: ["x": scrollLocation.x, "y": scrollLocation.y],
                totalTicks: totalTicks,
                targetPoint: scrollResolution.diagnostics,
                executionTime: Date().timeIntervalSince(startTime)
            )
            output(outputPayload) {
                print("✅ Scroll completed")
                print("🎯 Direction: \(self.direction)")
                print("📊 Amount: \(self.amount) ticks")
                if self.on != nil {
                    print("📍 Location: (\(Int(scrollLocation.x)), \(Int(scrollLocation.y)))")
                }
                print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
            }

        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    // Error handling is provided by ErrorHandlingCommand protocol
}

// MARK: - JSON Output Structure

struct ScrollResult: Codable {
    let success: Bool
    let direction: String
    let amount: Int
    let location: [String: Double]
    let totalTicks: Int
    let targetPoint: InteractionTargetPointDiagnostics?
    let executionTime: TimeInterval

    init(
        success: Bool,
        direction: String,
        amount: Int,
        location: [String: Double],
        totalTicks: Int,
        targetPoint: InteractionTargetPointDiagnostics? = nil,
        executionTime: TimeInterval
    ) {
        self.success = success
        self.direction = direction
        self.amount = amount
        self.location = location
        self.totalTicks = totalTicks
        self.targetPoint = targetPoint
        self.executionTime = executionTime
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
                    The 'scroll' command simulates mouse wheel scrolling events.
                    It can scroll up, down, left, or right by a specified amount.

                    EXAMPLES:
                      peekaboo scroll --direction down --amount 5
                      peekaboo scroll --direction up --amount 10 --on element_42
                      peekaboo scroll --direction right --amount 3 --smooth

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
        if let delay: Int = try values.decodeOption("delay", as: Int.self) {
            self.delay = delay
        }
        self.smooth = values.flag("smooth")
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions()
    }
}
