import Commander
import Testing
@testable import PeekabooCLI

@Suite(.tags(.fast))
struct RuntimeMutationBoundaryTests {
    @Test
    func `remote hosted click and application list retain their caller-side boundaries`() throws {
        let parsed = ParsedValues(positional: [], options: [:], flags: ["foreground", "activate"])
        let remoteHostedClick = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: ClickCommand.self
        )
        #expect(!remoteHostedClick.requiresCallerDesktopMutationBarrier)

        let readOnly = try CommanderCLIBinder.makeRuntimeOptions(
            from: parsed,
            commandType: AppCommand.ListSubcommand.self
        )
        #expect(!readOnly.requiresImplicitSnapshotInvalidation)
    }
}
