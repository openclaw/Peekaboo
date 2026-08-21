import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension WindowCommand {
    // MARK: - List Command

    @MainActor
    struct WindowListSubcommand: ErrorHandlingCommand, OutputFormattable, ApplicationResolvable,
    InjectedRuntimeBackedCommand {
        @Option(name: .long, help: "Target application name, bundle ID, or 'PID:12345'")
        var app: String?

        @Option(name: .long, help: "Target application by process ID")
        var pid: Int32?
        @RuntimeStorage var runtime: CommandRuntime?

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
                let inventory = try await WindowServiceBridge.mutationInventory(
                    windows: self.services.windows,
                    target: target
                )
                let rawWindows = inventory.items
                let windows = ObservationTargetResolver.filteredWindows(from: rawWindows, mode: .list)
                var outputCompleteness = inventory.completeness
                var outputWarnings = inventory.warnings
                if inventory.completeness == .partial, outputWarnings.isEmpty {
                    outputWarnings.append("Window inventory provider reported partial results without a reason.")
                }
                let omittedRowCount = rawWindows.count - windows.count
                if omittedRowCount > 0 {
                    outputCompleteness = .partial
                    outputWarnings.append(
                        "Window list omitted \(omittedRowCount) non-renderable or duplicate inventory " +
                            "row\(omittedRowCount == 1 ? "" : "s")."
                    )
                }

                // Convert ServiceWindowInfo to WindowInfo for consistency
                let windowInfos = windows.map(WindowInfo.init(serviceWindow:))

                // Use PeekabooCore's WindowListData
                let data = WindowListData(
                    windows: windowInfos,
                    target_application_info: TargetApplicationInfo(
                        app_name: appInfo.name,
                        bundle_id: appInfo.bundleIdentifier,
                        pid: appInfo.processIdentifier
                    ),
                    inventory_completeness: outputCompleteness.rawValue,
                    inventory_warnings: outputWarnings
                )

                output(data) {
                    print("\(data.target_application_info.app_name) has \(data.windows.count) window(s):")

                    for warning in outputWarnings {
                        print("Warning: \(warning)")
                    }

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
                                let observation = Self.observationDescription(
                                    window.observationCapability,
                                    windowID: window.windowID
                                )
                                print("         Observation: \(observation)")
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
                            let observation = Self.observationDescription(
                                window.observation_capability,
                                reason: window.observation_capability_reason,
                                windowID: window.window_id.map(Int.init)
                            )
                            print("       Observation: \(observation)")
                        }
                    }
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }

        static func observationDescription(
            _ capability: WindowObservationCapability?,
            windowID: Int?
        ) -> String {
            self.observationDescription(
                capability?.mode,
                reason: capability?.reason,
                windowID: windowID
            )
        }

        static func observationDescription(
            _ mode: WindowObservationCapability.Mode?,
            reason: WindowObservationCapability.Reason?,
            windowID: Int?
        ) -> String {
            switch mode {
            case .combinedEligible:
                "combined_eligible"
            case .pixelsOnly:
                if let windowID, let reason {
                    "pixels_only (\(reason.rawValue); use `peekaboo see --window-id \(windowID) --no-elements`)"
                } else if let reason {
                    "pixels_only (\(reason.rawValue); use `peekaboo see --no-elements`)"
                } else {
                    "pixels_only"
                }
            case .unknown:
                if let reason {
                    "unknown (\(reason.rawValue); refresh the window inventory before choosing an observation mode)"
                } else {
                    "unknown"
                }
            case nil:
                "unknown (host did not report combined-observation eligibility)"
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
            subrole: window.subrole,
            observation_capability: window.observationCapability?.mode,
            observation_capability_reason: window.observationCapability?.reason
        )
    }
}
