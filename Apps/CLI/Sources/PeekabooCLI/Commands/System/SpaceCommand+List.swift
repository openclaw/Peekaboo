import Commander
import CoreGraphics
import PeekabooCore

// MARK: - List Spaces

@MainActor
struct ListSubcommand: ErrorHandlingCommand, OutputFormattable, InjectedRuntimeBackedCommand {
    @Flag(name: .long, help: "Include detailed window information")
    var detailed = false
    @RuntimeStorage var runtime: CommandRuntime?

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        do {
            try SpaceCommandHostOwnership.requireLocalRead(
                services: self.services,
                operation: "list Spaces"
            )
        } catch {
            self.handleError(error)
            throw ExitCode(1)
        }

        let spaceService = SpaceCommandEnvironment.service
        let spaces = await spaceService.getAllSpaces()
        AutomationEventLogger.log(
            .space,
            "list count=\(spaces.count) detailed=\(self.detailed ? 1 : 0)"
        )

        if self.jsonOutput {
            let data = SpaceListData(
                spaces: spaces.map { space in
                    SpaceData(
                        id: space.id,
                        type: space.type.rawValue,
                        is_active: space.isActive,
                        display_id: space.displayID
                    )
                }
            )
            outputSuccessCodable(data: data, logger: self.logger)
            return
        }

        print("Spaces:")
        var windowsBySpace: [UInt64: [(app: String, window: ServiceWindowInfo)]] = [:]

        if self.detailed {
            let appService = self.services.applications
            let appListResult = try await appService.listApplications()

            for app in appListResult.data.applications
                where app.isUsableForBroadAutomationDiscovery && app.windowCount > 0 {
                do {
                    let windowsResult = try await appService.listWindows(for: app.name, timeout: nil)
                    for window in windowsResult.data.windows {
                        let windowSpaces = await spaceService.getSpacesForWindow(windowID: CGWindowID(window.windowID))
                        for space in windowSpaces {
                            windowsBySpace[space.id, default: []].append((app: app.name, window: window))
                        }
                    }
                } catch {
                    continue
                }
            }
        }

        for (index, space) in spaces.indexed() {
            let marker = space.isActive ? "→" : " "
            let displayInfo = space.displayID.map { " (Display \($0))" } ?? ""
            print("\(marker) Space \(index + 1) [ID: \(space.id), Type: \(space.type.rawValue)\(displayInfo)]")

            if self.detailed {
                if let windows = windowsBySpace[space.id], !windows.isEmpty {
                    for (app, window) in windows {
                        let title = window.title.isEmpty ? "[Untitled]" : window.title
                        let minimized = window.isMinimized ? " [MINIMIZED]" : ""
                        print("    • \(app): \(title)\(minimized)")
                    }
                } else {
                    print("    (No windows)")
                }
            }
        }

        if spaces.isEmpty {
            print("No Spaces found (this may indicate an API issue)")
        }
    }
}

@MainActor
extension ListSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "list",
                abstract: "List all Spaces and their windows"
            )
        }
    }
}

extension ListSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ListSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.detailed = values.flag("detailed")
    }
}
