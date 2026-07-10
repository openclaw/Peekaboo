import Commander
import Foundation
import PeekabooCore

/// List running applications, windows, or check system permissions.
@MainActor
struct ListCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "list",
        abstract: "List running applications, windows, or check permissions",
        discussion: """
        SYNOPSIS:
          peekaboo list SUBCOMMAND [OPTIONS]

        EXAMPLES:
          peekaboo list                                  # List all applications (default)
          peekaboo list apps                             # List all running applications
          peekaboo list apps --include-hidden            # Accepted for app-list parity
          peekaboo list apps --json                      # Output as JSON

          peekaboo list windows --app Safari             # List Safari windows
          peekaboo list windows --app "Visual Studio Code"
          peekaboo list windows --app Chrome --include-details bounds,ids

          peekaboo list menubar                          # List menu bar items
          peekaboo list menubar --json                   # Output as JSON

          peekaboo list permissions                      # Check permissions

          peekaboo list screens                          # List all displays
          peekaboo list screens --json                   # Output as JSON

        SUBCOMMANDS:
          apps          List all running applications with process IDs
          windows       List windows for a specific application
          permissions   Check permissions required for Peekaboo
          menubar       List all menu bar items (status icons)
          screens       List all available displays/monitors

        RELATED COMMANDS:
          peekaboo app list is the app-management view. It filters hidden/background apps
          unless --include-hidden/--include-background is passed. peekaboo list apps is
          the full inventory view and accepts those flags for parity.

          peekaboo window list is the renderable-window view used for window targeting.
          peekaboo list windows is the full per-application enumeration and may include
          utility, off-screen, tiny, or non-renderable entries.
        """,
        subcommands: [
            AppsSubcommand.self,
            WindowsSubcommand.self,
            PermissionsSubcommand.self,
            MenuBarSubcommand.self,
            ScreensSubcommand.self,
        ],
        defaultSubcommand: AppsSubcommand.self
    )

    func run() async throws {
        // Root command doesn’t do anything; subcommands handle the work.
    }
}

extension ListCommand {
    // MARK: - Permissions

    @MainActor

    struct PermissionsSubcommand: OutputFormattable, RuntimeOptionsConfigurable {
        @RuntimeStorage private var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
            }
            return runtime
        }

        private var logger: Logger {
            self.resolvedRuntime.logger
        }

        var outputLogger: Logger {
            self.logger
        }

        var jsonOutput: Bool {
            self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            let permissions = await PermissionHelpers.getCurrentPermissions(services: runtime.services)

            if self.jsonOutput {
                outputSuccessCodable(
                    data: PermissionsStatusPayload(permissions: permissions),
                    logger: self.outputLogger
                )
            } else {
                Swift.print("Peekaboo Permissions:")
                Swift.print("---------------------")
                for permission in permissions {
                    Swift.print("• \(PermissionHelpers.formatPermissionStatus(permission))")
                    if !permission.isGranted {
                        Swift.print("    Grant via: \(permission.grantInstructions)")
                    }
                }
            }
        }
    }

    private struct PermissionsStatusPayload: Codable {
        let permissions: [PermissionHelpers.PermissionInfo]
    }

    // MARK: - Menu Bar

    @MainActor

    struct MenuBarSubcommand: ErrorHandlingCommand, OutputFormattable, RuntimeOptionsConfigurable {
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
            self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                let items = try await MenuServiceBridge.listMenuBarItems(menu: self.services.menu)
                if self.jsonOutput {
                    MenuBarItemListOutput.outputJSON(items: items, logger: self.outputLogger)
                } else {
                    MenuBarItemListOutput.display(items)
                }
            } catch {
                self.handleError(error)
                throw ExitCode(1)
            }
        }
    }
}

// MARK: - Subcommand Conformances

@MainActor
extension ListCommand.PermissionsSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "permissions",
                abstract: "Check permissions required for Peekaboo"
            )
        }
    }
}

extension ListCommand.PermissionsSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ListCommand.MenuBarSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "menubar",
                abstract: "List all menu bar items (status icons)",
                discussion: """
                Lists status items from the right side of the macOS menu bar. This is the
                inventory counterpart to `peekaboo menubar list` and uses the same indexes.

                JSON emits legacy `items` plus preferred `menu_bar_items`.
                """
            )
        }
    }
}

extension ListCommand.MenuBarSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ListCommand.MenuBarSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@MainActor
extension ListCommand.ScreensSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "screens",
                abstract: "List all displays/monitors"
            )
        }
    }
}

extension ListCommand.ScreensSubcommand: AsyncRuntimeCommand {}
