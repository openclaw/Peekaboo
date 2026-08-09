import Commander
import Testing
@testable import PeekabooCLI

@Suite(.tags(.fast))
struct StrictBackgroundBridgeRequirementTests {
    @Test
    func `background window close requires strict remote capability`() throws {
        let background = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: WindowCommand.CloseSubcommand.self
        )
        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["foreground"]),
            commandType: WindowCommand.CloseSubcommand.self
        )

        #expect(background.requiresBackgroundWindowClose)
        #expect(!foreground.requiresBackgroundWindowClose)
    }

    @Test
    func `background dialog click requires strict remote capability`() throws {
        let background = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: DialogCommand.ClickSubcommand.self
        )
        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: ["foreground"]),
            commandType: DialogCommand.ClickSubcommand.self
        )

        #expect(background.requiresBackgroundDialogClick)
        #expect(!foreground.requiresBackgroundDialogClick)
    }
}
