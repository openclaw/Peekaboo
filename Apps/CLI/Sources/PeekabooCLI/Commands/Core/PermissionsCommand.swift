import Commander
import Foundation
import PeekabooCore

/// Check Peekaboo permissions.
@MainActor
struct PermissionsCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "permissions",
        abstract: "Check Peekaboo permissions",
        subcommands: [
            StatusSubcommand.self,
            GrantSubcommand.self,
            RequestSubcommand.self,
        ],
        defaultSubcommand: StatusSubcommand.self
    )

    func run() async throws {
        // Root command doesn’t do anything; subcommands handle the work.
    }
}

extension PermissionsCommand {
    @MainActor
    struct StatusSubcommand: OutputFormattable, RuntimeBackedCommand {
        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        @Flag(name: .customLong("no-remote"), help: "Skip remote hosts and query permissions locally")
        var noRemote = false

        @Flag(name: .customLong("all-sources"), help: "Show bridge and local permission status side by side")
        var allSources = false

        @Option(
            name: .customLong("bridge-socket"),
            help: "Override the Peekaboo Bridge socket path for permission checks"
        )
        var bridgeSocket: String?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            // CommanderCLIBinder applies --no-remote and --bridge-socket before it resolves
            // CommandRuntime. The injected services therefore already represent the exact
            // caller-selected host; resolving another host here would split ownership again.

            if self.allSources {
                let response = try await PermissionHelpers.getAllPermissionSources(services: runtime.services)

                if self.jsonOutput {
                    outputSuccessCodable(data: response, logger: self.outputLogger)
                } else {
                    for source in response.sources {
                        let marker = source.isSelected ? " (selected)" : ""
                        print("Source: \(source.displayName)\(marker)")
                        source.permissions.forEach { print(PermissionHelpers.formatPermissionStatus($0)) }
                        print("")
                    }
                }
                return
            }

            let response = try await PermissionHelpers.getCurrentPermissionsWithSource(services: runtime.services)

            if self.jsonOutput {
                outputSuccessCodable(data: response, logger: self.outputLogger)
            } else {
                let sourceLabel = response.source == "bridge" ? "Peekaboo Bridge" : "local runtime"
                print("Source: \(sourceLabel)")
                response.permissions.forEach { print(PermissionHelpers.formatPermissionStatus($0)) }
                if let hint = PermissionHelpers.bridgeDeniedPermissionsHint(for: response) {
                    print("")
                    print(hint)
                }
            }
        }
    }

    @MainActor
    struct GrantSubcommand: OutputFormattable, RuntimeBackedCommand {
        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            let permissions = try await PermissionHelpers.getCurrentPermissions(services: runtime.services)
            if self.jsonOutput {
                outputSuccessCodable(data: permissions, logger: self.outputLogger)
            } else {
                print("Grant the following permissions in System Settings:")
                for permission in permissions {
                    print("• \(permission.name): \(permission.grantInstructions)")
                }
            }
        }
    }

    @MainActor
    struct RequestSubcommand: RuntimeBackedCommand {
        @Argument(help: "Permission kind: accessibility, screen-recording, or event-synthesizing")
        var kind: String

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            switch self.kind {
            case "accessibility":
                var command = RequestAccessibilitySubcommand()
                command.runtimeOptions = self.runtimeOptions
                try await command.run(using: runtime)
            case "screen-recording":
                var command = RequestScreenRecordingSubcommand()
                command.runtimeOptions = self.runtimeOptions
                try await command.run(using: runtime)
            case "event-synthesizing":
                var command = RequestEventSynthesizingSubcommand()
                command.runtimeOptions = self.runtimeOptions
                try await command.run(using: runtime)
            default:
                throw ValidationError(
                    "Invalid permission kind '\(self.kind)'. "
                        + "Use accessibility, screen-recording, or event-synthesizing."
                )
            }
        }
    }

    @MainActor
    struct RequestScreenRecordingSubcommand: ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
        struct Result: Codable {
            let action: String
            let granted: Bool
        }

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let granted = await PermissionHelpers.performInteractivePermissionRequest(using: runtime) {
                runtime.services.permissions.requestScreenRecordingPermission(interactive: true)
            }
            let result = Result(action: "request-screen-recording", granted: granted)

            if self.jsonOutput {
                outputSuccessCodable(data: result, logger: self.outputLogger)
                return
            }

            if granted {
                print("Screen Recording permission is granted.")
            } else {
                print("Screen Recording permission was not granted.")
                print(
                    "If no prompt appeared, open System Settings > Privacy & Security > " +
                        "Screen & System Audio Recording."
                )
                print("Add or enable the current Peekaboo binary, then restart Peekaboo.")
            }
        }
    }

    @MainActor
    struct RequestAccessibilitySubcommand: OutputFormattable, RuntimeBackedCommand {
        private struct Result: Codable {
            let action: String
            let alreadyGranted: Bool
            let promptTriggered: Bool
            let granted: Bool

            private enum CodingKeys: String, CodingKey {
                case action
                case alreadyGranted = "already_granted"
                case promptTriggered = "prompt_triggered"
                case granted
            }
        }

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            let alreadyGranted = await AutomationServiceBridge
                .hasAccessibilityPermission(automation: runtime.services.automation)
            if alreadyGranted {
                self.render(Result(
                    action: "request-accessibility",
                    alreadyGranted: true,
                    promptTriggered: false,
                    granted: true
                ))
                return
            }

            let granted = await PermissionHelpers.performInteractivePermissionRequest(using: runtime) {
                runtime.services.permissions.requestAccessibilityPermission(interactive: true)
            }
            self.render(Result(
                action: "request-accessibility",
                alreadyGranted: false,
                promptTriggered: true,
                granted: granted
            ))
        }

        private func render(_ result: Result) {
            if self.jsonOutput {
                outputSuccessCodable(data: result, logger: self.outputLogger)
                return
            }

            if result.alreadyGranted {
                print("Accessibility permission is already granted.")
            } else if result.granted {
                print("Accessibility permission granted.")
            } else {
                print("Accessibility permission was not granted.")
                print("Grant it manually in System Settings > Privacy & Security > Accessibility.")
            }
        }
    }

    @MainActor
    struct RequestEventSynthesizingSubcommand: ErrorHandlingCommand, OutputFormattable, RuntimeBackedCommand {
        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            do {
                let result = try await PermissionHelpers.requestEventSynthesizingPermission(
                    services: runtime.services,
                    runtime: runtime
                )
                self.render(result)
            } catch {
                self.handleError(error)
                throw ExitCode.failure
            }
        }

        private func render(_ result: PermissionHelpers.EventSynthesizingPermissionRequestResult) {
            if self.jsonOutput {
                outputSuccessCodable(data: result, logger: self.outputLogger)
                return
            }

            guard !result.already_granted else {
                print("Event Synthesizing permission is already granted.")
                return
            }

            if result.granted == true {
                print("Event Synthesizing permission granted.")
            } else {
                print("Event Synthesizing permission was not granted.")
                print("Grant it manually in System Settings > Privacy & Security > Accessibility.")
            }
        }
    }
}

// MARK: - Subcommand Conformances

@MainActor
extension PermissionsCommand.StatusSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "status",
                abstract: "Show current permissions"
            )
        }
    }
}

extension PermissionsCommand.StatusSubcommand: AsyncRuntimeCommand {}

@MainActor
extension PermissionsCommand.StatusSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.noRemote = values.flag("no-remote")
        self.bridgeSocket = values.singleOption("bridge-socket")
        self.allSources = values.flag("all-sources")
    }
}

@MainActor
extension PermissionsCommand.GrantSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "grant",
                abstract: "Show grant instructions"
            )
        }
    }
}

extension PermissionsCommand.GrantSubcommand: AsyncRuntimeCommand {}

@MainActor
extension PermissionsCommand.GrantSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@MainActor
extension PermissionsCommand.RequestSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "request",
                abstract: "Request one local macOS permission"
            )
        }
    }
}

extension PermissionsCommand.RequestSubcommand: AsyncRuntimeCommand {}

@MainActor
extension PermissionsCommand.RequestSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.kind = try values.decodePositional(0, label: "kind")
        let allowed = Set(["accessibility", "screen-recording", "event-synthesizing"])
        guard allowed.contains(self.kind) else {
            throw CommanderBindingError.invalidArgument(
                label: "kind",
                value: self.kind,
                reason: "expected accessibility, screen-recording, or event-synthesizing"
            )
        }
    }
}
