import Commander
import CoreGraphics
import Foundation
import PeekabooCore

extension ListCommand {
    @MainActor
    struct WindowsSubcommand: ErrorHandlingCommand, OutputFormattable, ApplicationResolvable,
    RuntimeOptionsConfigurable {
        @Option(name: .long, help: "Target application name, bundle ID, or 'PID:12345'")
        var app: String?

        @Option(name: .long, help: "Target application by process ID")
        var pid: Int32?

        @Option(name: .long, help: "Additional details (comma-separated: off_screen,bounds,ids)")
        var includeDetails: String?
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
            // PIDWindowsSubcommandTests read jsonOutput immediately after parsing.
            self.runtime?.configuration.jsonOutput ?? self.runtimeOptions.jsonOutput
        }

        enum WindowDetailOption: String, ExpressibleFromArgument {
            case ids
            case bounds
            case off_screen

            init?(argument: String) {
                self.init(rawValue: argument.lowercased())
            }
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try await requireScreenRecordingPermission(services: self.services)
                let appIdentifier = try self.resolveApplicationIdentifier()
                let output = try await self.services.applications.listWindows(for: appIdentifier, timeout: nil)

                if self.jsonOutput {
                    let detailOptions = self.parseIncludeDetails()
                    self.renderJSON(from: output, detailOptions: detailOptions)
                } else {
                    print(CLIFormatter.format(output))
                }
            } catch {
                self.handleError(error)
                throw ExitCode(1)
            }
        }

        private func parseIncludeDetails() -> Set<WindowDetailOption> {
            guard let detailsString = includeDetails else { return [] }
            let normalizedTokens = detailsString
                .split(separator: ",")
                .map { token -> String in
                    token
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "-", with: "_")
                        .lowercased()
                }

            let options = normalizedTokens.compactMap { token -> WindowDetailOption? in
                switch token {
                case "offscreen", "off_screen":
                    return .off_screen
                case "bounds":
                    return .bounds
                case "ids":
                    return .ids
                default:
                    return nil
                }
            }

            return Set(options)
        }

        @MainActor
        private func renderJSON(
            from output: UnifiedToolOutput<ServiceWindowListData>,
            detailOptions: Set<WindowDetailOption>
        ) {
            guard !detailOptions.isEmpty else {
                outputSuccessCodable(data: output.data, logger: self.outputLogger)
                return
            }

            struct FilteredWindowListData: Codable {
                struct Window: Codable {
                    let index: Int
                    let title: String
                    let isMinimized: Bool
                    let isMainWindow: Bool
                    let windowID: Int?
                    let bounds: CGRect?
                    let offScreen: Bool?
                    let spaceID: UInt64?
                    let spaceName: String?
                }

                let windows: [Window]
                let targetApplication: ServiceApplicationInfo?
            }

            let windows = output.data.windows.map { window in
                FilteredWindowListData.Window(
                    index: window.index,
                    title: window.title,
                    isMinimized: window.isMinimized,
                    isMainWindow: window.isMainWindow,
                    windowID: detailOptions.contains(.ids) ? window.windowID : nil,
                    bounds: detailOptions.contains(.bounds) ? window.bounds : nil,
                    offScreen: detailOptions.contains(.off_screen) ? window.isOffScreen : nil,
                    spaceID: window.spaceID,
                    spaceName: window.spaceName
                )
            }

            let filteredOutput = FilteredWindowListData(
                windows: windows,
                targetApplication: output.data.targetApplication
            )

            outputSuccessCodable(data: filteredOutput, logger: self.outputLogger)
        }
    }
}

@MainActor
extension ListCommand.WindowsSubcommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "windows",
                abstract: "List all windows for a specific application",
                discussion: """
                Lists all windows for the specified application using PeekabooServices.
                Windows are listed in z-order (frontmost first) with optional details.

                This is the full per-application enumeration and can include utility,
                off-screen, tiny, or otherwise non-renderable windows. `peekaboo window list`
                uses the same window IDs and indexes but filters to renderable windows for
                interaction targeting.
                """
            )
        }
    }
}

extension ListCommand.WindowsSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ListCommand.WindowsSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        let resolvedApp = values.singleOption("app")
        let resolvedPID = try values.decodeOption("pid", as: Int32.self)
        guard resolvedApp != nil || resolvedPID != nil else {
            throw CommanderBindingError.missingArgument(label: "app")
        }
        self.app = resolvedApp
        self.pid = resolvedPID
        self.includeDetails = values.singleOption("includeDetails")
    }
}
