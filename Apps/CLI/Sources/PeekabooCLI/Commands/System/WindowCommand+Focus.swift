import Commander
import CoreGraphics
import Foundation
import PeekabooCore
import PeekabooFoundation

extension WindowCommand {
    @MainActor
    struct FocusSubcommand: ActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @OptionGroup var windowOptions: WindowIdentificationOptions

        @OptionGroup var focusOptions: FocusCommandOptions

        @Option(help: "Snapshot ID to focus the captured window context")
        var snapshot: String?

        @Flag(help: "Verify the window is focused after the action")
        var verify = false
        @RuntimeStorage var runtime: CommandRuntime?

        /// Focus the targeted window, handling Space switches or relocation according to the provided options.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.debug("FocusSubcommand.run() called")
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                self.logger.debug("About to validate window options")
                let observation = await InteractionObservationContext.resolve(
                    explicitSnapshot: self.snapshot,
                    fallbackToLatest: false,
                    snapshots: self.services.snapshots
                )
                try self.windowOptions.validateMutation(allowMissingTarget: observation.hasSnapshot)
                try await observation.validateIfExplicit(using: self.services.snapshots)
                self.logger.debug("Window options validated")
                let hasWindowTarget = self.windowOptions.app != nil ||
                    self.windowOptions.pid != nil ||
                    self.windowOptions.windowId != nil
                let target = hasWindowTarget ? try self.windowOptions.createTarget() : nil
                if let target {
                    self.logger.debug("Target created: \(target)")
                }
                let appInfo = try await self.windowOptions.resolveApplicationInfoIfNeeded(services: self.services)

                // Get window info before action
                let windowInfo: ServiceWindowInfo?
                let appName: String
                let snapshotContext = try await self.resolveSnapshotContextIfNeeded(observation)
                if hasWindowTarget {
                    windowInfo = try await self.resolvePreparedWindow(appInfo: appInfo)
                    appName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: windowInfo)
                } else if let snapshotContext {
                    windowInfo = await self.refetchWindowInfo(
                        target: snapshotContext.target,
                        context: "window-focus-snapshot"
                    )
                    appName = snapshotContext.appName
                } else {
                    throw ValidationError("Either --app, --pid, --window-id, or --snapshot must be specified")
                }

                // Check if we found any windows
                guard hasWindowTarget || snapshotContext != nil else { preconditionFailure("validated above") }

                // Use enhanced focus with space support
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult: UIAutomationActionResult<Void>
                if let windowInfo {
                    actionResult = try await ensureFocused(
                        preparedWindow: windowInfo,
                        applicationName: appName,
                        windowTitle: self.windowOptions.windowTitle,
                        options: self.focusOptions.asFocusOptions,
                        services: self.services
                    )
                } else if let snapshotContext {
                    actionResult = try await ensureFocused(
                        snapshotId: snapshotContext.snapshotId,
                        options: self.focusOptions.asFocusOptions,
                        services: self.services
                    )
                } else if let target {
                    // Fallback to regular focus if no window ID
                    actionResult = try await WindowServiceBridge.focusWindow(
                        windows: self.services.windows,
                        target: target
                    )
                } else {
                    throw ValidationError("Either --app, --pid, --window-id, or --snapshot must be specified")
                }
                await InteractionObservationInvalidator.invalidateAfterMutation(
                    targets: self.resolvedRuntime.interactionMutationTargets,
                    logger: self.logger,
                    reason: "window focus"
                )
                let targetIdentity = try validatedSuccessfulActionResult(
                    actionResult,
                    operation: "Window focus",
                    requiresTarget: true
                )

                try await withPreservedActionResultOnFailure(
                    actionResult,
                    targetIdentity: targetIdentity,
                    operation: "Window focus"
                ) {
                    guard let expectedIdentity = targetIdentity?.exactWindow?.identity else {
                        throw PeekabooError.windowNotFound(
                            criteria: "Window focus result lost its exact-window receipt"
                        )
                    }
                    let refreshedWindowInfo: ServiceWindowInfo? = if hasWindowTarget {
                        await self.windowOptions.refetchWindowInfo(
                            services: self.services,
                            logger: self.logger,
                            context: "window-focus"
                        )
                    } else if let snapshotContext {
                        await self.refetchWindowInfo(
                            target: snapshotContext.target,
                            context: "window-focus"
                        )
                    } else {
                        nil
                    }
                    let validatedRefreshed = try refreshedWindowInfo.map {
                        try validatedPostMutationWindowReadback(
                            $0,
                            expectedIdentity: expectedIdentity,
                            operation: "Window focus"
                        )
                    }
                    let finalWindowInfo = validatedRefreshed ?? windowInfo

                    if self.verify {
                        try await self.verifyFocus(
                            expectedWindowId: finalWindowInfo?.windowID,
                            expectedTitle: self.windowOptions.windowTitle,
                            expectedApp: appInfo,
                            expectedIdentity: expectedIdentity
                        )
                    }
                    let outputOutcome = self.verify
                        ? canonicalActionOutcomeAfterSuccessfulVerification(actionResult.outcome)
                        : actionResult.outcome
                    logWindowAction(
                        action: "focus",
                        appName: appName,
                        windowInfo: finalWindowInfo
                    )

                    let data = createWindowActionResult(
                        action: "focus",
                        windowInfo: finalWindowInfo,
                        appName: appName
                    )
                    output(
                        data,
                        effect: self.verify ? .confirmed : .unverifiable,
                        outcome: outputOutcome,
                        targetIdentity: targetIdentity
                    ) {
                        var message = "Successfully focused window " +
                            "'\(finalWindowInfo?.title ?? "Untitled")' of \(appName)"
                        if self.focusOptions.bringToCurrentSpace {
                            message += " (moved to current Space)"
                        }
                        print(message)
                    }
                }

            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }

        private func resolvePreparedWindow(
            appInfo: ServiceApplicationInfo?
        ) async throws -> ServiceWindowInfo {
            let windows = try await WindowServiceBridge.listWindows(
                windows: self.services.windows,
                target: self.windowOptions.toWindowSelectionTarget()
            )
            self.logger.debug("Found \(windows.count) windows")
            guard !windows.isEmpty else {
                let displayName = appInfo?.name ?? self.windowOptions.displayName(windowInfo: nil)
                throw PeekabooError.windowNotFound(criteria: "No windows found for \(displayName)")
            }
            return try self.windowOptions.requireMutationWindow(
                from: windows,
                expectedApplication: appInfo,
                action: "focus"
            )
        }

        private func resolveSnapshotContextIfNeeded(
            _ observation: InteractionObservationContext
        ) async throws -> (
            snapshotId: String,
            target: WindowTarget,
            appName: String
        )? {
            guard let snapshotId = observation.snapshotId else {
                return nil
            }
            guard let snapshot = try await self.services.snapshots.getUIAutomationSnapshot(snapshotId: snapshotId),
                  let target = windowTarget(from: snapshot)
            else {
                throw PeekabooError.snapshotNotFound(
                    """
                    Snapshot '\(snapshotId)' has no window context. \
                    Run 'peekaboo see' again against a window or provide --app/--pid/--window-id.
                    """
                )
            }
            return (snapshotId, target, windowDisplayName(from: snapshot, snapshotId: snapshotId))
        }

        private func refetchWindowInfo(target: WindowTarget, context: StaticString) async -> ServiceWindowInfo? {
            do {
                let refreshedWindows = try await WindowServiceBridge.listWindows(
                    windows: self.services.windows,
                    target: target
                )
                return refreshedWindows.first
            } catch {
                self.logger.warn("Failed to refetch window info (\(context)): \(error.localizedDescription)")
                return nil
            }
        }

        private func verifyFocus(
            expectedWindowId: Int?,
            expectedTitle: String?,
            expectedApp: ServiceApplicationInfo?,
            expectedIdentity: WindowMutationIdentity
        ) async throws {
            let deadline = Date().addingTimeInterval(1.5)
            while Date() < deadline {
                if let expectedApp {
                    let frontmost = try await self.services.applications.getFrontmostApplication()
                    if let expectedBundle = expectedApp.bundleIdentifier,
                       let frontBundle = frontmost.bundleIdentifier,
                       expectedBundle != frontBundle {
                        try await Task.sleep(nanoseconds: 120_000_000)
                        continue
                    }

                    if frontmost.name.compare(expectedApp.name, options: .caseInsensitive) != .orderedSame,
                       expectedApp.bundleIdentifier == nil {
                        try await Task.sleep(nanoseconds: 120_000_000)
                        continue
                    }
                }

                guard let focused = try await self.services.windows.getFocusedWindow() else {
                    try await Task.sleep(nanoseconds: 120_000_000)
                    continue
                }
                if let expectedWindowId, focused.windowID != expectedWindowId {
                    try await Task.sleep(nanoseconds: 120_000_000)
                    continue
                }
                if expectedWindowId == nil,
                   let expectedTitle,
                   !focused.title.localizedCaseInsensitiveContains(expectedTitle) {
                    try await Task.sleep(nanoseconds: 120_000_000)
                    continue
                }
                _ = try validatedPostMutationWindowReadback(
                    focused,
                    expectedIdentity: expectedIdentity,
                    operation: "Window focus"
                )

                return
            }

            throw PeekabooError.operationError(message: "Window focus verification failed")
        }
    }
}
