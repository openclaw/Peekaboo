import Commander
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct CommanderRuntimeArgvTests {
    @Test(arguments: ["/tmp/peekaboo-before", "pb", "peekaboo-4.9", "peekaboo", "/usr/local/bin/peekaboo"])
    func `router resolves command help for any executable name`(executable: String) {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: [executable, "see", "--help"])
        }
        #expect(exitCode == .success)
    }

    @Test(arguments: ["/tmp/peekaboo-before", "pb", "peekaboo-4.9", "peekaboo", "/usr/local/bin/peekaboo"])
    func `router drops exactly the executable before resolving a command`(executable: String) throws {
        let resolved = try CommanderRuntimeRouter.resolve(argv: [executable, "config", "show"])
        #expect(resolved.metadata.name == "show")
        #expect(ObjectIdentifier(resolved.type) == ObjectIdentifier(ConfigCommand.ShowCommand.self))
        #expect(resolved.parsedValues.positional.isEmpty)
    }

    @Test(
        arguments: ["/tmp/peekaboo-before", "pb", "peekaboo-4.9", "peekaboo", "/usr/local/bin/peekaboo"],
        [["--version"], ["see", "--help"]]
    )
    func `entry point handles version and help for any executable name`(
        executable: String,
        arguments: [String]
    ) async {
        let exitCode = await executePeekabooCLI(arguments: [executable] + arguments)
        #expect(exitCode == 0)
    }
}
