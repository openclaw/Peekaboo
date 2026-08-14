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
        Case(
            arguments: [
                "peekaboo", "move", "--at", "not-a-coordinate", "--foreground", "--no-remote", "--json",
            ],
            expectedMessage: "Invalid coordinates format. Use: x,y"
        ),
        Case(
            arguments: ["peekaboo", "type", "--profile", "human", "--no-remote", "--json"],
            expectedMessage: "No input specified. Provide text or use --clear."
        ),
        Case(
            arguments: [
                "peekaboo", "drag", "--from", "source_id", "--to", "target_id", "--button", "middle",
                "--foreground", "--no-remote", "--json",
            ],
            expectedMessage: "--button must be either 'left' or 'right'"
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

    @Test
    func `click coordinates validate before runtime selection`() throws {
        let resolved = try CommanderRuntimeRouter.resolve(argv: [
            "peekaboo", "click", "--at", "not-a-coordinate", "--json",
        ])
        let command = try CommanderCLIBinder.instantiateCommand(
            type: resolved.type,
            parsedValues: resolved.parsedValues
        )
        let validator = try #require(command as? any PreRuntimeValidatingCommand)

        let error = #expect(throws: PreDispatchActionError.self) {
            try validator.validateBeforeRuntime()
        }
        #expect(error?.localizedDescription == "Invalid coordinates format. Use: x,y")
    }

    @Test
    func `drag element selectors remain valid before runtime selection`() throws {
        let resolved = try CommanderRuntimeRouter.resolve(argv: [
            "peekaboo", "drag", "--from", "row_1", "--to", "row_5", "--foreground", "--json",
        ])
        let command = try CommanderCLIBinder.instantiateCommand(
            type: resolved.type,
            parsedValues: resolved.parsedValues
        )
        let validator = try #require(command as? any PreRuntimeValidatingCommand)

        #expect(throws: Never.self) {
            try validator.validateBeforeRuntime()
        }
    }

    @Test
    func `environment no remote validates local PID before runtime selection`() throws {
        let resolved = try CommanderRuntimeRouter.resolve(argv: [
            "peekaboo", "see", "--pid", "999999999", "--json",
        ])
        let command = try #require(CommanderCLIBinder.instantiateCommand(
            type: resolved.type,
            parsedValues: resolved.parsedValues
        ) as? SeeCommand)

        #expect(throws: Never.self) {
            try command.validateBeforeRuntime(environment: [:])
        }
        let error = #expect(throws: ValidationError.self) {
            try command.validateBeforeRuntime(environment: ["PEEKABOO_NO_REMOTE": "1"])
        }
        #expect(error?.localizedDescription == "No running application found for --pid 999999999.")
    }
}
