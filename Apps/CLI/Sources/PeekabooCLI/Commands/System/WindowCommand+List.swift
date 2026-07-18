import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension WindowCommand {
    // MARK: - List Command

    @MainActor
    struct WindowListSubcommand: ErrorHandlingCommand, OutputFormattable, ApplicationResolvable {
        @Option(name: .long, help: "Target application name, bundle ID, or 'PID:12345'")
        var app: String?

        @Option(name: .long, help: "Target application by process ID")
        var pid: Int32?
        @RuntimeStorage private var runtime: CommandRuntime?

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
            self.resolvedRuntime.configuration.jsonOutput
        }

        @Flag(name: .long, help: "Group windows by Space (virtual desktop)")
        var groupBySpace = false

        /// List windows for the target application and optionally organize them by Space.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                let appIdentifier = try self.resolveApplicationIdentifier()
                // First find the application to get its info
                let appInfo = try await self.services.applications.findApplication(identifier: appIdentifier)

                let target = WindowTarget.application(appIdentifier)
                let rawWindows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: target
                )
                let windows = ObservationTargetResolver.filteredWindows(from: rawWindows, mode: .list)

                // Convert ServiceWindowInfo to WindowInfo for consistency
                let windowInfos = windows.map(WindowInfo.init(serviceWindow:))

                // Use PeekabooCore's WindowListData
                let data = WindowListData(
                    windows: windowInfos,
                    target_application_info: TargetApplicationInfo(
                        app_name: appInfo.name,
                        bundle_id: appInfo.bundleIdentifier,
                        pid: appInfo.processIdentifier
                    )
                )

                output(data) {
                    print("\(data.target_application_info.app_name) has \(data.windows.count) window(s):")

                    if self.groupBySpace {
                        // Group windows by space
                        var windowsBySpace: [UInt64?: [(window: ServiceWindowInfo, index: Int)]] = [:]

                        for window in windows {
                            let spaceID = window.spaceID
                            windowsBySpace[spaceID, default: []].append((window, window.index))
                        }

                        // Sort spaces by ID (nil first for windows not on any space)
                        let sortedSpaces = windowsBySpace.keys.sorted { a, b in
                            switch (a, b) {
                            case (nil, nil): false
                            case (nil, _): true
                            case (_, nil): false
                            case let (a?, b?): a < b
                            }
                        }

                        // Print grouped windows
                        for spaceID in sortedSpaces {
                            if let spaceID {
                                let spaceName = windowsBySpace[spaceID]?.first?.window.spaceName ?? "Space \(spaceID)"
                                print("\n  Space: \(spaceName) [ID: \(spaceID)]")
                            } else {
                                print("\n  No Space:")
                            }

                            for (window, index) in windowsBySpace[spaceID] ?? [] {
                                let status = window.isMinimized ? " [minimized]" : ""
                                print("    [\(index)] \"\(window.title)\"\(status)")
                                let origin = window.bounds.origin
                                print("         Position: (\(Int(origin.x)), \(Int(origin.y)))")
                                print(
                                    "         Size: \(Int(window.bounds.size.width))x\(Int(window.bounds.size.height))"
                                )
                            }
                        }
                    } else {
                        // Original flat list
                        for window in data.windows {
                            let index = window.window_index ?? 0
                            let status = (window.is_on_screen == false) ? " [minimized]" : ""
                            print("  [\(index)] \"\(window.window_title)\"\(status)")
                            if let bounds = window.bounds {
                                print("       Position: (\(bounds.x), \(bounds.y))")
                                print("       Size: \(bounds.width)x\(bounds.height)")
                            }
                        }
                    }
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }
}

extension WindowInfo {
    init(serviceWindow window: ServiceWindowInfo) {
        self.init(
            window_title: window.title,
            window_id: UInt32(window.windowID),
            window_index: window.index,
            bounds: WindowBounds(
                x: Int(window.bounds.origin.x),
                y: Int(window.bounds.origin.y),
                width: Int(window.bounds.size.width),
                height: Int(window.bounds.size.height)
            ),
            is_on_screen: window.isOnScreen,
            is_frontmost: window.isFrontmost,
            is_key: window.isKeyWindow,
            layer: window.layer,
            subrole: window.subrole
        )
    }
}
