import Foundation
import MCP
import PeekabooAutomation
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// Lightweight dependency container for MCP tools so they no longer reach for
/// global singletons directly. Each tool can receive the subset of
/// services it needs, which keeps tests deterministic and unlocks DI.
public struct MCPToolContext: @unchecked Sendable {
    public let automation: any UIAutomationServiceProtocol
    public let menu: any MenuServiceProtocol
    public let windows: any WindowManagementServiceProtocol
    public let applications: any ApplicationServiceProtocol
    public let dialogs: any DialogServiceProtocol
    public let dock: any DockServiceProtocol
    public let screenCapture: any ScreenCaptureServiceProtocol
    public let desktopObservation: any DesktopObservationServiceProtocol
    public let snapshots: any SnapshotManagerProtocol
    public let screens: any ScreenServiceProtocol
    public let agent: (any AgentServiceProtocol)?
    public let permissions: PermissionsService
    public let permissionsStatusProvider: any PermissionsStatusProviding
    public let clipboard: any ClipboardServiceProtocol
    public let browser: any BrowserMCPClientProviding
    public let snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)?
    public let snapshotExecutionGate: MCPToolSnapshotExecutionGate

    @TaskLocal
    private static var taskOverride: MCPToolContext?
    @TaskLocal
    static var snapshotObservationStartedAt: Date?
    @MainActor
    private static var defaultContextFactory: (() -> MCPToolContext)?

    /// Default context backed by the configured factory closure.
    ///
    /// Task-local overrides can be read from any executor. Resolving the
    /// process-wide default synchronously requires the main thread; the guard
    /// provides an actionable diagnostic before `MainActor.assumeIsolated`
    /// verifies the executor. Off-main callers must use `sharedOnMainActor()`
    /// (an async actor hop) or pass an explicit `MCPToolContext`.
    /// This deliberately does **not** use `DispatchQueue.main.sync`, which can
    /// deadlock when the main actor is waiting on the calling task.
    public static var shared: MCPToolContext {
        if let override = self.taskOverride {
            return override
        }
        guard Thread.isMainThread else {
            fatalError(
                "MCPToolContext.shared must be accessed on the main thread. "
                    + "Use await MCPToolContext.sharedOnMainActor() or pass an explicit context.")
        }
        return MainActor.assumeIsolated {
            guard let factory = self.defaultContextFactory else {
                fatalError("MCPToolContext default factory not configured. Call configureDefaultContext(using:).")
            }
            return factory()
        }
    }

    /// Resolve `shared` from any isolation without a synchronous main-queue hop.
    @MainActor
    public static func sharedOnMainActor() -> MCPToolContext {
        self.shared
    }

    /// Temporarily override the shared context for the lifetime of `operation`.
    public static func withContext<T>(
        _ context: MCPToolContext,
        perform operation: () async throws -> T) async rethrows -> T
    {
        try await self.$taskOverride.withValue(context) {
            try await operation()
        }
    }

    /// Produce a fresh context using the process-wide services locator.
    ///
    /// Unconfigured factory is a programming error and traps. For recoverable
    /// construction (MCP server boot), use `makeDefaultIfConfigured()`.
    @MainActor
    public static func makeDefault() -> MCPToolContext {
        guard let factory = self.defaultContextFactory else {
            fatalError("MCPToolContext default factory not configured. Call configureDefaultContext(using:).")
        }
        return factory()
    }

    /// Recoverable default-context construction for callers that can fail open.
    ///
    /// Prefer this over `makeDefault()` at process/server startup so a missing
    /// factory becomes a thrown error instead of process termination.
    /// Does not change `ToolRegistry` or other programming-error invariants.
    @MainActor
    public static func makeDefaultIfConfigured() throws -> MCPToolContext {
        guard let factory = self.defaultContextFactory else {
            throw PeekabooError.operationError(
                message: "MCPToolContext default factory not configured. Call configureDefaultContext(using:).")
        }
        return factory()
    }

    /// Configure the default context factory used by `shared`/`makeDefault`.
    @MainActor
    public static func configureDefaultContext(using factory: @escaping () -> MCPToolContext) {
        self.defaultContextFactory = factory
    }

    /// Test helper that restores the exact process-wide factory after each case.
    @MainActor
    static func withDefaultContextFactoryForTesting<T>(
        _ factory: (() -> MCPToolContext)?,
        perform operation: @MainActor () async throws -> T) async rethrows -> T
    {
        let previousFactory = self.defaultContextFactory
        self.defaultContextFactory = factory
        defer { self.defaultContextFactory = previousFactory }
        return try await operation()
    }

    public init(
        automation: any UIAutomationServiceProtocol,
        menu: any MenuServiceProtocol,
        windows: any WindowManagementServiceProtocol,
        applications: any ApplicationServiceProtocol,
        dialogs: any DialogServiceProtocol,
        dock: any DockServiceProtocol,
        screenCapture: any ScreenCaptureServiceProtocol,
        desktopObservation: any DesktopObservationServiceProtocol,
        snapshots: any SnapshotManagerProtocol,
        screens: any ScreenServiceProtocol,
        agent: (any AgentServiceProtocol)?,
        permissions: PermissionsService,
        clipboard: any ClipboardServiceProtocol,
        browser: any BrowserMCPClientProviding,
        permissionsStatusProvider: (any PermissionsStatusProviding)? = nil,
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate? = nil)
    {
        self.automation = automation
        self.menu = menu
        self.windows = windows
        self.applications = applications
        self.dialogs = dialogs
        self.dock = dock
        self.screenCapture = screenCapture
        self.desktopObservation = desktopObservation
        self.snapshots = snapshots
        self.screens = screens
        self.agent = agent
        self.permissions = permissions
        self.permissionsStatusProvider = permissionsStatusProvider ?? permissions
        self.clipboard = clipboard
        self.browser = browser
        self.snapshotMutationCoordinator = snapshotMutationCoordinator
        self.snapshotExecutionGate = snapshotExecutionGate
            ?? (agent as? PeekabooAgentService)?.snapshotExecutionGate
            ?? MCPToolSnapshotExecutionGate()
    }

    @MainActor
    public init(
        services: any PeekabooServiceProviding,
        snapshotMutationCoordinator: (any MCPToolSnapshotMutationCoordinating)? = nil,
        snapshotExecutionGate: MCPToolSnapshotExecutionGate? = nil)
    {
        let resolvedSnapshotExecutionGate = snapshotExecutionGate
            ?? (services.agent as? PeekabooAgentService)?.snapshotExecutionGate
            ?? MCPToolSnapshotExecutionGate()
        self.init(
            automation: services.automation,
            menu: services.menu,
            windows: services.windows,
            applications: services.applications,
            dialogs: services.dialogs,
            dock: services.dock,
            screenCapture: services.screenCapture,
            desktopObservation: services.desktopObservation,
            snapshots: services.snapshots,
            screens: services.screens,
            agent: services.agent,
            permissions: services.permissions,
            clipboard: services.clipboard,
            browser: services.browser,
            permissionsStatusProvider: services,
            snapshotMutationCoordinator: snapshotMutationCoordinator,
            snapshotExecutionGate: resolvedSnapshotExecutionGate)
    }

    @MainActor
    public func execute(
        tool: any MCPTool,
        arguments: ToolArguments) async throws -> ToolResponse
    {
        if let rejection = MCPToolArgumentValidator.rejection(tool: tool, arguments: arguments) {
            return rejection
        }
        await UISnapshotManager.shared.synchronizeImplicitLatestInvalidationWatermark(
            self.snapshots.effectiveImplicitLatestInvalidationWatermark)
        let effect = MCPToolSnapshotMutationPolicy.effect(toolName: tool.name, arguments: arguments)
        guard effect != .none else {
            try Task.checkCancellation()
            let response = try await tool.execute(arguments: arguments)
            try Task.checkCancellation()
            return response
        }

        try await self.snapshotExecutionGate.acquire()
        do {
            try Task.checkCancellation()
            if let pendingScope = await self.snapshotExecutionGate.pendingInvalidation() {
                let retrySucceeded = await self.completeMutation(pendingScope, succeeded: false)
                try Task.checkCancellation()
                guard retrySucceeded else {
                    await self.snapshotExecutionGate.release()
                    return Self.pendingInvalidationResponse(
                        pendingScope: pendingScope,
                        blockedToolName: tool.name)
                }
                await self.snapshotExecutionGate.clearPendingInvalidation(id: pendingScope.id)
            }
        } catch {
            await self.snapshotExecutionGate.release()
            throw error
        }

        let scope = MCPToolSnapshotMutationScope(
            toolName: tool.name,
            effect: effect,
            preservedSnapshotID: effect == .mutationProducingFreshObservation
                ? arguments.getString("snapshot")
                : nil)
        var toolStarted = false
        do {
            try Task.checkCancellation()
            try self.snapshotMutationCoordinator?.prepareMutation(scope)
            toolStarted = true
            let response = try await Self.$snapshotObservationStartedAt.withValue(
                effect == .mutationProducingFreshObservation ? scope.startedAt : nil)
            {
                try await tool.execute(arguments: arguments)
            }
            try Task.checkCancellation()
            if Self.explicitlyNotDispatched(response) {
                let cancelled = await self.snapshotMutationCoordinator?.cancelMutation(scope) ?? true
                await self.snapshotExecutionGate.release()
                guard cancelled else {
                    return ToolResponse.error(
                        "The tool was refused before dispatch, but its mutation reservation could not be cancelled",
                        meta: response.meta)
                }
                return response
            }
            let completionCertificate = Self.mutationCompletionCertificate(response: response)
            let completedScope = scope.completed(
                at: Date(),
                preserving: response.isError ? nil : Self.refreshedSnapshotID(scope: scope, response: response),
                confirmedMutationCompletedAt: completionCertificate.completedAt,
                observationPreservationAllowed: completionCertificate.preservationAllowed)
            let completionSucceeded = await self.completeMutation(completedScope, succeeded: !response.isError)
            try Task.checkCancellation()
            if !completionSucceeded {
                if !response.isError,
                   effect == .freshObservation || effect == .mutationProducingFreshObservation
                {
                    let rollbackSucceeded = await self.completeMutation(completedScope, succeeded: false)
                    try Task.checkCancellation()
                    if !rollbackSucceeded {
                        await self.snapshotExecutionGate.recordPendingInvalidation(completedScope)
                    }
                    await self.snapshotExecutionGate.release()
                    return ToolResponse.error("Failed to publish the refreshed UI snapshot")
                }

                await self.snapshotExecutionGate.recordPendingInvalidation(completedScope)
                if response.isError {
                    await self.snapshotExecutionGate.release()
                    return response
                }

                await self.snapshotExecutionGate.release()
                return Self.mutationCompletionWarningResponse(
                    response,
                    toolName: tool.name)
            }
            await self.snapshotExecutionGate.release()
            return response
        } catch {
            if toolStarted {
                let failedScope = scope.completed(at: Date(), preserving: nil)
                let cleanupSucceeded = await self.completeMutation(failedScope, succeeded: false)
                if !cleanupSucceeded {
                    await self.snapshotExecutionGate.recordPendingInvalidation(failedScope)
                }
            }
            await self.snapshotExecutionGate.release()
            throw error
        }
    }

    @MainActor
    private func completeMutation(_ scope: MCPToolSnapshotMutationScope, succeeded: Bool) async -> Bool {
        guard scope.effect != .freshObservation else { return true }
        let resolvedScope: MCPToolSnapshotMutationScope
        do {
            if let barrier = try self.snapshotMutationCoordinator?.completeMutationBarrier(scope) {
                resolvedScope = scope.completed(
                    at: scope.completedAt ?? Date(),
                    preserving: scope.preservedSnapshotID,
                    confirmedMutationCompletedAt: max(
                        scope.confirmedMutationCompletedAt ?? barrier.cutoff,
                        barrier.cutoff),
                    observationPreservationAllowed: (scope.observationPreservationAllowed ?? true) &&
                        barrier.allowsObservationPreservation)
            } else {
                resolvedScope = scope
            }
        } catch {
            return false
        }
        let sharedWatermark = self.snapshots.effectiveImplicitLatestInvalidationWatermark
        let wantsPreservation = succeeded &&
            resolvedScope.effect == .mutationProducingFreshObservation &&
            resolvedScope.preservedSnapshotID != nil
        let preservationBoundary = resolvedScope.confirmedMutationCompletedAt ?? resolvedScope.startedAt
        let preservationAllowed = !wantsPreservation ||
            ((resolvedScope.observationPreservationAllowed ?? true) &&
                (sharedWatermark.map { $0 <= preservationBoundary } ?? true))
        let effectiveSucceeded = succeeded && preservationAllowed
        let requestedCutoff = resolvedScope.invalidationCutoff(succeeded: effectiveSucceeded)
        let cutoff = max(
            requestedCutoff,
            sharedWatermark ?? requestedCutoff)
        let preservedSnapshotID = effectiveSucceeded ? resolvedScope.preservedSnapshotID : nil
        await UISnapshotManager.shared.invalidateImplicitLatestSnapshot(
            through: cutoff,
            preserving: preservedSnapshotID,
            preservedAt: preservedSnapshotID == nil ? nil : resolvedScope.completedAt)

        let coordinatorScope = effectiveSucceeded ? resolvedScope : MCPToolSnapshotMutationScope(
            id: resolvedScope.id,
            toolName: resolvedScope.toolName,
            startedAt: resolvedScope.startedAt,
            effect: resolvedScope.effect,
            preservedSnapshotID: nil,
            completedAt: resolvedScope.completedAt,
            confirmedMutationCompletedAt: resolvedScope.confirmedMutationCompletedAt,
            observationPreservationAllowed: resolvedScope.observationPreservationAllowed)
        if let snapshotMutationCoordinator {
            let completed = await snapshotMutationCoordinator.completeMutation(
                coordinatorScope,
                succeeded: effectiveSucceeded)
            return completed && preservationAllowed
        }

        do {
            _ = try await self.snapshots.invalidateImplicitLatestSnapshot(
                through: cutoff,
                preserving: preservedSnapshotID,
                preservedAt: preservedSnapshotID == nil ? nil : resolvedScope.completedAt)
            return preservationAllowed
        } catch {
            return false
        }
    }

    private static func mutationCompletionCertificate(
        response: ToolResponse) -> (completedAt: Date?, preservationAllowed: Bool?)
    {
        guard case let .object(meta)? = response.meta else { return (nil, nil) }
        let completedAt: Date? = if case let .double(seconds)? = meta["desktop_mutation_completed_at"] {
            Date(timeIntervalSinceReferenceDate: seconds)
        } else {
            nil
        }
        let preservationAllowed: Bool? = if case let .bool(allowed)? =
            meta["desktop_mutation_preservation_allowed"]
        {
            allowed
        } else {
            nil
        }
        return (completedAt, preservationAllowed)
    }

    private static func explicitlyNotDispatched(_ response: ToolResponse) -> Bool {
        guard case let .object(meta)? = response.meta,
              case .bool(false)? = meta["mutation_dispatched"]
        else { return false }
        return true
    }

    private static func refreshedSnapshotID(
        scope: MCPToolSnapshotMutationScope,
        response: ToolResponse) -> String?
    {
        guard scope.effect == .mutationProducingFreshObservation,
              case let .object(meta)? = response.meta,
              case let .string(actualSnapshotID)? = meta["snapshot_id"],
              !actualSnapshotID.isEmpty
        else { return nil }
        return actualSnapshotID
    }

    private static func mutationCompletionWarningResponse(
        _ response: ToolResponse,
        toolName: String) -> ToolResponse
    {
        let warning = "Warning: The \(toolName) mutation completed, but UI snapshot cleanup is pending. " +
            "Do not retry this mutation; cleanup will be retried before the next snapshot-sensitive tool."
        var content = response.content
        if case let .text(text, annotations, meta)? = content.first {
            content[0] = .text(text: "\(text)\n\n\(warning)", annotations: annotations, _meta: meta)
        } else {
            content.insert(.text(text: warning, annotations: nil, _meta: nil), at: 0)
        }
        return ToolResponse(
            content: content,
            isError: false,
            meta: self.snapshotInvalidationMetadata(
                existing: response.meta,
                status: "pending_retry",
                warning: warning,
                toolExecuted: true,
                retryTool: false))
    }

    private static func pendingInvalidationResponse(
        pendingScope: MCPToolSnapshotMutationScope,
        blockedToolName: String) -> ToolResponse
    {
        let warning = "UI snapshot cleanup remains pending after the \(pendingScope.toolName) mutation. " +
            "The \(blockedToolName) tool was not executed; retry this request later."
        return ToolResponse.error(
            warning,
            meta: self.snapshotInvalidationMetadata(
                existing: nil,
                status: "pending_retry",
                warning: warning,
                toolExecuted: false,
                retryTool: true))
    }

    private static func snapshotInvalidationMetadata(
        existing: Value?,
        status: String,
        warning: String,
        toolExecuted: Bool,
        retryTool: Bool) -> Value
    {
        var metadata: [String: Value] = switch existing {
        case let .object(values)?:
            values
        case let existing?:
            ["tool_meta": existing]
        case nil:
            [:]
        }
        metadata["snapshot_invalidation"] = .object([
            "status": .string(status),
            "warning": .string(warning),
            "tool_executed": .bool(toolExecuted),
            "retry_tool": .bool(retryTool),
        ])
        return .object(metadata)
    }
}
