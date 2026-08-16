import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

extension DockCommand {
    // MARK: - Launch from Dock

    @MainActor
    struct LaunchSubcommand: ConfirmedActionOutputFormattable, ErrorHandlingCommand, OutputFormattable,
    InjectedRuntimeBackedCommand {
        @Argument(help: "Application name in the Dock")
        var app: String

        @Flag(help: "Verify the app is running after launch")
        var verify = false

        @Flag(help: "Confirm activation of the Dock item and its application")
        var foreground = false
        @RuntimeStorage var runtime: CommandRuntime?

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            do {
                guard self.foreground else {
                    throw PreDispatchActionError(
                        message: "dock launch activates its target and requires explicit foreground consent.",
                        code: .VALIDATION_ERROR,
                        hint: "Use --foreground to allow the Dock and target application to come forward.",
                        reason: .foregroundConsentRequired
                    )
                }
                self.resolvedRuntime.beginInteractionMutation()
                let actionResult = try await DockServiceBridge.launchFromDock(
                    dock: self.services.dock,
                    appName: self.app
                )
                let resultTargetIdentity = try validatedSuccessfulActionResult(
                    actionResult,
                    operation: "Dock launch",
                    requiresTarget: self.services.dock is any DockServiceActionResultProviding
                )
                try await withPreservedActionResultOnFailure(
                    actionResult,
                    targetIdentity: resultTargetIdentity,
                    operation: "Dock launch"
                ) {
                    let dockItem = try await DockServiceBridge.findDockItem(
                        dock: self.services.dock,
                        name: self.app
                    )
                    if self.verify {
                        try await self.verifyLaunch(dockItem: dockItem)
                    }
                    let outputOutcome = self.verify
                        ? canonicalActionOutcomeAfterSuccessfulVerification(actionResult.outcome)
                        : actionResult.outcome
                    AutomationEventLogger.log(.dock, "launch app=\(dockItem.title)")

                    if self.jsonOutput {
                        struct DockLaunchResult: Codable {
                            let action: String
                            let app: String
                            let selectedLeafEvidence: [DesktopSelectedLeafEvidence]?
                        }

                        let outputData = DockLaunchResult(
                            action: "dock_launch",
                            app: dockItem.title,
                            selectedLeafEvidence: actionResult.selectedLeafEvidence
                        )
                        outputSuccessCodable(
                            data: outputData,
                            effect: self.verify ? .confirmed : .unverifiable,
                            outcome: outputOutcome,
                            targetIdentity: resultTargetIdentity,
                            logger: self.outputLogger
                        )
                    } else if let outputOutcome {
                        print(ActionOutcomeHumanRenderer.statusLine(for: outputOutcome, operation: "Dock launch"))
                    } else {
                        print("✓ Launched \(dockItem.title) from Dock")
                    }
                }
            } catch let error as DockError {
                handleDockServiceError(error, jsonOutput: self.jsonOutput, logger: self.outputLogger)
                throw ExitCode(1)
            } catch {
                self.handleError(error)
                throw ExitCode(1)
            }
        }

        private func verifyLaunch(dockItem: DockItem) async throws {
            let identifier = dockItem.bundleIdentifier ?? dockItem.title
            let deadline = Date().addingTimeInterval(2.0)
            while Date() < deadline {
                if try await self.services.applications.isApplicationRunning(identifier: identifier) {
                    return
                }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw PeekabooError.operationError(message: "Dock launch verification failed for \(dockItem.title)")
        }
    }
}
