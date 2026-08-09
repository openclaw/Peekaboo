import Commander
import Testing
@testable import PeekabooCLI

@MainActor
struct CommanderRuntimeRouterHelpPathTests {
    @Test
    func `help resolves longest matching command prefix`() {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["peekaboo", "help", "app", "list", "extra-token"])
        }
        #expect(exitCode == .success)
    }

    @Test
    func `help ignores option-like trailing tokens`() {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: ["peekaboo", "help", "app", "quit", "--pid", "123"])
        }
        #expect(exitCode == .success)
    }

    @Test
    func `help tokens after double dash stay in capture action command tail`() throws {
        let resolved = try CommanderRuntimeRouter.resolve(
            argv: ["peekaboo", "capture", "action", "--", "/bin/echo", "--help"]
        )

        #expect(ObjectIdentifier(resolved.type) == ObjectIdentifier(CaptureActionCommand.self))
        #expect(resolved.parsedValues.options["command"] == ["/bin/echo", "--help"])
    }
}
