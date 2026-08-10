import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooCore

@available(macOS 14.0, *)
@MainActor
struct SetValueCommand: ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
    @Argument(help: "Value to set")
    var value: String?

    @Option(help: "Element ID or query to set")
    var on: String?

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @OptionGroup var target: InteractionTargetOptions
    @OptionGroup var focusOptions: FocusCommandOptions

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        try await ElementActionCommandExecutor.execute(
            context: ElementActionCommandContext(
                runtime: runtime,
                snapshot: self.snapshot,
                invalidationReason: "set-value",
                target: self.target,
                focusOptions: self.focusOptions
            ),
            prepare: {
                try (self.requireTarget(), self.requireValue())
            },
            operation: { automation, target, value, snapshotId in
                try await AutomationServiceBridge.setValue(
                    automation: automation,
                    target: target,
                    value: .string(value),
                    snapshotId: snapshotId
                )
            },
            render: { result, outputPayload, _ in
                self.output(outputPayload) {
                    print("✅ Set value on \(result.target)")
                    if let newValue = result.newValue {
                        print("📝 New value: \(newValue)")
                    }
                }
            },
            handleError: { self.handleError($0) }
        )
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
        self.target = try values.makeInteractionTargetOptions()
        self.focusOptions = try values.makeFocusOptions()
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
            ],
            optionGroups: [
                InteractionTargetOptions.commanderSignature(),
                FocusCommandOptions.commanderSignature(),
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

struct ElementActionCommandContext {
    let runtime: CommandRuntime
    let snapshot: String?
    let invalidationReason: String
    let target: InteractionTargetOptions
    let focusOptions: FocusCommandOptions
}

@MainActor
enum ElementActionCommandExecutor {
    static func execute<Prepared>(
        context: ElementActionCommandContext,
        prepare: () throws -> (target: String, value: Prepared),
        operation: (
            _ automation: any UIAutomationServiceProtocol,
            _ target: String,
            _ value: Prepared,
            _ snapshotId: String?
        ) async throws -> ElementActionResult,
        render: (_ result: ElementActionResult, _ output: ElementActionCommandResult, _ value: Prepared) -> Void,
        handleError: (any Error) -> Void
    ) async throws {
        let runtime = context.runtime
        let services = runtime.services
        let logger = runtime.logger
        logger.setJsonOutputMode(runtime.configuration.jsonOutput)

        do {
            var target = context.target
            try target.validate()
            let prepared = try prepare()
            var observation = await InteractionObservationContext.resolve(
                explicitSnapshot: context.snapshot,
                fallbackToLatest: true,
                snapshots: services.snapshots
            )
            let refreshRuntime = runtime
            observation = try await InteractionObservationRefresher.refreshForTargetIfNeeded(
                observation,
                elementTarget: prepared.target,
                target: target,
                services: services,
                logger: logger,
                beforeRefresh: { startedAt in
                    refreshRuntime.beginInteractionMutation(at: startedAt)
                }
            )
            try await observation.validateIfExplicit(using: services.snapshots)
            let startTime = Date()
            runtime.beginInteractionMutation()
            if target.hasAnyTarget {
                try await ensureFocused(
                    snapshotId: observation.focusSnapshotId(for: target),
                    target: target,
                    options: context.focusOptions,
                    services: services
                )
            }
            let result = try await operation(
                services.automation,
                prepared.target,
                prepared.value,
                observation.snapshotId
            )
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: runtime.interactionMutationTargets,
                logger: logger,
                reason: context.invalidationReason
            )

            let output = ElementActionCommandResult(
                success: true,
                target: result.target,
                actionName: result.actionName,
                oldValue: result.oldValue,
                newValue: result.newValue,
                executionTime: Date().timeIntervalSince(startTime)
            )
            render(result, output, prepared.value)
        } catch {
            handleError(error)
            throw ExitCode.failure
        }
    }
}
