import Commander
import Testing
@testable import PeekabooCLI

@Suite(.tags(.fast))
@MainActor
struct CommanderMigrationAdvisorTests {
    @Test(arguments: [
        (["image"], "peekaboo see --no-elements"),
        (["inspect-ui"], "peekaboo see --tree --no-screenshot"),
        (["hotkey"], "peekaboo press"),
        (["swipe"], "peekaboo drag"),
        (["perform-action"], "peekaboo action"),
        (["list", "windows"], "peekaboo window list"),
        (["help", "image"], "peekaboo see --no-elements"),
    ])
    func `Removed commands name their replacement`(arguments: [String], replacement: String) throws {
        let error = try #require(CommanderMigrationAdvisor.commandError(for: arguments))
        #expect(error.localizedDescription.contains("removed in v4"))
        #expect(error.localizedDescription.contains(replacement))
    }

    @Test(arguments: [
        (["click", "--coords", "1,2"], "--at"),
        (["paste", "--restore-delay-ms", "100"], "--restore-delay"),
        (["capture", "video", "in.mov", "--every-ms", "500"], "--every"),
        (["type", "hello", "--return"], "peekaboo press Return --foreground"),
        (["agent", "--resume-session", "abc"], "peekaboo agent resume <session-id>"),
        (["clipboard", "--action", "get"], "clipboard get|set|clear|save|restore"),
    ])
    func `Removed options name their replacement`(arguments: [String], replacement: String) throws {
        let error = try #require(CommanderMigrationAdvisor.optionError(for: arguments))
        #expect(error.localizedDescription.contains(replacement))
    }

    @Test
    func `Migration scanning stops at positional terminator`() {
        #expect(CommanderMigrationAdvisor.optionError(for: ["type", "--", "--coords"]) == nil)
    }

    @Test
    func `Router returns migration advice instead of generic parser errors`() {
        #expect(throws: CommanderUsageError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["peekaboo", "image"])
        }
        #expect(throws: CommanderUsageError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["peekaboo", "click", "--coords", "1,2"])
        }
        #expect(throws: CommanderUsageError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["peekaboo", "--json", "see"])
        }
    }
}
