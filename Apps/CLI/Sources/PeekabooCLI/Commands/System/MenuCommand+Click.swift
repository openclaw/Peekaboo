import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension MenuCommand {
    // MARK: - Click Menu Item

    @MainActor
    struct ClickSubcommand: ConfirmedActionOutputFormattable, OutputFormattable, InjectedRuntimeBackedCommand {
        @OptionGroup var target: InteractionTargetOptions

        @Option(help: "Menu item to click (for simple, non-nested items)")
        var item: String?

        @Option(help: "Menu path for nested items (e.g., 'File > Export > PDF')")
        var path: String?

        @Flag(help: "Focus the target before using its menu")
        var foreground = false

        @OptionGroup var focusOptions: FocusCommandOptions
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            let (normalizedItem, normalizedPath) = try self.normalizedSelection()

            let actionSequence = CommandActionSequenceAccumulator()
            let actionRoute = commandActionRoute(for: runtime.services)
            do {
                do {
                    try self.target.validate()
                    try self.validateForegroundOptions()
                    try self.validateTargetConsent()
                    let appIdentifier = try await self.resolveTargetApplicationIdentifier()
                    let appInfo = try await self.resolveApplicationForMutation(
                        appIdentifier,
                        services: self.services
                    )
                    let pinnedAppIdentifier = "PID:\(appInfo.processIdentifier)"
                    if self.foreground, self.focusOptions.autoFocus {
                        let focusResult = try await self.performForegroundFocus(
                            appInfo: appInfo,
                            pinnedAppIdentifier: pinnedAppIdentifier
                        )
                        try actionSequence.record(
                            focusResult,
                            receiptlessStep: .dispatched(
                                route: actionRoute,
                                delivery: .init(
                                    mechanism: .accessibilityAction,
                                    mode: .foreground
                                ),
                                unitCount: .one
                            )
                        )
                    }

                    let canonicalPath: String? = normalizedPath.map(Self.canonicalizeMenuPath)
                    let clickedPath = canonicalPath ?? normalizedItem!

                    self.resolvedRuntime.beginInteractionMutation()
                    let actionResult = try await self.performMenuClick(
                        appInfo: appInfo,
                        itemName: normalizedItem,
                        path: canonicalPath
                    )
                    _ = try validatedSuccessfulActionResult(
                        actionResult,
                        operation: "Menu click",
                        requiresTarget: self.services.menu is any MenuServiceActionResultProviding
                    )
                    try actionSequence.record(
                        actionResult,
                        receiptlessStep: .dispatched(
                            route: actionRoute,
                            delivery: .init(
                                mechanism: .accessibilityAction,
                                mode: self.foreground ? .foreground : .background
                            ),
                            unitCount: .one
                        )
                    )
                    let compositeResult = actionSequence.result(payload: ())

                    try withPreservedActionResultOnFailure(
                        compositeResult,
                        targetIdentity: compositeResult.targetIdentity,
                        operation: "Menu click"
                    ) {
                        if self.jsonOutput {
                            let data = MenuClickResult(
                                action: "menu_click",
                                app: appInfo.name,
                                menu_path: clickedPath,
                                clicked_item: clickedPath
                            )
                            outputSuccessCodable(
                                data: data,
                                effect: .confirmed,
                                outcome: compositeResult.outcome,
                                targetIdentity: compositeResult.targetIdentity,
                                logger: self.outputLogger
                            )
                        } else if let outcome = compositeResult.outcome {
                            print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Menu click"))
                        } else {
                            print("✓ Clicked menu item: \(clickedPath)")
                        }
                    }
                } catch {
                    throw actionSequence.preservingFailure(
                        error,
                        fallbackRoute: actionRoute,
                        message: "Menu click failed after foreground focus may have changed desktop state.",
                        hint: "Observe the exact target before deciding whether to retry the menu action."
                    )
                }
            } catch let error as Commander.ValidationError {
                if self.jsonOutput {
                    outputError(message: error.localizedDescription, code: .INVALID_INPUT, logger: self.outputLogger)
                } else {
                    fputs("Error: \(error.localizedDescription)\n", stderr)
                }
                throw ExitCode(1)
            } catch let error as MenuError {
                MenuErrorOutputSupport.renderMenuError(
                    error,
                    jsonOutput: self.jsonOutput,
                    details: "Failed to click menu item",
                    logger: self.outputLogger
                )
                throw ExitCode(1)
            } catch let error as PeekabooError {
                MenuErrorOutputSupport.renderApplicationError(
                    error,
                    jsonOutput: self.jsonOutput,
                    logger: self.outputLogger
                )
                throw ExitCode(1)
            } catch {
                MenuErrorOutputSupport.renderGenericError(
                    error,
                    jsonOutput: self.jsonOutput,
                    details: "Menu operation failed",
                    logger: self.outputLogger
                )
                throw ExitCode(1)
            }
        }

        private func normalizedSelection() throws -> (item: String?, path: String?) {
            // Agents often copy "File > New" paths from list output into --item. Normalize that shape so click
            // execution and enabled-state validation stay aligned.
            let normalization = normalizeMenuSelection(item: self.item, path: self.path)
            if normalization.convertedFromItem, let resolvedPath = normalization.path {
                let note = "Interpreting --item value as menu path: \(resolvedPath)"
                if self.jsonOutput {
                    self.logger.info(note)
                } else {
                    print("ℹ️ \(note)")
                }
            }
            guard normalization.item != nil || normalization.path != nil else {
                throw ValidationError("Must specify either --item or --path")
            }
            guard normalization.item == nil || normalization.path == nil else {
                throw ValidationError("Cannot specify both --item and --path")
            }
            return (normalization.item, normalization.path)
        }

        private func performMenuClick(
            appInfo: ServiceApplicationInfo,
            itemName: String?,
            path: String?
        ) async throws -> UIAutomationActionResult<Void> {
            let identity = try Self.requireMenuProcessIdentity(appInfo)
            let pinnedAppIdentifier = "PID:\(identity.processIdentifier)"
            let deliveryMode: DesktopActionOutcome.Delivery.Mode = self.foreground ? .foreground : .background

            if let itemName {
                return try await MenuServiceBridge.clickMenuItemByName(
                    menu: self.services.menu,
                    request: MenuItemByNameActionRequest(
                        appIdentifier: pinnedAppIdentifier,
                        itemName: itemName,
                        expectedIdentity: identity,
                        deliveryMode: deliveryMode
                    )
                )
            }

            guard let path else {
                throw ValidationError("Must specify either --item or --path")
            }
            return try await MenuServiceBridge.clickMenuItem(
                menu: self.services.menu,
                request: MenuItemActionRequest(
                    appIdentifier: pinnedAppIdentifier,
                    itemPath: path,
                    expectedIdentity: identity,
                    deliveryMode: deliveryMode
                )
            )
        }

        private static func requireMenuProcessIdentity(
            _ application: ServiceApplicationInfo
        ) throws -> ApplicationProcessIdentity {
            guard let identity = application.processIdentity else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Menu click requires a stable application process receipt.",
                    hint: "Refresh the application inventory before retrying."
                )
            }
            return identity
        }

        private func performForegroundFocus(
            appInfo: ServiceApplicationInfo,
            pinnedAppIdentifier: String
        ) async throws -> UIAutomationActionResult<Void> {
            if let preparedWindow = try await self.resolvePreparedForegroundWindow(appInfo: appInfo) {
                self.resolvedRuntime.beginInteractionMutation()
                return try await ensureFocused(
                    preparedWindow: preparedWindow,
                    applicationName: pinnedAppIdentifier,
                    options: self.focusOptions,
                    services: self.services
                )
            }

            self.resolvedRuntime.beginInteractionMutation()
            return try await ApplicationServiceBridge.activateApplicationTargeted(
                applications: self.services.applications,
                application: appInfo
            )
        }

        private func resolvePreparedForegroundWindow(
            appInfo: ServiceApplicationInfo
        ) async throws -> ServiceWindowInfo? {
            let expectedIdentity = try Self.requireMenuProcessIdentity(appInfo)
            let hasExplicitWindowSelector = self.target.windowId != nil ||
                self.target.windowTitle != nil ||
                self.target.windowIndex != nil
            let inventoryTarget: WindowTarget = if let windowID = self.target.windowId {
                .windowId(windowID)
            } else {
                .application("PID:\(expectedIdentity.processIdentifier)")
            }
            let windows = try await WindowServiceBridge.listWindows(
                windows: self.services.windows,
                target: inventoryTarget
            )
            let window: ServiceWindowInfo
            if hasExplicitWindowSelector {
                do {
                    window = try ExactWindowSelectorResolver.select(
                        from: windows,
                        selector: self.target.selector,
                        operation: "Menu focus"
                    )
                } catch {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: error.localizedDescription,
                        hint: "Refresh the window inventory and select one exact --window-id."
                    )
                }
            } else {
                guard let bestWindow = ObservationTargetResolver.bestWindow(from: windows) else {
                    return nil
                }
                window = bestWindow
            }
            guard let windowIdentity = window.mutationIdentity,
                  windowIdentity.ownerProcessIdentifier == expectedIdentity.processIdentifier,
                  windowIdentity.ownerProcessStartIdentity == expectedIdentity.processStartIdentity
            else {
                throw DesktopTargetPlanningError.windowOwnerMismatch(
                    windowID: window.windowID,
                    expected: expectedIdentity
                ).desktopActionFailure
            }
            return window
        }

        private func resolveTargetApplicationIdentifier() async throws -> String {
            if let appIdentifier = try self.target.resolveApplicationIdentifierOptional() {
                return appIdentifier
            }

            guard let frontmost = try? await self.services.applications.getFrontmostApplication() else {
                throw ValidationError("No frontmost app found; provide --app or --pid")
            }

            return frontmost.bundleIdentifier ?? frontmost.name
        }

        private func validateForegroundOptions() throws {
            guard self.foreground || !self.focusOptions.hasForegroundFocusOverrides else {
                throw ValidationError("Menu focus options require --foreground")
            }
        }

        private func validateTargetConsent() throws {
            guard self.target.app != nil || self.target.pid != nil || self.foreground else {
                throw ValidationError(
                    "Background menu click requires --app or --pid; use --foreground to target the frontmost app"
                )
            }
        }
    }
}

extension MenuCommand.ClickSubcommand: ApplicationResolver {}

@MainActor
extension MenuCommand.ClickSubcommand {
    fileprivate static func canonicalizeMenuPath(_ rawPath: String) -> String {
        rawPath
            .split(separator: ">")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " > ")
    }
}

@MainActor
func normalizeMenuSelection(item: String?, path: String?) -> (item: String?, path: String?, convertedFromItem: Bool) {
    guard path == nil, let item, item.contains(">") else {
        return (item, path, false)
    }
    return (nil, item, true)
}
