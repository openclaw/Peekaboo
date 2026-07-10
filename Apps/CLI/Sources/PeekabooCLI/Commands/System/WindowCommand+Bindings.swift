import Commander
import Foundation
import PeekabooCore

struct WindowActionResult: Codable {
    let action: String
    let success: Bool
    let app_name: String
    let window_title: String?
    /// The frame the window actually has after the operation (read back from the OS).
    let new_bounds: WindowBounds?
    /// The frame the command asked for; differs from `new_bounds` when the app constrained it.
    let requested_bounds: WindowBounds?
    /// Set when the achieved geometry differs from the requested one or could not be verified.
    let warning: String?
}

// MARK: - Subcommand Conformances

@MainActor
extension WindowCommand.MoveSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "move", abstract: "Move a window to a new position")
        }
    }
}

extension WindowCommand.MoveSubcommand: AsyncRuntimeCommand {}

@MainActor
extension WindowCommand.ResizeSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "resize", abstract: "Resize a window")
        }
    }
}

extension WindowCommand.ResizeSubcommand: AsyncRuntimeCommand {}

@MainActor
extension WindowCommand.SetBoundsSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "set-bounds", abstract: "Set window position and size in one operation")
        }
    }
}

extension WindowCommand.SetBoundsSubcommand: AsyncRuntimeCommand {}

@MainActor
extension WindowCommand.WindowListSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "list",
                abstract: "List renderable windows for an application",
                discussion: """
                Lists windows suitable for interaction targeting. It uses the same window IDs
                and indexes as `peekaboo list windows`, but filters out non-renderable entries
                such as non-zero layer, tiny, transparent, or Windows-menu-excluded windows.

                Use `peekaboo list windows --app <app>` when you need the full enumeration.
                """
            )
        }
    }
}

extension WindowCommand.WindowListSubcommand: AsyncRuntimeCommand {}

@MainActor
extension WindowCommand.CloseSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "close", abstract: "Close a window")
        }
    }
}

extension WindowCommand.CloseSubcommand: AsyncRuntimeCommand {}

@MainActor
extension WindowCommand.MinimizeSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "minimize", abstract: "Minimize a window to the Dock")
        }
    }
}

extension WindowCommand.MinimizeSubcommand: AsyncRuntimeCommand {}

@MainActor
extension WindowCommand.MaximizeSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(commandName: "maximize", abstract: "Maximize a window (full screen)")
        }
    }
}

extension WindowCommand.MaximizeSubcommand: AsyncRuntimeCommand {}

@MainActor
extension WindowCommand.FocusSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "focus",
                abstract: "Bring a window to the foreground",
                discussion: """
                Focus brings a window to the foreground and activates its application.

                Space Support:
                Pass --space-switch to switch to a window on a different Space,
                or --bring-to-current-space to move it to the current Space.

                Examples:
                peekaboo window focus --app Safari
                peekaboo window focus --app "Visual Studio Code" --window-title "main.swift"
                peekaboo window focus --app Terminal --space-switch
                peekaboo window focus --app Finder --bring-to-current-space
                """
            )
        }
    }
}

extension WindowCommand.FocusSubcommand: AsyncRuntimeCommand {}

// MARK: - Commander Binding

@MainActor
extension WindowCommand.CloseSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.windowOptions = try values.makeWindowOptions()
    }
}

@MainActor
extension WindowCommand.MinimizeSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.windowOptions = try values.makeWindowOptions()
    }
}

@MainActor
extension WindowCommand.MaximizeSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.windowOptions = try values.makeWindowOptions()
    }
}

@MainActor
extension WindowCommand.FocusSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.windowOptions = try values.makeWindowOptions()
        self.focusOptions = try values.makeFocusOptions()
        self.snapshot = values.singleOption("snapshot")
        self.verify = values.flag("verify")
    }
}

@MainActor
extension WindowCommand.MoveSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.windowOptions = try values.makeWindowOptions()
        self.x = try values.requireOption("x", as: Int.self)
        self.y = try values.requireOption("y", as: Int.self)
    }
}

@MainActor
extension WindowCommand.ResizeSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.windowOptions = try values.makeWindowOptions()
        self.width = try values.requireOption("width", as: Int.self)
        self.height = try values.requireOption("height", as: Int.self)
    }
}

@MainActor
extension WindowCommand.SetBoundsSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.windowOptions = try values.makeWindowOptions()
        self.x = try values.requireOption("x", as: Int.self)
        self.y = try values.requireOption("y", as: Int.self)
        self.width = try values.requireOption("width", as: Int.self)
        self.height = try values.requireOption("height", as: Int.self)
    }
}

@MainActor
extension WindowCommand.WindowListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = values.singleOption("app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
    }
}
