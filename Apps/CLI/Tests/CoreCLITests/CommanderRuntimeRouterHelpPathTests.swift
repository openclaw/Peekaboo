import Commander
import Testing
@testable import PeekabooCLI

@MainActor
struct CommanderRuntimeRouterHelpPathTests {
    @Test(arguments: [
        ["peekaboo", "--junk", "--help"],
        ["peekaboo", "--junk", "-h"],
        ["peekaboo", "--json", "--help"],
        ["peekaboo", "help", "--junk"],
        ["peekaboo", "--junk", "--version"],
        ["peekaboo", "--junk", "-V"],
        ["peekaboo", "--json", "--version"],
        ["peekaboo", "--log-level", "debug", "--version"],
        ["peekaboo", "--logLevel=debug", "-V"],
        ["peekaboo", "--bridge-socket", "/tmp/missing.sock", "--help"],
        ["peekaboo", "--input-strategy", "actionOnly", "-h"],
    ])
    func `root early-exit flags ignore preceding root options`(arguments: [String]) {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(exitCode == .success)
    }

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

    @Test(arguments: [
        ["peekaboo", "--junk", "click", "--help"],
        ["peekaboo", "--junk", "app", "--help"],
        ["peekaboo", "--unknown=1", "app", "list", "--help"],
    ])
    func `option-leading command help retains the command path`(arguments: [String]) {
        let exitCode = #expect(throws: ExitCode.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(exitCode == .success)
    }

    @Test
    func `help tokens after double dash stay in capture action command tail`() throws {
        let resolved = try CommanderRuntimeRouter.resolve(
            argv: ["peekaboo", "capture", "action", "--", "/bin/echo", "--help"]
        )

        #expect(ObjectIdentifier(resolved.type) == ObjectIdentifier(CaptureActionCommand.self))
        #expect(resolved.parsedValues.positional == ["/bin/echo", "--help"])
        #expect(resolved.parsedValues.options["command"] == nil)
    }

    @Test(arguments: [
        ["peekaboo", "does-not-exist", "--help"],
        ["peekaboo", "--junk", "does-not-exist", "--help"],
    ])
    func `unknown positional help target remains an error`(arguments: [String]) {
        let error = #expect(throws: CommanderProgramError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(error == .unknownCommand("does-not-exist"))
    }

    @Test(arguments: [
        ["peekaboo", "--log-level", "--help"],
        ["peekaboo", "--logLevel", "--help"],
        ["peekaboo", "--bridge-socket", "--help"],
        ["peekaboo", "--bridgeSocket", "--help"],
        ["peekaboo", "--input-strategy", "--help"],
        ["peekaboo", "--inputStrategy", "--help"],
    ])
    func `missing runtime option value does not become root help`(arguments: [String]) {
        let error = #expect(throws: CommanderUsageError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(error?.message.contains("Runtime flags must follow the leaf command") == true)
    }

    @Test(arguments: [
        ["peekaboo", "--log-level=--help"],
        ["peekaboo", "--logLevel=--help"],
    ])
    func `attached help token remains a runtime option value`(arguments: [String]) {
        let error = #expect(throws: CommanderProgramError.self) {
            _ = try CommanderRuntimeRouter.resolve(argv: arguments)
        }
        #expect(error == .unknownCommand(arguments[1]))
    }

    @Test
    func `early-exit flags after double dash remain ordinary arguments`() {
        do {
            _ = try CommanderRuntimeRouter.resolve(argv: ["peekaboo", "--junk", "--", "--help"])
            Issue.record("Expected an argument error")
        } catch let exitCode as ExitCode {
            #expect(exitCode != .success)
        } catch {
            // Any ordinary parser error proves the root help short-circuit did not run.
        }
    }

    @Test
    func `leaf version remains an option error`() {
        do {
            _ = try CommanderRuntimeRouter.resolve(argv: ["peekaboo", "click", "--version"])
            Issue.record("Expected an option error")
        } catch let exitCode as ExitCode {
            #expect(exitCode != .success)
        } catch {
            // Expected: version is a root early-exit flag, not a leaf command option.
        }
    }
}
