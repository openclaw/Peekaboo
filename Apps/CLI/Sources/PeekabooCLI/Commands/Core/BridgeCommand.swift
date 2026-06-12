import Commander

/// Diagnose Peekaboo Bridge host connectivity and resolution.
struct BridgeCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "bridge",
        abstract: "Inspect Peekaboo Bridge host connectivity",
        discussion: """
        Peekaboo Bridge lets the CLI run permission-bound operations (Screen Recording, Accessibility,
        AppleScript) via a host app that already has the needed TCC grants.

        By default, automation commands use the dedicated Peekaboo daemon and fall back to local execution.
        Peekaboo.app, Claude.app, and ClawdBot.app sockets are shown for diagnostics and can be selected explicitly.

        Examples:
          peekaboo bridge status
          peekaboo bridge status --json
          peekaboo bridge status --verbose
          peekaboo bridge status --bridge-socket ~/Library/Application\\ Support/clawdbot/bridge.sock
          peekaboo bridge status --no-remote
        """,
        subcommands: [
            StatusSubcommand.self
        ],
        defaultSubcommand: StatusSubcommand.self,
        showHelpOnEmptyInvocation: true
    )
}

extension BridgeCommand {
    @MainActor
    struct StatusSubcommand: OutputFormattable, RuntimeOptionsConfigurable {
        nonisolated(unsafe) static var commandDescription: CommandDescription {
            MainActorCommandDescription.describe {
                CommandDescription(
                    commandName: "status",
                    abstract: "Report which Bridge host would be used"
                )
            }
        }

        @RuntimeStorage private var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        private var resolvedRuntime: CommandRuntime {
            guard let runtime else {
                preconditionFailure("CommandRuntime must be configured before accessing runtime resources")
            }
            return runtime
        }

        private var configuration: CommandRuntime.Configuration {
            if let runtime {
                return runtime.configuration
            }
            return self.runtimeOptions.makeConfiguration()
        }

        private var logger: Logger {
            self.resolvedRuntime.logger
        }

        var outputLogger: Logger {
            self.logger
        }

        var jsonOutput: Bool {
            self.configuration.jsonOutput
        }

        private var verbose: Bool {
            self.configuration.verbose
        }

        @MainActor
        mutating func run(using runtime: CommandRuntime) async throws {
            self.runtime = runtime
            self.logger.setJsonOutputMode(self.jsonOutput)

            let report = await BridgeDiagnostics(logger: self.logger).run(runtimeOptions: self.runtimeOptions)
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
            if let hint = report.bridgeScreenRecordingHint {
                print("")
                print(hint)
            }

            if report.remoteSkipped {
                print("Remote: skipped (\(report.remoteSkipReason ?? "disabled"))")
                return
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
