import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooCore

@available(macOS 14.0, *)
@MainActor
struct SetValueCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Argument(help: "Value to set")
    var value: String?

    @Option(help: "Element ID or query to set")
    var on: String?

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
            let value = try self.requireValue()
            let observation = await self.resolveObservationContext()
            try await observation.validateIfExplicit(using: self.services.snapshots)
            let startTime = Date()
            self.resolvedRuntime.beginInteractionMutation()
            let result = try await AutomationServiceBridge.setValue(
                automation: self.services.automation,
                target: target,
                value: .string(value),
                snapshotId: observation.snapshotId
            )
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "set-value"
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
                print("✅ Set value on \(result.target)")
                if let newValue = result.newValue {
                    print("📝 New value: \(newValue)")
                }
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

    private func requireValue() throws -> String {
        guard let value else {
            throw ValidationError("Value is required")
        }
        return value
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
extension SetValueCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: "set-value",
            abstract: "Set an accessibility element value directly",
            discussion: """
                Sets a settable accessibility value without synthesizing keystrokes.

                EXAMPLES:
                  peekaboo set-value "hello" --on "$ELEMENT_ID"
                  peekaboo set-value "42" --on "Search"
            """,
            showHelpOnEmptyInvocation: true
        )
    }
}

extension SetValueCommand: AsyncRuntimeCommand {}

@MainActor
extension SetValueCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.value = try values.decodeOptionalPositional(0, label: "value") ?? values.singleOption("value")
        self.on = values.singleOption("on")
        self.snapshot = values.singleOption("snapshot")
    }
}

extension SetValueCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature(
            arguments: [
                .make(label: "value", help: "Value to set", isOptional: true),
            ],
            options: [
                .commandOption("value", help: "Value to set (alternative to positional argument)", long: "value"),
                .commandOption("on", help: "Element ID or query to set", long: "on"),
                .commandOption(
                    "snapshot",
                    help: "Snapshot ID, or 'latest' (uses latest if not specified)",
                    long: "snapshot"
                ),
            ]
        )
    }
}

struct ElementActionCommandResult: Codable {
    let success: Bool
    let target: String
    let actionName: String?
    let oldValue: String?
    let newValue: String?
    let executionTime: TimeInterval
}
