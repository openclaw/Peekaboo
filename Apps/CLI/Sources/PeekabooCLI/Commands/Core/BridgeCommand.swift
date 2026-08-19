import Commander

/// Diagnose Peekaboo Bridge host connectivity and verify signed receipt bundles.
struct BridgeCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "bridge",
        abstract: "Inspect Bridge hosts and verify signed receipts",
        discussion: """
        Peekaboo Bridge lets the CLI run permission-bound operations (Screen Recording, Accessibility,
        and Event Synthesizing) via a host app that already has the needed TCC grants.

        Most automation commands first reuse a healthy Peekaboo daemon, then try a capable Peekaboo.app Bridge host,
        and otherwise start a daemon on demand. Operations that allow local fallback can finally run in the caller.
        Application inventory and launch prefer Peekaboo.app; relaunch and quit require a reusable daemon.
        Claude.app and ClawdBot.app sockets are diagnostic-only unless selected explicitly.

        Examples:
          peekaboo bridge status
          peekaboo bridge status --json
          peekaboo bridge status --verbose
          peekaboo bridge status --bridge-socket ~/Library/Application\\ Support/clawdbot/bridge.sock
          peekaboo bridge status --no-remote
          peekaboo bridge receipt validate --bundle /private/path/receipt.json \\
            --bridge-socket /private/path/bridge.sock --json
        """,
        subcommands: [
            StatusSubcommand.self,
            ReceiptSubcommand.self,
            AgentExecutionTraceSubcommand.self,
        ],
        defaultSubcommand: StatusSubcommand.self,
        showHelpOnEmptyInvocation: true
    )
}

extension BridgeCommand {
    struct ReceiptSubcommand: ParsableCommand {
        static let commandDescription = CommandDescription(
            commandName: "receipt",
            abstract: "Verify exported protocol 1.29 receipt bundles",
            subcommands: [ValidateSubcommand.self],
            showHelpOnEmptyInvocation: true
        )
    }

    @MainActor
    struct StatusSubcommand: OutputFormattable, RuntimeBackedCommand {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "status",
                    abstract: "Report which Bridge host would be used"
                )
            }
        }

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        private var configuration: CommandRuntime.Configuration {
            if let runtime {
                return runtime.configuration
            }
            return self.runtimeOptions.makeConfiguration()
        }

        private var verbose: Bool {
            self.configuration.verbose
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            let report = try await BridgeDiagnostics(logger: self.logger).run(runtimeOptions: self.runtimeOptions)
            if self.jsonOutput {
                outputSuccessCodable(data: report, logger: self.outputLogger)
                return
            }

            self.printHumanReadable(report: report)
        }

        private func printHumanReadable(report: BridgeStatusReport) {
            print("Peekaboo Bridge")
            print("===============")
            print("")
            print("Selected: \(report.selected.humanSummary)")
            let deniedHints = report.bridgeDeniedPermissionsHints
            if !deniedHints.isEmpty {
                print("")
                for hint in deniedHints {
                    print(hint)
                }
            }

            if report.remoteSkipped {
                print("Remote: skipped (\(report.remoteSkipReason ?? "disabled"))")
                return
            }

            let fallbackWarningLines = report.localFallbackWarningLines
            if !fallbackWarningLines.isEmpty {
                print("")
                for line in fallbackWarningLines {
                    print(line)
                }
            }

            guard self.verbose else {
                if report.selected.source == .local {
                    print("")
                    print("Tip: run with --verbose to see remote host probe results.")
                }
                return
            }

            print("")
            print("Client: \(report.client.humanSummary)")
            if report.client.teamIdentifier == nil {
                print("Note: unsigned clients may be rejected by host code-sign checks.")
            }

            print("")
            print("Candidates:")
            for candidate in report.candidates {
                print("- \(candidate.humanSummary)")
                if case let .failure(error) = candidate.result, let hint = error.hint {
                    print("  hint: \(hint)")
                }
            }
        }
    }
}

extension BridgeCommand.StatusSubcommand: AsyncRuntimeCommand {}

@MainActor
extension BridgeCommand.StatusSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_: CommanderBindableValues) throws {
        // No command-specific flags; runtime flags are bound via RuntimeOptionsConfigurable.
    }
}
