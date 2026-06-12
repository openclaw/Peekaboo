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
            RequestScreenRecordingSubcommand.self,
            RequestEventSynthesizingSubcommand.self,
        ],
        defaultSubcommand: StatusSubcommand.self
    )

    func run() async throws {
        // Root command doesn’t do anything; subcommands handle the work.
    }
}

extension PermissionsCommand {
    @MainActor
    struct StatusSubcommand: OutputFormattable, RuntimeOptionsConfigurable {
        @RuntimeStorage private var runtime: CommandRuntime?
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

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
            }
            return runtime
        }

        var outputLogger: Logger {
            self.resolvedRuntime.logger
        }

        var jsonOutput: Bool {
            self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            if self.allSources {
                let response = await PermissionHelpers.getAllPermissionSources(
                    services: runtime.services,
                    allowRemote: !self.noRemote,
                    socketPath: self.bridgeSocket
                )

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

            let response = await PermissionHelpers.getCurrentPermissionsWithSource(
                services: runtime.services,
                allowRemote: !self.noRemote,
                socketPath: self.bridgeSocket
            )

            if self.jsonOutput {
                outputSuccessCodable(data: response, logger: self.outputLogger)
            } else {
                let sourceLabel = response.source == "bridge" ? "Peekaboo Bridge" : "local runtime"
                print("Source: \(sourceLabel)")
                response.permissions.forEach { print(PermissionHelpers.formatPermissionStatus($0)) }
                if let hint = PermissionHelpers.bridgeScreenRecordingHint(for: response) {
                    print("")
                    print(hint)
                }
            }
        }
    }

    @MainActor
    struct GrantSubcommand: OutputFormattable, RuntimeOptionsConfigurable {
        @RuntimeStorage private var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
            }
            return runtime
        }

        var outputLogger: Logger {
            self.resolvedRuntime.logger
        }

        var jsonOutput: Bool {
            self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime

            let permissions = await PermissionHelpers.getCurrentPermissions(services: runtime.services)
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
    struct RequestScreenRecordingSubcommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
        struct Result: Codable {
            let action: String
            let granted: Bool
        }

        @RuntimeStorage private var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
            }
            return runtime
        }

        var outputLogger: Logger {
            self.resolvedRuntime.logger
        }

        var jsonOutput: Bool {
            self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let granted = runtime.services.permissions.requestScreenRecordingPermission(interactive: true)
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
    struct RequestEventSynthesizingSubcommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
        @RuntimeStorage private var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
            }
            return runtime
        }

        var outputLogger: Logger {
            self.resolvedRuntime.logger
        }

        var jsonOutput: Bool {
            self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            do {
                let result = try await PermissionHelpers.requestEventSynthesizingPermission(services: runtime.services)
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
extension PermissionsCommand.RequestScreenRecordingSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "request-screen-recording",
                abstract: "Request Screen Recording permission for the local Peekaboo process"
            )
        }
    }
}

extension PermissionsCommand.RequestScreenRecordingSubcommand: AsyncRuntimeCommand {}

@MainActor
extension PermissionsCommand.RequestScreenRecordingSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@MainActor
extension PermissionsCommand.RequestEventSynthesizingSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "request-event-synthesizing",
                abstract: "Request Event Synthesizing permission for background input"
            )
        }
    }
}

extension PermissionsCommand.RequestEventSynthesizingSubcommand: AsyncRuntimeCommand {}

@MainActor
extension PermissionsCommand.RequestEventSynthesizingSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}
