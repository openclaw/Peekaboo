import Commander
@testable import PeekabooCLI

extension AgentCommand {
    static func parse(_ arguments: [String]) throws -> AgentCommand {
        try AgentExecutionTestParser.parse(arguments)
    }
}

private enum AgentExecutionTestParser {
    static func parse(_ arguments: [String]) throws -> AgentCommand {
        var filtered: [String] = []
        var command = AgentCommand()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--resume": command.resume = true
            case "--resume-session":
                index += 1
                guard index < arguments.count else {
                    throw CommanderBindingError.missingArgument(label: "session-id")
                }
                command.resumeSession = arguments[index]
            case "--list-sessions": command.listSessions = true
            case "--chat": command.chat = true
            default: filtered.append(arguments[index])
            }
            index += 1
        }
        let parsed = try AgentRunSubcommand.parse(filtered)
        command.task = parsed.task
        parsed.options.apply(to: &command)
        command.runtimeOptions = parsed.runtimeOptions
        return command
    }
}
