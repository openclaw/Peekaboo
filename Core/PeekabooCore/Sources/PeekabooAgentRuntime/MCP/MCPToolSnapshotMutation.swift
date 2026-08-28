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

    static func requiresScreenCaptureKitOwnerPreflight(
        toolName: String,
        arguments: ToolArguments) -> Bool?
    {
        guard let requiresPixels = self.requiresPixels(toolName: toolName, arguments: arguments) else { return nil }
        guard requiresPixels else { return false }
        if toolName == "see",
           arguments.getString("capture_engine")?
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .lowercased() == "classic"
        {
            return false
        }
        return true
    }
}

struct MCPToolPendingSnapshotInvalidation: Sendable, Equatable {
    let scope: MCPToolSnapshotMutationScope
    let owner: MCPToolSnapshotOwner
    let usesCoordinatorBarrier: Bool
    let snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scope == rhs.scope &&
            lhs.owner == rhs.owner &&
            lhs.usesCoordinatorBarrier == rhs.usesCoordinatorBarrier
    }
}

public actor MCPToolSnapshotExecutionGate {
    private struct ExclusiveWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct SharedWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, any Error>
    }

    private var locked = false
    private var sharedHolderCount = 0
    private var exclusiveWaiters: [ExclusiveWaiter] = []
    private var sharedWaiters: [SharedWaiter] = []
    private var pendingInvalidationRecords: [UUID: MCPToolPendingSnapshotInvalidation] = [:]
    private var pendingInvalidationOrder: [UUID] = []

    public init() {}

    func acquire() async throws {
        try Task.checkCancellation()
        guard self.locked || self.sharedHolderCount > 0 else {
            self.locked = true
            return
        }

        let waiterID = UUID()
        let _: Void = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.exclusiveWaiters.append(ExclusiveWaiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelExclusiveWaiter(id: waiterID)
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
        self.locked = false
        self.resumeWaitersIfPossible()
    }

    func acquireSharedIfNoPendingInvalidation() async throws -> Bool {
        try Task.checkCancellation()
        if !self.pendingInvalidationOrder.isEmpty {
            return false
        }
        if !self.locked, self.exclusiveWaiters.isEmpty {
            self.sharedHolderCount += 1
            return true
        }

        let waiterID = UUID()
        let acquired: Bool = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    self.sharedWaiters.append(SharedWaiter(id: waiterID, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelSharedWaiter(id: waiterID)
            }
        }
        do {
            try Task.checkCancellation()
            return acquired
        } catch {
            if acquired {
                self.releaseShared()
            }
            throw error
        }
    }

    func releaseShared() {
        guard self.sharedHolderCount > 0 else { return }
        self.sharedHolderCount -= 1
        self.resumeWaitersIfPossible()
    }

    func pendingInvalidation() -> MCPToolPendingSnapshotInvalidation? {
        guard let id = self.pendingInvalidationOrder.first else { return nil }
        return self.pendingInvalidationRecords[id]
    }

    func recordPendingInvalidation(
        _ scope: MCPToolSnapshotMutationScope,
        owner: MCPToolSnapshotOwner,
        usesCoordinatorBarrier: Bool,
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)?)
    {
        if self.pendingInvalidationRecords[scope.id] == nil {
            self.pendingInvalidationOrder.append(scope.id)
        }
        self.pendingInvalidationRecords[scope.id] = MCPToolPendingSnapshotInvalidation(
            scope: scope,
            owner: owner,
            usesCoordinatorBarrier: usesCoordinatorBarrier,
            snapshotMutationCoordinator: snapshotMutationCoordinator)
    }

    func clearPendingInvalidation(id: UUID) {
        self.pendingInvalidationRecords.removeValue(forKey: id)
        self.pendingInvalidationOrder.removeAll { $0 == id }
    }

    private func resumeWaitersIfPossible() {
        guard !self.locked, self.sharedHolderCount == 0 else { return }
        if !self.exclusiveWaiters.isEmpty {
            self.locked = true
            self.exclusiveWaiters.removeFirst().continuation.resume()
            return
        }
        let canAcquire = self.pendingInvalidationOrder.isEmpty
        let waiters = self.sharedWaiters
        self.sharedWaiters.removeAll()
        if canAcquire {
            self.sharedHolderCount = waiters.count
        }
        for waiter in waiters {
            waiter.continuation.resume(returning: canAcquire)
        }
    }

    private func cancelExclusiveWaiter(id: UUID) {
        guard let index = self.exclusiveWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = self.exclusiveWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func cancelSharedWaiter(id: UUID) {
        guard let index = self.sharedWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = self.sharedWaiters.remove(at: index)
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

    /// Records a mutation that owns a caller-local execution lane without acquiring the shared durable barrier.
    @MainActor
    func prepareConcurrentMutation(_ scope: MCPToolSnapshotMutationScope) throws

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
    public func prepareConcurrentMutation(_ scope: MCPToolSnapshotMutationScope) throws {
        try self.prepareMutation(scope)
    }

    @MainActor
    public func completeMutationBarrier(
        _: MCPToolSnapshotMutationScope) throws -> MCPToolMutationBarrierCompletion?
    {
        nil
    }

    @MainActor
    public func cancelMutation(_ scope: MCPToolSnapshotMutationScope) async -> Bool {
        do {
            _ = try self.completeMutationBarrier(scope)
        } catch {
            return false
        }
        return await self.completeMutation(scope, succeeded: false)
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
        return BrowserMCPCallMapper.effectiveActionSemantics(action: action, arguments: arguments) == .mutating
            ? .mutation
            : .none
    }
}

/// Invocation-level visual verification derived from the canonical mutation effect.
///
/// Browser connection state is intentionally nonvisual even though connecting mutates the session.
/// Empty arguments preserve broad verification for tools whose concrete action is unavailable.
enum MCPToolVisualVerificationPolicy {
    static func requiresVerification(toolName: String, stringArguments: [String: String]) -> Bool {
        guard !stringArguments.isEmpty else { return true }
        let arguments = ToolArguments(raw: stringArguments.mapValues(Self.typedArgumentValue))
        if toolName == "browser",
           let actionName = arguments.getString("action"),
           let action = BrowserAction(rawValue: actionName)
        {
            switch action {
            case .status, .connect, .disconnect:
                return false
            default:
                break
            }
        }
        return MCPToolSnapshotMutationPolicy.effect(toolName: toolName, arguments: arguments) != .none
    }

    private static func typedArgumentValue(_ value: String) -> Any {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": true
        case "false": false
        default: value
        }
    }
}
