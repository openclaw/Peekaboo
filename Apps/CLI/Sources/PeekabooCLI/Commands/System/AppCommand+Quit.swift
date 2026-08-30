import Commander
import Foundation
import PeekabooCore
import PeekabooFoundation

@MainActor
extension AppCommand {
    // MARK: - Quit Application

    @MainActor
    struct QuitSubcommand: InjectedRuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "quit",
            abstract: "Quit one or more applications"
        )

        @Option(help: "Application to quit")
        var app: String?

        @Option(name: .long, help: "Target application by process ID")
        var pid: Int32?

        @Option(
            name: .long,
            help: "Require this process-start identity (cleanup safety; requires --pid)"
        )
        var expectedProcessStartIdentity: CLIProcessStartIdentity?

        @Flag(help: "Quit all applications")
        var all = false

        @Option(help: "Comma-separated list of apps to exclude when using --all")
        var except: String?

        @Flag(help: "Force quit (doesn't save changes)")
        var force = false
        @RuntimeStorage var runtime: CommandRuntime?

        /// Resolve the targeted applications, issue quit or force-quit requests, and report results per app.
        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            let logger = self.logger

            do {
                try self.validateArguments()
                let quitApps = try await self.resolveQuitTargets()

                var results: [AppQuitInfo] = []
                var actionOutcomes: [DesktopActionOutcome?] = []
                var caughtFailureHints: [String?] = []
                var caughtFailureReceipts: [DesktopActionTargetReceipt?] = []
                var wasCancelled = false
                var cancellationInterruptedAttempt = false
                for target in quitApps {
                    if Task.isCancelled {
                        guard !results.isEmpty else { throw CancellationError() }
                        wasCancelled = true
                        break
                    }
                    if target.pid == self.resolvedRuntime.selectedRemoteHostProcessIdentifier {
                        throw PeekabooError.invalidInput(
                            "Cannot quit the daemon host executing this command; use a different runtime host"
                        )
                    }
                    self.resolvedRuntime.beginInteractionMutation()
                    let success: Bool
                    var caughtFailureHint: String?
                    var caughtFailureReceipt: DesktopActionTargetReceipt?
                    do {
                        let actionResult = try await ApplicationServiceBridge.quitApplication(
                            applications: self.services.applications,
                            request: ApplicationQuitRequest(
                                identifier: target.identifier,
                                force: self.force,
                                expectedIdentity: target.expectedIdentity
                            )
                        )
                        success = actionResult.payload
                        actionOutcomes.append(actionResult.outcome)
                    } catch is CancellationError {
                        wasCancelled = true
                        cancellationInterruptedAttempt = true
                        break
                    } catch let failure as DesktopActionFailure {
                        success = false
                        actionOutcomes.append(failure.outcome)
                        caughtFailureHint = failure.hint
                        caughtFailureReceipt = failure.targetReceipt
                    } catch {
                        // Preserve legacy per-app failure reporting for services without canonical receipts.
                        success = false
                        actionOutcomes.append(nil)
                    }
                    results.append(AppQuitInfo(
                        app_name: target.name,
                        pid: target.pid,
                        process_start_identity_decimal: String(target.expectedIdentity.processStartIdentity),
                        success: success
                    ))
                    caughtFailureHints.append(caughtFailureHint)
                    caughtFailureReceipts.append(caughtFailureReceipt)
                }

                let data = QuitResult(
                    action: "quit",
                    force: force,
                    results: results
                )
                let allSucceeded = !wasCancelled && results.allSatisfy(\.success)
                let succeededCount = results.count(where: \.success)
                let batchOutcome = Self.resolveBatchOutcome(
                    actionOutcomes: actionOutcomes,
                    progress: BatchProgress(
                        succeededCount: succeededCount,
                        attemptedCount: results.count,
                        plannedCount: quitApps.count,
                        wasCancelled: wasCancelled,
                        cancellationInterruptedAttempt: cancellationInterruptedAttempt
                    )
                )
                let aggregateOutcome = batchOutcome.outcome
                let singleFailureHint = results.count == 1 ? caughtFailureHints[0] : nil
                let singleFailureReceipt = results.count == 1 ? caughtFailureReceipts[0] : nil
                let failureHint: String? = if wasCancelled {
                    "The quit batch was cancelled; inspect completed targets before retrying."
                } else if allSucceeded {
                    nil
                } else {
                    Self.failureHint(
                        force: self.force,
                        aggregateOutcome: aggregateOutcome,
                        singleFailureHint: singleFailureHint
                    )
                }

                for result in results where !result.success {
                    let action = self.force ? "Force quit" : "Quit"
                    let recovery = failureHint.map { " \($0)" } ?? ""
                    logger.debug("\(action) failed for \(result.app_name) (PID: \(result.pid)).\(recovery)")
                }

                if self.jsonOutput {
                    let response = ResultEnvelope(
                        success: allSucceeded,
                        effect: batchOutcome.interruptionEffect ?? aggregateOutcome?.effect ??
                            (allSucceeded ? .confirmed :
                                (wasCancelled || succeededCount > 0 ? .partial : .suspectedNoop)),
                        outcome: aggregateOutcome?.projection,
                        data: data,
                        target_receipt: singleFailureReceipt,
                        messages: nil,
                        debug_logs: self.outputLogger.getDebugLogs(),
                        error: allSucceeded ? nil : ErrorInfo(
                            message: wasCancelled
                                ? "Quit batch cancelled after \(results.count) of \(quitApps.count) target(s)."
                                : "Failed to quit \(results.count - succeededCount) application(s).",
                            code: .INTERACTION_FAILED,
                            hint: failureHint,
                            retrySafe: aggregateOutcome.map { $0.retrySafety == .safe },
                            mutationDispatched: aggregateOutcome.map(\.dispatchState.mutationDispatched)
                        )
                    )
                    outputJSONCodable(response, logger: self.outputLogger)
                } else {
                    for result in results {
                        if result.success {
                            print("✓ Quit \(result.app_name)")
                        } else {
                            print("✗ Failed to quit \(result.app_name) (PID: \(result.pid))")
                        }
                    }
                    if wasCancelled {
                        print("✗ Quit batch cancelled after \(results.count) of \(quitApps.count) targets")
                    }
                    if let failureHint {
                        print("  💡 Tip: \(failureHint)")
                    }
                }
                for result in results {
                    AutomationEventLogger.log(
                        .app,
                        "quit app=\(result.app_name) pid=\(result.pid) success=\(result.success) force=\(self.force)"
                    )
                }
                if !allSucceeded {
                    throw ExitCode.failure
                }

            } catch let exitCode as ExitCode {
                throw exitCode
            } catch {
                handleError(error)
                throw ExitCode(1)
            }
        }

        private struct AppQuitInfo: Codable {
            let app_name: String
            let pid: Int32
            let process_start_identity_decimal: String
            let success: Bool
        }

        private struct QuitResult: Codable {
            let action: String
            let force: Bool
            let results: [AppQuitInfo]
        }

        private struct BatchOutcome {
            let outcome: DesktopActionOutcome?
            let interruptionEffect: DesktopActionOutcome.Effect?
        }

        private struct BatchProgress {
            let succeededCount: Int
            let attemptedCount: Int
            let plannedCount: Int
            let wasCancelled: Bool
            let cancellationInterruptedAttempt: Bool
        }

        private static func resolveBatchOutcome(
            actionOutcomes: [DesktopActionOutcome?],
            progress: BatchProgress
        ) -> BatchOutcome {
            if progress.wasCancelled,
               let interruption = DesktopActionSequenceAccumulator.interruptedBatch(
                   completedOutcomes: actionOutcomes,
                   succeededCount: progress.succeededCount,
                   attemptedCount: progress.attemptedCount,
                   plannedCount: progress.plannedCount,
                   inFlightAttemptMayHaveDispatched: progress.cancellationInterruptedAttempt
               ) {
                return BatchOutcome(outcome: interruption.outcome, interruptionEffect: interruption.effect)
            }
            return BatchOutcome(
                outcome: DesktopActionSequenceAccumulator.completedBatch(
                    outcomes: actionOutcomes,
                    succeededCount: progress.succeededCount,
                    attemptedCount: progress.attemptedCount
                ),
                interruptionEffect: nil
            )
        }

        private func validateArguments() throws {
            if self.all {
                guard self.app == nil, self.pid == nil, self.expectedProcessStartIdentity == nil else {
                    throw ValidationError(
                        "Cannot combine --all with --app, --pid, or --expected-process-start-identity"
                    )
                }
                return
            }
            if let except = self.except,
               !except.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--except requires --all")
            }
            if self.app != nil, self.pid != nil {
                throw ValidationError("Cannot combine --app with --pid")
            }
            if self.expectedProcessStartIdentity != nil, self.pid == nil {
                throw ValidationError("--expected-process-start-identity requires --pid")
            }
            if self.app == nil, self.pid == nil {
                throw ValidationError("Either --app, --pid, or --all must be specified")
            }
        }

        private static func failureHint(
            force: Bool,
            aggregateOutcome: DesktopActionOutcome?,
            singleFailureHint: String?
        ) -> String? {
            let canonicalPlaceholder = "Follow the canonical escalation metadata before deciding whether to retry."
            if let singleFailureHint,
               !singleFailureHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               singleFailureHint != canonicalPlaceholder {
                return singleFailureHint
            }
            guard let aggregateOutcome else {
                return "Perform a fresh observation of the targeted application state before taking another action."
            }
            if aggregateOutcome.state == .refused {
                if aggregateOutcome.refusalReason == .targetUnavailable {
                    return "Refresh the application inventory and select the current target before retrying."
                }
                return switch aggregateOutcome.escalation {
                case .correctRequest:
                    "Correct the quit request before retrying."
                case .grantPermission:
                    "Grant the required permission before retrying."
                case .refreshTarget:
                    "Refresh the targeted application state before retrying."
                case .updateRuntime:
                    "Update or select a compatible runtime before retrying."
                case .reconnectSession:
                    "Reconnect the Bridge session before retrying."
                case .recoverSideEffect, .observeBeforeRetry:
                    "Perform a fresh observation of the targeted application state before taking another action."
                case .none:
                    "Review the refusal and correct the quit request before retrying."
                }
            }
            guard aggregateOutcome.retrySafety == .safe else {
                return "Perform a fresh observation of the targeted application state before taking another action."
            }
            guard aggregateOutcome.state == .suspectedNoop, !force else {
                return nil
            }
            return "Try --force to force quit."
        }

        private func resolveQuitTargets() async throws -> [AppQuitTarget] {
            if self.all {
                let excluded = Set((self.except ?? "").split(separator: ",")
                    .map { String($0).trimmingCharacters(in: .whitespaces) })
                let systemApps = Set(["Finder", "Dock", "SystemUIServer", "WindowServer"])
                return try await self.services.applications.listApplications().data.applications.compactMap { app in
                    guard app.isEligibleForBulkQuit,
                          !systemApps.contains(app.name),
                          !excluded.contains(app.name) else { return nil }
                    return try AppQuitTarget(appInfo: app)
                }
            }
            if let appName = self.app {
                let appInfo = try await resolveApplicationForMutation(appName, services: self.services)
                return try [AppQuitTarget(appInfo: appInfo)]
            }
            guard let pid = self.pid else {
                throw ValidationError("Either --app, --pid, or --all must be specified")
            }
            if let processStartIdentity = self.expectedProcessStartIdentity {
                return [AppQuitTarget(
                    processIdentifier: pid,
                    processStartIdentity: processStartIdentity.value
                )]
            }
            let appInfo = try await self.services.applications.findApplication(identifier: "PID:\(pid)")
            return try [AppQuitTarget(appInfo: appInfo)]
        }
    }
}

private struct AppQuitTarget {
    let name: String
    let pid: Int32
    let identifier: String
    let expectedIdentity: ApplicationProcessIdentity

    init(appInfo: ServiceApplicationInfo) throws {
        guard let processIdentity = appInfo.processIdentity else {
            throw PeekabooError.commandFailed(
                "Application selection did not include a stable process-generation identity for \(appInfo.name)"
            )
        }
        self.name = appInfo.name
        self.pid = appInfo.processIdentifier
        self.identifier = "PID:\(appInfo.processIdentifier)"
        self.expectedIdentity = processIdentity
    }

    init(processIdentifier: Int32, processStartIdentity: UInt64) {
        self.name = "PID \(processIdentifier)"
        self.pid = processIdentifier
        self.identifier = "PID:\(processIdentifier)"
        self.expectedIdentity = ApplicationProcessIdentity(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity
        )
    }
}

extension AppCommand.QuitSubcommand: AsyncRuntimeCommand, ConfirmedActionOutputFormattable, ErrorHandlingCommand,
    OutputFormattable,
    ApplicationResolvable,
    ApplicationResolver {}

@MainActor
extension AppCommand.QuitSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.app = try AppCommand.resolveAppArgument(values, optionLabel: "app")
        self.pid = try values.decodeOption("pid", as: Int32.self)
        self.expectedProcessStartIdentity = try values.decodeOption(
            "expectedProcessStartIdentity",
            as: CLIProcessStartIdentity.self
        )
        self.all = values.flag("all")
        self.except = values.singleOption("except")
        self.force = values.flag("force")
    }
}
