import Foundation
import Testing
@testable import PeekabooCLI

#if !PEEKABOO_SKIP_AUTOMATION

// MARK: - Test Helpers

private func runCommand(
    _ args: [String],
    allowedExitStatuses: Set<Int32> = [0]
) async throws -> String {
    let result = try ExternalCommandRunner.runPeekabooCLI(args, allowedExitCodes: allowedExitStatuses)
    return result.combinedOutput
}

@Suite(
    .serialized,
    .tags(.automation),
    .enabled(if: CLITestEnvironment.runAutomationActions)
)
struct AgentMenuTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RUN_AGENT_TESTS"] == "true")
    )
    func `Agent can discover menus using list subcommand`() async throws {
        #if !os(Linux)
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENAI_API_KEY"] != nil || environment["ANTHROPIC_API_KEY"] != nil else { return }

        guard environment["RUN_LOCAL_TESTS"] != nil else { return }

        // Ensure Calculator is running
        _ = try await runCommand(["app", "launch", "Calculator", "--wait-ready"])
        try await Task.sleep(for: .seconds(2))

        // Test agent discovering menus
        let output = try await runCommand([
            "agent",
            "List all menus available in the Calculator app",
            "--json",
        ])

        let data = try #require(output.data(using: String.Encoding.utf8))
        let json = try JSONDecoder().decode(AgentCLIResponse.self, from: data)

        #expect(json.success == true)

        // Check that agent used menu command
        let menuToolCallFound = json.result?.toolCalls?.contains(where: { $0.name == "menu" }) ?? false
        #expect(menuToolCallFound, "Agent should use menu tool for menu discovery")

        // Check summary mentions menus
        if let content = json.result?.content {
            #expect(content.lowercased().contains("menu"), "Summary should mention menus")
            #expect(content.contains("View") || content.contains("Edit"), "Summary should list actual menu names")
        }
        #endif
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RUN_AGENT_TESTS"] == "true")
    )
    func `Agent can navigate menus to perform actions`() async throws {
        #if !os(Linux)
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENAI_API_KEY"] != nil || environment["ANTHROPIC_API_KEY"] != nil else { return }

        guard environment["RUN_LOCAL_TESTS"] != nil else { return }

        // Ensure Calculator is running
        _ = try await runCommand(["app", "launch", "Calculator", "--wait-ready"])
        try await Task.sleep(for: .seconds(2))

        // Test agent using menu to switch Calculator mode
        let output = try await runCommand([
            "agent",
            "Switch Calculator to Scientific mode using the View menu",
            "--json",
        ])

        let data = try #require(output.data(using: String.Encoding.utf8))
        let json = try JSONDecoder().decode(AgentCLIResponse.self, from: data)

        #expect(json.success == true)

        let toolCalls = json.result?.toolCalls ?? []
        let menuToolCallFound = toolCalls.contains(where: { $0.name == "menu" })
        #expect(menuToolCallFound, "Should use the menu tool at least once")

        if let content = json.result?.content {
            #expect(content.localizedCaseInsensitiveContains("scientific"), "Agent summary should mention Scientific")
        }
        #endif
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RUN_AGENT_TESTS"] == "true")
    )
    func `Agent uses menu discovery before clicking`() async throws {
        #if !os(Linux)
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENAI_API_KEY"] != nil || environment["ANTHROPIC_API_KEY"] != nil else { return }

        guard environment["RUN_LOCAL_TESTS"] != nil else { return }

        // Test with TextEdit
        _ = try await runCommand(["app", "launch", "TextEdit", "--wait-ready"])
        try await Task.sleep(for: .seconds(2))

        let output = try await runCommand([
            "agent",
            "Find and use the spell check feature in TextEdit",
            "--json",
        ])

        let data = try #require(output.data(using: String.Encoding.utf8))
        let json = try JSONDecoder().decode(AgentCLIResponse.self, from: data)

        #expect(json.success == true)

        let toolCalls = json.result?.toolCalls ?? []
        let menuToolCalls = toolCalls.filter { $0.name == "menu" }
        #expect(menuToolCalls.isEmpty == false, "Should use the menu tool at least once")

        let menuArgumentStrings = menuToolCalls.compactMap { $0.arguments?.lowercased() }
        let listIndex = menuArgumentStrings.firstIndex(where: { $0.contains("list") })
        let clickIndex = menuArgumentStrings.firstIndex(where: { $0.contains("click") })

        if let listIndex, let clickIndex {
            #expect(listIndex <= clickIndex, "Agent should list menus before clicking items")
        } else {
            #expect(!menuToolCalls.isEmpty, "Should discover menus or have menu tool calls")
        }
        #endif
    }

    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["RUN_AGENT_TESTS"] == "true")
    )
    func `Agent handles menu errors gracefully`() async throws {
        #if !os(Linux)
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENAI_API_KEY"] != nil || environment["ANTHROPIC_API_KEY"] != nil else { return }

        guard environment["RUN_LOCAL_TESTS"] != nil else { return }

        _ = try await runCommand(["app", "launch", "Calculator", "--wait-ready"])
        try await Task.sleep(for: .seconds(2))

        // Test with non-existent menu item
        let output = try await runCommand([
            "agent",
            "Click on the 'Quantum Computing' menu item in Calculator",
            "--json",
        ])

        let data = try #require(output.data(using: String.Encoding.utf8))
        let json = try JSONDecoder().decode(AgentCLIResponse.self, from: data)

        // Agent should handle this gracefully
        #expect(json.success == true || json.error != nil)

        if let summary = json.result?.content {
            // Should mention the item wasn't found or similar
            let handledGracefully = summary.lowercased().contains("not found") ||
                summary.lowercased().contains("doesn't exist") ||
                summary.lowercased().contains("unable to find") ||
                summary.lowercased().contains("couldn't find")
            #expect(handledGracefully || json.success == true, "Agent should handle missing menu items gracefully")
        }
        #endif
    }
}

// MARK: - Agent Response Types for Testing

struct AgentCLIResponse: Decodable {
    let success: Bool
    let result: AgentCLIResult?
    let error: AgentErrorData?
}

struct AgentCLIResult: Decodable {
    let content: String?
    let toolCalls: [AgentToolCall]?
}

struct AgentToolCall: Decodable {
    let arguments: String?
    let name: String
}

struct AgentErrorData: Decodable {
    let message: String
    let code: String?

    private enum CodingKeys: String, CodingKey {
        case message
        case code
    }

    init(from decoder: any Decoder) throws {
        if let string = try? decoder.singleValueContainer().decode(String.self) {
            self.message = string
            self.code = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.message = try container.decode(String.self, forKey: .message)
        self.code = try container.decodeIfPresent(String.self, forKey: .code)
    }
}
#endif
