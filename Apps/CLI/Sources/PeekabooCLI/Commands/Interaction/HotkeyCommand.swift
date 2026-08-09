import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Presses key combinations like Cmd+C, Ctrl+A, etc. using the UIAutomationService.
@available(macOS 14.0, *)
@MainActor
struct HotkeyCommand: ErrorHandlingCommand, OutputFormattable, InjectedRuntimeBackedCommand {
    @Argument(help: "Keys to press (comma-, plus-, or space-separated)")
    var keysArgument: String?

    @Option(name: .customLong("keys"), help: "Keys to press (comma-, plus-, or space-separated)")
    var keysOption: String?

    @OptionGroup var target: InteractionTargetOptions

    @Option(help: "Delay between key press and release in milliseconds")
    var holdDuration: Int = 50

    @Option(help: "Snapshot ID, or 'latest'")
    var snapshot: String?

    @Flag(name: .customLong("focus-background"), help: "Send the hotkey to the target process without focusing it")
    var focusBackground = false

    @Flag(help: "Focus target and send a foreground/global hotkey")
    var foreground = false

    @OptionGroup var focusOptions: FocusCommandOptions
    @RuntimeStorage var runtime: CommandRuntime?

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
            try KeyboardDeliverySupport.validateForegroundFlags(
                foreground: self.foreground,
                focusOptions: self.focusOptions
            )
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
            try await observation.validateIfExplicit(using: self.services.snapshots)

            let deliveryMode: String
            let targetPID: pid_t?

            let backgroundPID = try await self.backgroundProcessIdentifier(snapshotId: observation.snapshotId)
            self.resolvedRuntime.beginInteractionMutation()

            if let backgroundPID {
                try await AutomationServiceBridge.hotkey(
                    automation: self.services.automation,
                    keys: keysCsv,
                    holdDuration: self.holdDuration,
                    targetProcessIdentifier: backgroundPID
                )
                deliveryMode = "background"
                targetPID = backgroundPID
            } else {
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

            await InteractionObservationInvalidator.invalidateAfterMutation(
                targets: self.resolvedRuntime.interactionMutationTargets,
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
                if targetPID != nil {
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

    private static func parseKeyNames(_ keysString: String) -> [String] {
        keysString
            .components(separatedBy: CharacterSet(charactersIn: ",+").union(.whitespacesAndNewlines))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private func backgroundProcessIdentifier(snapshotId: String?) async throws -> pid_t? {
        guard !self.foreground else {
            return nil
        }

        if self.target.app != nil, self.target.pid != nil {
            throw ValidationError("Background hotkey accepts one process target: use --app or --pid")
        }

        return try await KeyboardDeliverySupport.requireBackgroundProcessIdentifier(
            target: self.target,
            snapshotId: snapshotId,
            services: self.services
        )
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
                      peekaboo hotkey "cmd,c" --foreground  # Copy current selection
                      peekaboo hotkey "cmd+c" --app TextEdit # Background app shortcut
                      peekaboo hotkey "cmd space" --foreground # Spotlight (intentional global shortcut)
                      peekaboo hotkey --keys "cmd,c" --foreground
                      peekaboo hotkey --keys "cmd,v" --app TextEdit
                      peekaboo hotkey --keys "cmd,shift,t" --app Safari
                      peekaboo hotkey "cmd,l" --app Safari
                      peekaboo hotkey "cmd,l" --app Safari --foreground

                    KEY NAMES:
                      Modifiers: cmd, shift, alt/option, ctrl, fn
                      Letters: a-z
                      Numbers: 0-9
                      Special: space, return, tab, escape, delete, arrow_up, arrow_down, arrow_left, arrow_right
                      Function: f1-f12

                    Background hotkeys require --app, --pid, or a snapshot with process metadata.
                    Use --foreground for intentional OS-global shortcuts and window targeting.
                    Background Cmd+W/Q/H/M fail closed because event delivery cannot verify lifecycle changes;
                    use the semantic window/app commands or add --foreground explicitly.
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
        self.foreground = values.flag("foreground")
        self.focusOptions = try values.makeFocusOptions(includeBackgroundDelivery: true)
        self.focusBackground = self.focusOptions.focusBackground
    }
}
