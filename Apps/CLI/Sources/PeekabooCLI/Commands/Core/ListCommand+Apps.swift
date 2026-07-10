import Commander
import PeekabooCore

extension ListCommand {
    @MainActor
    struct AppsSubcommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
        @Flag(help: "Accepted for parity with 'app list'; 'list apps' already includes hidden apps")
        var includeHidden = false

        @Flag(help: "Accepted for parity with 'app list'; 'list apps' already includes background apps")
        var includeBackground = false

        @RuntimeStorage private var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

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
            // Tests read jsonOutput on parsed values before the runtime is injected.
            self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                let output = try await services.applications.listApplications()

                if self.jsonOutput {
                    outputSuccessCodable(
                        data: ApplicationInventoryPayload(from: output.data),
                        logger: self.outputLogger
                    )
                } else {
                    print(CLIFormatter.format(output))
                }
            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    private struct ApplicationInventoryPayload: Codable {
        let applications: [ServiceApplicationInfo]
        let apps: [ServiceApplicationInfo]

        init(from data: ServiceApplicationListData) {
            self.applications = data.applications
            self.apps = data.applications
        }
    }
}

@MainActor
extension ListCommand.AppsSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "apps",
                abstract: "List running applications with details",
                discussion: """
                Lists running applications exposed by ApplicationService from PeekabooCore.
                Applications are sorted by name and include process IDs, bundle identifiers,
                and activation status.

                This is the broader inventory form. `peekaboo app list` is the app-management
                view and filters hidden/background apps by default; `list apps` accepts
                --include-hidden and --include-background for parity, but already includes
                those applications when ApplicationService exposes them.

                JSON emits both the legacy `applications` key and the preferred `apps` alias.
                """
            )
        }
    }
}

extension ListCommand.AppsSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ListCommand.AppsSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.includeHidden = values.flag("includeHidden")
        self.includeBackground = values.flag("includeBackground")
    }
}
