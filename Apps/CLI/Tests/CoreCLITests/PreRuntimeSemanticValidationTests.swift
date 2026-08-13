import Commander
import Testing
@testable import PeekabooCLI

@MainActor
struct PreRuntimeSemanticValidationTests {
    struct Case: Sendable {
        let arguments: [String]
        let expectedMessage: String
    }

    @Test(arguments: [
        Case(
            arguments: [
                "peekaboo", "see", "--app", "Digital Color Meter", "--pid", "38461", "--no-remote", "--json",
            ],
            expectedMessage: "Use either --app or --pid, not both."
        ),
        Case(
            arguments: [
                "peekaboo", "see", "--window-title", "Digital Color Meter", "--no-remote", "--json",
            ],
            expectedMessage: "--window-title and --window-index require --app or --pid."
        ),
        Case(
            arguments: ["peekaboo", "see", "--pid", "999999999", "--no-remote", "--json"],
            expectedMessage: "No running application found for --pid 999999999."
        ),
        Case(
            arguments: [
                "peekaboo", "scroll", "--direction", "sideways", "--on", "elem_6", "--snapshot", "stale-valid",
                "--no-remote", "--json",
            ],
            expectedMessage: "Invalid direction. Use: up, down, left, or right"
        ),
    ])
    func `request semantics validate through the pre-runtime hook`(_ testCase: Case) throws {
        let resolved = try CommanderRuntimeRouter.resolve(argv: testCase.arguments)
        let command = try CommanderCLIBinder.instantiateCommand(
            type: resolved.type,
            parsedValues: resolved.parsedValues
        )
        let validator = try #require(command as? any PreRuntimeValidatingCommand)

        let error = #expect(throws: ValidationError.self) {
            try validator.validateBeforeRuntime()
        }
        #expect(error?.localizedDescription == testCase.expectedMessage)
    }
}
