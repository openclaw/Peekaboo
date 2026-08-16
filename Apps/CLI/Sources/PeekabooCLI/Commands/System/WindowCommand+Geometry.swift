import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

extension WindowCommand {
    // MARK: - Move Command

    @MainActor
    struct MoveSubcommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @OptionGroup var windowOptions: WindowIdentificationOptions

        @Option(name: .customShort("x", allowingJoined: false), help: "New X coordinate")
        var x: Int

        @Option(name: .customShort("y", allowingJoined: false), help: "New Y coordinate")
        var y: Int
        @RuntimeStorage var runtime: CommandRuntime?

        /// Move the window to the absolute screen coordinates provided by the user.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validateMutation()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowSelectionTarget()
                )
                let windowInfo = try self.windowOptions.requireMutationWindow(
                    from: windows,
                    expectedApplication: appInfo,
                    action: "move"
                )
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                let target = WindowTarget.windowId(windowInfo.windowID)
                guard let mutationIdentity = windowInfo.mutationIdentity else {
                    throw PeekabooError.commandFailed(
                        "Window \(windowInfo.windowID) did not include a process-generation identity"
                    )
                }

                // Move the window
                let newOrigin = CGPoint(x: x, y: y)
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await WindowServiceBridge.moveWindow(
                    windows: self.services.windows,
                    target: target,
                    expectedIdentity: mutationIdentity,
                    to: newOrigin
                )
                await invalidateLatestSnapshotAfterWindowMutation(
                    runtime: self.resolvedRuntime,
                    reason: "window move"
                )

                try await withPreservedActionResultOnFailure(
                    actionResult,
                    targetIdentity: actionResult.targetIdentity,
                    operation: "Window move"
                ) {
                    let readback = try await WindowServiceBridge.listWindows(
                        windows: self.services.windows,
                        target: target
                    ).first
                    let refreshedWindowInfo = try readback.map {
                        try validatedPostMutationWindowReadback(
                            $0,
                            expectedIdentity: mutationIdentity,
                            operation: "Window move"
                        )
                    }
                    let verified = try verifiedWindowActionResult(
                        action: "move",
                        appName: appName,
                        requested: WindowGeometryExpectation(origin: newOrigin, size: nil),
                        originalInfo: windowInfo,
                        refreshedInfo: refreshedWindowInfo
                    )
                    let outputOutcome = verified.effect == .confirmed
                        ? canonicalActionOutcomeAfterSuccessfulVerification(
                            actionResult.outcome,
                            observedChange: observedWindowFrameChange(
                                original: windowInfo,
                                verified: verified.windowInfo
                            )
                        )
                        : actionResult.outcome
                    logWindowAction(action: "move", appName: appName, windowInfo: verified.windowInfo)
                    output(
                        verified.result,
                        effect: verified.effect,
                        outcome: outputOutcome,
                        targetIdentity: actionResult.targetIdentity
                    ) {
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
    struct ResizeSubcommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @OptionGroup var windowOptions: WindowIdentificationOptions

        @Option(name: .customShort("w", allowingJoined: false), help: "New width")
        var width: Int

        @Option(name: .long, help: "New height")
        var height: Int
        @RuntimeStorage var runtime: CommandRuntime?

        /// Resize the window to the supplied dimensions, preserving its origin.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validateMutation()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowSelectionTarget()
                )
                let windowInfo = try self.windowOptions.requireMutationWindow(
                    from: windows,
                    expectedApplication: appInfo,
                    action: "resize"
                )
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                let target = WindowTarget.windowId(windowInfo.windowID)
                guard let mutationIdentity = windowInfo.mutationIdentity else {
                    throw PeekabooError.commandFailed(
                        "Window \(windowInfo.windowID) did not include a process-generation identity"
                    )
                }

                // Resize the window
                let newSize = CGSize(width: width, height: height)
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await WindowServiceBridge.resizeWindow(
                    windows: self.services.windows,
                    target: target,
                    expectedIdentity: mutationIdentity,
                    to: newSize
                )
                await invalidateLatestSnapshotAfterWindowMutation(
                    runtime: self.resolvedRuntime,
                    reason: "window resize"
                )

                try await withPreservedActionResultOnFailure(
                    actionResult,
                    targetIdentity: actionResult.targetIdentity,
                    operation: "Window resize"
                ) {
                    let readback = try await WindowServiceBridge.listWindows(
                        windows: self.services.windows,
                        target: target
                    ).first
                    let refreshedWindowInfo = try readback.map {
                        try validatedPostMutationWindowReadback(
                            $0,
                            expectedIdentity: mutationIdentity,
                            operation: "Window resize"
                        )
                    }
                    let verified = try verifiedWindowActionResult(
                        action: "resize",
                        appName: appName,
                        requested: WindowGeometryExpectation(origin: nil, size: newSize),
                        originalInfo: windowInfo,
                        refreshedInfo: refreshedWindowInfo
                    )
                    let outputOutcome = verified.effect == .confirmed
                        ? canonicalActionOutcomeAfterSuccessfulVerification(
                            actionResult.outcome,
                            observedChange: observedWindowFrameChange(
                                original: windowInfo,
                                verified: verified.windowInfo
                            )
                        )
                        : actionResult.outcome
                    logWindowAction(action: "resize", appName: appName, windowInfo: verified.windowInfo)
                    output(
                        verified.result,
                        effect: verified.effect,
                        outcome: outputOutcome,
                        targetIdentity: actionResult.targetIdentity
                    ) {
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
    struct SetBoundsSubcommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @OptionGroup var windowOptions: WindowIdentificationOptions

        @Option(name: .customShort("x", allowingJoined: false), help: "New X coordinate")
        var x: Int

        @Option(name: .customShort("y", allowingJoined: false), help: "New Y coordinate")
        var y: Int

        @Option(name: .customShort("w", allowingJoined: false), help: "New width")
        var width: Int

        @Option(name: .long, help: "New height")
        var height: Int
        @RuntimeStorage var runtime: CommandRuntime?

        /// Set both position and size for the window in a single operation, then confirm the new bounds.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.windowOptions.validateMutation()
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info
                let windows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: self.windowOptions.toWindowSelectionTarget()
                )
                let windowInfo = try self.windowOptions.requireMutationWindow(
                    from: windows,
                    expectedApplication: appInfo,
                    action: "set bounds"
                )
                let appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                let target = WindowTarget.windowId(windowInfo.windowID)
                guard let mutationIdentity = windowInfo.mutationIdentity else {
                    throw PeekabooError.commandFailed(
                        "Window \(windowInfo.windowID) did not include a process-generation identity"
                    )
                }

                // Set bounds
                let newBounds = CGRect(x: x, y: y, width: width, height: height)
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await WindowServiceBridge.setWindowBounds(
                    windows: self.services.windows,
                    target: target,
                    expectedIdentity: mutationIdentity,
                    bounds: newBounds
                )
                await invalidateLatestSnapshotAfterWindowMutation(
                    runtime: self.resolvedRuntime,
                    reason: "window set-bounds"
                )

                try await withPreservedActionResultOnFailure(
                    actionResult,
                    targetIdentity: actionResult.targetIdentity,
                    operation: "Window set bounds"
                ) {
                    let readback = try await WindowServiceBridge.listWindows(
                        windows: self.services.windows,
                        target: target
                    ).first
                    let refreshedWindowInfo = try readback.map {
                        try validatedPostMutationWindowReadback(
                            $0,
                            expectedIdentity: mutationIdentity,
                            operation: "Window set bounds"
                        )
                    }
                    let verified = try verifiedWindowActionResult(
                        action: "set-bounds",
                        appName: appName,
                        requested: WindowGeometryExpectation(origin: newBounds.origin, size: newBounds.size),
                        originalInfo: windowInfo,
                        refreshedInfo: refreshedWindowInfo
                    )
                    let outputOutcome = verified.effect == .confirmed
                        ? canonicalActionOutcomeAfterSuccessfulVerification(
                            actionResult.outcome,
                            observedChange: observedWindowFrameChange(
                                original: windowInfo,
                                verified: verified.windowInfo
                            )
                        )
                        : actionResult.outcome
                    logWindowAction(action: "set-bounds", appName: appName, windowInfo: verified.windowInfo)
                    output(
                        verified.result,
                        effect: verified.effect,
                        outcome: outputOutcome,
                        targetIdentity: actionResult.targetIdentity
                    ) {
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
