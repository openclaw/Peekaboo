import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

/// Menu-specific errors
enum MenuError: Error {
    case menuBarNotFound
    case menuItemNotFound(String)
    case submenuNotFound(String)
    case menuExtraNotFound
    case menuItemDisabled(String)
    case menuOperationFailed(String)
}

extension MenuError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .menuBarNotFound:
            "Menu bar not found"
        case let .menuItemNotFound(path):
            "Menu item not found: \(path)"
        case let .submenuNotFound(path):
            "Submenu not found: \(path)"
        case .menuExtraNotFound:
            "Menu extra not found"
        case let .menuItemDisabled(path):
            "Menu item is disabled: \(path)"
        case let .menuOperationFailed(reason):
            "Menu operation failed: \(reason)"
        }
    }
}

/// Interact with application menu bar items and system menu extras
@MainActor
struct MenuCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "menu",
                abstract: "Interact with application menu bar",
                discussion: """
                Provides access to application menu bar items and system menu extras.

                EXAMPLES:
                  # Click a simple menu item
                  peekaboo menu click --app Safari --item "New Window"

                  # Navigate nested menus with path
                  peekaboo menu click --app TextEdit --path "Format > Font > Show Fonts"

                  # Click system menu extras (WiFi, Bluetooth, etc.)
                  peekaboo menu click-extra --title "WiFi"

                  # List all menu items for an app
                  peekaboo menu list --app Finder
                """,
                subcommands: [
                    ClickSubcommand.self,
                    ClickExtraSubcommand.self,
                    ListSubcommand.self,
                    ListAllSubcommand.self,
                ],
                showHelpOnEmptyInvocation: true
            )
        }
    }
}

// MARK: - Focus Helpers

@MainActor
struct FocusIgnoringMissingWindowsRequest {
    let windowID: CGWindowID?
    let applicationName: String
    let windowTitle: String?
}

@MainActor
func ensureFocusIgnoringMissingWindows(
    request: FocusIgnoringMissingWindowsRequest,
    options: any FocusOptionsProtocol,
    services: any PeekabooServiceProviding,
    logger: Logger
) async throws {
    do {
        try await ensureFocused(
            windowID: request.windowID,
            applicationName: request.applicationName,
            windowTitle: request.windowTitle,
            options: options,
            services: services
        )
    } catch let focusError as FocusError {
        switch focusError {
        case .noWindowsFound:
            logger.debug("Skipping focus: no windows found for '\(request.applicationName)'")
        case .windowNotFound, .axElementNotFound:
            logger.debug("Skipping focus: window lookup failed for '\(request.applicationName)': \(focusError)")
        default:
            throw focusError
        }
    }
}

// MARK: - Subcommand Conformances

@MainActor
extension MenuCommand.ClickSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "click",
                abstract: "Click a menu item"
            )
        }
    }
}

extension MenuCommand.ClickSubcommand: AsyncRuntimeCommand {}

@MainActor
extension MenuCommand.ClickSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.target = try values.makeInteractionTargetOptions()
        self.item = values.singleOption("item")
        self.path = values.singleOption("path")
        self.foreground = values.flag("foreground")
        self.focusOptions = try values.makeFocusOptions()
    }
}

@MainActor
extension MenuCommand.ClickExtraSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "click-extra",
                abstract: "Click a system menu extra (status bar item)"
            )
        }
    }
}

extension MenuCommand.ClickExtraSubcommand: AsyncRuntimeCommand {}

@MainActor
extension MenuCommand.ClickExtraSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.title = try values.requireOption("title", as: String.self)
        self.item = values.singleOption("item")
        self.verify = values.flag("verify")
    }
}

@MainActor
extension MenuCommand.ListSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "list",
                abstract: "List all menu items for an application"
            )
        }
    }
}

extension MenuCommand.ListSubcommand: AsyncRuntimeCommand {}

@MainActor
extension MenuCommand.ListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.target = try values.makeInteractionTargetOptions()
        self.includeDisabled = values.flag("includeDisabled")
        self.foreground = values.flag("foreground")
        self.focusOptions = try values.makeFocusOptions()
    }
}

@MainActor
extension MenuCommand.ListAllSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "list-all",
                abstract: "List all menu bar items system-wide (including status items)"
            )
        }
    }
}

extension MenuCommand.ListAllSubcommand: AsyncRuntimeCommand {}

@MainActor
extension MenuCommand.ListAllSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.includeDisabled = values.flag("includeDisabled")
        self.includeFrames = values.flag("includeFrames")
    }
}

// MARK: - Data Structures

struct MenuClickResult: Codable {
    let action: String
    let app: String
    let menu_path: String
    let clicked_item: String
}

struct MenuExtraClickResult: Codable {
    let action: String
    let menu_extra: String
    let clicked_item: String
    let location: [String: Double]?
    let verified: Bool?
}

/// Typed menu structures for JSON output
struct MenuListData: Codable {
    let app: String
    let owner_name: String?
    let bundle_id: String?
    let menu_structure: [MenuData]
}

struct MenuData: Codable {
    let title: String
    let bundle_id: String?
    let owner_name: String?
    let enabled: Bool
    let items: [MenuItemData]?
}

struct MenuItemData: Codable {
    let title: String
    let bundle_id: String?
    let owner_name: String?
    let enabled: Bool
    let shortcut: String?
    let checked: Bool?
    let separator: Bool?
    let items: [MenuItemData]?
}
