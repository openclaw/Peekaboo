import Commander
import Foundation
import PeekabooFoundation

@MainActor

struct CommanderCommand: OutputFormattable, RuntimeBackedCommand {
    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    static var commandDescription: CommandDescription {
        CommandDescription(
            commandName: "commander",
            abstract: "Commander diagnostics (experimental)",
            discussion: "Inspect the upcoming Commander parser state."
        )
    }

    @MainActor
    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
        self.logger.setJsonOutputMode(self.jsonOutput)

        let summaries = CommanderRegistryBuilder.buildCommandSummaries()
        let outputStruct = CommanderDiagnostics(commands: summaries)
        CommanderDiagnosticsReporter(runtime: runtime).report(outputStruct)
    }
}

struct CommanderDiagnostics: Codable {
    let commands: [CommanderCommandSummary]
}

@MainActor
struct CommanderDiagnosticsReporter {
    let runtime: CommandRuntime

    func report(_ diagnostics: CommanderDiagnostics) {
        if self.runtime.configuration.jsonOutput {
            outputSuccessCodable(data: diagnostics, logger: self.runtime.logger)
        } else {
            for command in diagnostics.commands {
                self.runtime.logger.info("\(command.name): \(command.abstract)")
                for option in command.options {
                    let help = option.help ?? "No description provided"
                    self.runtime.logger.verbose(
                        "Option: \(option.names.joined(separator: ", ")) -- \(help)",
                        category: "Commander"
                    )
                }
            }
        }
    }
}

@MainActor
extension CommanderCommand: ParsableCommand {}
extension CommanderCommand: AsyncRuntimeCommand {}

extension CommanderCommand: CommanderSignatureProviding {
    static func commanderSignature() -> CommandSignature {
        CommandSignature()
    }
}

@MainActor
extension CommanderCommand: CommanderBindableCommand {
    /// Runtime flags are handled by the shared binder; this diagnostics command has no command-specific arguments.
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}
