import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Press individual keys or key sequences
@available(macOS 14.0, *)
@MainActor
struct PressCommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
    @Argument(help: "Key(s) to press")
    var keys: [String]

    @OptionGroup var target: InteractionTargetOptions

    @Option(help: "Repeat count for all keys")
    var count: Int = 1

    @Option(help: "Delay between key presses in milliseconds")
    var delay: Int = 100

    @Option(help: "Hold duration for each key in milliseconds")
    var hold: Int = 50

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
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

            try await ensureFocused(
                snapshotId: observation.focusSnapshotId(for: self.target),
                target: self.target,
                options: self.focusOptions,
                services: self.services
            )

            let normalizedKeys = self.keys.map { $0.lowercased() }
            var completedPresses = 0

            for repetition in 0..<self.count {
                for (index, key) in normalizedKeys.indexed() {
                    try await AutomationServiceBridge.hotkey(
                        automation: self.services.automation,
                        keys: key,
                        holdDuration: self.hold
                    )
                    completedPresses += 1

                    let isLastKey = index == normalizedKeys.count - 1
                    let isLastRepetition = repetition == self.count - 1
                    if self.delay > 0, !(isLastKey && isLastRepetition) {
                        try await Task.sleep(nanoseconds: UInt64(self.delay) * 1_000_000)
                    }
                }
            }

            await InteractionObservationInvalidator.invalidateAfterMutationOrLatest(
                observation,
                snapshots: self.services.snapshots,
                logger: self.logger,
                reason: "press"
            )

            // Output results
            let pressResult = PressResult(
                success: true,
                keys: keys,
                totalPresses: completedPresses,
                count: self.count,
                executionTime: Date().timeIntervalSince(startTime)
            )

            output(pressResult) {
                print("✅ Key press completed")
                print("🔑 Keys: \(self.keys.joined(separator: " → "))")
                if self.count > 1 {
                    print("🔢 Repeated: \(self.count) times")
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
        guard self.count >= 1 else {
            throw ValidationError("--count must be greater than 0")
        }
        guard self.delay >= 0 else {
            throw ValidationError("--delay must be greater than or equal to 0")
        }
        guard self.hold >= 0 else {
            throw ValidationError("--hold must be greater than or equal to 0")
        }
        for key in self.keys {
            guard SpecialKey(rawValue: key.lowercased()) != nil else {
                throw ValidationError("Unknown key: '\(key)'. Run 'peekaboo press --help' for available keys.")
            }
        }
    }
}

// MARK: - JSON Output Structure

struct PressResult: Codable {
    let success: Bool
    let keys: [String]
    let totalPresses: Int
    let count: Int
    let executionTime: TimeInterval
}

// MARK: - Conformances

@MainActor
extension PressCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "press",
                abstract: "Press individual keys or key sequences",
                discussion: """
                    The 'press' command sends individual key presses or sequences.
                    It's designed for special keys and navigation, not for typing text.

                    EXAMPLES:
                      peekaboo press return                # Press Enter/Return
                      peekaboo press tab --count 3         # Press Tab 3 times
                      peekaboo press escape                # Press Escape
                      peekaboo press delete                # Press Backspace/Delete
                      peekaboo press forward_delete        # Press Forward Delete (fn+delete)
                      peekaboo press up down left right    # Arrow key sequence
                      peekaboo press f1                    # Press F1 function key
                      peekaboo press space                 # Press spacebar
                      peekaboo press enter                 # Numeric keypad Enter

                    AVAILABLE KEYS:
                      Navigation: up, down, left, right, home, end, pageup, pagedown
                      Editing: delete (backspace), forward_delete, clear
                      Control: return, enter, tab, escape, space
                      Function: f1-f12
                      Special: caps_lock, help

                    KEY SEQUENCES:
                      Multiple keys can be pressed in sequence with optional delay:
                      peekaboo press tab tab return        # Tab twice then Enter
                      peekaboo press down down return      # Navigate down and select

                    TIMING:
                      Use --delay to control timing between key presses (default: 100ms)
                      Use --hold to control how long each key is held (default: 50ms)
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
        let resolvedKeys = if values.positional.isEmpty {
            values.singleOption("key").map { [$0] } ?? []
        } else {
            values.positional
        }
        guard !resolvedKeys.isEmpty else {
            throw CommanderBindingError.missingArgument(label: "keys")
        }
        self.keys = resolvedKeys
        self.target = try values.makeInteractionTargetOptions()
        if let count: Int = try values.decodeOption("count", as: Int.self) {
            self.count = count
        }
        if let delay: Int = try values.decodeOption("delay", as: Int.self) {
            self.delay = delay
        }
        if let hold: Int = try values.decodeOption("hold", as: Int.self) {
            self.hold = hold
        }
        self.snapshot = values.singleOption("snapshot")
        self.focusOptions = try values.makeFocusOptions()
    }
}
