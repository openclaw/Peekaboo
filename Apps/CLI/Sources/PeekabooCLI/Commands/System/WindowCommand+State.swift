import AppKit
import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension WindowCommand {
    @MainActor
    struct CloseSubcommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @OptionGroup var windowOptions: WindowIdentificationOptions

        @Flag(help: "Allow focused/global fallback if AX close does not dismiss the window")
        var foreground = false
        @RuntimeStorage var runtime: CommandRuntime?

        /// Resolve the target window, close it, and surface the outcome in JSON or text form.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info before action
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowSelectionTarget()
                )
                let selectedWindowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: selectedWindowInfo)
                let windowInfo = try self.windowOptions.requireMutationWindow(
                    from: windows,
                    expectedApplication: appInfo,
                    action: "close"
                )
                let exactTarget = WindowTarget.windowId(windowInfo.windowID)
                guard let mutationIdentity = windowInfo.mutationIdentity else {
                    throw PeekabooError.commandFailed(
                        "Window \(windowInfo.windowID) did not include a process-generation identity"
                    )
                }

                // Perform the action
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await WindowServiceBridge.closeWindow(
                    windows: self.services.windows,
                    target: exactTarget,
                    expectedIdentity: mutationIdentity,
                    allowForegroundFallback: self.foreground
                )
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
                    windowInfo: windowInfo,
                    appName: appName
                )

                output(data, outcome: actionResult.outcome) {
                    print("Successfully closed window '\(windowInfo.title)' of \(appName)")
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    struct MinimizeSubcommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @OptionGroup var windowOptions: WindowIdentificationOptions
        @RuntimeStorage var runtime: CommandRuntime?

        /// Resolve the target window, minimize it to the Dock, and report the action.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info before action
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowSelectionTarget()
                )
                let selectedWindowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: selectedWindowInfo)
                let windowInfo = try self.windowOptions.requireMutationWindow(
                    from: windows,
                    expectedApplication: appInfo,
                    action: "minimize"
                )
                let exactTarget = WindowTarget.windowId(windowInfo.windowID)
                guard let mutationIdentity = windowInfo.mutationIdentity else {
                    throw PeekabooError.commandFailed(
                        "Window \(windowInfo.windowID) did not include a process-generation identity"
                    )
                }

                // Perform the action
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await WindowServiceBridge.minimizeWindow(
                    windows: self.services.windows,
                    target: exactTarget,
                    expectedIdentity: mutationIdentity
                )
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
                    windowInfo: windowInfo,
                    appName: appName
                )

                output(data, outcome: actionResult.outcome) {
                    print("Successfully minimized window '\(windowInfo.title)' of \(appName)")
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    struct RestoreSubcommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @OptionGroup var windowOptions: WindowIdentificationOptions
        @RuntimeStorage var runtime: CommandRuntime?

        /// Restore a minimized exact window without activating or focusing its application.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowSelectionTarget()
                )
                let selectedWindowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: selectedWindowInfo)
                let windowInfo = try self.windowOptions.requireMutationWindow(
                    from: windows,
                    expectedApplication: appInfo,
                    action: "restore"
                )
                guard let mutationIdentity = windowInfo.mutationIdentity else {
                    throw PeekabooError.commandFailed(
                        "Window \(windowInfo.windowID) did not include a process-generation identity"
                    )
                }
                let exactTarget = WindowTarget.windowId(windowInfo.windowID)

                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await WindowServiceBridge.restoreWindow(
                    windows: self.services.windows,
                    target: exactTarget,
                    expectedIdentity: mutationIdentity
                )
                await invalidateLatestSnapshotAfterWindowMutation(
                    runtime: self.resolvedRuntime,
                    reason: "window restore"
                )

                let refreshedWindow = await restoredWindowOutputInfo(original: windowInfo) {
                    try await WindowServiceBridge.listWindows(
                        windows: self.services.windows,
                        target: exactTarget
                    ).first
                }
                logWindowAction(
                    action: "restore",
                    appName: appName,
                    windowInfo: refreshedWindow
                )
                let data = createWindowActionResult(
                    action: "restore",
                    windowInfo: refreshedWindow,
                    appName: appName
                )
                output(data, outcome: actionResult.outcome) {
                    print("Successfully restored window '\(refreshedWindow?.title ?? windowInfo.title)' of \(appName)")
                }
            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }
    }

    @MainActor
    struct MaximizeSubcommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @OptionGroup var windowOptions: WindowIdentificationOptions
        @RuntimeStorage var runtime: CommandRuntime?

        /// Expand the resolved window to fill the available screen real estate and share the updated frame.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validate()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info before action
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowSelectionTarget()
                )
                let selectedWindowInfo = self.windowOptions.selectWindow(from: windows)
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: selectedWindowInfo)
                let windowInfo = try self.windowOptions.requireMutationWindow(
                    from: windows,
                    expectedApplication: appInfo,
                    action: "maximize"
                )
                let exactTarget = WindowTarget.windowId(windowInfo.windowID)
                guard let mutationIdentity = windowInfo.mutationIdentity else {
                    throw PeekabooError.commandFailed(
                        "Window \(windowInfo.windowID) did not include a process-generation identity"
                    )
                }

                // Quiet per-attempt reader used while polling for the frame to settle. Unlike
                // `refetchWindowInfo`, it does not log a warning on every poll.
                let readTarget = exactTarget
                let readWindow: () async -> ServiceWindowInfo? = { [services = self.services] in
                    guard let windows = try? await WindowServiceBridge.listWindows(
                        windows: services.windows,
                        target: readTarget
                    )
                    else {
                        return nil
                    }
                    return windows.first
                }

                // The service applies bounded exact-window geometry without activating the app or
                // entering full screen. Poll until WindowServer reports a stable read-back so JSON
                // never returns an intermediate frame.
                let primaryDisplayHeight = (NSScreen.screens.first { $0.frame.origin == .zero }
                    ?? NSScreen.main)?.frame.height ?? 0
                let screenVisibleFramesTopLeft = NSScreen.screens.map {
                    convertAppKitFrameToTopLeft($0.visibleFrame, primaryDisplayHeight: primaryDisplayHeight)
                }
                self.resolvedRuntime.beginInteractionMutation()
                var actionResult = DesktopActionResult<Void>(outcome: .confirmedNoChange())
                let outcome = try await resolveIdempotentMaximize(
                    original: windowInfo,
                    screenVisibleFramesTopLeft: screenVisibleFramesTopLeft,
                    apply: {
                        actionResult = try await WindowServiceBridge.maximizeWindow(
                            windows: self.services.windows,
                            target: exactTarget,
                            expectedIdentity: mutationIdentity
                        )
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
                    windowInfo: finalWindowInfo,
                    appName: appName,
                    warning: warning
                )

                let effect: ActionEffect = if outcome.alreadyMaximized {
                    .suspectedNoop
                } else if outcome.info == nil {
                    .unverifiable
                } else if !outcome.stabilized {
                    .partial
                } else {
                    .confirmed
                }
                output(data, effect: effect, outcome: actionResult.outcome) {
                    let title = finalWindowInfo.title
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

@MainActor
func restoredWindowOutputInfo(
    original: ServiceWindowInfo,
    tolerance: CGFloat = 1,
    refresh: @MainActor () async throws -> ServiceWindowInfo?
) async -> ServiceWindowInfo? {
    guard let expectedIdentity = original.mutationIdentity,
          expectedIdentity.windowID == original.windowID,
          expectedIdentity.isMinimized == original.isMinimized,
          let expectedBounds = expectedIdentity.capturedBounds,
          windowFramesMatch(original.bounds, expectedBounds, tolerance: tolerance)
    else {
        return nil
    }

    // The service has already repinned the exact restored window. Public/AX inventory can
    // still omit it briefly or expose its Dock thumbnail, so accept refresh metadata only
    // when its complete identity receipt matches the verified restore receipt.
    guard let refreshed = try? await refresh(),
          let refreshedIdentity = refreshed.mutationIdentity,
          refreshed.windowID == expectedIdentity.windowID,
          refreshedIdentity.windowID == expectedIdentity.windowID,
          refreshedIdentity.ownerProcessIdentifier == expectedIdentity.ownerProcessIdentifier,
          refreshedIdentity.ownerProcessStartIdentity == expectedIdentity.ownerProcessStartIdentity,
          refreshed.isMinimized == false,
          refreshedIdentity.isMinimized == false,
          let refreshedBounds = refreshedIdentity.capturedBounds,
          windowFramesMatch(refreshed.bounds, expectedBounds, tolerance: tolerance),
          windowFramesMatch(refreshedBounds, expectedBounds, tolerance: tolerance)
    else {
        return original
    }
    return refreshed
}
