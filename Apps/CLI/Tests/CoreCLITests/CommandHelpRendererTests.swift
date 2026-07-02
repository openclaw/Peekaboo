import Commander
import Testing
@testable import PeekabooCLI

@MainActor
struct CommandHelpRendererTests {
    @Test
    func `option placeholders use public long option spelling`() {
        let help = SampleHelpCommand.helpMessage()

        #expect(help.contains("[script-path]"))
        #expect(help.contains("--action <action>"))
        #expect(help.contains("--file-path <file-path>"))
        #expect(help.contains("--data-base64 <data-base64>"))
        #expect(help.contains("--also-text <also-text>"))
        #expect(help.contains("--log-level <log-level>"))
        #expect(!help.contains("[scriptPath]"))
        #expect(!help.contains("<actionOption>"))
        #expect(!help.contains("<filePath>"))
        #expect(!help.contains("<dataBase64>"))
        #expect(!help.contains("<alsoText>"))
        #expect(!help.contains("<logLevel>"))
    }

    @Test
    func `interaction help describes element IDs as opaque`() {
        for help in [ClickCommand.helpMessage(), MoveCommand.helpMessage()] {
            #expect(help.contains("Opaque element ID"))
            #expect(help.range(of: #"\b[BTMS]\d+\b"#, options: .regularExpression) == nil)
        }
    }
}

private struct SampleHelpCommand: ParsableCommand {
    static var commandDescription: CommandDescription {
        CommandDescription(commandName: "sample-help", abstract: "Sample help command")
    }

    @Option(
        names: [.customShort("a", allowingJoined: false), .customLong("action")],
        help: "Action alias"
    )
    var actionOption: String?

    @Option(name: .long, help: "Path to file")
    var filePath: String?

    @Option(name: .long, help: "Base64 payload")
    var dataBase64: String?

    @Option(name: .long, help: "Companion text")
    var alsoText: String?

    @Argument(help: "Path to script")
    var scriptPath: String?

    @RuntimeStorage private var runtime: CommandRuntime?
    var runtimeOptions = CommandRuntimeOptions()

    mutating func run(using runtime: CommandRuntime) async throws {
        self.runtime = runtime
    }
}
