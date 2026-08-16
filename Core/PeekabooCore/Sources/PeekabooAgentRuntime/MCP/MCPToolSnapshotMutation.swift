import Foundation
import TachikomaMCP

public enum MCPToolSnapshotEffect: Sendable, Equatable {
    case none
    case freshObservation
    case conditionalMutation
    case mutation
    case mutationProducingFreshObservation
}

/// Shared request semantics used by both snapshot planning and Agent turn boundaries.
///
/// Keep this classification argument-only and conservative. Leaf services still prove that an advertised read did
/// not dispatch a mutation; this planner only decides whether the request needs the mutation gate and fresh-UI debt.
enum MCPToolRequestSemantics {
    static func isReadOnly(toolName: String, arguments: ToolArguments) -> Bool {
        let action = self.normalized(arguments.getString("action"))
        return switch toolName {
        case "app":
            action == "list" || self.isSafeBackgroundApplicationLaunchNoOp(arguments)
        case "dialog", "dock", "space", "window":
            action == "list"
        case "menu":
            action == "list" && self.isFalseOrAbsent(arguments, key: "foreground")
        default:
            false
        }
    }

    static func isSafeBackgroundApplicationLaunchNoOp(_ arguments: ToolArguments) -> Bool {
        self.normalized(arguments.getString("action")) == "launch" &&
            self.isFalseOrAbsent(arguments, key: "foreground") &&
            self.isFalseOrAbsent(arguments, key: "newInstance") &&
            self.isAbsentOrEmptyStringArray(arguments, key: "openTargets")
    }

    private static func isFalseOrAbsent(_ arguments: ToolArguments, key: String) -> Bool {
        guard let value = arguments.getValue(for: key) else { return true }
        return value == .bool(false)
    }

    private static func isAbsentOrEmptyStringArray(_ arguments: ToolArguments, key: String) -> Bool {
        guard let value = arguments.getValue(for: key) else { return true }
        guard case let .array(values) = value else { return false }
        return values.isEmpty
    }

    private static func normalized(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}

enum MCPToolCaptureRequirement: Sendable, Equatable {
    case never
    case always
    case liveCaptureSource
    case requestedFinalScreenshot

    static func profile(toolName: String) -> MCPToolCaptureRequirement? {
        switch toolName {
        case "see", "image":
            .always
        case "capture":
            .liveCaptureSource
        case "verify_state":
            .requestedFinalScreenshot
        case "analyze", "browser", "permissions", "sleep", "inspect_ui", "click", "type", "set_value",
             "action", "scroll", "press", "drag", "move", "app", "window", "menu", "clipboard", "paste",
             "agent", "dock", "dialog", "space":
            .never
        default:
            nil
        }
    }

    static func requiresPixels(toolName: String, arguments: ToolArguments) -> Bool? {
        switch self.profile(toolName: toolName) {
        case .never:
            false
        case .always:
            true
        case .liveCaptureSource:
            arguments.getString("source")?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() != "video"
        case .requestedFinalScreenshot:
            arguments.getBool("final_screenshot") == true
        case nil:
            nil
        }
    }
}

struct MCPToolPendingSnapshotInvalidation: Sendable, Equatable {
    let scope: MCPToolSnapshotMutationScope
    let owner: MCPToolSnapshotOwner
}

public actor MCPToolSnapshotExecutionGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var locked = false
    private var waiters: [Waiter] = []
    private var pendingInvalidationRecord: MCPToolPendingSnapshotInvalidation?

    public init() {}

    func acquire() async throws {
        try Task.checkCancellation()
        guard self.locked else {
            self.locked = true
            return
        }

        let waiterID = UUID()
        let _: Void = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.waiters.append(Waiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }

        do {
            try Task.checkCancellation()
        } catch {
            self.release()
            throw error
        }
    }

    func release() {
        guard !self.waiters.isEmpty else {
            self.locked = false
            return
        }
        self.waiters.removeFirst().continuation.resume()
    }

    func pendingInvalidation() -> MCPToolPendingSnapshotInvalidation? {
        self.pendingInvalidationRecord
    }

    func recordPendingInvalidation(
        _ scope: MCPToolSnapshotMutationScope,
        owner: MCPToolSnapshotOwner)
    {
        guard let pendingInvalidation = self.pendingInvalidationRecord else {
            self.pendingInvalidationRecord = MCPToolPendingSnapshotInvalidation(scope: scope, owner: owner)
            return
        }
        let pendingCutoff = pendingInvalidation.scope.invalidationCutoff(succeeded: false)
        let newCutoff = scope.invalidationCutoff(succeeded: false)
        if newCutoff > pendingCutoff {
            self.pendingInvalidationRecord = MCPToolPendingSnapshotInvalidation(scope: scope, owner: owner)
        }
    }

    func clearPendingInvalidation(id: UUID) {
        guard self.pendingInvalidationRecord?.scope.id == id else { return }
        self.pendingInvalidationRecord = nil
    }

    private func cancelWaiter(id: UUID) {
        guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = self.waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

public struct MCPToolSnapshotMutationScope: Sendable, Equatable {
    public let id: UUID
    public let toolName: String
    public let startedAt: Date
    public let effect: MCPToolSnapshotEffect
    public let preservedSnapshotID: String?
    public let completedAt: Date?
    public let confirmedMutationCompletedAt: Date?
    public let observationPreservationAllowed: Bool?

    public init(
        id: UUID = UUID(),
        toolName: String,
        startedAt: Date = Date(),
        effect: MCPToolSnapshotEffect,
        preservedSnapshotID: String? = nil,
        completedAt: Date? = nil,
        confirmedMutationCompletedAt: Date? = nil,
        observationPreservationAllowed: Bool? = nil)
    {
        self.id = id
        self.toolName = toolName
        self.startedAt = startedAt
        self.effect = effect
        self.preservedSnapshotID = preservedSnapshotID
        self.completedAt = completedAt
        self.confirmedMutationCompletedAt = confirmedMutationCompletedAt
        self.observationPreservationAllowed = observationPreservationAllowed
    }

    public func invalidationCutoff(completedAt: Date = Date(), succeeded: Bool) -> Date {
        if succeeded, self.effect == .mutationProducingFreshObservation {
            return self.confirmedMutationCompletedAt ?? self.startedAt
        }
        return self.completedAt ?? completedAt
    }

    public func completed(
        at completedAt: Date,
        preserving snapshotID: String?,
        confirmedMutationCompletedAt: Date? = nil,
        observationPreservationAllowed: Bool? = nil) -> Self
    {
        Self(
            id: self.id,
            toolName: self.toolName,
            startedAt: self.startedAt,
            effect: self.effect,
            preservedSnapshotID: snapshotID,
            completedAt: completedAt,
            confirmedMutationCompletedAt: confirmedMutationCompletedAt,
            observationPreservationAllowed: observationPreservationAllowed)
    }
}

public struct MCPToolMutationBarrierCompletion: Sendable, Equatable {
    public let cutoff: Date
    public let allowsObservationPreservation: Bool

    public init(cutoff: Date, allowsObservationPreservation: Bool) {
        self.cutoff = cutoff
        self.allowsObservationPreservation = allowsObservationPreservation
    }
}

public protocol MCPToolSnapshotMutationCoordinating: Sendable {
    @MainActor
    func prepareMutation(_ scope: MCPToolSnapshotMutationScope) throws

    @MainActor
    func completeMutationBarrier(
        _ scope: MCPToolSnapshotMutationScope) throws -> MCPToolMutationBarrierCompletion?

    @MainActor
    @discardableResult
    func completeMutation(_ scope: MCPToolSnapshotMutationScope, succeeded: Bool) async -> Bool

    /// Cancel preparation when a tool proves that no mutation was dispatched.
    @MainActor
    @discardableResult
    func cancelMutation(_ scope: MCPToolSnapshotMutationScope) async -> Bool
}

extension MCPToolSnapshotMutationCoordinating {
    @MainActor
    public func prepareMutation(_: MCPToolSnapshotMutationScope) throws {}

    @MainActor
    public func completeMutationBarrier(
        _: MCPToolSnapshotMutationScope) throws -> MCPToolMutationBarrierCompletion?
    {
        nil
    }

    @MainActor
    public func cancelMutation(_: MCPToolSnapshotMutationScope) async -> Bool {
        true
    }
}

enum MCPToolSnapshotMutationPolicy {
    static func effect(toolName: String, arguments: ToolArguments) -> MCPToolSnapshotEffect {
        self.explicitEffect(toolName: toolName, arguments: arguments) ?? .none
    }

    static func explicitEffect(toolName: String, arguments: ToolArguments) -> MCPToolSnapshotEffect? {
        switch toolName {
        case "click", "type", "set_value", "action", "scroll", "press", "drag", "move",
             "paste", "shell":
            .mutation
        case "see":
            self.observationEffect(arguments: arguments)
        case "inspect_ui":
            self.observationEffect(arguments: arguments)
        case "verify_state":
            .freshObservation
        case "image":
            self.captureEffect(arguments: arguments)
        case "capture":
            self.captureEffect(arguments: arguments)
        case "app":
            if MCPToolRequestSemantics.isSafeBackgroundApplicationLaunchNoOp(arguments) {
                .conditionalMutation
            } else {
                MCPToolRequestSemantics.isReadOnly(toolName: toolName, arguments: arguments)
                    ? MCPToolSnapshotEffect.none
                    : .mutation
            }
        case "window", "menu":
            MCPToolRequestSemantics.isReadOnly(toolName: toolName, arguments: arguments)
                ? MCPToolSnapshotEffect.none
                : .mutation
        case "dialog":
            self.dialogEffect(arguments: arguments)
        case "dock", "space":
            MCPToolRequestSemantics.isReadOnly(toolName: toolName, arguments: arguments)
                ? MCPToolSnapshotEffect.none
                : .mutation
        case "clipboard":
            self.clipboardEffect(arguments: arguments)
        case "browser":
            self.browserEffect(arguments: arguments)
        case "permissions":
            arguments.getString("action") == "request" ? .mutation : MCPToolSnapshotEffect.none
        case "agent":
            // Nested agent tools acquire this gate themselves; locking the outer call would deadlock.
            MCPToolSnapshotEffect.none
        case "analyze", "sleep":
            MCPToolSnapshotEffect.none
        default:
            nil
        }
    }

    private static func captureEffect(arguments: ToolArguments) -> MCPToolSnapshotEffect {
        switch arguments.getString("capture_focus")?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "auto", "foreground": .mutation
        default: .none
        }
    }

    private static func observationEffect(arguments: ToolArguments) -> MCPToolSnapshotEffect {
        arguments.getBool("web_focus") == true ? .mutationProducingFreshObservation : .freshObservation
    }

    static func scope(
        toolName: String,
        arguments: ToolArguments,
        startedAt: Date = Date()) -> MCPToolSnapshotMutationScope?
    {
        let effect = self.effect(toolName: toolName, arguments: arguments)
        guard effect != .none else { return nil }
        return MCPToolSnapshotMutationScope(
            toolName: toolName,
            startedAt: startedAt,
            effect: effect,
            preservedSnapshotID: effect == .mutationProducingFreshObservation
                ? arguments.getString("snapshot")
                : nil)
    }

    private static func dialogEffect(arguments: ToolArguments) -> MCPToolSnapshotEffect {
        MCPToolRequestSemantics.isReadOnly(toolName: "dialog", arguments: arguments) ? .none : .mutation
    }

    private static func clipboardEffect(arguments: ToolArguments) -> MCPToolSnapshotEffect {
        switch arguments.getString("action") {
        case "set", "clear", "restore":
            .mutation
        default:
            .none
        }
    }

    private static func browserEffect(arguments: ToolArguments) -> MCPToolSnapshotEffect {
        guard let actionName = arguments.getString("action"),
              let action = BrowserAction(rawValue: actionName)
        else { return .none }
        return BrowserMCPCallMapper.actionSemantics(action: action, arguments: arguments) == .mutating
            ? .mutation
            : .none
    }
}
