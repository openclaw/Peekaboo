import Commander

@MainActor
extension AgentCommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.task = try values.decodeOptionalPositional(0, label: "task")
        self.debugTerminal = values.flag("debugTerminal")
        self.quiet = values.flag("quiet")
        self.dryRun = values.flag("dryRun")
        if let steps: Int = try values.decodeOption("maxSteps", as: Int.self) {
            self.maxSteps = steps
        }
        self.model = values.singleOption("model")
        self.resume = values.flag("resume")
        self.resumeSession = values.singleOption("resumeSession")
        self.listSessions = values.flag("listSessions")
        self.noCache = values.flag("noCache")
        self.audio = values.flag("audio")
        self.audioFile = values.singleOption("audioFile")
        self.simple = values.flag("simple")
        self.noColor = values.flag("noColor")
        self.chat = values.flag("chat")
    }
}
