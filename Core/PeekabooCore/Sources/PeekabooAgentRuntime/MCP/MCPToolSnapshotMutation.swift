import Foundation
import TachikomaMCP

public enum MCPToolSnapshotEffect: Sendable, Equatable {
    case none
    case freshObservation
    case mutation
    case mutationProducingFreshObservation
}

public actor MCPToolSnapshotExecutionGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private var locked = false
    private var waiters: [Waiter] = []
    private var pendingInvalidationScope: MCPToolSnapshotMutationScope?

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

    func pendingInvalidation() -> MCPToolSnapshotMutationScope? {
        self.pendingInvalidationScope
    }

    func recordPendingInvalidation(_ scope: MCPToolSnapshotMutationScope) {
        guard let pendingInvalidationScope else {
            self.pendingInvalidationScope = scope
            return
        }
        let pendingCutoff = pendingInvalidationScope.invalidationCutoff(succeeded: false)
        let newCutoff = scope.invalidationCutoff(succeeded: false)
        if newCutoff > pendingCutoff {
            self.pendingInvalidationScope = scope
        }
    }

    func clearPendingInvalidation(id: UUID) {
        guard self.pendingInvalidationScope?.id == id else { return }
        self.pendingInvalidationScope = nil
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
        case "click", "type", "set_value", "perform_action", "scroll", "hotkey", "swipe", "drag", "move",
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
            arguments.getString("action") == "list" ? MCPToolSnapshotEffect.none : .mutation
        case "window":
            arguments.getString("action") == "list" ? MCPToolSnapshotEffect.none : .mutation
        case "menu":
            arguments.getString("action") == "click" ? .mutation : MCPToolSnapshotEffect.none
        case "dialog":
            self.dialogEffect(arguments: arguments)
        case "dock", "space":
            arguments.getString("action") == "list" ? MCPToolSnapshotEffect.none : .mutation
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
        guard arguments.getString("action") == "list" else { return .mutation }
        let hasTarget = ["app", "window_title"].contains { key in
            !(arguments.getString(key)?.isEmpty ?? true)
        } || ["pid", "window_id", "window_index"].contains { key in
            arguments.getInt(key) != nil
        }
        return hasTarget ? .mutation : .none
    }

    private static func clipboardEffect(arguments: ToolArguments) -> MCPToolSnapshotEffect {
        switch arguments.getString("action") {
        case "set", "clear", "restore", "load":
            .mutation
        default:
            .none
        }
    }

    private static func browserEffect(arguments: ToolArguments) -> MCPToolSnapshotEffect {
        guard let action = arguments.getString("action") else { return .none }
        let readOnlyActions = [
            "status",
            "connect",
            "disconnect",
            "list_pages",
            "snapshot",
            "screenshot",
            "console",
            "network",
            "wait_for",
        ]
        return readOnlyActions.contains(action) ? .none : .mutation
    }
}
