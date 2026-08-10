import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
@MainActor
struct VerifyCommandTests {
    @Test
    func `window predicate parses with defaults`() throws {
        let command = try VerifyCommand.parse(["--app", "Finder", "--window-exists"])
        #expect(command.target.app == "Finder")
        #expect(command.windowExists)
        #expect(command.timeout.roundedMilliseconds == 5000)
        #expect(command.stableSamples == 2)
    }

    @Test
    func `element predicates and timing parse`() throws {
        let command = try VerifyCommand.parse([
            "--pid", "123", "--on", "button:Save", "--exists", "--value-equals", "Ready",
            "--enabled", "--selected", "--timeout", "9000", "--stable-samples", "3",
        ])
        #expect(command.target.pid == 123)
        #expect(command.on == "button:Save")
        #expect(command.exists && command.enabled && command.selected)
        #expect(command.valueEquals == "Ready")
        #expect(command.timeout.roundedMilliseconds == 9000)
        #expect(command.stableSamples == 3)
        #expect(try VerifyCommand.elementSelector("button:Save") == ["role": "button", "label": "Save"])
        #expect(try VerifyCommand.elementSelector("B7") == ["identifier": "B7"])
    }

    @Test
    func `window bounds accepts optional tolerance`() throws {
        let predicate = try VerifyCommand.boundsPredicate("10,20,800,600,2.5")
        #expect(predicate["kind"] as? String == "window_bounds")
        #expect(predicate["tolerance"] as? Double == 2.5)
        let bounds = try #require(predicate["bounds"] as? [String: Double])
        #expect(bounds["width"] == 800)
        #expect(bounds["height"] == 600)
    }

    @Test
    func `verify is registered under vision`() {
        var category: CommandRegistryEntry.Category?
        for entry in CommandRegistry.entries where entry.type.commandDescription.commandName == "verify" {
            category = entry.category
        }
        #expect(category == .vision)
    }
}
