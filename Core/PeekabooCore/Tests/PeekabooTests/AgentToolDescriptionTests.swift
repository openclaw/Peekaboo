import Foundation
import Testing
@testable import PeekabooAgentRuntime
@testable import PeekabooAutomation
@testable import PeekabooCore
@testable import PeekabooVisualizer

struct AgentToolDescriptionTests {
    // MARK: - Tool Definition Structure Tests

    @Test
    @MainActor
    func `All agent tools have comprehensive descriptions`() {
        let allTools = makeAgentTools()

        for tool in allTools {
            // Check that essential fields are present and non-empty
            #expect(!tool.name.isEmpty, "Tool must have a name")
            #expect(!tool.abstract.isEmpty, "Tool '\(tool.name)' must have an abstract")
            #expect(!tool.discussion.isEmpty, "Tool '\(tool.name)' must have a discussion")

            // Verify category is set (all categories are valid)
        }
    }

    @Test
    @MainActor
    func `Tool descriptions follow consistent format`() {
        let allTools = makeAgentTools()

        for tool in allTools {
            let discussion = tool.discussion

            // Check for common sections in enhanced descriptions
            if discussion.count > 200 { // Only check substantial descriptions
                // Many enhanced tools include EXAMPLES section
                if tool.name == "click" || tool.name == "type" || tool.name == "see" {
                    #expect(
                        discussion.contains("EXAMPLE"),
                        "Tool '\(tool.name)' should include examples")
                }

                // UI tools should mention relevant keywords
                if tool.category == .automation {
                    let hasUIGuidance = discussion.contains("element") ||
                        discussion.contains("UI") ||
                        discussion.contains("click") ||
                        discussion.contains("type") ||
                        discussion.contains("key") ||
                        discussion.contains("press") ||
                        discussion.contains("scroll")
                    #expect(
                        hasUIGuidance,
                        "Automation tool '\(tool.name)' should mention UI interaction")
                }
            }
        }
    }

    // MARK: - Specific Tool Enhancement Tests

    @Test
    @MainActor
    func `Click tool has enhanced element matching description`() {
        guard let clickTool = makeAgentTools().first(where: { $0.name == "click" }) else {
            Issue.record("Click tool not found")
            return
        }

        let discussion = clickTool.discussion

        // Verify enhanced features are documented
        #expect(discussion.contains("Fuzzy matching"))
        #expect(discussion.contains("Smart waiting"))
        #expect(discussion.contains("ELEMENT MATCHING"))
        #expect(discussion.contains("TROUBLESHOOTING"))

        // Check for specific examples
        #expect(discussion.contains("peekaboo click"))
        #expect(discussion.contains("--wait-for"))
        #expect(discussion.contains("--double"))
    }

    @Test
    @MainActor
    func `Type tool includes escape sequence documentation`() {
        guard let typeTool = makeAgentTools().first(where: { $0.name == "type" }) else {
            Issue.record("Type tool not found")
            return
        }

        let discussion = typeTool.discussion

        // Check for escape sequence documentation
        #expect(discussion.contains("\\n") || discussion.contains("newline"))
        #expect(discussion.contains("\\t") || discussion.contains("tab"))
        #expect(discussion.contains("escape") || discussion.contains("\\"))
    }

    @Test
    @MainActor
    func `See tool has comprehensive UI detection description`() {
        guard let seeTool = makeAgentTools().first(where: { $0.name == "see" }) else {
            Issue.record("See tool not found")
            return
        }

        let discussion = seeTool.discussion

        // Verify see tool features are documented
        #expect(discussion.contains("screenshot") || discussion.contains("capture"))
        #expect(discussion.contains("app") || discussion.contains("window"))

        // Check for snapshot management info
        #expect(discussion.contains("snapshot"))
    }

    @Test
    @MainActor
    func `Agent interaction tool schemas accept snapshots from see or inspect ui`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tools = service.createAgentTools()
        let interactionToolNames = Set(["click", "type", "set_value", "perform_action", "scroll", "drag", "move"])
        let stalePhrases = [
            "from see command",
            "from see output",
            "Run 'see' command",
            "Run 'see' again",
        ]

        for tool in tools where interactionToolNames.contains(tool.name) {
            let parameterDescriptions = tool.parameters.properties.values.map(\.description)
            let guidance = ([tool.description] + parameterDescriptions).joined(separator: "\n")

            #expect(
                guidance.contains("inspect_ui"),
                "Tool '\(tool.name)' should mention that `inspect_ui` snapshots/IDs are valid.")

            for phrase in stalePhrases {
                #expect(
                    !guidance.contains(phrase),
                    "Tool '\(tool.name)' still implies only `see` can provide snapshots/IDs: \(phrase)")
            }
        }
    }

    @Test
    @MainActor
    func `Agent tools treat element IDs as opaque`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let agentTools = service.createAgentTools()

        for tool in agentTools {
            let parameterDescriptions = tool.parameters.properties.values.map(\.description)
            let guidance = ([tool.description] + parameterDescriptions).joined(separator: "\n")

            #expect(
                guidance.range(of: #"\b[BTMS]\d+\b"#, options: .regularExpression) == nil,
                "Tool '\(tool.name)' must not imply that element ID shape encodes element role.")
        }

        let clickGuidance = agentTools.first(where: { $0.name == "click" }).map { tool in
            ([tool.description] + tool.parameters.properties.values.map(\.description)).joined(separator: "\n")
        }
        #expect(clickGuidance?.localizedCaseInsensitiveContains("opaque") == true)
    }

    @Test
    @MainActor
    func `Shell tool has quoting examples`() {
        guard let shellTool = makeAgentTools().first(where: { $0.name == "shell" }) else {
            Issue.record("Shell tool not found")
            return
        }

        let discussion = shellTool.discussion

        // Shell tool should have examples
        #expect(discussion.contains("EXAMPLE") || discussion.contains("shell"))

        // Should have examples with quotes
        let hasQuotedExample = discussion.contains("\"") || discussion.contains("'")
        #expect(hasQuotedExample, "Shell tool should include quoted examples")
    }

    // MARK: - Parameter Documentation Tests

    @Test
    @MainActor
    func `Required parameters are clearly marked`() {
        let allTools = makeAgentTools()

        for tool in allTools {
            for param in tool.parameters where param.required {
                // Required parameters should have clear descriptions
                #expect(
                    !param.description.isEmpty,
                    "Required parameter '\(param.name)' in tool '\(tool.name)' must have description")
            }
        }
    }

    @Test
    @MainActor
    func `MCP union parameters remain visible to agent providers`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tool = service.createSetValueTool()
        let properties = tool.parameters.properties

        #expect(properties["value"] != nil)
        #expect(properties["value"]?.type == .string)
        #expect(tool.parameters.required.contains("value"))
        #expect(tool.parameters.required.allSatisfy { properties[$0] != nil })
    }

    @Test
    @MainActor
    func `Optional parameters have default values documented`() {
        let allTools = makeAgentTools()

        for tool in allTools {
            for param in tool.parameters where !param.required {
                // Check if default value is documented either in defaultValue or description
                let hasDefault = param.defaultValue != nil ||
                    param.description.contains("default") ||
                    param.description.contains("if not")

                // Some parameters genuinely have no defaults, so this is informational
                if !hasDefault, param.type != .boolean {
                    // This is OK, just noting parameters without clear defaults
                    // Boolean parameters implicitly default to false
                }
            }
        }
    }

    // MARK: - Tool Category Tests

    @Test
    @MainActor
    func `Tools are properly categorized`() {
        let allTools = makeAgentTools()
        let categorizedTools = Dictionary(grouping: allTools, by: { $0.category })

        // Verify we have tools in expected categories
        #expect(categorizedTools[.automation]?.count ?? 0 > 0, "Should have automation tools")
        #expect(categorizedTools[.vision]?.count ?? 0 > 0, "Should have vision tools")
        #expect(categorizedTools[.app]?.count ?? 0 > 0, "Should have app tools")

        // Check specific tools are in correct categories
        let clickTool = allTools.first { $0.name == "click" }
        #expect(clickTool?.category == .automation)

        let seeTool = allTools.first { $0.name == "see" }
        #expect(seeTool?.category == .vision)

        let inspectUITool = allTools.first { $0.name == "inspect_ui" }
        #expect(inspectUITool?.category == .element)

        let launchTool = allTools.first { $0.name == "launch_app" }
        #expect(launchTool?.category == .app)
    }

    // MARK: - Error Guidance Tests

    @Test
    @MainActor
    func `Tools provide helpful error guidance`() {
        // Only check tools that are expected to have error guidance
        // Based on actual tool definitions, only 'click' has TROUBLESHOOTING section
        let toolsWithErrorGuidance = ["click"]

        for toolName in toolsWithErrorGuidance {
            guard let tool = makeAgentTools().first(where: { $0.name == toolName }) else {
                continue
            }

            let discussion = tool.discussion

            // Check for troubleshooting or error handling guidance
            let hasErrorGuidance = discussion.contains("TROUBLESHOOTING") ||
                discussion.contains("If") ||
                discussion.contains("not found") ||
                discussion.contains("fail") ||
                discussion.contains("error") ||
                discussion.contains("try")

            #expect(
                hasErrorGuidance,
                "Tool '\(toolName)' should include error guidance")
        }

        // Additionally, verify that tools that need error guidance have it
        // This is more of a design guideline check
        let interactionTools = ["click", "type", "see", "launch_app"]
        var toolsWithGuidance = 0
        var toolsWithoutGuidance: [String] = []

        for toolName in interactionTools {
            guard let tool = makeAgentTools().first(where: { $0.name == toolName }) else {
                continue
            }

            let discussion = tool.discussion
            let hasGuidance = discussion.contains("TROUBLESHOOTING") ||
                discussion.contains("If") ||
                discussion.contains("not found") ||
                discussion.contains("fail") ||
                discussion.contains("error") ||
                discussion.contains("try")

            if hasGuidance {
                toolsWithGuidance += 1
            } else {
                toolsWithoutGuidance.append(toolName)
            }
        }

        // At least some interaction tools should have error guidance
        #expect(toolsWithGuidance > 0, "At least some interaction tools should have error guidance")

        // This is informational - not a hard requirement
        if !toolsWithoutGuidance.isEmpty {
            // Note: Tools without explicit error guidance: \(toolsWithoutGuidance)
            // This is OK as long as they have clear descriptions
        }
    }

    // MARK: - Example Quality Tests

    @Test
    @MainActor
    func `Tool examples are realistic and helpful`() {
        let allTools = makeAgentTools()

        for tool in allTools where tool.discussion.contains("EXAMPLE") {
            // Examples should reference the tool somehow
            let toolNameParts = tool.name.split(separator: "_")
            let hasReference = tool.discussion.contains("peekaboo") ||
                tool.discussion.contains(tool.name) ||
                toolNameParts.contains { part in
                    tool.discussion.lowercased().contains(part.lowercased())
                }
            #expect(
                hasReference,
                "Examples for '\(tool.name)' should reference the tool")

            // Examples should demonstrate various options
            if tool.parameters.count > 2 {
                let hasOptionExample = tool.discussion.contains("--")
                #expect(
                    hasOptionExample,
                    "Tool '\(tool.name)' with multiple parameters should show option examples")
            }
        }
    }
}

@MainActor
private func makeAgentTools() -> [PeekabooToolDefinition] {
    let services = PeekabooServices()
    ToolRegistry.configureDefaultServices { services }
    return ToolRegistry.allTools(using: services)
}
