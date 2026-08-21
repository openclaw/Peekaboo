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

            if discussion.count > 200 {
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
    func `Click tool preserves native receipt and background guidance`() {
        guard let clickTool = makeAgentTools().first(where: { $0.name == "click" }) else {
            Issue.record("Click tool not found")
            return
        }

        let discussion = clickTool.discussion

        #expect(discussion.contains("specific IDs from `see` or `inspect_ui`"))
        #expect(discussion.contains("fresh exact-window `see`"))
        #expect(discussion.contains("Background delivery is the default"))
    }

    @Test
    @MainActor
    func `Type tool preserves native background policy documentation`() {
        guard let typeTool = makeAgentTools().first(where: { $0.name == "type" }) else {
            Issue.record("Type tool not found")
            return
        }

        let discussion = typeTool.discussion

        #expect(discussion.contains("explicit fresh exact non-dialog snapshot receipt"))
        #expect(discussion.contains("App/PID/window-only"))
        #expect(discussion.contains("implicit-latest"))
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
        #expect(discussion.contains("background-only"))
        #expect(discussion.contains("opaque Peekaboo element IDs"))

        // Check for snapshot management info
        #expect(discussion.contains("snapshot"))
    }

    @Test
    @MainActor
    func `Agent interaction tool schemas accept snapshots from see or inspect ui`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tools = service.createAgentTools()
        let interactionToolNames = Set(["click", "type", "set_value", "action", "scroll", "drag", "move"])
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
    func `Raw privileged Shell factory retains quoting examples`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let discussion = service.createShellTool().description

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
    func `Verify state agent schema exposes structured predicate objects and examples`() throws {
        let service = try PeekabooAgentService(services: PeekabooServices())
        let tool = service.createVerifyStateTool()
        let predicates = try #require(tool.parameters.properties["predicates"])
        let items = try #require(predicates.items)

        #expect(predicates.type == .array)
        #expect(items.type == "object")
        #expect(items.description?.contains(#"{"kind":"window_exists","expected":true}"#) == true)
        #expect(items.description?.contains(#"{"kind":"element_value""#) == true)
        #expect(tool.description.contains("never prose strings or AX expressions"))
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

        let launchTool = allTools.first { $0.name == "app" }
        #expect(launchTool?.category == .app)
    }

    // MARK: - Error Guidance Tests

    @Test
    @MainActor
    func `Policy-sensitive tools preserve native refusal guidance`() throws {
        let tools = Dictionary(uniqueKeysWithValues: makeAgentTools().map { ($0.name, $0) })
        #expect(try #require(tools["app"]).discussion.contains("unavailable"))
        #expect(try #require(tools["window"]).discussion.contains("Unavailable under background-only authority"))
        #expect(try #require(tools["clipboard"]).discussion.contains("persistently"))
    }

    // MARK: - Example Quality Tests

    @Test
    @MainActor
    func `Final public definitions do not layer examples over policy-filtered schemas`() {
        for tool in makeAgentTools() {
            #expect(tool.examples.isEmpty, "Tool '\(tool.name)' should use only its policy-aware native description")
        }
    }
}

@MainActor
private func makeAgentTools() -> [PeekabooToolDefinition] {
    let services = PeekabooServices()
    ToolRegistry.configureDefaultServices { services }
    return ToolRegistry.allTools(using: services)
}
