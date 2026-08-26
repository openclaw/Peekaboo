import Commander
import PeekabooFoundation
import PeekabooFoundationTestSupport
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
                "peekaboo", "scroll", "--direction", "sideways", "--on", "elem_6", "--snapshot",
                SnapshotReferenceFixtures.first.rawValue,
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
        Case(
            arguments: ["peekaboo", "action", "AXIncrement", "--json"],
            expectedMessage: "--on is required"
        ),
        Case(
            arguments: ["peekaboo", "action", "--on", "B1", "--json"],
            expectedMessage: "Action name is required"
        ),
        Case(
            arguments: ["peekaboo", "set-value", "hello", "--json"],
            expectedMessage: "--on is required"
        ),
        Case(
            arguments: ["peekaboo", "set-value", "--on", "T1", "--json"],
            expectedMessage: "Value is required"
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
    func `direct element actions reject concrete snapshots with explicit targets before runtime selection`() throws {
        let cases = [
            [
                "action", "AXIncrement", "--on", "B1", "--snapshot",
                SnapshotReferenceFixtures.first.rawValue, "--window-id", "42",
            ],
            [
                "set-value", "hello", "--on", "T1", "--snapshot", SnapshotReferenceFixtures.first.rawValue,
                "--app", "TextEdit",
                "--window-title", "Document",
            ],
            [
                "action", "AXIncrement", "--on", "B1", "--snapshot", SnapshotReferenceFixtures.first.rawValue,
                "--pid", "123",
                "--window-index", "0",
            ],
        ]

        for arguments in cases {
            let resolved = try CommanderRuntimeRouter.resolve(argv: ["peekaboo"] + arguments + ["--json"])
            let command = try CommanderCLIBinder.instantiateCommand(
                type: resolved.type,
                parsedValues: resolved.parsedValues
            )
            let validator = try #require(command as? any PreRuntimeValidatingCommand)

            let error = #expect(throws: PeekabooError.self) {
                try validator.validateBeforeRuntime()
            }
            #expect(error?.localizedDescription.contains("Do not combine an explicit --snapshot") == true)
        }
    }

    @Test
    func `direct element actions accept refreshable snapshots with every valid target selector`() throws {
        let selectors = [
            ["--window-id", "42"],
            ["--app", "TextEdit", "--window-title", "Document"],
            ["--pid", "123", "--window-index", "0"],
        ]
        let commands = [
            ["action", "AXIncrement", "--on", "B1"],
            ["set-value", "hello", "--on", "T1"],
        ]

        for commandArguments in commands {
            for selector in selectors {
                for snapshot in [[], ["--snapshot", "latest"]] {
                    let resolved = try CommanderRuntimeRouter.resolve(
                        argv: ["peekaboo"] + commandArguments + selector + snapshot + ["--json"]
                    )
                    let command = try CommanderCLIBinder.instantiateCommand(
                        type: resolved.type,
                        parsedValues: resolved.parsedValues
                    )
                    let validator = try #require(command as? any PreRuntimeValidatingCommand)

                    #expect(throws: Never.self) {
                        try validator.validateBeforeRuntime()
                    }
                }
            }
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
