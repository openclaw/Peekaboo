import Darwin
import Testing
@testable import PeekabooCLI

struct ClickCommandCoordsCrashRegressionTests {
    @Test
    @MainActor
    func `click --at ',' returns failure (no crash)`() async {
        let status = await executePeekabooCLI(arguments: ["peekaboo", "click", "--at", ",", "--json"])
        #expect(status == EXIT_FAILURE)
    }
}
