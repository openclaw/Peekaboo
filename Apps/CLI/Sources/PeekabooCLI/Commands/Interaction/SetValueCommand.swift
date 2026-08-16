import Commander
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation

@available(macOS 14.0, *)
@MainActor
struct SetValueCommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
RuntimeBackedCommand {
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
                deliveryMechanism: .accessibilityValue,
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
            render: { result, outcome, targetIdentity, outputPayload, _ in
                self.output(outputPayload, outcome: outcome, targetIdentity: targetIdentity) {
                    if let outcome {
                        print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Set value"))
                        print("🎯 Target: \(result.target)")
                    } else {
                        print("✅ Set value on \(result.target)")
                    }
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

extension SetValueCommand: PreRuntimeValidatingCommand {
    func validateBeforeRuntime() throws {
        _ = try ElementActionCommandExecutor.validateRequest(
            snapshot: self.snapshot,
            target: self.target,
            prepare: { try (self.requireTarget(), self.requireValue()) }
        )
    }
}

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
    let deliveryMechanism: DesktopActionOutcome.Delivery.Mechanism
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
        ) async throws -> UIAutomationActionResult<ElementActionResult>,
        render: (
            _ result: ElementActionResult,
            _ outcome: DesktopActionOutcome?,
            _ targetIdentity: DesktopTargetIdentity?,
            _ output: ElementActionCommandResult,
            _ value: Prepared
        ) -> Void,
        handleError: (any Error) -> Void
    ) async throws {
        let runtime = context.runtime
        let services = runtime.services
        let logger = runtime.logger
        logger.setJsonOutputMode(runtime.configuration.jsonOutput)
        let actionSequence = CommandActionSequenceAccumulator()
        let actionRoute = commandActionRoute(for: runtime.services)

        do {
            let target = context.target
            let prepared = try self.validateRequest(
                snapshot: context.snapshot,
                target: target,
                prepare: prepare
            )
            var observation = await InteractionObservationContext.resolve(
                explicitSnapshot: context.snapshot,
                fallbackToLatest: true,
                snapshots: services.snapshots
            )
            let refreshRuntime = runtime
            observation = try await InteractionObservationRefresher.refreshForTargetIfNeeded(
                observation,
                options: TargetedElementObservationRefreshOptions(
                    elementTarget: prepared.target,
                    allowWebFocusFallback: Self.shouldAllowWebFocusFallback(
                        focusOptions: context.focusOptions
                    )
                ),
                target: target,
                services: services,
                logger: logger,
                beforeRefresh: { startedAt in
                    refreshRuntime.beginInteractionMutation(at: startedAt)
                }
            )
            let actionSnapshotId = try await self.requireActionSnapshot(
                observation,
                snapshots: services.snapshots
            )
            let startTime = Date()
            runtime.beginInteractionMutation()
            if Self.shouldFocus(target: target, focusOptions: context.focusOptions) {
                let focusResult = try await ensureFocused(
                    snapshotId: observation.focusSnapshotId(for: target),
                    target: target,
                    options: context.focusOptions,
                    services: services
                )
                try actionSequence.record(
                    focusResult,
                    operation: "Element action setup focus",
                    receiptlessStep: .dispatched(
                        route: actionRoute,
                        delivery: .init(mechanism: .accessibilityAction, mode: .foreground),
                        unitCount: .one
                    )
                )
            }
            let actionResult = try await SnapshotMutationCoordinator.perform(
                snapshotId: actionSnapshotId,
                snapshots: services.snapshots,
                operation: {
                    try await operation(
                        services.automation,
                        prepared.target,
                        prepared.value,
                        actionSnapshotId
                    )
                },
                outcome: { $0.outcome }
            )
            try actionSequence.record(
                actionResult,
                operation: "Element action",
                receiptlessStep: .dispatched(
                    route: actionRoute,
                    delivery: .init(
                        mechanism: context.deliveryMechanism,
                        mode: .background
                    ),
                    unitCount: .one
                )
            )
            let compositeResult = actionSequence.result(payload: actionResult.payload)
            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: runtime.interactionMutationTargets,
                logger: logger,
                reason: context.invalidationReason
            )

            let output = ElementActionCommandResult(
                target: compositeResult.payload.target,
                actionName: compositeResult.payload.actionName,
                oldValue: compositeResult.payload.oldValue,
                newValue: compositeResult.payload.newValue,
                executionTime: Date().timeIntervalSince(startTime)
            )
            render(
                compositeResult.payload,
                compositeResult.outcome,
                compositeResult.targetIdentity,
                output,
                prepared.value
            )
        } catch {
            let preservedError = actionSequence.preservingFailure(
                error,
                fallbackRoute: actionRoute,
                message: "Element action failed after foreground focus may have changed desktop state.",
                hint: "Observe the exact target before deciding whether to retry the element action."
            )
            handleError(preservedError)
            throw ExitCode.failure
        }
    }

    static func validateRequest<Prepared>(
        snapshot: String?,
        target: InteractionTargetOptions,
        prepare: () throws -> (target: String, value: Prepared)
    ) throws -> (target: String, value: Prepared) {
        try target.validate()
        let prepared = try prepare()
        try InteractionObservationRefresher.validateSnapshotTargetCombination(
            snapshot: snapshot,
            target: target
        )
        return prepared
    }

    static func shouldFocus(
        target: InteractionTargetOptions,
        focusOptions: FocusCommandOptions
    ) -> Bool {
        target.hasAnyTarget && focusOptions.foreground && focusOptions.autoFocus
    }

    static func shouldAllowWebFocusFallback(focusOptions: FocusCommandOptions) -> Bool {
        focusOptions.foreground && focusOptions.autoFocus
    }

    private static func requireActionSnapshot(
        _ observation: InteractionObservationContext,
        snapshots: any SnapshotManagerProtocol
    ) async throws -> String {
        do {
            try await observation.validateIfExplicit(using: snapshots)
            return try observation.requireSnapshot()
        } catch let error as PeekabooError {
            let code: ErrorCode = switch error {
            case .snapshotNotFound, .snapshotNotAvailable:
                .SNAPSHOT_NOT_FOUND
            case .snapshotStale:
                .SNAPSHOT_STALE
            default:
                throw error
            }
            throw PreDispatchActionError(
                message: error.localizedDescription,
                code: code,
                hint: nil,
                reason: .targetUnavailable
            )
        }
    }
}
