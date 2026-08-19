import Commander

/// Marks leaf commands whose empty invocation is missing required semantic input.
///
/// These commands still render discovery-oriented help, but the invocation is invalid usage rather than a
/// successful help request. Explicit `--help` remains the successful help path.
@MainActor
protocol CommanderRejectsEmptyInvocation {}

extension TypeCommand: CommanderRejectsEmptyInvocation {}
extension PressCommand: CommanderRejectsEmptyInvocation {}
extension ActionCommand: CommanderRejectsEmptyInvocation {}
extension SetValueCommand: CommanderRejectsEmptyInvocation {}
extension ClickCommand: CommanderRejectsEmptyInvocation {}

enum CommanderEmptyInvocationPolicy {
    @MainActor
    static func error(for descriptor: CommanderCommandDescriptor) -> CommanderUsageError? {
        guard descriptor.type is any CommanderRejectsEmptyInvocation.Type else { return nil }
        let command = descriptor.metadata.name
        return CommanderUsageError(
            message: "Command 'peekaboo \(command)' requires command input; " +
                "run 'peekaboo \(command) --help' for usage."
        )
    }
}
