import Commander
import PeekabooCore

extension DockCommand {
    // MARK: - Hide Dock

    @MainActor
    struct HideSubcommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @Flag(help: "Required explicit foreground consent for changing shared Dock visibility")
        var foreground = false
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.requireForegroundConsent()
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await DockServiceBridge.hideDock(dock: self.services.dock)
                try validateSuccessfulActionOutcome(
                    actionResult.outcome,
                    targetIdentity: nil,
                    operation: "Dock hide"
                )
                AutomationEventLogger.log(.dock, "hide")

                if self.jsonOutput {
                    struct DockHideResult: Codable { let action: String }
                    outputSuccessCodable(
                        data: DockHideResult(action: "dock_hide"),
                        effect: .confirmed,
                        outcome: actionResult.outcome,
                        logger: self.outputLogger
                    )
                } else if let outcome = actionResult.outcome {
                    print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Dock hide"))
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

        func requireForegroundConsent() throws {
            guard self.foreground else {
                throw PreDispatchActionError(
                    message: "Dock hide changes shared desktop UI and requires explicit foreground consent.",
                    code: .VALIDATION_ERROR,
                    hint: "Use --foreground only when changing the user's Dock visibility is intentional.",
                    reason: .foregroundConsentRequired
                )
            }
        }
    }

    // MARK: - Show Dock

    @MainActor
    struct ShowSubcommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @Flag(help: "Required explicit foreground consent for changing shared Dock visibility")
        var foreground = false
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                try self.requireForegroundConsent()
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await DockServiceBridge.showDock(dock: self.services.dock)
                try validateSuccessfulActionOutcome(
                    actionResult.outcome,
                    targetIdentity: nil,
                    operation: "Dock show"
                )
                AutomationEventLogger.log(.dock, "show")

                if self.jsonOutput {
                    struct DockShowResult: Codable { let action: String }
                    outputSuccessCodable(
                        data: DockShowResult(action: "dock_show"),
                        effect: .confirmed,
                        outcome: actionResult.outcome,
                        logger: self.outputLogger
                    )
                } else if let outcome = actionResult.outcome {
                    print(ActionOutcomeHumanRenderer.statusLine(for: outcome, operation: "Dock show"))
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

        func requireForegroundConsent() throws {
            guard self.foreground else {
                throw PreDispatchActionError(
                    message: "Dock show changes shared desktop UI and requires explicit foreground consent.",
                    code: .VALIDATION_ERROR,
                    hint: "Use --foreground only when changing the user's Dock visibility is intentional.",
                    reason: .foregroundConsentRequired
                )
            }
        }
    }
}
