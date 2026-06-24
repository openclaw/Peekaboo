import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooCore

@available(macOS 14.0, *)
@MainActor
struct PerformActionCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Option(help: "Element ID or query to act on")
    var on: String?

    @Option(help: "Accessibility action name, e.g. AXPress, AXShowMenu, AXIncrement")
    var action: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

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
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            let target = try self.requireTarget()
            let actionName = try self.requireAction()
            let observation = await self.resolveObservationContext()
            try await observation.validateIfExplicit(using: self.services.snapshots)
            let startTime = Date()
            self.resolvedRuntime.beginInteractionMutation()
            let result = try await AutomationServiceBridge.performAction(
                automation: self.services.automation,
                target: target,
                actionName: actionName,
                snapshotId: observation.snapshotId
            )
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "perform-action"
            )

            let outputPayload = ElementActionCommandResult(
                success: true,
                target: result.target,
                actionName: result.actionName,
                oldValue: result.oldValue,
                newValue: result.newValue,
                executionTime: Date().timeIntervalSince(startTime)
            )

            self.output(outputPayload) {
                print("✅ Performed \(result.actionName ?? actionName) on \(result.target)")
            }
        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private func requireTarget() throws -> String {
        guard let on = self.on?.trimmingCharacters(in: .whitespacesAndNewlines), !on.isEmpty else {
            throw ValidationError("--on is required")
        }
        return on
    }

    private func requireAction() throws -> String {
        guard let action = self.action?.trimmingCharacters(in: .whitespacesAndNewlines), !action.isEmpty else {
            throw ValidationError("--action is required")
        }
        return action
    }

    private func resolveObservationContext() async -> InteractionObservationContext {
        await InteractionObservationContext.resolve(
            explicitSnapshot: self.snapshot,
            fallbackToLatest: true,
            snapshots: self.services.snapshots
        )
    }
}

@MainActor
extension PerformActionCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: "perform-action",
            abstract: "Invoke a named accessibility action on an element",
            discussion: """
                Invokes an accessibility action without synthesizing a mouse or keyboard event.

                EXAMPLES:
                  peekaboo perform-action --on "$ELEMENT_ID" --action AXPress
                  peekaboo perform-action --on Stepper --action AXIncrement
            """,
            showHelpOnEmptyInvocation: true
        )
    }
}

extension PerformActionCommand: AsyncRuntimeCommand {}

@MainActor
extension PerformActionCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.on = values.singleOption("on")
        self.action = values.singleOption("action")
        self.snapshot = values.singleOption("snapshot")
    }
}

extension PerformActionCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            options: [
                .commandOption("on", help: "Element ID or query to act on", long: "on"),
                .commandOption(
                    "action",
                    help: "Accessibility action name, e.g. AXPress, AXShowMenu, AXIncrement",
                    long: "action"
                ),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
            ]
        )
    }
}
