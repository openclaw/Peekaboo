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
        hint: RawPressPolicy.foregroundConsentRequiredHint
    )

    @Argument(help: "One or more chords. Chord syntax matches xdotool key (cmd+shift+t).")
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

            do {
                for repetition in 0..<self.count {
                    for (index, chord) in parsedChords.indexed() {
                        try Task.checkCancellation()
                        try await AutomationServiceBridge.hotkey(
                            automation: self.services.automation,
                            keys: chord.serviceKeys,
                            holdDuration: self.hold.roundedMilliseconds
                        )
                        completedPresses += 1
                        try Task.checkCancellation()

                        let isLastKey = index == parsedChords.count - 1
                        let isLastRepetition = repetition == self.count - 1
                        if self.delay.milliseconds > 0, !(isLastKey && isLastRepetition) {
                            try await Task.sleep(for: .seconds(self.delay.seconds))
                        }
                    }
                }
            } catch let error as InputDeliveryIndeterminateError {
                throw error
            } catch {
                guard completedPresses > 0 else { throw error }
                throw InputDeliveryIndeterminateError(
                    operation: .hotkey,
                    emittedUnitCount: completedPresses,
                    causeDescription: error.localizedDescription
                )
            }

            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "press"
            )

            // Output results
            let pressResult = PressResult(
                keys: parsedChords.map(\.displayValue),
                totalPresses: completedPresses,
                count: self.count,
                deliveryMode: KeyboardDeliveryMode.foreground.rawValue,
                targetPID: nil,
                executionTime: Date().timeIntervalSince(startTime)
            )

            output(pressResult, effect: .unverifiable) {
                print("✅ Key press dispatched")
                print("🔑 Chords: \(parsedChords.map(\.displayValue).joined(separator: " → "))")
                if self.count > 1 {
                    print("🔢 Repeated: \(self.count) times")
                }
                print("🎯 Mode: foreground")
                print("📊 Total presses: \(completedPresses)")
                print("⚠️  Effect: unverifiable; observe the target before continuing")
                print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
            }

        } catch {
            self.handleError(error)
            throw ExitCode.failure
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
