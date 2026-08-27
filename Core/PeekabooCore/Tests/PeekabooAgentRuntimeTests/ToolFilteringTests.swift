import Foundation
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooCore
import Tachikoma
import Testing
@testable import PeekabooAgentRuntime

@Suite(.serialized)
struct ToolFilteringTests {
    @Test
    func `Explicit browser-only environment allow-list proves ScreenCaptureKit unreachable`() {
        #expect(MCPToolCatalog.explicitEnvironmentAllowListProvesNoScreenCaptureKitUse(
            environment: ["PEEKABOO_ALLOW_TOOLS": "browser permissions sleep"]))
        #expect(MCPToolCatalog.explicitEnvironmentAllowListProvesNoScreenCaptureKitUse(environment: [
            "PEEKABOO_ALLOW_TOOLS": "browser,see",
            "PEEKABOO_DISABLE_TOOLS": "see",
        ]))
    }

    @Test(arguments: [
        "browser,see",
        "browser,image",
        "browser,capture",
        "browser,verify_state",
        "browser,agent",
        "browser,future_unknown_tool",
    ])
    func `Capture-capable nested and unknown environment tools remain fail closed`(_ allowList: String) {
        #expect(!MCPToolCatalog.explicitEnvironmentAllowListProvesNoScreenCaptureKitUse(
            environment: ["PEEKABOO_ALLOW_TOOLS": allowList]))
    }

    @Test
    func `Absent explicit environment allow-list cannot prove ScreenCaptureKit unreachable`() {
        #expect(!MCPToolCatalog.explicitEnvironmentAllowListProvesNoScreenCaptureKitUse(environment: [:]))
        #expect(!MCPToolCatalog.explicitEnvironmentAllowListProvesNoScreenCaptureKitUse(
            environment: ["PEEKABOO_ALLOW_TOOLS": "   "]))
        #expect(!MCPToolCatalog.explicitEnvironmentAllowListProvesNoScreenCaptureKitUse(
            environment: ["PEEKABOO_ALLOW_TOOLS": ", ,"]))
    }

    @Test
    func `Config allow list narrows tools`() {
        let filters = ToolFiltering.filters(
            config: Configuration(tools: .init(allow: ["see", "click"])),
            environment: [:])
        let tools = makeTools(["see", "click", "type"])
        var logs: [String] = []
        let filtered = ToolFiltering.apply(tools, filters: filters, log: { logs.append($0) }).map(\.name)

        #expect(filtered == ["see", "click"])
        #expect(logs.contains { $0.contains("type") && $0.contains("allow list") })
    }

    @Test
    func `Env allow overrides config allow; deny accumulates`() {
        let filters = ToolFiltering.filters(
            config: Configuration(tools: .init(allow: ["see"], deny: ["shell"])),
            environment: [
                "PEEKABOO_ALLOW_TOOLS": "see,type",
                "PEEKABOO_DISABLE_TOOLS": "type",
            ])
        let tools = makeTools(["see", "type", "shell"])
        var logs: [String] = []
        let filtered = ToolFiltering.apply(tools, filters: filters, log: { logs.append($0) }).map(\.name)

        #expect(filtered == ["see"])
        #expect(filters.deny.contains("type"))
        #expect(filters.deny.contains("shell"))
        #expect(filters.denySources["shell"] == .config)
        #expect(logs.contains { $0.contains("type") && $0.contains("environment") })
        #expect(logs.contains { $0.contains("shell") && $0.contains("allow list") })
    }

    @Test
    func `Hyphenated names normalize to snake_case`() {
        let filters = ToolFiltering.filters(
            config: Configuration(tools: .init(deny: ["menu-click"])),
            environment: [:])
        let tools = makeTools(["menu_click", "see"])
        let names = ToolFiltering.apply(tools, filters: filters, log: nil).map(\.name)

        #expect(!names.contains("menu_click"))
        #expect(names.contains("see"))
    }

    @Test
    func `Action-only tools are hidden when strategy disables action invocation`() {
        let tools = makeTools(["see", "set_value", "action", "click"])
        let policy = UIInputPolicy(
            defaultStrategy: .synthFirst,
            setValue: .synthOnly,
            performAction: .synthFirst)
        var logs: [String] = []

        let names = ToolFiltering.applyInputStrategyAvailability(
            tools,
            policy: policy,
            log: { logs.append($0) })
            .map(\.name)

        #expect(names == ["see", "click"])
        #expect(logs.contains { $0.contains("set_value") && $0.contains("disables action invocation") })
        #expect(logs.contains { $0.contains("action") && $0.contains("disables action invocation") })
    }

    @Test
    func `Action-only tools remain visible when action invocation is enabled`() {
        let tools = makeTools(["see", "set_value", "action"])
        let policy = UIInputPolicy(
            defaultStrategy: .synthFirst,
            setValue: .actionOnly,
            performAction: .actionFirst)

        let names = ToolFiltering.applyInputStrategyAvailability(tools, policy: policy).map(\.name)

        #expect(names == ["see", "set_value", "action"])
    }

    @Test
    func `Action-only tools remain visible when per-app strategy enables action invocation`() {
        let tools = makeTools(["see", "set_value", "action"])
        let policy = UIInputPolicy(
            defaultStrategy: .synthOnly,
            setValue: .synthOnly,
            performAction: .synthOnly,
            perApp: [
                "com.example.Editor": AppUIInputPolicy(
                    setValue: .actionOnly,
                    performAction: .actionFirst),
            ])

        let names = ToolFiltering.applyInputStrategyAvailability(tools, policy: policy).map(\.name)

        #expect(names == ["see", "set_value", "action"])
    }

    @Test
    func `Action-only tools remain visible when per-app default enables action invocation`() {
        let tools = makeTools(["see", "set_value", "action"])
        let policy = UIInputPolicy(
            defaultStrategy: .synthOnly,
            setValue: .synthOnly,
            performAction: .synthOnly,
            perApp: [
                "com.example.Editor": AppUIInputPolicy(defaultStrategy: .actionFirst),
            ])

        let names = ToolFiltering.applyInputStrategyAvailability(tools, policy: policy).map(\.name)

        #expect(names == ["see", "set_value", "action"])
    }

    @Test
    @MainActor
    func `Agent toolset filtering uses runtime input policy`() async throws {
        let services = PeekabooServices(inputPolicy: UIInputPolicy(
            defaultStrategy: .synthOnly,
            setValue: .synthOnly,
            performAction: .synthOnly))
        let agent = try PeekabooAgentService(services: services)

        let names = await agent.buildToolset(for: .anthropic(.sonnet45)).map(\.name)

        #expect(!names.contains("set_value"))
        #expect(!names.contains("action"))
    }
}

// MARK: - Helpers

private func makeTools(_ names: [String]) -> [AgentTool] {
    names.map { name in
        AgentTool(
            name: name,
            description: "tool \(name)",
            parameters: .init(),
            execute: { _ in AnyAgentToolValue(string: name) })
    }
}
