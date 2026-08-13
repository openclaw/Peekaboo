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
            try await observation.validateIfExplicit(using: self.services.snapshots)

            self.resolvedRuntime.beginInteractionMutation()
            try await ensureFocused(
                snapshotId: observation.focusSnapshotId(for: self.target),
                target: self.target,
                options: self.focusOptions,
                services: self.services
            )

            let parsedChords = try self.parsedChords()
            var completedPresses = 0
            var sequence = DesktopActionSequenceAccumulator()

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
                            holdDuration: self.hold.roundedMilliseconds
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
                            delivery: Self.foregroundHotkeyDelivery,
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
                            delivery: Self.foregroundHotkeyDelivery,
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
            deliveryMode: KeyboardDeliveryMode.foreground.rawValue,
            targetPID: nil,
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
            print("🎯 Mode: foreground")
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
        guard self.focusOptions.foreground else {
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
    private static let foregroundHotkeyDelivery = DesktopActionOutcome.Delivery(
        mechanism: .globalEvents,
        mode: .foreground
    )
}

struct PressResult: Codable {
    let keys: [String]
    let totalPresses: Int
    let count: Int
    let deliveryMode: String
    let targetPID: Int?
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

                    Raw chords cannot prove their semantic effect on a shared desktop and require
                    explicit --foreground consent. Use action, menu, window, app, or dialog for
                    certifiable background intent.

                    EXAMPLES:
                      peekaboo press cmd+c --app TextEdit --foreground
                      peekaboo press Return --app TextEdit --foreground
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
                      --foreground is required. App, PID, snapshot, and window selectors identify
                      what Peekaboo focuses before dispatch; they do not authorize raw background input.
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
