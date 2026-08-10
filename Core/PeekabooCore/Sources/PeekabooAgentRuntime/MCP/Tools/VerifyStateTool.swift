import CoreGraphics
import Darwin
import MCP
import PeekabooAutomationKit
import TachikomaMCP

/// Polls native window and accessibility state without focusing or mutating the target.
public struct VerifyStateTool: MCPTool {
    let context: MCPToolContext
    let processStartIdentityProvider: @Sendable (pid_t) -> UInt64?
    let windowIdentityProvider: @Sendable (CGWindowID) -> SystemWindowIdentity?

    public let name = "verify_state"

    public var description: String {
        """
        Waits for 1–8 AND predicates against one exact app/PID and its exact resolved window.
        When an incomplete observation creates completion-evidence debt, the first same-target call commits this
        exact predicate set but cannot clear the debt. Repeat the identical target and predicates; only a later
        fully satisfied receipt can authorize completion.
        It polls fresh native window/Accessibility state every 100 ms, requires two identical
        satisfied samples by default, and never focuses, clicks, types, or replays an action.
        The hard timeout is 10 seconds. Results are `satisfied`, `unsatisfied`, or `unknown`;
        truncated, stale, ambiguous, process-generation-changed, or owner-mismatched observations are `unknown`.
        Predicates are structured JSON objects, never prose strings or AX expressions. For example:
        {"kind":"element_value","selector":{"identifier":"basic-text-field"},"expected_value":"Ready"}
        """
    }

    public var inputSchema: Value {
        SchemaBuilder.object(
            properties: [
                "app": SchemaBuilder.string(
                    description: "Exact running app name or bundle ID, pinned to its first PID. Exclusive with pid."),
                "pid": SchemaBuilder.integer(
                    description: "Exact running process ID. Mutually exclusive with app.",
                    minimum: 1),
                "window_id": SchemaBuilder.integer(
                    description: "Optional exact CoreGraphics window ID. Its live PID/process ownership is verified.",
                    minimum: 1,
                    maximum: Int(UInt32.max)),
                "window_title": SchemaBuilder.string(
                    description: "Optional window-title substring resolved on every poll. " +
                        "Exclusive with other window selectors."),
                "window_index": SchemaBuilder.integer(
                    description: "Optional window index resolved on every poll. Exclusive with other window selectors.",
                    minimum: 0),
                "predicates": SchemaBuilder.array(
                    items: Self.predicateSchema,
                    description: "One to eight structured predicate objects. Every predicate must be satisfied.",
                    minItems: 1,
                    maxItems: 8),
                "timeout_ms": SchemaBuilder.integer(
                    description: "Polling timeout in milliseconds; hard-capped at 10000.",
                    minimum: 100,
                    maximum: 10000,
                    default: VerifyStateRequest.defaultTimeoutMilliseconds),
                "stable_samples": SchemaBuilder.integer(
                    description: "Consecutive identical satisfied samples required.",
                    minimum: 1,
                    maximum: 10,
                    default: 2),
                "final_screenshot": SchemaBuilder.boolean(
                    description: "Attach one silent exact-window screenshot after verification when available.",
                    default: false),
            ],
            required: ["predicates"])
    }

    public init(context: MCPToolContext = .shared) {
        self.context = context
        self.processStartIdentityProvider = SystemIdentityResolver.processStartIdentity
        self.windowIdentityProvider = SystemIdentityResolver.windowIdentity
    }

    init(
        context: MCPToolContext,
        processStartIdentityProvider: @escaping @Sendable (pid_t) -> UInt64?,
        windowIdentityProvider: @escaping @Sendable (CGWindowID) -> SystemWindowIdentity?)
    {
        self.context = context
        self.processStartIdentityProvider = processStartIdentityProvider
        self.windowIdentityProvider = windowIdentityProvider
    }

    @MainActor
    public func execute(arguments: ToolArguments) async throws -> ToolResponse {
        do {
            let request = try VerifyStateRequest(arguments: arguments)
            return try await self.verify(request)
        } catch let error as VerifyStateInputError {
            return ToolResponse.error("Invalid verify_state request: \(error.message)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ToolResponse.error("Failed to verify state: \(error.localizedDescription)")
        }
    }

    private static var selectorSchema: Value {
        SchemaBuilder.object(
            properties: [
                "identifier": SchemaBuilder.string(description: "Exact AXIdentifier."),
                "label": SchemaBuilder.string(description: "Exact accessibility label."),
                "role": SchemaBuilder.string(description: "Exact AX role or Peekaboo element type."),
            ],
            description: "Exact-match selector. Provide at least one field.")
    }

    private static var boundsSchema: Value {
        SchemaBuilder.object(
            properties: [
                "x": SchemaBuilder.number(),
                "y": SchemaBuilder.number(),
                "width": SchemaBuilder.number(minimum: 0),
                "height": SchemaBuilder.number(minimum: 0),
            ],
            required: ["x", "y", "width", "height"])
    }

    private static var predicateSchema: Value {
        SchemaBuilder.oneOf([
            SchemaBuilder.object(
                properties: [
                    "kind": SchemaBuilder.string(enum: ["window_exists"]),
                    "expected": SchemaBuilder.boolean(),
                ],
                required: ["kind", "expected"]),
            SchemaBuilder.object(
                properties: [
                    "kind": SchemaBuilder.string(enum: ["window_bounds"]),
                    "bounds": self.boundsSchema,
                    "tolerance": SchemaBuilder.number(minimum: 0, maximum: 100, default: 1),
                ],
                required: ["kind", "bounds"]),
            SchemaBuilder.object(
                properties: [
                    "kind": SchemaBuilder.string(enum: ["element_exists"]),
                    "selector": self.selectorSchema,
                    "expected": SchemaBuilder.boolean(),
                ],
                required: ["kind", "selector", "expected"]),
            SchemaBuilder.object(
                properties: [
                    "kind": SchemaBuilder.string(enum: ["element_value"]),
                    "selector": self.selectorSchema,
                    "expected_value": SchemaBuilder.string(),
                ],
                required: ["kind", "selector", "expected_value"]),
            SchemaBuilder.object(
                properties: [
                    "kind": SchemaBuilder.string(enum: ["element_enabled"]),
                    "selector": self.selectorSchema,
                    "expected": SchemaBuilder.boolean(),
                ],
                required: ["kind", "selector", "expected"]),
            SchemaBuilder.object(
                properties: [
                    "kind": SchemaBuilder.string(enum: ["element_selected"]),
                    "selector": self.selectorSchema,
                    "expected": SchemaBuilder.boolean(),
                ],
                required: ["kind", "selector", "expected"]),
        ], description: VerifyStatePredicateContract.schemaDescription)
    }
}
