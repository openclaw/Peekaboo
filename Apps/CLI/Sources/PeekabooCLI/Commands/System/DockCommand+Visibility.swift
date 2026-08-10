import Commander
import PeekabooCore

extension DockCommand {
    // MARK: - Hide Dock

    @MainActor
    struct HideSubcommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                self.resolvedRuntime.beginInteractionMutation()
                try await DockServiceBridge.hideDock(dock: self.services.dock)
                AutomationEventLogger.log(.dock, "hide")

                if self.jsonOutput {
                    struct DockHideResult: Codable { let action: String }
                    outputSuccessCodable(
                        data: DockHideResult(action: "dock_hide"),
                        effect: .confirmed,
                        logger: self.outputLogger
                    )
                } else {
                    print("✓ Dock hidden")
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

    // MARK: - Show Dock

    @MainActor
    struct ShowSubcommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                self.resolvedRuntime.beginInteractionMutation()
                try await DockServiceBridge.showDock(dock: self.services.dock)
                AutomationEventLogger.log(.dock, "show")

                if self.jsonOutput {
                    struct DockShowResult: Codable { let action: String }
                    outputSuccessCodable(
                        data: DockShowResult(action: "dock_show"),
                        effect: .confirmed,
                        logger: self.outputLogger
                    )
                } else {
                    print("✓ Dock shown")
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
