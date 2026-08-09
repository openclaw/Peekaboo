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

    @Option(help: "Snapshot ID, or 'latest'")
    var snapshot: String?

    @OptionGroup var focusOptions: FocusCommandOptions
    @Flag(help: "Focus target and send foreground/global key presses")
    var foreground = false

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

            let normalizedKeys = self.keys.map { $0.lowercased() }
            var completedPresses = 0

            for repetition in 0..<self.count {
                for (index, key) in normalizedKeys.indexed() {
                    if let targetPID {
                        guard let specialKey = SpecialKey(rawValue: key) else {
                            throw ValidationError(
                                "Unknown key: '\(key)'. Run 'peekaboo press --help' for available keys."
                            )
                        }
                        _ = try await AutomationServiceBridge.typeActions(
                            automation: self.services.automation,
                            request: TypeActionsRequest(
                                actions: [.key(specialKey)],
                                cadence: .fixed(milliseconds: 0),
                                snapshotId: observation.snapshotId
                            ),
                            targetProcessIdentifier: targetPID
                        )
                    } else {
                        try await AutomationServiceBridge.hotkey(
                            automation: self.services.automation,
                            keys: key,
                            holdDuration: self.hold
                        )
                    }
                    completedPresses += 1

                    let isLastKey = index == normalizedKeys.count - 1
                    let isLastRepetition = repetition == self.count - 1
                    if self.delay > 0, !(isLastKey && isLastRepetition) {
                        try await Task.sleep(nanoseconds: UInt64(self.delay) * 1_000_000)
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
                keys: keys,
                totalPresses: completedPresses,
                count: self.count,
                deliveryMode: targetPID == nil ? KeyboardDeliveryMode.foreground.rawValue :
                    KeyboardDeliveryMode.background.rawValue,
                targetPID: targetPID.map(Int.init),
                executionTime: Date().timeIntervalSince(startTime)
            )

            output(pressResult) {
                print("✅ Key press completed")
                print("🔑 Keys: \(self.keys.joined(separator: " → "))")
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
            foreground: self.foreground,
            focusOptions: self.focusOptions
        )
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

    private func backgroundProcessIdentifier(snapshotId: String?) async throws -> pid_t? {
        guard !self.foreground else {
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
                abstract: "Press individual keys or key sequences",
                discussion: """
                    The 'press' command sends individual key presses or sequences.
                    It's designed for special keys and navigation, not for typing text.

                    EXAMPLES:
                      peekaboo press return --foreground   # Press focused Enter/Return
                      peekaboo press return --app TextEdit # Background-target TextEdit
                      peekaboo press tab --count 3 --app Safari
                      peekaboo press escape --foreground
                      peekaboo press delete --app TextEdit
                      peekaboo press up down left right --app Safari

                    AVAILABLE KEYS:
                      Navigation: up, down, left, right, home, end, pageup, pagedown
                      Editing: delete (backspace), forward_delete, clear
                      Control: return, enter, tab, escape, space
                      Function: f1-f12
                      Special: caps_lock, help

                    KEY SEQUENCES:
                      Multiple keys can be pressed in sequence with optional delay:
                      peekaboo press tab tab return --app Safari
                      peekaboo press down down return --foreground

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
        self.foreground = values.flag("foreground")
        self.focusOptions = try values.makeFocusOptions()
    }
}
