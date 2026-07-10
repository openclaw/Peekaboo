import Commander
import PeekabooCore

extension DockCommand {
    // MARK: - List Dock Items

    @MainActor
    struct ListSubcommand: ErrorHandlingCommand, OutputFormattable {
        @Flag(help: "Include separators and spacers")
        var includeAll = false
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
                let dockItems = try await DockServiceBridge.listDockItems(
                    dock: self.services.dock,
                    includeAll: self.includeAll
                )
                AutomationEventLogger.log(
                    .dock,
                    "list count=\(dockItems.count) includeAll=\(self.includeAll)"
                )

                if self.jsonOutput {
                    struct DockListResult: Codable {
                        let dockItems: [DockItemInfo]
                        let dock_items: [DockItemInfo]
                        let count: Int

                        struct DockItemInfo: Codable {
                            let index: Int
                            let title: String
                            let type: String
                            let running: Bool?
                            let bundleId: String?
                        }

                        init(items: [DockItemInfo]) {
                            self.dockItems = items
                            self.dock_items = items
                            self.count = items.count
                        }
                    }

                    let items = dockItems.map { item in
                        DockListResult.DockItemInfo(
                            index: item.index,
                            title: item.title,
                            type: item.itemType.rawValue,
                            running: item.isRunning,
                            bundleId: item.bundleIdentifier
                        )
                    }

                    let outputData = DockListResult(items: items)
                    outputSuccessCodable(data: outputData, logger: self.outputLogger)
                } else {
                    print("Dock items:")
                    for item in dockItems {
                        let runningIndicator = (item.isRunning == true) ? " •" : ""
                        let typeIndicator = item.itemType != .application ? " (\(item.itemType.rawValue))" : ""
                        print("  [\(item.index)] \(item.title)\(typeIndicator)\(runningIndicator)")
                    }
                    print("\nTotal: \(dockItems.count) items")
                }
            } catch let error as DockError {
                handleDockServiceError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            } catch {
                handleGenericError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            }
        }
    }
}
