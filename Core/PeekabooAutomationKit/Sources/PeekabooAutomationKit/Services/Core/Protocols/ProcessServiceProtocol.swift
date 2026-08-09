import Foundation

/// Service for executing Peekaboo automation scripts
@available(macOS 14.0, *)
@MainActor
public protocol ProcessServiceProtocol: Sendable {
    /// Load and validate a Peekaboo script from file
    /// - Parameter path: Path to the script file (.peekaboo.json)
    /// - Returns: The loaded script structure
    /// - Throws: ProcessServiceError if the script cannot be loaded or is invalid
    func loadScript(from path: String) async throws -> PeekabooScript

    /// Execute a Peekaboo script
    /// - Parameters:
    ///   - script: The script to execute
    ///   - failFast: Whether to stop execution on first error (default: true)
    ///   - verbose: Whether to provide detailed step execution information
    /// - Returns: Array of step results
    /// - Throws: ProcessServiceError if execution fails
    func executeScript(
        _ script: PeekabooScript,
        failFast: Bool,
        verbose: Bool) async throws -> [StepResult]

    /// Execute a single step from a script
    /// - Parameters:
    ///   - step: The step to execute
    ///   - snapshotId: Optional snapshot ID to use for the step
    /// - Returns: The result of the step execution
    /// - Throws: ProcessServiceError if the step fails
    func executeStep(
        _ step: ScriptStep,
        snapshotId: String?) async throws -> StepExecutionResult
}

/// Script structure for Peekaboo automation
public nonisolated struct PeekabooScript: Codable, Sendable {
    // Load and validate a Peekaboo script from file
    public let description: String?
    public let steps: [ScriptStep]

    public init(description: String?, steps: [ScriptStep]) {
        self.description = description
        self.steps = steps
    }
}

/// Individual step in a script
public struct ScriptStep: Codable, Sendable {
    public let stepId: String
    public let comment: String?
    public let command: String
    public let params: ProcessCommandParameters?

    public init(
        stepId: String,
        comment: String?,
        command: String,
        params: ProcessCommandParameters?)
    {
        self.stepId = stepId
        self.comment = comment
        self.command = command
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case stepId
        case comment
        case command
        case params
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stepId = try container.decode(String.self, forKey: .stepId)
        self.comment = try container.decodeIfPresent(String.self, forKey: .comment)
        self.command = try container.decode(String.self, forKey: .command)

        guard container.contains(.params), try !(container.decodeNil(forKey: .params)) else {
            self.params = nil
            return
        }

        // Continue accepting the original synthesized enum representation so existing scripts keep working.
        if let legacy = try? container.decode(ProcessCommandParameters.self, forKey: .params) {
            self.params = legacy
            return
        }

        let flat = try container.decode([String: FlatScriptParameter?].self, forKey: .params)
        self.params = .generic(flat.compactMapValues { $0?.stringValue })
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.stepId, forKey: .stepId)
        try container.encodeIfPresent(self.comment, forKey: .comment)
        try container.encode(self.command, forKey: .command)

        guard let params else {
            try container.encodeNil(forKey: .params)
            return
        }

        let paramsEncoder = container.superEncoder(forKey: .params)
        switch params {
        case let .click(value): try value.encode(to: paramsEncoder)
        case let .type(value): try value.encode(to: paramsEncoder)
        case let .hotkey(value): try value.encode(to: paramsEncoder)
        case let .scroll(value): try value.encode(to: paramsEncoder)
        case let .menuClick(value): try value.encode(to: paramsEncoder)
        case let .dialog(value): try value.encode(to: paramsEncoder)
        case let .launchApp(value): try value.encode(to: paramsEncoder)
        case let .findElement(value): try value.encode(to: paramsEncoder)
        case let .screenshot(value): try value.encode(to: paramsEncoder)
        case let .focusWindow(value): try value.encode(to: paramsEncoder)
        case let .resizeWindow(value): try value.encode(to: paramsEncoder)
        case let .swipe(value): try value.encode(to: paramsEncoder)
        case let .drag(value): try value.encode(to: paramsEncoder)
        case let .sleep(value): try value.encode(to: paramsEncoder)
        case let .dock(value): try value.encode(to: paramsEncoder)
        case let .clipboard(value): try value.encode(to: paramsEncoder)
        case let .generic(value): try value.encode(to: paramsEncoder)
        }
    }
}

/// Scalar or string-list values accepted by the stable, flat script parameter schema.
private enum FlatScriptParameter: Decodable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case strings([String])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode([String].self) {
            self = .strings(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Script params must be strings, booleans, numbers, or string arrays")
        }
    }

    var stringValue: String {
        switch self {
        case let .string(value): value
        case let .bool(value): String(value)
        case let .int(value): String(value)
        case let .double(value): String(value)
        case let .strings(value): value.joined(separator: ",")
        }
    }
}

/// Result of executing a script step
public struct StepResult: Codable, Sendable {
    public let stepId: String
    public let stepNumber: Int
    public let command: String
    public let success: Bool
    public let output: ProcessCommandOutput?
    public let error: String?
    public let executionTime: TimeInterval
    /// Wall-clock time immediately before the step started executing.
    public let startedAt: Date?
    /// Snapshot carried or produced by the step, when applicable.
    public let snapshotId: String?
    /// Host-confirmed desktop mutation completion boundary for a produced observation.
    public let desktopMutationCompletedAt: Date?
    /// Whether the host certified that the produced observation may remain implicit-latest.
    public let desktopMutationPreservationAllowed: Bool?

    public init(
        stepId: String,
        stepNumber: Int,
        command: String,
        success: Bool,
        output: ProcessCommandOutput?,
        error: String?,
        executionTime: TimeInterval,
        startedAt: Date? = nil,
        snapshotId: String? = nil,
        desktopMutationCompletedAt: Date? = nil,
        desktopMutationPreservationAllowed: Bool? = nil)
    {
        self.stepId = stepId
        self.stepNumber = stepNumber
        self.command = command
        self.success = success
        self.output = output
        self.error = error
        self.executionTime = executionTime
        self.startedAt = startedAt
        self.snapshotId = snapshotId
        self.desktopMutationCompletedAt = desktopMutationCompletedAt
        self.desktopMutationPreservationAllowed = desktopMutationPreservationAllowed
    }
}

/// Detailed result from step execution
public struct StepExecutionResult: Sendable {
    public let output: ProcessCommandOutput?
    public let snapshotId: String?
    public let desktopMutationCompletedAt: Date?
    public let desktopMutationPreservationAllowed: Bool?

    public init(
        output: ProcessCommandOutput?,
        snapshotId: String?,
        desktopMutationCompletedAt: Date? = nil,
        desktopMutationPreservationAllowed: Bool? = nil)
    {
        self.output = output
        self.snapshotId = snapshotId
        self.desktopMutationCompletedAt = desktopMutationCompletedAt
        self.desktopMutationPreservationAllowed = desktopMutationPreservationAllowed
    }
}
