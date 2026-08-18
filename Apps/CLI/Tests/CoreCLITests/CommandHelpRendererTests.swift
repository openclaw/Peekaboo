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

    @Test
    func `V4 generated help uses canonical commands and explicit duration units`() {
        let help = [
            AppCommand.helpMessage(),
            AppCommand.ListSubcommand.helpMessage(),
            WindowCommand.WindowListSubcommand.helpMessage(),
            ClickCommand.helpMessage(),
            DragCommand.helpMessage(),
            TypeCommand.helpMessage(),
        ].joined(separator: "\n")

        for removed in [
            "peekaboo image",
            "peekaboo list apps",
            "peekaboo list windows",
            "peekaboo hotkey",
            "peekaboo inspect-ui",
            "peekaboo perform-action",
            "peekaboo swipe",
        ] {
            #expect(!help.contains(removed), "Generated help contains removed CLI form: \(removed)")
        }
        #expect(help.contains("--wait 3s"))
        #expect(help.contains("--duration 2s"))
        #expect(help.contains("--delay 50ms"))
    }

    @Test
    func `Bridge help describes the selectable GUI host and on demand fallback`() {
        let help = BridgeCommand.helpMessage()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")

        #expect(help.contains(
            "Most automation commands first reuse a healthy Peekaboo daemon, then try a capable " +
                "Peekaboo.app Bridge host, and otherwise start a daemon on demand."
        ))
        #expect(help.contains(
            "Application inventory and launch prefer Peekaboo.app; relaunch and quit require a reusable daemon."
        ))
        #expect(help.contains("Claude.app and ClawdBot.app sockets are diagnostic-only unless selected explicitly."))
        #expect(!help.contains("dedicated Peekaboo daemon and fall back to local execution"))
        #expect(!help.contains("Peekaboo.app, Claude.app, and ClawdBot.app sockets are shown for diagnostics"))
    }

    @Test
    func `permission status help renders standard runtime flags once`() {
        let help = PermissionsCommand.StatusSubcommand.helpMessage()

        #expect(help.components(separatedBy: "--bridge-socket").count - 1 == 1)
        #expect(help.components(separatedBy: "--no-remote").count - 1 == 1)
        #expect(help.contains("--all-sources"))
    }

    @Test
    func `click help makes the background coordinate receipt contract explicit`() {
        let help = ClickCommand.helpMessage()

        #expect(help.contains("Background coordinates require `--snapshot` from a fresh exact-window `see`"))
        #expect(help.contains("background coordinates require an explicit fresh exact-window snapshot"))
        #expect(help.contains("peekaboo see --window-id 12345 --no-elements --json"))
        #expect(help.contains("peekaboo click --window-id 12345 --at 20,40 --snapshot SNAPSHOT_ID"))
    }

    @Test
    func `interaction help distinguishes current and legacy targeting`() {
        let typeHelp = TypeCommand.helpMessage()
        let clickHelp = ClickCommand.helpMessage()
        let legacyBackgroundDescription =
            "Deprecated compatibility alias; targeted background delivery is already the default"

        #expect(typeHelp.contains("Type text into a targeted app process or the foreground focus"))
        #expect(!typeHelp.contains("Type text into an app or UI element"))
        #expect(clickHelp.contains(legacyBackgroundDescription))
    }

    @Test
    func `keyboard dialog and action help expose exact background authority`() {
        let pressHelp = PressCommand.helpMessage()
        let dialogInputHelp = DialogCommand.InputSubcommand.helpMessage()
        let actionHelp = ActionCommand.helpMessage()

        #expect(pressHelp.contains("Agent/MCP background-only policy"))
        #expect(pressHelp.contains("explicit non-dialog snapshot"))
        #expect(pressHelp.contains("exact receipt or explicit --foreground consent"))
        #expect(dialogInputHelp.contains("exact targeted input defaults to background AXValue"))
        #expect(actionHelp.contains(#"AXPress --on "$ELEMENT_ID" --foreground"#))
        #expect(actionHelp.contains("AXPress and AXShowMenu, require"))
    }

    @Test
    func `verify help labels optional predicate values as expected`() {
        let help = VerifyCommand.helpMessage()

        #expect(help.contains("Expected x,y,width,height[,tolerance]"))
        #expect(help.contains("Expected element value"))
        #expect(!help.contains("Required x,y,width,height"))
        #expect(!help.contains("Required element value"))
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
