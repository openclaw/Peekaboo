import Commander

@available(macOS 14.0, *)
struct AgentExecutionOptions: CommanderParsable {
    @Flag(name: .customLong("debug-terminal"), help: "Show detailed terminal detection info")
    var debugTerminal = false

    @Flag(names: [.short("q"), .long], help: "Quiet mode - only show final result")
    var quiet = false

    @Flag(name: .long, help: "Validate and echo the task without calling a model or tools")
    var dryRun = false

    @Option(name: .long, help: "Maximum model turns before failing (1-100, default 100)")
    var maxSteps: Int?

    @Option(name: .long, help: "Queue mode for queued prompts: one-at-a-time (default) or all")
    var queueMode: String?

    @Option(
        name: .long,
        help: """
        AI model to use (for example: gpt-5.6, claude-opus-5, claude-fable-5, claude-sonnet-5, \
        gemini-3.5-flash, grok-4.3, minimax-m2.7, minimax-cn/m2.7, \
        ollama/<model>, lmstudio/<model>, or <custom-provider>/<model>)
        """
    )
    var model: String?

    @Flag(name: .long, help: "Run without saving a resumable session")
    var noCache = false

    @Flag(
        name: .customLong("allow-foreground"),
        help: "Authorize foreground/global UI for this run (new sessions persist it as an immutable maximum)"
    )
    var allowForeground = false

    @Flag(name: .long, help: "Enable audio input mode (record from microphone)")
    var audio = false

    @Option(name: .long, help: "Audio input file path (instead of microphone)")
    var audioFile: String?

    @Flag(name: .long, help: "Force simple output mode (no colors or rich formatting)")
    var simple = false

    @Flag(name: .long, help: "Disable colors in output")
    var noColor = false

    init() {}

    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.debugTerminal = values.flag("debugTerminal")
        self.quiet = values.flag("quiet")
        self.dryRun = values.flag("dryRun")
        self.maxSteps = try values.decodeOption("maxSteps", as: Int.self)
        self.queueMode = values.singleOption("queueMode")
        self.model = values.singleOption("model")
        self.noCache = values.flag("noCache")
        self.allowForeground = values.flag("allowForeground")
        self.audio = values.flag("audio")
        self.audioFile = values.singleOption("audioFile")
        self.simple = values.flag("simple")
        self.noColor = values.flag("noColor")
    }

    func apply(to command: inout AgentCommand) {
        command.debugTerminal = self.debugTerminal
        command.quiet = self.quiet
        command.dryRun = self.dryRun
        command.maxSteps = self.maxSteps
        command.queueMode = self.queueMode
        command.model = self.model
        command.noCache = self.noCache
        command.allowForeground = self.allowForeground
        command.audio = self.audio
        command.audioFile = self.audioFile
        command.simple = self.simple
        command.noColor = self.noColor
    }
}

@available(macOS 14.0, *)
struct AgentRootCommand: ParsableCommand {
    static let commandDescription = CommandDescription(
        commandName: "agent",
        abstract: "Execute complex automation tasks using the Peekaboo agent",
        discussion: """
        Run a one-shot task, resume a saved session, list sessions, or start interactive chat.
        `peekaboo agent \"task\"` is shorthand for `peekaboo agent run \"task\"`.
        Agent UI authority is background-only unless the human passes `--allow-foreground` for that invocation.
        """,
        subcommands: [
            AgentRunSubcommand.self,
            AgentResumeSubcommand.self,
            AgentSessionsSubcommand.self,
            AgentChatSubcommand.self,
        ],
        defaultSubcommand: AgentRunSubcommand.self
    )
}

@available(macOS 14.0, *)
struct AgentRunSubcommand: RuntimeBackedCommand {
    static let commandDescription = CommandDescription(
        commandName: "run",
        abstract: "Run a one-shot automation task",
        discussion: """
        New sessions are background-only by default. `--allow-foreground` authorizes foreground/global UI for this
        invocation and stores it only as the session's immutable maximum; it never exposes the Shell tool.
        """
    )

    @Argument(help: "Natural-language task to perform")
    var task: String?

    @OptionGroup var options: AgentExecutionOptions
    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = AgentRunSubcommand.localRuntimeOptions()

    mutating func run(using runtime: CommandRuntime) async throws {
        var command = self.makeAgentCommand()
        try await command.run(using: runtime)
    }

    private func makeAgentCommand() -> AgentCommand {
        var command = AgentCommand()
        command.task = self.task
        self.options.apply(to: &command)
        command.runtimeOptions = self.runtimeOptions
        return command
    }

    func validateBeforeRuntime() throws {
        do {
            try self.makeAgentCommand().validateDryRunRequest()
        } catch {
            throw ValidationError(error.localizedDescription)
        }
    }
}

@available(macOS 14.0, *)
struct AgentResumeSubcommand: RuntimeBackedCommand {
    static let commandDescription = CommandDescription(
        commandName: "resume",
        abstract: "Resume the most recent or a specified session",
        discussion: """
        Copy the exact full ID from `peekaboo agent sessions`. Every resumed process invocation defaults to
        background-only; pass `--allow-foreground` again only when the stored maximum permits it. Use one process per
        session: if another run is using the session, wait for it to finish and retry the same full ID.
        """
    )

    @Argument(help: "Session ID (defaults to the most recent session)")
    var sessionId: String?

    @OptionGroup var options: AgentExecutionOptions
    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = AgentRunSubcommand.localRuntimeOptions()

    mutating func run(using runtime: CommandRuntime) async throws {
        var command = AgentCommand()
        if let sessionId = self.sessionId {
            command.resumeSession = sessionId
        } else {
            command.resume = true
        }
        self.options.apply(to: &command)
        command.runtimeOptions = self.runtimeOptions
        try await command.run(using: runtime)
    }
}

@available(macOS 14.0, *)
struct AgentSessionsSubcommand: RuntimeBackedCommand {
    static let commandDescription = CommandDescription(
        commandName: "sessions",
        abstract: "List saved agent sessions",
        discussion: """
        Shows each full resumable ID, task, lifecycle status, and stored policy maximum. `active` means the saved
        session is resumable; it does not mean a process is currently running or prove that the session is not busy.
        """
    )

    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = AgentRunSubcommand.localRuntimeOptions()

    mutating func run(using runtime: CommandRuntime) async throws {
        var command = AgentCommand()
        command.listSessions = true
        command.runtimeOptions = self.runtimeOptions
        try await command.run(using: runtime)
    }
}

@available(macOS 14.0, *)
struct AgentChatSubcommand: RuntimeBackedCommand {
    static let commandDescription = CommandDescription(
        commandName: "chat",
        abstract: "Start an interactive agent chat"
    )

    @Argument(help: "Optional initial prompt")
    var task: String?

    @OptionGroup var options: AgentExecutionOptions
    @RuntimeStorage var runtime: CommandRuntime?
    var runtimeOptions = AgentRunSubcommand.localRuntimeOptions()

    mutating func run(using runtime: CommandRuntime) async throws {
        var command = AgentCommand()
        command.task = self.task
        command.chat = true
        self.options.apply(to: &command)
        command.runtimeOptions = self.runtimeOptions
        try await command.run(using: runtime)
    }
}

@available(macOS 14.0, *)
extension AgentRunSubcommand {
    fileprivate static func localRuntimeOptions() -> CommandRuntimeOptions {
        var options = CommandRuntimeOptions()
        options.preferRemote = false
        return options
    }
}

extension AgentRunSubcommand: AsyncRuntimeCommand {}
extension AgentRunSubcommand: PreRuntimeValidatingCommand {}
extension AgentResumeSubcommand: AsyncRuntimeCommand {}
extension AgentSessionsSubcommand: AsyncRuntimeCommand {}
extension AgentChatSubcommand: AsyncRuntimeCommand {}

@MainActor
extension AgentRunSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.task = try values.decodeOptionalPositional(0, label: "task")
        try self.options.applyCommanderValues(values)
    }
}

@MainActor
extension AgentResumeSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.sessionId = try values.decodeOptionalPositional(0, label: "sessionId")
        try self.options.applyCommanderValues(values)
    }
}

@MainActor
extension AgentSessionsSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@MainActor
extension AgentChatSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.task = try values.decodeOptionalPositional(0, label: "task")
        try self.options.applyCommanderValues(values)
    }
}
