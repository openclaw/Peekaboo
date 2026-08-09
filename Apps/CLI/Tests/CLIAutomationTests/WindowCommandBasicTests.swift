import Foundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
struct WindowCommandBasicTests {
    @Test
    func `Window command exists`() {
        // Verify WindowCommand type exists and has proper configuration
        let config = WindowCommand.commandDescription
        #expect(config.commandName == "window")
        #expect(config.abstract.contains("Manipulate application windows"))
    }

    @Test
    func `Window command has expected subcommands`() {
        let subcommands = WindowCommand.commandDescription.subcommands

        // We expect 9 subcommands
        #expect(subcommands.count == 9)

        // Verify subcommand names by checking configuration
        let subcommandNames = Set([
            "close", "minimize", "restore", "maximize", "move", "resize", "set-bounds", "focus", "list",
        ])

        // Each subcommand should have one of these names
        for subcommand in subcommands {
            let config = subcommand.commandDescription
            #expect(
                subcommandNames.contains(config.commandName ?? ""),
                "Unexpected subcommand: \(config.commandName ?? "")"
            )
        }
    }
}
