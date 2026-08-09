import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension MenuCommand {
    // MARK: - List Menu Items

    @MainActor
    struct ListSubcommand: OutputFormattable {
        @OptionGroup var target: InteractionTargetOptions

        @Flag(help: "Include disabled menu items")
        var includeDisabled = false

        @Flag(help: "Focus the target before listing its menu")
        var foreground = false

        @OptionGroup var focusOptions: FocusCommandOptions
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

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.target.validate()
                guard self.foreground || !self.focusOptions.hasForegroundFocusOverrides else {
                    throw ValidationError("Menu focus options require --foreground")
                }
                let appIdentifier = try await self.resolveTargetApplicationIdentifier()
                if self.foreground {
                    let windowID = try await self.target.resolveWindowID(services: self.services)
                    if self.focusOptions.autoFocus {
                        self.resolvedRuntime.beginInteractionMutation()
                    }
                    try await ensureFocusIgnoringMissingWindows(
                        request: FocusIgnoringMissingWindowsRequest(
                            windowID: windowID,
                            applicationName: appIdentifier,
                            windowTitle: self.target.windowTitle
                        ),
                        options: self.focusOptions,
                        services: self.services,
                        logger: self.logger
                    )
                }

                let menuStructure = try await MenuServiceBridge.listMenus(
                    menu: self.services.menu,
                    appIdentifier: appIdentifier
                )
                let filteredMenus = self.includeDisabled ? menuStructure.menus : MenuOutputSupport
                    .filterDisabledMenus(menuStructure.menus)

                if self.jsonOutput {
                    let data = MenuListData(
                        app: menuStructure.application.name,
                        owner_name: menuStructure.application.name,
                        bundle_id: menuStructure.application.bundleIdentifier,
                        menu_structure: MenuOutputSupport.convertMenusToTyped(filteredMenus)
                    )
                    outputSuccessCodable(data: data, logger: self.outputLogger)
                } else {
                    print("Menu structure for \(menuStructure.application.name):")
                    for menu in filteredMenus {
                        MenuOutputSupport.printMenu(menu, indent: 0)
                    }
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

        private func resolveTargetApplicationIdentifier() async throws -> String {
            if let appIdentifier = try self.target.resolveApplicationIdentifierOptional() {
                return appIdentifier
            }

            guard let frontmost = try? await self.services.applications.getFrontmostApplication() else {
                throw ValidationError("No frontmost app found; provide --app or --pid")
            }

            return frontmost.bundleIdentifier ?? frontmost.name
        }
    }

    // MARK: - List All Menu Bar Items

    @MainActor
    struct ListAllSubcommand: OutputFormattable {
        @Flag(help: "Include disabled menu items")
        var includeDisabled = false

        @Flag(help: "Include item frames (pixel positions)")
        var includeFrames = false
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

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                let frontmostMenus = try await MenuServiceBridge.listFrontmostMenus(menu: self.services.menu)
                let menuExtras = try await MenuServiceBridge.listMenuExtras(menu: self.services.menu)

                let filteredMenus = self.includeDisabled ? frontmostMenus.menus : MenuOutputSupport
                    .filterDisabledMenus(frontmostMenus.menus)

                if self.jsonOutput {
                    let statusItems = menuExtras.map { extra in
                        MenuAllResult.StatusItem(
                            type: "status_item",
                            title: extra.title,
                            enabled: true,
                            frame: self.includeFrames ? MenuAllResult.StatusItem.Frame(
                                x: Double(extra.position.x),
                                y: Double(extra.position.y),
                                width: 0,
                                height: 0
                            ) : nil
                        )
                    }

                    let appInfo = MenuAllResult.AppMenuInfo(
                        appName: frontmostMenus.application.name,
                        bundleId: frontmostMenus.application.bundleIdentifier ?? "unknown",
                        pid: frontmostMenus.application.processIdentifier,
                        menus: MenuOutputSupport.convertMenusToTyped(filteredMenus),
                        statusItems: statusItems.isEmpty ? nil : statusItems
                    )

                    let outputData = MenuAllResult(apps: [appInfo])
                    outputSuccessCodable(data: outputData, logger: self.outputLogger)
                } else {
                    print("\n=== \(frontmostMenus.application.name) ===")
                    for menu in filteredMenus {
                        MenuOutputSupport.printMenu(menu, indent: 0)
                    }

                    if !menuExtras.isEmpty {
                        print("\n=== System Menu Extras ===")
                        for extra in menuExtras {
                            print("  \(extra.title)")
                            if self.includeFrames {
                                print("    Position: (\(Int(extra.position.x)), \(Int(extra.position.y)))")
                            }
                        }
                    }
                }

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

struct MenuAllResult: Codable {
    let apps: [AppMenuInfo]

    struct AppMenuInfo: Codable {
        let appName: String
        let bundleId: String
        let pid: Int32
        let menus: [MenuData]
        let statusItems: [StatusItem]?
    }

    struct StatusItem: Codable {
        let type: String
        let title: String
        let enabled: Bool
        let frame: Frame?

        struct Frame: Codable {
            let x: Double
            let y: Double
            let width: Int
            let height: Int
        }
    }
}
