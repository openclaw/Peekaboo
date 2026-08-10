import Foundation
import os.log
import PeekabooAutomation
import PeekabooAutomationKit
import Tachikoma
import TachikomaMCP

/// Normalized allow/deny lists used when exposing tools.
public struct ToolFilters: Sendable {
    public enum AllowSource: Sendable {
        case env
        case config
        case none
    }

    public enum DenySource: Sendable {
        case env
        case config
    }

    public let allow: Set<String>
    public let deny: Set<String>
    public let allowSource: AllowSource
    public let denySources: [String: DenySource]

    public init(
        allow: Set<String>,
        deny: Set<String>,
        allowSource: AllowSource,
        denySources: [String: DenySource])
    {
        self.allow = allow
        self.deny = deny
        self.allowSource = allowSource
        self.denySources = denySources
    }
}

public enum ToolFiltering {
    /// Resolve filters from environment + config with the defined precedence rules.
    public static func currentFilters(configuration: ConfigurationManager = .shared) -> ToolFilters {
        self.filters(
            config: configuration.getConfiguration(),
            environment: ProcessInfo.processInfo.environment)
    }

    static func filters(config: Configuration?, environment: [String: String]) -> ToolFilters {
        let envAllow = self.parseList(environment["PEEKABOO_ALLOW_TOOLS"])
        let envDeny = self.parseList(environment["PEEKABOO_DISABLE_TOOLS"])
        let configAllow = config?.tools?.allow ?? []
        let configDeny = config?.tools?.deny ?? []

        // env allow replaces config allow when present; deny always accumulates
        let allowList = envAllow?.map(self.normalize) ?? configAllow.map(self.normalize)
        let denyList = (configDeny + (envDeny ?? [])).map(self.normalize)

        var denySources: [String: ToolFilters.DenySource] = [:]
        for name in configDeny.map(self.normalize) {
            denySources[name] = .config
        }
        for name in (envDeny ?? []).map(self.normalize) {
            denySources[name] = .env
        }

        let allowSource: ToolFilters.AllowSource = envAllow != nil
            ? .env
            : (allowList.isEmpty ? .none : .config)

        return ToolFilters(
            allow: Set(allowList),
            deny: Set(denyList),
            allowSource: allowSource,
            denySources: denySources)
    }

    /// Filter AgentTool list.
    public static func apply(
        _ tools: [AgentTool],
        filters: ToolFilters,
        log: ((String) -> Void)? = nil) -> [AgentTool]
    {
        self.apply(tools, filters: filters, log: log) { $0.name }
    }

    /// Remove tools that are unavailable under the current input strategy policy.
    public static func applyInputStrategyAvailability(
        _ tools: [AgentTool],
        policy: UIInputPolicy,
        log: ((String) -> Void)? = nil) -> [AgentTool]
    {
        self.applyInputStrategyAvailability(tools, policy: policy, log: log) { $0.name }
    }

    /// Filter MCPTool list.
    public static func apply(
        _ tools: [any MCPTool],
        filters: ToolFilters,
        log: ((String) -> Void)? = nil) -> [any MCPTool]
    {
        self.apply(tools, filters: filters, log: log) { $0.name }
    }

    /// Remove MCP tools that are unavailable under the current input strategy policy.
    public static func applyInputStrategyAvailability(
        _ tools: [any MCPTool],
        policy: UIInputPolicy,
        log: ((String) -> Void)? = nil) -> [any MCPTool]
    {
        self.applyInputStrategyAvailability(tools, policy: policy, log: log) { $0.name }
    }

    // MARK: - Helpers

    private static func apply<T>(
        _ tools: [T],
        filters: ToolFilters,
        log: ((String) -> Void)?,
        nameProvider: (T) -> String) -> [T]
    {
        let allow = filters.allow
        let deny = filters.deny

        // First, enforce allow list if present
        var filtered: [T] = tools
        if !allow.isEmpty {
            filtered = filtered.filter { tool in
                let name = self.normalize(nameProvider(tool))
                if allow.contains(name) {
                    return true
                } else {
                    if let log {
                        let source = switch filters.allowSource {
                        case .env: "environment (PEEKABOO_ALLOW_TOOLS)"
                        case .config: "config (tools.allow)"
                        case .none: "allow list"
                        }
                        log("Tool '\(name)' not exposed because allow list from \(source) excludes it.")
                    }
                    return false
                }
            }
        }

        // Then remove any denies
        if !deny.isEmpty {
            filtered = filtered.filter { tool in
                let name = self.normalize(nameProvider(tool))
                if deny.contains(name) {
                    if let log {
                        let source = filters.denySources[name] == .env
                            ? "environment (PEEKABOO_DISABLE_TOOLS)"
                            : "config (tools.deny)"
                        log("Tool '\(name)' disabled via \(source); dropped.")
                    }
                    return false
                }

                return true
            }
        }

        return filtered
    }

    private static func applyInputStrategyAvailability<T>(
        _ tools: [T],
        policy: UIInputPolicy,
        log: ((String) -> Void)?,
        nameProvider: (T) -> String) -> [T]
    {
        tools.filter { tool in
            let name = self.normalize(nameProvider(tool))
            let isAvailable = switch name {
            case "set_value":
                self.supportsActionInvocation(policy: policy, verb: .setValue)
            case "action":
                self.supportsActionInvocation(policy: policy, verb: .performAction)
            default:
                true
            }

            if !isAvailable, let log {
                log("Tool '\(name)' not exposed because input strategy disables action invocation.")
            }
            return isAvailable
        }
    }

    private static func supportsActionInvocation(policy: UIInputPolicy, verb: UIInputVerb) -> Bool {
        if policy.strategy(for: verb).supportsActionInvocation {
            return true
        }

        return policy.perApp.keys.contains { bundleIdentifier in
            policy.strategy(for: verb, bundleIdentifier: bundleIdentifier).supportsActionInvocation
        }
    }

    private static func parseList(_ raw: String?) -> [String]? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return raw
            .split { $0 == "," || $0.isWhitespace }
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    private static func normalize(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
    }
}

extension UIInputStrategy {
    fileprivate var supportsActionInvocation: Bool {
        switch self {
        case .actionFirst, .actionOnly:
            true
        case .synthFirst, .synthOnly:
            false
        }
    }
}
