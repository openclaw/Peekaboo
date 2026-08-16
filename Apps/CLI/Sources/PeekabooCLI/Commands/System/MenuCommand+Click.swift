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
                    if self.foreground {
                        let windowID = try await self.target.resolveWindowID(services: self.services)
                        if self.focusOptions.autoFocus {
                            self.resolvedRuntime.beginInteractionMutation()
                        }
                        if let focusResult = try await ensureFocusIgnoringMissingWindows(
                            request: FocusIgnoringMissingWindowsRequest(
                                windowID: windowID,
                                applicationName: appIdentifier,
                                windowTitle: self.target.windowTitle
                            ),
                            options: self.focusOptions,
                            services: self.services,
                            logger: self.logger
                        ) {
                            try actionSequence.record(
                                focusResult,
                                receiptlessStep: self.focusOptions.autoFocus
                                    ? .dispatched(
                                        route: actionRoute,
                                        delivery: .init(
                                            mechanism: .accessibilityAction,
                                            mode: .foreground
                                        ),
                                        unitCount: .one
                                    )
                                    : nil
                            )
                        }
                    }

                    let canonicalPath: String? = normalizedPath.map(Self.canonicalizeMenuPath)
                    if let canonicalPath {
                        try await self.ensureMenuItemEnabled(appIdentifier: appIdentifier, menuPath: canonicalPath)
                    }
                    let appInfo = try await self.services.applications.findApplication(identifier: appIdentifier)
                    let clickedPath = canonicalPath ?? normalizedItem!

                    self.resolvedRuntime.beginInteractionMutation()
                    let actionResult = try await self.performMenuClick(
                        appIdentifier: appIdentifier,
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
            appIdentifier: String,
            appInfo: ServiceApplicationInfo,
            itemName: String?,
            path: String?
        ) async throws -> UIAutomationActionResult<Void> {
            if let itemName {
                guard !self.foreground else {
                    return try await MenuServiceBridge.clickMenuItemByName(
                        menu: self.services.menu,
                        appIdentifier: appIdentifier,
                        itemName: itemName
                    )
                }
                let identity = try Self.requireBackgroundProcessIdentity(appInfo)
                return try await MenuServiceBridge.clickMenuItemByName(
                    menu: self.services.menu,
                    request: MenuItemByNameActionRequest(
                        appIdentifier: "PID:\(identity.processIdentifier)",
                        itemName: itemName,
                        expectedIdentity: identity,
                        deliveryMode: .background
                    )
                )
            }

            guard let path else {
                throw ValidationError("Must specify either --item or --path")
            }
            guard !self.foreground else {
                return try await MenuServiceBridge.clickMenuItem(
                    menu: self.services.menu,
                    appIdentifier: appIdentifier,
                    itemPath: path
                )
            }
            let identity = try Self.requireBackgroundProcessIdentity(appInfo)
            return try await MenuServiceBridge.clickMenuItem(
                menu: self.services.menu,
                request: MenuItemActionRequest(
                    appIdentifier: "PID:\(identity.processIdentifier)",
                    itemPath: path,
                    expectedIdentity: identity,
                    deliveryMode: .background
                )
            )
        }

        private static func requireBackgroundProcessIdentity(
            _ application: ServiceApplicationInfo
        ) throws -> ApplicationProcessIdentity {
            guard let identity = application.processIdentity else {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "Background menu click requires a stable application process receipt.",
                    hint: "Refresh the application inventory before retrying."
                )
            }
            return identity
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

@MainActor
private func findMenuItem(
    canonicalPath: String,
    in menus: [Menu]
) -> MenuItem? {
    for menu in menus {
        let menuBase = MenuCommand.ClickSubcommand.canonicalizeMenuPath(menu.title)
        if menuBase == canonicalPath {
            return nil // top-level menu is not a clickable item
        }
        if let item = findMenuItem(in: menu.items, canonicalPath: canonicalPath) {
            return item
        }
    }
    return nil
}

private func findMenuItem(
    in items: [MenuItem],
    canonicalPath: String
) -> MenuItem? {
    for item in items {
        if MenuCommand.ClickSubcommand.canonicalizeMenuPath(item.path) == canonicalPath {
            return item
        }
        if let nested = findMenuItem(in: item.submenu, canonicalPath: canonicalPath) {
            return nested
        }
    }
    return nil
}

@MainActor
extension MenuCommand.ClickSubcommand {
    fileprivate static func canonicalizeMenuPath(_ rawPath: String) -> String {
        rawPath
            .split(separator: ">")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " > ")
    }

    fileprivate func ensureMenuItemEnabled(appIdentifier: String, menuPath: String) async throws {
        let structure = try await MenuServiceBridge.listMenus(
            menu: self.services.menu,
            appIdentifier: appIdentifier
        )
        let canonical = menuPath
        guard let item = findMenuItem(canonicalPath: canonical, in: structure.menus) else {
            throw MenuError.menuItemNotFound(canonical)
        }
        guard item.isEnabled else {
            throw MenuError.menuItemDisabled(canonical)
        }
    }
}

@MainActor
func normalizeMenuSelection(item: String?, path: String?) -> (item: String?, path: String?, convertedFromItem: Bool) {
    guard path == nil, let item, item.contains(">") else {
        return (item, path, false)
    }
    return (nil, item, true)
}
