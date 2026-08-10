import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Press keyboard chords or chord sequences.
@available(macOS 14.0, *)
@MainActor
struct PressCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Argument(help: "Chord(s) to press. Chord syntax matches xdotool key (cmd+shift+t).")
    var chords: [String]

    @OptionGroup var target: InteractionTargetOptions

    @Option(help: "Repeat count for all keys")
    var count: Int = 1

    @Option(help: "Delay between key presses (bare values are milliseconds)")
    var delay: CLIDuration = .milliseconds(100)

    @Option(help: "Hold duration for each key (bare values are milliseconds)")
    var hold: CLIDuration = .milliseconds(50)

    @Option(help: "Snapshot ID, or 'latest'")
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

            let targetPID = try await self.backgroundProcessIdentifier(snapshotId: observation.snapshotId)
            self.resolvedRuntime.beginInteractionMutation()
            if targetPID == nil {
                try await ensureFocused(
                    snapshotId: observation.focusSnapshotId(for: self.target),
                    target: self.target,
                    options: self.focusOptions,
                    services: self.services
                )
            }

            let parsedChords = try self.parsedChords()
            var completedPresses = 0

            for repetition in 0..<self.count {
                for (index, chord) in parsedChords.indexed() {
                    if let targetPID {
                        try await AutomationServiceBridge.hotkey(
                            automation: self.services.automation,
                            keys: chord.serviceKeys,
                            holdDuration: self.hold.roundedMilliseconds,
                            targetProcessIdentifier: targetPID
                        )
                    } else {
                        try await AutomationServiceBridge.hotkey(
                            automation: self.services.automation,
                            keys: chord.serviceKeys,
                            holdDuration: self.hold.roundedMilliseconds
                        )
                    }
                    completedPresses += 1

                    let isLastKey = index == parsedChords.count - 1
                    let isLastRepetition = repetition == self.count - 1
                    if self.delay.milliseconds > 0, !(isLastKey && isLastRepetition) {
                        try await Task.sleep(for: .seconds(self.delay.seconds))
                    }
                }
            }

            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
                logger: self.logger,
                reason: "press"
            )

            // Output results
            let pressResult = PressResult(
                success: true,
                keys: parsedChords.map(\.displayValue),
                totalPresses: completedPresses,
                count: self.count,
                deliveryMode: targetPID == nil ? KeyboardDeliveryMode.foreground.rawValue :
                    KeyboardDeliveryMode.background.rawValue,
                targetPID: targetPID.map(Int.init),
                executionTime: Date().timeIntervalSince(startTime)
            )

            output(pressResult) {
                print("✅ Key press completed")
                print("🔑 Chords: \(parsedChords.map(\.displayValue).joined(separator: " → "))")
                if self.count > 1 {
                    print("🔢 Repeated: \(self.count) times")
                }
                if let targetPID {
                    print("🎯 Mode: background to PID \(targetPID)")
                }
                print("📊 Total presses: \(completedPresses)")
                print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
            }

        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    // Error handling is provided by ErrorHandlingCommand protocol

    mutating func validate() throws {
        try self.target.validate()
        try KeyboardDeliverySupport.validateForegroundFlags(
            foreground: self.focusOptions.foreground,
            focusOptions: self.focusOptions
        )
        guard self.count >= 1 else {
            throw ValidationError("--count must be greater than 0")
        }
        _ = try self.parsedChords()
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

    private func backgroundProcessIdentifier(snapshotId: String?) async throws -> pid_t? {
        guard !self.focusOptions.foreground else {
            return nil
        }

        return try await KeyboardDeliverySupport.requireBackgroundProcessIdentifier(
            target: self.target,
            snapshotId: snapshotId,
            services: self.services
        )
    }
}

// MARK: - JSON Output Structure

struct PressResult: Codable {
    let success: Bool
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

                    EXAMPLES:
                      peekaboo press cmd+c --foreground
                      peekaboo press Return --app TextEdit
                      peekaboo press cmd+shift+4 --foreground
                      peekaboo press ctrl+a Delete --app TextEdit

                    MODIFIERS:
                      cmd/command, shift, option/alt, ctrl/control, fn

                    KEYS:
                      return, tab, escape, delete, arrows, f1-f12, letters, digits, space

                    SEQUENCES:
                      Separate chords with spaces: peekaboo press ctrl+a Delete

                    TIMING:
                      Use --delay to control timing between key presses (default: 100ms)
                      Use --hold to control how long each key is held (default: 50ms)

                    TARGETING:
                      Background input requires --app, --pid, or a snapshot with process metadata.
                      Use --foreground for intentional global input and for window selectors.
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
