import Commander
import CoreGraphics
import PeekabooCore

// MARK: - Move Window to Space

@MainActor
struct MoveWindowSubcommand: ActionOutputFormattable, ApplicationResolvable, ErrorHandlingCommand,
    OutputFormattable,
    InjectedRuntimeBackedCommand {
    @Option(name: .long, help: "Target application name, bundle ID, or 'PID:12345'")
    var app: String?

    @Option(name: .long, help: "Target application by process ID")
    var pid: Int32?

    @Option(name: .long, help: "Target window by title (partial match supported)")
    var windowTitle: String?

    @Option(name: .long, help: "Target window by index (0-based, frontmost is 0)")
    var windowIndex: Int?

    @Option(name: .long, help: "Space number to move window to (1-based)")
    var to: Int?

    @Flag(name: .long, help: "Move window to current Space")
    var toCurrent = false

    @Flag(name: .long, help: "Switch to the target Space after moving")
    var follow = false
    @RuntimeStorage var runtime: CommandRuntime?

    mutating func validate() throws {
        _ = try self.resolveApplicationIdentifier()

        guard self.to != nil || self.toCurrent else {
            throw ValidationError("Must specify either --to or --to-current")
        }
        guard !(self.to != nil && self.toCurrent) else {
            throw ValidationError("Cannot specify both --to and --to-current")
        }
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            try self.validate()
            let appIdentifier = try self.resolveApplicationIdentifier()

            var windowOptions = WindowIdentificationOptions()
            windowOptions.app = appIdentifier
            windowOptions.windowTitle = self.windowTitle
            windowOptions.windowIndex = self.windowIndex

            let target = try windowOptions.toWindowTarget()
            let windows = try await self.services.windows.listWindows(target: target)
            guard let windowInfo = windowOptions.selectWindow(from: windows) else {
                throw NotFoundError.window(app: appIdentifier)
            }

            let windowID = CGWindowID(windowInfo.windowID)
            let spaceService = SpaceCommandEnvironment.service

            if self.toCurrent {
                self.resolvedRuntime.beginInteractionMutation()
                try await spaceService.moveWindowToCurrentSpace(windowID: windowID)
                AutomationEventLogger.log(
                    .space,
                    "move_window window_id=\(windowID) mode=current title=\"\(windowInfo.title)\""
                )
                if self.jsonOutput {
                    let data = WindowSpaceActionResult(
                        action: "move-window",
                        success: true,
                        window_id: windowID,
                        window_title: windowInfo.title,
                        space_id: nil,
                        space_number: nil,
                        moved_to_current: true,
                        followed: nil
                    )
                    outputSuccessCodable(data: data, effect: .unverifiable, logger: self.logger)
                } else {
                    print("✓ Moved window '\(windowInfo.title)' to current Space")
                }
                return
            }

            guard let spaceNum = self.to else {
                preconditionFailure("Expected either --to or --to-current validation")
            }

            let spaces = await spaceService.getAllSpaces()
            guard spaceNum > 0 && spaceNum <= spaces.count else {
                throw ValidationError("Invalid Space number. Available: 1-\(spaces.count)")
            }

            let targetSpace = spaces[spaceNum - 1]
            self.resolvedRuntime.beginInteractionMutation()
            try await spaceService.moveWindowToSpace(windowID: windowID, spaceID: targetSpace.id)
            if self.follow {
                try await spaceService.switchToSpace(targetSpace.id)
            }
            AutomationEventLogger.log(
                .space,
                "move_window window_id=\(windowID) space=\(spaceNum) follow=\(self.follow ? 1 : 0) "
                    + "title=\"\(windowInfo.title)\""
            )

            if self.jsonOutput {
                let data = WindowSpaceActionResult(
                    action: "move-window",
                    success: true,
                    window_id: windowID,
                    window_title: windowInfo.title,
                    space_id: targetSpace.id,
                    space_number: spaceNum,
                    moved_to_current: false,
                    followed: self.follow
                )
                outputSuccessCodable(data: data, effect: .unverifiable, logger: self.logger)
            } else {
                var message = "✓ Moved window '\(windowInfo.title)' to Space \(spaceNum)"
                if self.follow {
                    message += " (and switched to it)"
                }
                print(message)
            }
        } catch {
            handleError(error)
            throw ExitCode(1)
        }
    }
}

@MainActor
extension MoveWindowSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "move-window",
                abstract: "Move a window to a different Space"
            )
        }
    }
}

extension MoveWindowSubcommand: AsyncRuntimeCommand {}

@MainActor
extension MoveWindowSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = values.singleOption("app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        self.windowTitle = values.singleOption("windowTitle")
        self.windowIndex = try values.decodeOption("windowIndex", as: Int.self)
        self.to = try values.decodeOption("to", as: Int.self)
        self.toCurrent = values.flag("toCurrent")
        self.follow = values.flag("follow")
    }
}
