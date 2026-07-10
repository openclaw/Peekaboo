import AppKit
import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension WindowCommand {
    @MainActor
    struct CloseSubcommand: ErrorHandlingCommand, OutputFormattable {
        @OptionGroup var windowOptions: WindowIdentificationOptions
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

        /// Resolve the target window, close it, and surface the outcome in JSON or text form.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let target = try self.windowOptions.createTarget()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info before action
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowTarget()
                )
                let windowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                guard windowInfo != nil else {
                    throw PeekabooError.windowNotFound(criteria: "No windows found for \(appName)")
                }

                // Perform the action
                self.resolvedRuntime.beginInteractionMutation()
                try await WindowServiceBridge.closeWindow(windows: self.services.windows, target: target)
                await invalidateLatestSnapshotAfterWindowMutation(
                    runtime: self.resolvedRuntime,
                    reason: "window close"
                )

                logWindowAction(
                    action: "close",
                    appName: appName,
                    windowInfo: windowInfo
                )

                let data = createWindowActionResult(
                    action: "close",
                    success: true,
                    windowInfo: windowInfo,
                    appName: appName
                )

                output(data) {
                    print("Successfully closed window '\(windowInfo?.title ?? "Untitled")' of \(appName)")
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    struct MinimizeSubcommand: ErrorHandlingCommand, OutputFormattable {
        @OptionGroup var windowOptions: WindowIdentificationOptions
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

        /// Resolve the target window, minimize it to the Dock, and report the action.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let target = try self.windowOptions.createTarget()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info before action
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowTarget()
                )
                let windowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                guard windowInfo != nil else {
                    throw PeekabooError.windowNotFound(criteria: "No windows found for \(appName)")
                }

                // Perform the action
                self.resolvedRuntime.beginInteractionMutation()
                try await WindowServiceBridge.minimizeWindow(windows: self.services.windows, target: target)
                await invalidateLatestSnapshotAfterWindowMutation(
                    runtime: self.resolvedRuntime,
                    reason: "window minimize"
                )
                logWindowAction(
                    action: "minimize",
                    appName: appName,
                    windowInfo: windowInfo
                )

                let data = createWindowActionResult(
                    action: "minimize",
                    success: true,
                    windowInfo: windowInfo,
                    appName: appName
                )

                output(data) {
                    print("Successfully minimized window '\(windowInfo?.title ?? "Untitled")' of \(appName)")
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    struct MaximizeSubcommand: ErrorHandlingCommand, OutputFormattable {
        @OptionGroup var windowOptions: WindowIdentificationOptions
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

        /// Expand the resolved window to fill the available screen real estate and share the updated frame.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let target = try self.windowOptions.createTarget()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info before action
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowTarget()
                )
                let windowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                guard windowInfo != nil else {
                    throw PeekabooError.windowNotFound(criteria: "No windows found for \(appName)")
                }

                // Quiet per-attempt reader used while polling for the frame to settle. Unlike
                // `refetchWindowInfo`, it does not log a warning on every poll.
                let readTarget = try self.windowOptions.toWindowTarget()
                let readWindow: () async -> ServiceWindowInfo? = { [services = self.services] in
                    guard let windows = try? await WindowServiceBridge.listWindows(
                        windows: services.windows,
                        target: readTarget
                    ) else {
                        return nil
                    }
                    return self.windowOptions.selectWindow(from: windows)
                }

                // Perform the action. `maximize` presses the animated green zoom button, so the frame
                // must settle before we read it back. It is also idempotent: a window already occupying
                // a screen's visible frame (matched on origin and size) is left as-is (see
                // resolveIdempotentMaximize). Screen frames are flipped into the AX/CG top-left space
                // that window bounds use.
                let primaryDisplayHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                    ?? NSScreen.main)?.frame.height ?? 0
                let screenVisibleFramesTopLeft = NSScreen.screens.map {
                    convertAppKitFrameToTopLeft($0.visibleFrame, primaryDisplayHeight: primaryDisplayHeight)
                }
                self.resolvedRuntime.beginInteractionMutation()
                let outcome = try await resolveIdempotentMaximize(
                    original: windowInfo,
                    screenVisibleFramesTopLeft: screenVisibleFramesTopLeft,
                    press: {
                        try await WindowServiceBridge.maximizeWindow(windows: self.services.windows, target: target)
                        await invalidateLatestSnapshotAfterWindowMutation(
                            runtime: self.resolvedRuntime,
                            reason: "window maximize"
                        )
                    },
                    read: readWindow
                )

                let finalWindowInfo = outcome.info ?? windowInfo
                logWindowAction(
                    action: "maximize",
                    appName: appName,
                    windowInfo: finalWindowInfo
                )

                let warning: String? = if outcome.info == nil {
                    "Could not read back the window frame after maximize; reported bounds may be stale."
                } else if !outcome.stabilized {
                    "The window frame was still changing after maximize; reported bounds may be approximate."
                } else {
                    nil
                }
                let data = createWindowActionResult(
                    action: "maximize",
                    success: true,
                    windowInfo: finalWindowInfo,
                    appName: appName,
                    warning: warning
                )

                output(data) {
                    let title = finalWindowInfo?.title ?? "Untitled"
                    if outcome.alreadyMaximized {
                        print("Window '\(title)' of \(appName) is already maximized")
                    } else {
                        print("Successfully maximized window '\(title)' of \(appName)")
                    }
                    if let warning {
                        print("Warning: \(warning)")
                    }
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }
}
