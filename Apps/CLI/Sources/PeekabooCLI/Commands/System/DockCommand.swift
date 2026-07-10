import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Interact with the macOS Dock
@MainActor
struct DockCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "dock",
                abstract: "Interact with the macOS Dock",
                discussion: """

                EXAMPLES:
                  # Launch an app from the Dock
                  peekaboo dock launch Safari

                  # Right-click a Dock item
                  peekaboo dock right-click --app Finder --select "New Window"

                  # Show/hide the Dock
                  peekaboo dock hide
                  peekaboo dock show

                  # List all Dock items
                  peekaboo dock list
                """,
                subcommands: [
                    LaunchSubcommand.self,
                    RightClickSubcommand.self,
                    HideSubcommand.self,
                    ShowSubcommand.self,
                    ListSubcommand.self,
                ],
                showHelpOnEmptyInvocation: true
            )
        }
    }
}

// MARK: - Subcommand Conformances

@MainActor
extension DockCommand.LaunchSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "launch", abstract: "Launch an application from the Dock")
        }
    }
}

extension DockCommand.LaunchSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DockCommand.LaunchSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = try values.decodePositional(0, label: "app")
        self.verify = values.flag("verify")
    }
}

@MainActor
extension DockCommand.RightClickSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "right-click",
                abstract: "Right-click a Dock item and optionally select from menu"
            )
        }
    }
}

extension DockCommand.RightClickSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DockCommand.RightClickSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = try values.requireOption("app", as: String.self)
        self.select = values.singleOption("select")
    }
}

@MainActor
extension DockCommand.HideSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "hide", abstract: "Hide the Dock")
        }
    }
}

extension DockCommand.HideSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DockCommand.HideSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@MainActor
extension DockCommand.ShowSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "show", abstract: "Show the Dock")
        }
    }
}

extension DockCommand.ShowSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DockCommand.ShowSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@MainActor
extension DockCommand.ListSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "list",
                abstract: "List all Dock items",
                discussion: """
                Enumerates Dock items, their bundle IDs, and running state.

                JSON emits legacy `dockItems` plus preferred `dock_items`.
                """
            )
        }
    }
}

extension DockCommand.ListSubcommand: AsyncRuntimeCommand {}

@MainActor
extension DockCommand.ListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.includeAll = values.flag("includeAll")
    }
}

// MARK: - Error Handling

func handleDockServiceError(_ error: DockError, jsonOutput: Bool, logger: Logger) {
    let errorCode: ErrorCode = switch error {
    case .dockNotFound:
        .DOCK_NOT_FOUND
    case .dockListNotFound:
        .DOCK_LIST_NOT_FOUND
    case .itemNotFound:
        .DOCK_ITEM_NOT_FOUND
    case .menuItemNotFound:
        .MENU_ITEM_NOT_FOUND
    case .positionNotFound:
        .POSITION_NOT_FOUND
    case .launchFailed:
        .INTERACTION_FAILED
    case .scriptError:
        .SCRIPT_ERROR
    }

    if jsonOutput {
        let response = JSONResponse(
            success: false,
            error: ErrorInfo(
                message: error.localizedDescription,
                code: errorCode
            )
        )
        outputJSON(response, logger: logger)
    } else {
        fputs("❌ \(error.localizedDescription)\n", stderr)
    }
}
