import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension MenuCommand {
    // MARK: - List Menu Items

    @MainActor
    struct ListSubcommand: OutputFormattable, InjectedRuntimeBackedCommand {
        @OptionGroup var target: InteractionTargetOptions

        @Flag(help: "Include disabled menu items")
        var includeDisabled = false

        @Flag(help: "Focus the target before listing its menu")
        var foreground = false

        @OptionGroup var focusOptions: FocusCommandOptions
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            let actionSequence = CommandActionSequenceAccumulator()
            let actionRoute = commandActionRoute(for: runtime.services)
            do {
                do {
                    try self.target.validate()
                    guard self.foreground || !self.focusOptions.hasForegroundFocusOverrides else {
                        throw ValidationError("Menu focus options require --foreground")
                    }
                    let appIdentifier = try await MenuForegroundTargetSupport.resolveApplicationIdentifier(
                        target: self.target,
                        services: self.services
                    )
                    let preparedTarget: MenuForegroundTargetSupport.PreparedTarget?
                    if self.foreground {
                        let application = try await self.resolveApplicationForMutation(
                            appIdentifier,
                            services: self.services
                        )
                        preparedTarget = try MenuForegroundTargetSupport.prepare(application: application)
                    } else {
                        preparedTarget = nil
                    }
                    if let preparedTarget, self.focusOptions.autoFocus {
                        let focusResult = try await MenuForegroundTargetSupport.focus(
                            target: preparedTarget,
                            selector: self.target,
                            options: self.focusOptions,
                            services: self.services,
                            beginMutation: { self.resolvedRuntime.beginInteractionMutation() }
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

                    let menuStructure = if let preparedTarget {
                        try await MenuServiceBridge.listMenus(
                            menu: self.services.menu,
                            request: MenuListRequest(
                                appIdentifier: preparedTarget.identifier,
                                expectedIdentity: preparedTarget.identity
                            )
                        )
                    } else {
                        try await MenuServiceBridge.listMenus(
                            menu: self.services.menu,
                            appIdentifier: appIdentifier
                        )
                    }
                    let filteredMenus = self.includeDisabled ? menuStructure.menus : MenuOutputSupport
                        .filterDisabledMenus(menuStructure.menus)
                    let compositeResult = actionSequence.result(payload: menuStructure)

                    if self.jsonOutput {
                        let data = MenuListData(
                            app: menuStructure.application.name,
                            owner_name: menuStructure.application.name,
                            bundle_id: menuStructure.application.bundleIdentifier,
                            menu_structure: MenuOutputSupport.convertMenusToTyped(filteredMenus)
                        )
                        outputSuccessCodable(
                            data: data,
                            outcome: compositeResult.outcome,
                            targetIdentity: compositeResult.targetIdentity,
                            logger: self.outputLogger
                        )
                    } else {
                        if let outcome = compositeResult.outcome {
                            print(ActionOutcomeHumanRenderer.statusLine(
                                for: outcome,
                                operation: "Menu focus"
                            ))
                        }
                        print("Menu structure for \(menuStructure.application.name):")
                        for menu in filteredMenus {
                            MenuOutputSupport.printMenu(menu, indent: 0)
                        }
                    }
                } catch {
                    throw actionSequence.preservingFailure(
                        error,
                        fallbackRoute: actionRoute,
                        message: "Menu listing failed after foreground focus may have changed desktop state.",
                        hint: "Observe the exact target before retrying foreground menu listing."
                    )
                }
            } catch let error as Commander.ValidationError {
                if self.jsonOutput {
                    outputError(message: error.localizedDescription, code: .INVALID_INPUT, logger: self.outputLogger)
                } else {
                    fputs("Error: \(error.localizedDescription)\n", stderr)
                }
                throw ExitCode(1)
            } catch let error as PeekabooError {
                MenuErrorOutputSupport.renderApplicationError(
                    error,
                    jsonOutput: self.jsonOutput,
                    logger: self.outputLogger
                )
                throw ExitCode(1)
            } catch let error as MenuError {
                MenuErrorOutputSupport.renderMenuError(
                    error,
                    jsonOutput: self.jsonOutput,
                    details: "Failed to list menus",
                    logger: self.outputLogger
                )
                throw ExitCode(1)
            } catch {
                MenuErrorOutputSupport.renderGenericError(
                    error,
                    jsonOutput: self.jsonOutput,
                    details: "Menu list operation failed",
                    logger: self.outputLogger
                )
                throw ExitCode(1)
            }
        }
    }
}

extension MenuCommand.ListSubcommand: ApplicationResolver {}
