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
    func `background dialog click requires prepared exact remote capabilities`() throws {
        let background = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["pid": ["123"], "button": ["OK"]],
                flags: []
            ),
            commandType: DialogCommand.ClickSubcommand.self
        )
        let foreground = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [],
                options: ["pid": ["123"], "button": ["OK"]],
                flags: ["foreground"]
            ),
            commandType: DialogCommand.ClickSubcommand.self
        )

        #expect(background.requiresPreparedDialogClick)
        #expect(!background.requiresBackgroundDialogClick)
        #expect(foreground.requiresPreparedDialogClick)
        #expect(!foreground.requiresBackgroundDialogClick)
    }

    @Test
    func `dialog semantic errors refuse before runtime resolution`() {
        #expect(throws: PreDispatchActionError.self) {
            _ = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(positional: [], options: ["button": ["OK"]], flags: []),
                commandType: DialogCommand.ClickSubcommand.self
            )
        }
        #expect(throws: PreDispatchActionError.self) {
            _ = try CommanderCLIBinder.makeRuntimeOptions(
                from: ParsedValues(
                    positional: [],
                    options: ["button": ["OK"], "pid": ["42"], "windowId": ["700"], "windowTitle": ["Save"]],
                    flags: []
                ),
                commandType: DialogCommand.ClickSubcommand.self
            )
        }
        for commandType in [DialogCommand.InputSubcommand.self, DialogCommand.FileSubcommand.self]
            as [any ParsableCommand.Type] {
            #expect(throws: PreDispatchActionError.self) {
                _ = try CommanderCLIBinder.makeRuntimeOptions(
                    from: ParsedValues(positional: [], options: [:], flags: []),
                    commandType: commandType
                )
            }
            #expect(throws: Never.self) {
                _ = try CommanderCLIBinder.makeRuntimeOptions(
                    from: ParsedValues(positional: [], options: [:], flags: ["foreground"]),
                    commandType: commandType
                )
            }
        }
    }

    @Test
    func `Window mutators declare pinned host requirement without restricting reads or focus`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: [])
        let mutators: [any ParsableCommand.Type] = [
            WindowCommand.CloseSubcommand.self,
            WindowCommand.MinimizeSubcommand.self,
            WindowCommand.RestoreSubcommand.self,
            WindowCommand.MaximizeSubcommand.self,
            WindowCommand.MoveSubcommand.self,
            WindowCommand.ResizeSubcommand.self,
            WindowCommand.SetBoundsSubcommand.self,
        ]

        for commandType in mutators {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(options.requiresPinnedWindowMutations, "Missing pinned mutation requirement: \(commandType)")
        }

        for commandType in [
            WindowCommand.WindowListSubcommand.self,
            WindowCommand.FocusSubcommand.self,
        ] as [any ParsableCommand.Type] {
            let options = try CommanderCLIBinder.makeRuntimeOptions(from: parsed, commandType: commandType)
            #expect(!options.requiresPinnedWindowMutations, "Unexpected pinned mutation requirement: \(commandType)")
        }
    }
}
