import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

extension WindowCommand {
    // MARK: - Move Command

    @MainActor
    struct MoveSubcommand: ErrorHandlingCommand, OutputFormattable {
        @OptionGroup var windowOptions: WindowIdentificationOptions

        @Option(name: .customShort("x", allowingJoined: false), help: "New X coordinate")
        var x: Int

        @Option(name: .customShort("y", allowingJoined: false), help: "New Y coordinate")
        var y: Int
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

        /// Move the window to the absolute screen coordinates provided by the user.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let target = try self.windowOptions.createTarget()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowTarget()
                )
                let windowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                guard windowInfo != nil else {
                    throw PeekabooError.windowNotFound(criteria: "No windows found for \(appName)")
                }

                // Move the window
                let newOrigin = CGPoint(x: x, y: y)
                self.resolvedRuntime.beginInteractionMutation()
                try await WindowServiceBridge.moveWindow(windows: self.services.windows, target: target, to: newOrigin)
                await invalidateLatestSnapshotAfterWindowMutation(
                    runtime: self.resolvedRuntime,
                    reason: "window move"
                )

                // Read the frame back so the report shows what the OS actually applied.
                let refreshedWindowInfo = await self.windowOptions.refetchWindowInfo(
                    services: self.services,
                    logger: self.logger,
                    context: "window-move"
                )
                let verified = try verifiedWindowActionResult(
                    action: "move",
                    appName: appName,
                    requested: WindowGeometryExpectation(origin: newOrigin, size: nil),
                    originalInfo: windowInfo,
                    refreshedInfo: refreshedWindowInfo
                )

                logWindowAction(
                    action: "move",
                    appName: appName,
                    windowInfo: verified.windowInfo
                )

                output(verified.result) {
                    let title = verified.windowInfo?.title ?? "Untitled"
                    let actualOrigin = verified.windowInfo?.bounds.origin ?? newOrigin
                    if let warning = verified.warning {
                        print("Moved window '\(title)' to \(formatWindowPoint(actualOrigin)) " +
                            "(requested \(formatWindowPoint(newOrigin)))")
                        print("Warning: \(warning)")
                    } else {
                        print("Successfully moved window '\(title)' to \(formatWindowPoint(actualOrigin))")
                    }
                }

            } catch let geometryError as WindowGeometryIgnoredError {
                handleError(geometryError, customCode: .WINDOW_MANIPULATION_ERROR)
                throw ExitCode(1)
            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    // MARK: - Resize Command

    @MainActor
    struct ResizeSubcommand: ErrorHandlingCommand, OutputFormattable {
        @OptionGroup var windowOptions: WindowIdentificationOptions

        @Option(name: .customShort("w", allowingJoined: false), help: "New width")
        var width: Int

        @Option(name: .long, help: "New height")
        var height: Int
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

        /// Resize the window to the supplied dimensions, preserving its origin.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let target = try self.windowOptions.createTarget()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowTarget()
                )
                let windowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                guard windowInfo != nil else {
                    throw PeekabooError.windowNotFound(criteria: "No windows found for \(appName)")
                }

                // Resize the window
                let newSize = CGSize(width: width, height: height)
                self.resolvedRuntime.beginInteractionMutation()
                try await WindowServiceBridge.resizeWindow(windows: self.services.windows, target: target, to: newSize)
                await invalidateLatestSnapshotAfterWindowMutation(
                    runtime: self.resolvedRuntime,
                    reason: "window resize"
                )

                // Read the frame back: AX accepts resizes the app then clamps (e.g. minimum size).
                let refreshedWindowInfo = await self.windowOptions.refetchWindowInfo(
                    services: self.services,
                    logger: self.logger,
                    context: "window-resize"
                )
                let verified = try verifiedWindowActionResult(
                    action: "resize",
                    appName: appName,
                    requested: WindowGeometryExpectation(origin: nil, size: newSize),
                    originalInfo: windowInfo,
                    refreshedInfo: refreshedWindowInfo
                )

                logWindowAction(
                    action: "resize",
                    appName: appName,
                    windowInfo: verified.windowInfo
                )

                output(verified.result) {
                    let title = verified.windowInfo?.title ?? "Untitled"
                    let actualSize = verified.windowInfo?.bounds.size ?? newSize
                    if let warning = verified.warning {
                        print("Resized window '\(title)' to \(formatWindowSize(actualSize)) " +
                            "(requested \(formatWindowSize(newSize)))")
                        print("Warning: \(warning)")
                    } else {
                        print("Successfully resized window '\(title)' to \(formatWindowSize(actualSize))")
                    }
                }

            } catch let geometryError as WindowGeometryIgnoredError {
                handleError(geometryError, customCode: .WINDOW_MANIPULATION_ERROR)
                throw ExitCode(1)
            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    // MARK: - Set Bounds Command

    @MainActor
    struct SetBoundsSubcommand: ErrorHandlingCommand, OutputFormattable {
        @OptionGroup var windowOptions: WindowIdentificationOptions

        @Option(name: .customShort("x", allowingJoined: false), help: "New X coordinate")
        var x: Int

        @Option(name: .customShort("y", allowingJoined: false), help: "New Y coordinate")
        var y: Int

        @Option(name: .customShort("w", allowingJoined: false), help: "New width")
        var width: Int

        @Option(name: .long, help: "New height")
        var height: Int
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

        /// Set both position and size for the window in a single operation, then confirm the new bounds.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let target = try self.windowOptions.createTarget()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowTarget()
                )
                let windowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                guard windowInfo != nil else {
                    throw PeekabooError.windowNotFound(criteria: "No windows found for \(appName)")
                }

                // Set bounds
                let newBounds = CGRect(x: x, y: y, width: width, height: height)
                self.resolvedRuntime.beginInteractionMutation()
                try await WindowServiceBridge.setWindowBounds(
                    windows: self.services.windows,
                    target: target,
                    bounds: newBounds
                )
                await invalidateLatestSnapshotAfterWindowMutation(
                    runtime: self.resolvedRuntime,
                    reason: "window set-bounds"
                )

                // Read the frame back so the report shows what the OS actually applied.
                let refreshedWindowInfo = await self.windowOptions.refetchWindowInfo(
                    services: self.services,
                    logger: self.logger,
                    context: "window-set-bounds"
                )
                let verified = try verifiedWindowActionResult(
                    action: "set-bounds",
                    appName: appName,
                    requested: WindowGeometryExpectation(origin: newBounds.origin, size: newBounds.size),
                    originalInfo: windowInfo,
                    refreshedInfo: refreshedWindowInfo
                )

                logWindowAction(
                    action: "set-bounds",
                    appName: appName,
                    windowInfo: verified.windowInfo
                )

                output(verified.result) {
                    let title = verified.windowInfo?.title ?? "Untitled"
                    let actualBounds = verified.windowInfo?.bounds ?? newBounds
                    let actualDescription =
                        "\(formatWindowPoint(actualBounds.origin)) \(formatWindowSize(actualBounds.size))"
                    if let warning = verified.warning {
                        let requestedDescription =
                            "\(formatWindowPoint(newBounds.origin)) \(formatWindowSize(newBounds.size))"
                        print("Set window '\(title)' bounds to \(actualDescription) " +
                            "(requested \(requestedDescription))")
                        print("Warning: \(warning)")
                    } else {
                        print("Successfully set window '\(title)' bounds to \(actualDescription)")
                    }
                }

            } catch let geometryError as WindowGeometryIgnoredError {
                handleError(geometryError, customCode: .WINDOW_MANIPULATION_ERROR)
                throw ExitCode(1)
            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }
}
