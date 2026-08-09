import Commander

@available(macOS 14.0, *)
@MainActor
struct ClipboardCommand: ParsableCommand {
    nonisolated(unsafe) static var commandDescription: CommandDescription {
        MainActorCommandDescription.describe {
            CommandDescription(
                commandName: "clipboard",
                abstract: "Read and write the macOS clipboard",
                subcommands: [
                    GetSubcommand.self,
                    SetSubcommand.self,
                    ClearSubcommand.self,
                    SaveSubcommand.self,
                    RestoreSubcommand.self,
                ],
                showHelpOnEmptyInvocation: true
            )
        }
    }
}

@available(macOS 14.0, *)
extension ClipboardCommand {
    @MainActor
    struct GetSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(commandName: "get", abstract: "Read the clipboard")

        @Option(name: .long, help: "Preferred UTI when reading clipboard")
        var prefer: String?

        @Option(name: .shortAndLong, help: "Output path for binary reads ('-' for stdout)")
        var output: String?

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            var command = ClipboardActionCommand()
            command.action = "get"
            command.prefer = self.prefer
            command.output = self.output
            command.runtimeOptions = self.runtimeOptions
            try await command.run(using: runtime)
        }
    }

    @MainActor
    struct SetSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(commandName: "set", abstract: "Write the clipboard")

        @Option(name: .long, help: "Text to set")
        var text: String?

        @Option(name: .long, help: "Path to file to copy")
        var filePath: String?

        @Option(name: .long, help: "Base64 data to copy")
        var dataBase64: String?

        @Option(name: .long, help: "UTI for base64 payload or to force type")
        var uti: String?

        @Option(name: .long, help: "Optional plain-text companion when setting binary")
        var alsoText: String?

        @Flag(name: .long, help: "Allow payloads larger than 10 MB")
        var allowLarge = false

        @Flag(name: .long, help: "Read back clipboard after setting and validate contents")
        var verify = false

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            var command = ClipboardActionCommand()
            command.action = "set"
            command.text = self.text
            command.filePath = self.filePath
            command.dataBase64 = self.dataBase64
            command.uti = self.uti
            command.alsoText = self.alsoText
            command.allowLarge = self.allowLarge
            command.verify = self.verify
            command.runtimeOptions = self.runtimeOptions
            try await command.run(using: runtime)
        }
    }

    @MainActor
    struct ClearSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(commandName: "clear", abstract: "Empty the clipboard")
        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            var command = ClipboardActionCommand()
            command.action = "clear"
            command.runtimeOptions = self.runtimeOptions
            try await command.run(using: runtime)
        }
    }

    @MainActor
    struct SaveSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "save",
            abstract: "Save the clipboard to a named slot"
        )

        @Option(name: .long, help: "Slot name (default: 0)")
        var slot: String?

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            var command = ClipboardActionCommand()
            command.action = "save"
            command.slot = self.slot
            command.runtimeOptions = self.runtimeOptions
            try await command.run(using: runtime)
        }
    }

    @MainActor
    struct RestoreSubcommand: RuntimeBackedCommand {
        static let commandDescription = CommandDescription(
            commandName: "restore",
            abstract: "Restore the clipboard from a named slot"
        )

        @Option(name: .long, help: "Slot name (default: 0)")
        var slot: String?

        @RuntimeStorage var runtime: CommandRuntime?
        var runtimeOptions = CommandRuntimeOptions()

        mutating func run(using runtime: CommandRuntime) async throws {
            var command = ClipboardActionCommand()
            command.action = "restore"
            command.slot = self.slot
            command.runtimeOptions = self.runtimeOptions
            try await command.run(using: runtime)
        }
    }
}

extension ClipboardCommand.GetSubcommand: AsyncRuntimeCommand {}
extension ClipboardCommand.SetSubcommand: AsyncRuntimeCommand {}
extension ClipboardCommand.ClearSubcommand: AsyncRuntimeCommand {}
extension ClipboardCommand.SaveSubcommand: AsyncRuntimeCommand {}
extension ClipboardCommand.RestoreSubcommand: AsyncRuntimeCommand {}

@MainActor
extension ClipboardCommand.GetSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.prefer = values.singleOption("prefer")
        self.output = values.singleOption("output")
    }
}

@MainActor
extension ClipboardCommand.SetSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.text = values.singleOption("text")
        self.filePath = values.singleOption("filePath")
        self.dataBase64 = values.singleOption("dataBase64")
        self.uti = values.singleOption("uti")
        self.alsoText = values.singleOption("alsoText")
        self.allowLarge = values.flag("allowLarge")
        self.verify = values.flag("verify")
    }
}

@MainActor
extension ClipboardCommand.ClearSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        _ = values
    }
}

@MainActor
extension ClipboardCommand.SaveSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.slot = values.singleOption("slot")
    }
}

@MainActor
extension ClipboardCommand.RestoreSubcommand: CommanderBindableCommand {
    mutating func applyCommanderValues(_ values: CommanderBindableValues) throws {
        self.slot = values.singleOption("slot")
    }
}
