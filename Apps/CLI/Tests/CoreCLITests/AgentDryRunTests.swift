import Commander
import Foundation
import PeekabooAgentRuntimeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe), AuthorityTestIsolation())
@MainActor
struct AgentDryRunTests {
    @Test(arguments: [false, true])
    func `preview normalizes instruction and exposes background authority with zero execution`(
        noDesktopContext: Bool
    ) throws {
        for testCase in [
            (arguments: ["  Inspect TextEdit  ", "--dry-run"], requestedForeground: false, policy: "background_only"),
            (
                arguments: ["  Inspect TextEdit  ", "--dry-run", "--allow-foreground"],
                requestedForeground: true,
                policy: "foreground_allowed"
            ),
        ] {
            let command = try AgentCommand.parse(
                testCase.arguments + (noDesktopContext ? ["--no-desktop-context"] : [])
            )
            let instruction = try #require(command.newTaskDryRunInstruction)

            #expect(instruction == "Inspect TextEdit")
            #expect(command.dryRunHumanLines(instruction: instruction) == [
                "Dry run preview",
                "Instruction: Inspect TextEdit",
                "Requested foreground UI: \(testCase.requestedForeground ? "yes" : "no")",
                "Effective UI authority: \(testCase.policy)",
                "Temporary clipboard paste: \(testCase.requestedForeground ? "yes" : "no")",
                "Automatic desktop context: \(noDesktopContext ? "no" : "yes")",
                "Model execution: skipped",
                "Tool calls: 0",
                "Session saved: no",
            ])

            let response = command.makeDryRunJSONResponse(instruction: instruction)
            #expect(response["success"] as? Bool == true)
            let result = try #require(response["result"] as? [String: Any])
            let metadata = try #require(result["metadata"] as? [String: Any])
            let trace = try #require(result["executionTrace"] as? [String: Any])
            let authority = try #require(result["uiAuthority"] as? [String: Any])
            #expect(result["dryRun"] as? Bool == true)
            #expect(result["instruction"] as? String == instruction)
            #expect(result["modelExecution"] as? String == "skipped")
            #expect(result["automaticDesktopContext"] as? Bool == !noDesktopContext)
            #expect(result["sessionId"] is NSNull)
            #expect((result["toolCalls"] as? [Any])?.isEmpty == true)
            #expect(result["usage"] is NSNull)
            #expect(authority["requestedForeground"] as? Bool == testCase.requestedForeground)
            #expect(authority["effectivePolicy"] as? String == testCase.policy)
            #expect(authority["backgroundOnly"] as? Bool == !testCase.requestedForeground)
            #expect(authority["requestedTemporaryClipboard"] as? Bool == false)
            #expect(authority["temporaryClipboardPaste"] as? Bool == testCase.requestedForeground)
            #expect(metadata["toolCallCount"] as? Int == 0)
            #expect(metadata["modelName"] as? String == "not_invoked")
            #expect((trace["entries"] as? [Any])?.isEmpty == true)
            #expect(trace["totalCallCount"] as? Int == 0)
            #expect(trace["truncated"] as? Bool == false)
        }
    }

    @Test
    func `temporary clipboard dry run reports the grant without foreground permission or execution`() throws {
        let command = try AgentCommand.parse(["Paste synthetic data", "--dry-run", "--allow-temporary-clipboard"])
        let result = try #require(command
            .makeDryRunJSONResponse(instruction: "Paste synthetic data")["result"] as? [String: Any])
        let authority = try #require(result["uiAuthority"] as? [String: Any])
        #expect(authority["requestedTemporaryClipboard"] as? Bool == true)
        #expect(authority["temporaryClipboardPaste"] as? Bool == true)
        #expect(authority["requestedForeground"] as? Bool == false)
        #expect(authority["backgroundOnly"] as? Bool == true)
        #expect(result["modelExecution"] as? String == "skipped")
        #expect(result["sessionId"] is NSNull)
    }

    @Test
    func `taskless shorthand and explicit run are invalid before terminal routing`() throws {
        let shorthand = try AgentCommand.parse(["--dry-run"])
        let parsedRun = try AgentRunSubcommand.parse(["--dry-run"])
        var explicitRun = AgentCommand()
        explicitRun.task = parsedRun.task
        parsedRun.options.apply(to: &explicitRun)

        let terminalContexts = [
            Self.capabilities(interactive: true, piped: false),
            Self.capabilities(interactive: false, piped: true),
        ]
        let strategies = terminalContexts.map { capabilities in
            AgentChatLaunchPolicy().strategy(for: AgentChatLaunchContext(
                chatFlag: false,
                hasTaskInput: false,
                listSessions: false,
                normalizedTaskInput: nil,
                capabilities: capabilities
            ))
        }
        #expect(strategies[0] == .interactive(initialPrompt: nil))
        #expect(strategies[1] == .helpOnly)

        for command in [shorthand, explicitRun] {
            for _ in terminalContexts {
                let caught = #expect(throws: PeekabooError.self) {
                    try command.validateDryRunRequest()
                }
                let error = try #require(caught)
                #expect(error.localizedDescription.contains("Task argument is required for --dry-run."))
            }
        }
    }

    @Test
    func `dry run refuses audio instead of invoking transcription`() throws {
        var command = try AgentCommand.parse(["Inspect audio", "--dry-run"])
        command.audio = true

        let caught = #expect(throws: PeekabooError.self) {
            try command.validateDryRunRequest()
        }
        let error = try #require(caught)
        #expect(error.localizedDescription.contains("audio input would require transcription"))
    }

    private static func capabilities(interactive: Bool, piped: Bool) -> TerminalCapabilities {
        TerminalCapabilities(
            isInputInteractive: interactive,
            isInteractive: interactive,
            supportsColors: interactive,
            supportsTrueColor: interactive,
            width: 80,
            height: 24,
            termType: interactive ? "xterm-256color" : nil,
            isCI: false,
            isPiped: piped
        )
    }
}
