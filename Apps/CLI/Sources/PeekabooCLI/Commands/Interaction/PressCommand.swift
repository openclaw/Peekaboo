import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Press keyboard chords or chord sequences.
@available(macOS 14.0, *)
@MainActor
struct PressCommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable, PreRuntimeValidatingCommand,
RuntimeOptionsConfigurable {
    private static let foregroundConsentRequired = PreDispatchActionError(
        message: RawPressPolicy.foregroundConsentRequiredMessage,
        code: .INTERACTION_FAILED,
        hint: RawPressPolicy.foregroundConsentRequiredHint,
        reason: .foregroundConsentRequired
    )

    @Argument(
        help: "One or more chords. Chord syntax matches xdotool key (cmd+shift+t).",
        parsing: .remaining
    )
    var chords: [String]

    @OptionGroup var target: InteractionTargetOptions

    @Option(help: "Repeat count for all keys")
    var count: Int = 1

    @Option(help: "Delay between key presses (bare values are milliseconds)")
    var delay: CLIDuration = .milliseconds(100)

    @Option(help: "Hold duration for each key (bare values are milliseconds)")
    var hold: CLIDuration = .milliseconds(50)

    @Option(help: "Snapshot ID (or explicit 'latest'); no snapshot is inferred when omitted")
    var snapshot: String?

    @OptionGroup var focusOptions: FocusCommandOptions
    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    private var resolvedRuntime: CommandRuntime {
        if let runtime {
            return runtime
        }
        // Parsing-only code paths in tests may access runtime-dependent helpers; default lazily.
        return CommandRuntime.makeDefault(options: self.runtimeOptions)
    }

    private var configuration: CommandRuntime.Configuration {
        if let runtime {
            return runtime.configuration
        }
        // Unit tests may parse without a runtime; fall back to parsed runtime options.
        return self.runtimeOptions.makeConfiguration()
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
        self.configuration.jsonOutput
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        let startTime = Date()
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            try self.validate()

            let observation = await InteractionObservationContext.resolve(
                explicitSnapshot: self.snapshot,
                fallbackToLatest: false,
                snapshots: self.services.snapshots
            )
            do {
                try await observation.validateIfExplicit(using: self.services.snapshots)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                throw self.preDispatchActionError(for: error, reason: .targetUnavailable)
            }

            self.resolvedRuntime.beginInteractionMutation()
            let parsedChords = try self.parsedChords()
            var completedPresses = 0
            var sequence = DesktopActionSequenceAccumulator()
            let deliveryPlan = try await self.resolveDeliveryPlan(observation: observation)
            if deliveryPlan.foregroundSetupMayHaveMutated {
                sequence.record(.mayHaveDispatched(route: nil, delivery: nil, unitCount: .one))
            }
            let deliveryTarget = deliveryPlan.target

            for repetition in 0..<self.count {
                for (index, chord) in parsedChords.indexed() {
                    do {
                        try Task.checkCancellation()
                    } catch {
                        guard let failure = sequence.cancellationFailure(
                            fallbackRoute: self.sequenceRoute,
                            message: Self.indeterminateSequenceMessage(completedPresses: completedPresses),
                            hint: Self.sequenceObservationHint,
                            causeDescription: error.localizedDescription
                        )
                        else { throw error }
                        await self.invalidateAfterFailedMutation(failure)
                        throw failure
                    }
                    let actionResult: UIAutomationActionResult<Void>
                    do {
                        actionResult = try await AutomationServiceBridge.hotkey(
                            automation: self.services.automation,
                            keys: chord.serviceKeys,
                            holdDuration: self.hold.roundedMilliseconds,
                            target: deliveryTarget
                        )
                        try DesktopActionFailure.requireConfirmedIfReported(
                            actionResult.outcome,
                            operation: "Raw chord \(chord.displayValue)"
                        )
                    } catch let failure as DesktopActionFailure {
                        let composed = sequence.failure(
                            combining: failure,
                            message: Self.sequenceFailureMessage(
                                completedPresses: completedPresses,
                                detail: failure.message
                            ),
                            hint: Self.sequenceObservationHint
                        )
                        await self.invalidateAfterFailedMutation(composed)
                        throw composed
                    } catch let error as InputDeliveryIndeterminateError {
                        let failure = error.desktopActionFailure(
                            delivery: Self.delivery(for: deliveryTarget),
                            route: self.sequenceRoute
                        )
                        let composed = sequence.failure(
                            combining: failure,
                            message: Self.indeterminateSequenceMessage(completedPresses: completedPresses),
                            hint: Self.sequenceObservationHint,
                            causeDescription: error.causeDescription ?? error.localizedDescription
                        )
                        await self.invalidateAfterFailedMutation(composed)
                        throw composed
                    } catch {
                        guard sequence.mutationDisposition.mutationDispatched else { throw error }
                        let leaf = DesktopActionFailure.preDispatchRefusal(
                            route: self.sequenceRoute,
                            reason: .operationUnsupported,
                            message: error.localizedDescription
                        )
                        let composed = sequence.failure(
                            combining: leaf,
                            message: Self.indeterminateSequenceMessage(completedPresses: completedPresses),
                            hint: Self.sequenceObservationHint,
                            causeDescription: error.localizedDescription
                        )
                        await self.invalidateAfterFailedMutation(composed)
                        throw composed
                    }
                    if let outcome = actionResult.outcome {
                        sequence.record(.reportedOutcome(
                            outcome,
                            defaultDispatchedUnitCount: .one
                        ))
                    } else {
                        sequence.record(.dispatched(
                            route: self.sequenceRoute,
                            delivery: Self.delivery(for: deliveryTarget),
                            unitCount: .one
                        ))
                    }
                    completedPresses += 1

                    do {
                        let isLastKey = index == parsedChords.count - 1
                        let isLastRepetition = repetition == self.count - 1
                        let isLastDispatch = isLastKey && isLastRepetition
                        if !isLastDispatch {
                            try Task.checkCancellation()
                        }
                        if self.delay.milliseconds > 0, !isLastDispatch {
                            try await Task.sleep(for: .seconds(self.delay.seconds))
                        }
                    } catch {
                        guard let failure = sequence.cancellationFailure(
                            fallbackRoute: self.sequenceRoute,
                            message: Self.indeterminateSequenceMessage(completedPresses: completedPresses),
                            hint: Self.sequenceObservationHint,
                            causeDescription: error.localizedDescription
                        )
                        else { throw error }
                        await self.invalidateAfterFailedMutation(failure)
                        throw failure
                    }
                }
            }

            await self.finishSuccess(
                parsedChords: parsedChords,
                completedPresses: completedPresses,
                sequence: sequence,
                deliveryTarget: deliveryTarget,
                startTime: startTime
            )

        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private func finishSuccess(
        parsedChords: [KeyboardChord],
        completedPresses: Int,
        sequence: DesktopActionSequenceAccumulator,
        deliveryTarget: UIAutomationTarget,
        startTime: Date
    ) async {
        await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: self.resolvedRuntime.interactionMutationTargets,
            logger: self.logger,
            reason: "press"
        )
        let pressResult = PressResult(
            keys: parsedChords.map(\.displayValue),
            totalPresses: completedPresses,
            count: self.count,
            deliveryMode: deliveryTarget.processIdentifier == nil
                ? KeyboardDeliveryMode.foreground.rawValue
                : KeyboardDeliveryMode.background.rawValue,
            targetPID: deliveryTarget.processIdentifier.map(Int.init),
            targetWindowID: deliveryTarget.exactWindow?.identity.windowID,
            executionTime: Date().timeIntervalSince(startTime)
        )
        let actionOutcome = sequence.successResolution().outcome
        self.output(pressResult, effect: .unverifiable, outcome: actionOutcome) {
            if let actionOutcome {
                print(ActionOutcomeHumanRenderer.statusLine(for: actionOutcome, operation: "Key press"))
            } else {
                print("✅ Key press dispatched")
            }
            print("🔑 Chords: \(parsedChords.map(\.displayValue).joined(separator: " → "))")
            if self.count > 1 {
                print("🔢 Repeated: \(self.count) times")
            }
            if let targetPID = deliveryTarget.processIdentifier {
                print("🎯 Mode: background to PID \(targetPID)")
            } else {
                print("🎯 Mode: foreground")
            }
            if let targetWindowID = deliveryTarget.exactWindow?.identity.windowID {
                print("🪟 Window: \(targetWindowID)")
            }
            print("📊 Total presses: \(completedPresses)")
            if actionOutcome == nil {
                print("⚠️  Effect: unverifiable; observe the target before continuing")
            }
            print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
        }
    }

    // Error handling is provided by ErrorHandlingCommand protocol

    mutating func validate() throws {
        try self.validateBeforeRuntime()
    }

    func validateBeforeRuntime() throws {
        try self.target.validate()
        try KeyboardDeliverySupport.validateForegroundFlags(
            foreground: self.focusOptions.foreground,
            focusOptions: self.focusOptions
        )
        guard self.count >= 1 else {
            throw ValidationError("--count must be greater than 0")
        }
        _ = try self.parsedChords()
        let hasExactSelector = self.target.windowId != nil || self.target.windowTitle != nil ||
            self.target
            .windowIndex != nil || !(self.snapshot?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ??
                true)
        guard self.focusOptions.foreground || hasExactSelector else {
            throw Self.foregroundConsentRequired
        }
    }

    func parsedChords() throws -> [KeyboardChord] {
        try self.chords.map { value in
            do {
                return try KeyboardChord(parsing: value)
            } catch {
                throw ValidationError(error.localizedDescription)
            }
        }
    }

    private func resolveDeliveryPlan(
        observation: InteractionObservationContext
    ) async throws -> PressDeliveryPlan {
        if self.focusOptions.foreground {
            try await ensureFocused(
                snapshotId: observation.focusSnapshotId(for: self.target),
                target: self.target,
                options: self.focusOptions,
                services: self.services
            )
            return PressDeliveryPlan(
                target: .foreground,
                foregroundSetupMayHaveMutated: self.target.hasAnyTarget ||
                    observation.focusSnapshotId(for: self.target) != nil
            )
        }

        let target: UIAutomationTarget
        do {
            target = try await KeyboardDeliverySupport.requireBackgroundKeyboardTarget(
                target: self.target,
                snapshotId: observation.snapshotId,
                services: self.services,
                requiresExplicitExactWindow: true
            )
        } catch {
            throw self.preDispatchActionError(for: error, reason: .targetUnavailable)
        }
        guard target.exactWindow != nil else {
            throw self.preDispatchActionError(
                for: PeekabooError.invalidInput(
                    field: "target",
                    reason: "Background raw key presses require one exact-window receipt"
                )
            )
        }
        do {
            _ = try ExactWindowKeyboardRuntime.requireOutcomeProvider(
                automation: self.services.automation,
                operation: "Background hotkeys"
            )
        } catch {
            throw PreDispatchActionError(
                message: error.localizedDescription,
                code: .INTERACTION_FAILED,
                hint: "Update the Peekaboo host and retry with a fresh exact-window target.",
                reason: .runtimeIncompatible
            )
        }
        guard self.services.automation is any TargetedFocusedElementServiceProtocol else {
            throw PreDispatchActionError(
                message: "This automation host does not support focused exact-window background hotkeys.",
                code: .INTERACTION_FAILED,
                hint: "Update the Peekaboo host and retry with a fresh exact-window target.",
                reason: .runtimeIncompatible
            )
        }
        do {
            let pinnedTarget = try await target.pinningCurrentFocusedElement(using: self.services.automation)
            return PressDeliveryPlan(target: pinnedTarget, foregroundSetupMayHaveMutated: false)
        } catch {
            throw self.preDispatchActionError(for: error, reason: .targetUnavailable)
        }
    }

    private static func sequenceFailureMessage(completedPresses: Int, detail: String) -> String {
        "Key sequence stopped after \(completedPresses) completed press" +
            (completedPresses == 1 ? "" : "es") + ": \(detail)"
    }

    private static func indeterminateSequenceMessage(completedPresses: Int) -> String {
        "Key sequence outcome is indeterminate after \(completedPresses) completed press" +
            (completedPresses == 1 ? "" : "es")
    }

    private var sequenceRoute: DesktopActionOutcome.Route {
        self.services.automation is RemoteUIAutomationService ? .bridge : .local
    }

    private func invalidateAfterFailedMutation(_ failure: DesktopActionFailure) async {
        guard failure.outcome.dispatchState.mutationDispatched else { return }
        await InteractionObservationInvalidator.invalidateAfterMutation(
            targets: self.resolvedRuntime.interactionMutationTargets,
            logger: self.logger,
            reason: "press failure"
        )
    }

    private static let sequenceObservationHint = "Observe the target before retrying this key sequence."

    private static func delivery(for target: UIAutomationTarget) -> DesktopActionOutcome.Delivery {
        target.exactWindow == nil
            ? .init(mechanism: .globalEvents, mode: .foreground)
            : .init(mechanism: .windowTargetedEvents, mode: .background)
    }
}

private struct PressDeliveryPlan {
    let target: UIAutomationTarget
    let foregroundSetupMayHaveMutated: Bool
}

struct PressResult: Codable {
    let keys: [String]
    let totalPresses: Int
    let count: Int
    let deliveryMode: String
    let targetPID: Int?
    let targetWindowID: Int?
    let executionTime: TimeInterval
}

// MARK: - Conformances

@MainActor
extension PressCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "press",
                abstract: "Press keyboard chords or chord sequences",
                discussion: """
                    The 'press' command sends keyboard chords in sequence.
                    Chord syntax matches xdotool key (cmd+shift+t).

                    Raw chords require either explicit --foreground consent or a fresh exact-window
                    receipt whose focused element remains pinned through native background dispatch.
                    App/PID-only and targetless background press are refused.

                    EXAMPLES:
                      peekaboo press cmd+c --app TextEdit --foreground
                      peekaboo press Return --app TextEdit --window-id 1234
                      peekaboo press cmd+shift+4 --foreground
                      peekaboo press ctrl+a Delete --app TextEdit --foreground

                    MODIFIERS:
                      cmd/command, shift, option/alt, ctrl/control, fn

                    KEYS:
                      return, tab, escape, delete, arrows, f1-f12, letters, digits, space

                    SEQUENCES:
                      Separate chords with spaces: peekaboo press ctrl+a Delete --foreground

                    TIMING:
                      Use --delay to control timing between key presses (default: 100ms)
                      Use --hold to control how long each key is held (default: 50ms)

                    TARGETING:
                      Exact window selectors or a fresh exact-window snapshot authorize receipt-pinned
                      background dispatch. App/PID-only targets require --foreground.
                """,

                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension PressCommand: AsyncRuntimeCommand {}

@MainActor
extension PressCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        if !values.positional.isEmpty, values.singleOption("key") != nil {
            throw ValidationError("Provide chords either positionally or with --key, not both")
        }
        let resolvedChords = if values.positional.isEmpty {
            values.singleOption("key").map { [$0] } ?? []
        } else {
            values.positional
        }
        guard !resolvedChords.isEmpty else {
            throw CommanderBindingError.missingArgument(label: "chords")
        }
        self.chords = resolvedChords
        self.target = try values.makeInteractionTargetOptions()
        if let count: Int = try values.decodeOption("count", as: Int.self) {
            self.count = count
        }
        if let delay: CLIDuration = try values.decodeOption("delay", as: CLIDuration.self) {
            self.delay = delay
        }
        if let hold: CLIDuration = try values.decodeOption("hold", as: CLIDuration.self) {
            self.hold = hold
        }
        self.snapshot = values.singleOption("snapshot")
        self.focusOptions = try values.makeFocusOptions(includeBackgroundDelivery: true)
    }
}
