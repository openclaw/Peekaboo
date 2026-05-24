import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Presses key combinations like Cmd+C, Ctrl+A, etc. using the UIAutomationService.
@available(macOS 14.0, *)
@MainActor
struct HotkeyCommand: ErrorHandlingCommand, OutputFormattable {
    @Argument(help: "Keys to press (comma-, plus-, or space-separated)")
    var keysArgument: String?

    @Option(name: .customLong("keys"), help: "Keys to press (comma-, plus-, or space-separated)")
    var keysOption: String?

    @OptionGroup var target: InteractionTargetOptions

    @Option(help: "Delay between key press and release in milliseconds")
    var holdDuration: Int = 50

    @Option(help: "Snapshot ID, or 'latest' (uses latest if not specified)")
    var snapshot: String?

    @Flag(name: .customLong("focus-background"), help: "Send the hotkey to the target process without focusing it")
    var focusBackground = false

    @OptionGroup var focusOptions: FocusCommandOptions
    @RuntimeStorage private var runtime: CommandRuntime?

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
        self.resolvedRuntime.configuration.jsonOutput
    }

    /// Keys after resolving positional/option input and trimming whitespace. Nil when missing/empty.
    var resolvedKeys: String? {
        let raw = self.keysArgument ?? self.keysOption
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.focusOptions.focusBackground = self.focusBackground || self.focusOptions.focusBackground
        let startTime = Date()
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            try self.target.validate()
            // Parse key names - support both comma-separated and space-separated
            guard let keysString = self.resolvedKeys else {
                throw ValidationError("No keys specified")
            }

            let keyNames = Self.parseKeyNames(keysString)

            guard !keyNames.isEmpty else {
                throw ValidationError("No keys specified")
            }

            // Convert key names to comma-separated format for the service
            let keysCsv = keyNames.joined(separator: ",")

            let observation = await InteractionObservationContext.resolve(
                explicitSnapshot: self.snapshot,
                fallbackToLatest: false,
                snapshots: self.services.snapshots
            )

            let deliveryMode: String
            let targetPID: pid_t?

            if self.focusOptions.focusBackground {
                try self.validateBackgroundHotkeyOptions(snapshotId: observation.snapshotId)
                let resolvedPID = try await self.resolveBackgroundHotkeyProcessIdentifier()
                try await AutomationServiceBridge.hotkey(
                    automation: self.services.automation,
                    keys: keysCsv,
                    holdDuration: self.holdDuration,
                    targetProcessIdentifier: resolvedPID
                )
                deliveryMode = "background"
                targetPID = resolvedPID
            } else {
                try await observation.validateIfExplicit(using: self.services.snapshots)

                try await ensureFocused(
                    snapshotId: observation.focusSnapshotId(for: self.target),
                    target: self.target,
                    options: self.focusOptions,
                    services: self.services
                )

                try await AutomationServiceBridge.hotkey(
                    automation: self.services.automation,
                    keys: keysCsv,
                    holdDuration: self.holdDuration
                )
                deliveryMode = "foreground"
                targetPID = nil
            }

            await InteractionObservationInvalidator.invalidateAfterMutationOrLatest(
                observation,
                snapshots: self.services.snapshots,
                logger: self.logger,
                reason: "hotkey"
            )

            // Output results
            let result = HotkeyResult(
                success: true,
                keys: keyNames,
                keyCount: keyNames.count,
                deliveryMode: deliveryMode,
                targetPID: targetPID.map(Int.init),
                executionTime: Date().timeIntervalSince(startTime)
            )

            output(result) {
                if self.focusOptions.focusBackground {
                    print("✅ Hotkey sent")
                } else {
                    print("✅ Hotkey pressed")
                }
                print("🎹 Keys: \(keyNames.joined(separator: " + "))")
                if let targetPID {
                    print("🎯 Mode: background to PID \(targetPID)")
                }
                print("⏱️  Completed in \(String(format: "%.2f", Date().timeIntervalSince(startTime)))s")
            }

        } catch {
            self.handleError(error)
            throw ExitCode.failure
        }
    }

    private func validateBackgroundHotkeyOptions(snapshotId: String?) throws {
        if snapshotId != nil {
            throw ValidationError("--focus-background cannot be combined with --snapshot")
        }

        if self.focusOptions.noAutoFocus ||
            self.focusOptions.focusTimeoutSeconds != nil ||
            self.focusOptions.focusRetryCount != nil ||
            self.focusOptions.spaceSwitch ||
            self.focusOptions.bringToCurrentSpace {
            throw ValidationError("--focus-background cannot be combined with focus options")
        }
    }

    private static func parseKeyNames(_ keysString: String) -> [String] {
        keysString
            .components(separatedBy: CharacterSet(charactersIn: ",+").union(.whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func resolveBackgroundHotkeyProcessIdentifier() async throws -> pid_t {
        if self.target.windowId != nil || self.target.windowTitle != nil || self.target.windowIndex != nil {
            throw ValidationError("--focus-background supports --app or --pid")
        }

        if self.target.app != nil, self.target.pid != nil {
            throw ValidationError("--focus-background accepts one target: use --app or --pid")
        }

        if let pid = self.target.pid {
            guard pid > 0 else {
                throw ValidationError("--pid must be greater than 0")
            }
            return pid_t(pid)
        }

        guard let appIdentifier = self.target.app?.trimmingCharacters(in: .whitespacesAndNewlines),
              !appIdentifier.isEmpty
        else {
            throw ValidationError("--focus-background requires --app or --pid")
        }

        let app = try await self.services.applications.findApplication(identifier: appIdentifier)
        return pid_t(app.processIdentifier)
    }

    // Error handling is provided by ErrorHandlingCommand protocol
}

// MARK: - JSON Output Structure

struct HotkeyResult: Codable {
    let success: Bool
    let keys: [String]
    let keyCount: Int
    let deliveryMode: String
    let targetPID: Int?
    let executionTime: TimeInterval
}

// MARK: - Conformances

@MainActor
extension HotkeyCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "hotkey",
                abstract: "Press keyboard shortcuts and key combinations",
                discussion: """
                    The 'hotkey' command simulates keyboard shortcuts by pressing
                    multiple keys simultaneously, like Cmd+C for copy or Cmd+Shift+T.

                    EXAMPLES:
                      peekaboo hotkey "cmd,c"               # Copy (comma-separated, positional)
                      peekaboo hotkey "cmd+c"               # Copy (plus-separated, positional)
                      peekaboo hotkey "cmd space"           # Spotlight (space-separated, positional)
                      peekaboo hotkey --keys "cmd,c"          # Copy (comma-separated)
                      peekaboo hotkey --keys "cmd+c"          # Copy (plus-separated)
                      peekaboo hotkey --keys "cmd c"          # Copy (space-separated)
                      peekaboo hotkey --keys "cmd,v"          # Paste
                      peekaboo hotkey --keys "cmd a"          # Select all
                      peekaboo hotkey --keys "cmd,shift,t"    # Reopen closed tab
                      peekaboo hotkey --keys "cmd space"      # Spotlight
                      peekaboo hotkey "cmd,l" --app Safari --focus-background

                    KEY NAMES:
                      Modifiers: cmd, shift, alt/option, ctrl, fn
                      Letters: a-z
                      Numbers: 0-9
                      Special: space, return, tab, escape, delete, arrow_up, arrow_down, arrow_left, arrow_right
                      Function: f1-f12

                    Background hotkeys accept one non-modifier key plus optional modifiers.
                    Use --focus-background with --app or --pid to target a process without focusing it.
                """,

                showHelpOnEmptyInvocation: true
            )
        }
    }
}

extension HotkeyCommand: AsyncRuntimeCommand {}

@MainActor
extension HotkeyCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.keysArgument = values.positional.first
        self.keysOption = values.singleOption("keys") ?? values.singleOption("keysOption")
        guard self.resolvedKeys != nil else {
            throw ValidationError("No keys specified. Provide keys like \"cmd,c\" or \"cmd c\".")
        }
        if let hold: Int = try values.decodeOption("holdDuration", as: Int.self) {
            self.holdDuration = hold
        }
        self.target = try values.makeInteractionTargetOptions()
        self.snapshot = values.singleOption("snapshot")
        self.focusOptions = try values.makeFocusOptions(includeBackgroundDelivery: true)
        self.focusBackground = self.focusOptions.focusBackground
    }
}
