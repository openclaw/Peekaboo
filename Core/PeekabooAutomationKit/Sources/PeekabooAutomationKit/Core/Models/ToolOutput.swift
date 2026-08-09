import Foundation

/// Unified output structure for all Peekaboo tools
/// Used by CLI, Agent, macOS app, and MCP server
public struct UnifiedToolOutput<T: Codable & Sendable>: Codable, Sendable {
    /// The actual data returned by the tool
    public let data: T

    /// Human and agent-readable summary information
    public let summary: Summary

    /// Metadata about the tool execution
    public let metadata: Metadata

    public init(data: T, summary: Summary, metadata: Metadata) {
        self.data = data
        self.summary = summary
        self.metadata = metadata
    }

    /// Summary information for quick understanding of results
    public struct Summary: Codable, Sendable {
        /// One-line summary of the result (e.g., "Found 5 apps")
        public let brief: String

        /// Optional detailed description
        public let detail: String?

        /// Execution status
        public let status: Status

        /// Key counts from the operation
        public let counts: [String: Int]

        /// Important items to highlight
        public let highlights: [Highlight]

        public init(
            brief: String,
            detail: String? = nil,
            status: Status,
            counts: [String: Int] = [:],
            highlights: [Highlight] = [])
        {
            self.brief = brief
            self.detail = detail
            self.status = status
            self.counts = counts
            self.highlights = highlights
        }

        public enum Status: String, Codable, Sendable {
            case success
            case partial
            case failed
        }

        public enum HighlightKind: String, Codable, Sendable {
            case primary // The main item (e.g., active app)
            case warning // Something needing attention
            case info // Additional context
        }

        public struct Highlight: Codable, Sendable {
            public let label: String
            public let value: String
            public let kind: HighlightKind

            public init(label: String, value: String, kind: HighlightKind) {
                self.label = label
                self.value = value
                self.kind = kind
            }
        }
    }

    /// Metadata about the tool execution
    public struct Metadata: Codable, Sendable {
        /// Execution duration in seconds
        public let duration: Double

        /// Any warnings generated during execution
        public let warnings: [String]

        /// Helpful hints for next actions
        public let hints: [String]

        public init(
            duration: Double,
            warnings: [String] = [],
            hints: [String] = [])
        {
            self.duration = duration
            self.warnings = warnings
            self.hints = hints
        }
    }
}

// MARK: - Convenience Extensions

extension UnifiedToolOutput {
    /// Convert to JSON string for CLI output
    public func toJSON(prettyPrinted: Bool = true) throws -> String {
        // Convert to JSON string for CLI output
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        }
        let data = try encoder.encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - Specific Tool Data Types

/// Data structure for application list results
public nonisolated struct ServiceApplicationListData: Codable, Sendable {
    public let applications: [ServiceApplicationInfo]

    public init(applications: [ServiceApplicationInfo]) {
        self.applications = applications
    }
}

/// Data structure for window list results
public nonisolated struct ServiceWindowListData: Codable, Sendable {
    public let windows: [ServiceWindowInfo]
    public let targetApplication: ServiceApplicationInfo?

    public init(windows: [ServiceWindowInfo], targetApplication: ServiceApplicationInfo? = nil) {
        self.windows = windows
        self.targetApplication = targetApplication
    }
}
