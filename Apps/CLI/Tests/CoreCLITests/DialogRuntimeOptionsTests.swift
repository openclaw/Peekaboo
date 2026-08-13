import Commander
import Testing
@testable import PeekabooCLI

@Suite(.tags(.fast))
struct DialogRuntimeOptionsTests {
    @Test
    func `dialog mutations require invalidation while every list remains read only`() throws {
        let mutations: [(any ParsableCommand.Type, ParsedValues)] = [
            (
                DialogCommand.ClickSubcommand.self,
                ParsedValues(
                    positional: [],
                    options: ["pid": ["42"], "button": ["OK"]],
                    flags: ["foreground"]
                )
            ),
            (
                DialogCommand.DismissSubcommand.self,
                ParsedValues(positional: [], options: ["pid": ["42"]], flags: ["foreground"])
            ),
            (
                DialogCommand.InputSubcommand.self,
                ParsedValues(
                    positional: [],
                    options: ["pid": ["42"], "text": ["value"]],
                    flags: ["foreground"]
                )
            ),
            (
                DialogCommand.FileSubcommand.self,
                ParsedValues(positional: [], options: ["pid": ["42"]], flags: ["foreground"])
            ),
        ]
        for (commandType, parsed) in mutations {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresImplicitSnapshotInvalidation)
        }

        let untargeted = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(positional: [], options: [:], flags: []),
            commandType: DialogCommand.ListSubcommand.self
        )
        #expect(!untargeted.requiresImplicitSnapshotInvalidation)
        #expect(!untargeted.requiresTargetedDialogList)

        for option in ["app", "windowId", "windowTitle", "windowIndex"] {
            var targetOptions = [option: [option == "app" ? "TextEdit" : "1"]]
            if option == "windowTitle" || option == "windowIndex" {
                targetOptions["pid"] = ["123"]
            }
            let targeted = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: targetOptions, flags: []),
                commandType: DialogCommand.ListSubcommand.self
            )
            #expect(!targeted.requiresImplicitSnapshotInvalidation)
            #expect(targeted.requiresTargetedDialogList)
        }
    }
}
