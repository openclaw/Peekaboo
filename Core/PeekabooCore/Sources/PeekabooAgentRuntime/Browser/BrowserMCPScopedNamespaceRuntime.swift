import CoreGraphics
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

/// Host-local identity for one authenticated browser capability namespace.
///
/// Authentication and receipt validation are Bridge responsibilities. The runtime accepts this identity only after
/// the authority layer has admitted the current request, and never parses bearer tokens or reusable wire receipts.
public struct BrowserMCPScopedNamespaceID: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// Per-call authority for a scoped browser action.
///
/// Foreground authority is deliberately invocation-scoped. It is never retained on the namespace, so a foreground
/// connect cannot silently authorize later page-fronting actions.
public enum BrowserMCPScopedNamespaceExecutionPolicy: Equatable, Sendable {
    case backgroundOnly
    case explicitlyForegroundAllowed
}

/// Exact native-window evidence projected from trusted host metadata.
public struct BrowserMCPScopedNamespaceNativeWindowReceipt: Equatable, Sendable {
    public enum Quality: String, Equatable, Sendable {
        case exact
    }

    public let pageReference: String
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64
    public let windowID: UInt32
    public let bounds: CGRect
    public let quality: Quality
}

/// Sanitized host result for one high-level BrowserTool invocation.
///
/// `targetIdentity` and `outcome` are extracted from Peekaboo-owned evidence before Bridge serialization. The Bridge
/// handler can therefore attest mutation semantics without reinterpreting untrusted provider metadata.
public struct BrowserMCPScopedNamespaceExecutionResult: Sendable {
    public let response: ToolResponse
    public let targetIdentity: DesktopTargetIdentity?
    public let outcome: DesktopActionOutcome?
    public let nativeWindowReceipt: BrowserMCPScopedNamespaceNativeWindowReceipt?
}

public enum BrowserMCPScopedNamespaceRuntimeError: LocalizedError, Equatable, Sendable {
    case localExecutionRequired
    case localBrowserServiceRequired
    case scopedSessionUnavailable
    case namespaceAlreadyExists
    case namespaceUnknown
    case namespaceClosing
    case namespaceEnded

    public var errorDescription: String? {
        switch self {
        case .localExecutionRequired:
            "Browser capability namespaces require the local execution host."
        case .localBrowserServiceRequired:
            "Browser capability namespaces require Peekaboo's concrete local browser service."
        case .scopedSessionUnavailable:
            "The local browser service could not create an independent authenticated session."
        case .namespaceAlreadyExists:
            "The browser capability namespace already exists."
        case .namespaceUnknown:
            "The browser capability namespace is unknown to this runtime instance."
        case .namespaceClosing:
            "The browser capability namespace is closing and rejects new work."
        case .namespaceEnded:
            "The browser capability namespace has ended and cannot be reused."
        }
    }
}

@MainActor
protocol BrowserMCPScopedNamespaceSession: AnyObject {
    func execute(
        arguments: ToolArguments,
        policy: BrowserMCPScopedNamespaceExecutionPolicy) async throws -> ToolResponse
    func close() async
}

/// Owns process-local browser children for authenticated Bridge namespaces.
///
/// No action ever executes on the root BrowserMCPService. Opening a namespace obtains a distinct service from
/// BrowserMCPAuthenticatedSessionPool, including its provider child, capability map, mutation gate, and operation
/// gate. Closing publishes the terminal phase before awaiting those gates, so later requests fail without entering
/// BrowserTool while already-admitted work is drained.
@MainActor
public final class BrowserMCPScopedNamespaceRuntime {
    typealias SessionFactory = @MainActor (BrowserMCPScopedNamespaceID) throws
        -> any BrowserMCPScopedNamespaceSession

    private enum Slot {
        case active(any BrowserMCPScopedNamespaceSession)
        case closing(Task<Void, Never>)
        case ended
    }

    private enum Phase: Equatable {
        case active
        case retiring
        case ended
    }

    private let makeSession: SessionFactory
    private var slots: [BrowserMCPScopedNamespaceID: Slot] = [:]
    private var phase = Phase.active
    private var retirementTask: Task<Void, Never>?

    /// Creates a runtime adapter around one local services context.
    ///
    /// The supplied context contributes desktop mutation coordination and the pool-owning root browser service. The
    /// root is only a factory/lock owner; it is never exposed as a namespace or used for action dispatch.
    public convenience init(context: MCPToolContext) throws {
        guard context.executionHost == .local else {
            throw BrowserMCPScopedNamespaceRuntimeError.localExecutionRequired
        }
        guard let root = context.browser as? BrowserMCPService else {
            throw BrowserMCPScopedNamespaceRuntimeError.localBrowserServiceRequired
        }
        self.init { _ in
            let sessionID = BrowserMCPAuthenticatedSessionPool.SessionID()
            guard let service = root.authenticatedSession(sessionID) else {
                throw BrowserMCPScopedNamespaceRuntimeError.scopedSessionUnavailable
            }
            return BrowserMCPScopedNamespaceLiveSession(
                service: service,
                baseContext: context)
        }
    }

    init(makeSession: @escaping SessionFactory) {
        self.makeSession = makeSession
    }

    /// Allocates the exact provider child for a previously authenticated namespace identity.
    public func open(_ namespaceID: BrowserMCPScopedNamespaceID) throws {
        switch self.phase {
        case .active:
            break
        case .retiring:
            throw BrowserMCPScopedNamespaceRuntimeError.namespaceClosing
        case .ended:
            throw BrowserMCPScopedNamespaceRuntimeError.namespaceEnded
        }
        if let slot = self.slots[namespaceID] {
            switch slot {
            case .active:
                throw BrowserMCPScopedNamespaceRuntimeError.namespaceAlreadyExists
            case .closing:
                throw BrowserMCPScopedNamespaceRuntimeError.namespaceClosing
            case .ended:
                throw BrowserMCPScopedNamespaceRuntimeError.namespaceEnded
            }
        }
        self.slots[namespaceID] = try .active(self.makeSession(namespaceID))
    }

    /// Executes one high-level BrowserTool request in the caller's exact capability namespace.
    ///
    /// `bind_window` intentionally travels through this same entry point. There is no raw/provider call surface and no
    /// fallback to legacy browserExecute, a root browser client, or another namespace.
    public func execute(
        in namespaceID: BrowserMCPScopedNamespaceID,
        arguments: ToolArguments,
        policy: BrowserMCPScopedNamespaceExecutionPolicy = .backgroundOnly) async throws
        -> BrowserMCPScopedNamespaceExecutionResult
    {
        switch self.phase {
        case .active:
            break
        case .retiring:
            throw BrowserMCPScopedNamespaceRuntimeError.namespaceClosing
        case .ended:
            throw BrowserMCPScopedNamespaceRuntimeError.namespaceEnded
        }
        let session: any BrowserMCPScopedNamespaceSession
        switch self.slots[namespaceID] {
        case let .active(activeSession):
            session = activeSession
        case .closing:
            throw BrowserMCPScopedNamespaceRuntimeError.namespaceClosing
        case .ended:
            throw BrowserMCPScopedNamespaceRuntimeError.namespaceEnded
        case nil:
            throw BrowserMCPScopedNamespaceRuntimeError.namespaceUnknown
        }

        let response = try await session.execute(arguments: arguments, policy: policy)
        return BrowserMCPScopedNamespaceResponseSanitizer.result(
            response,
            arguments: arguments,
            policy: policy)
    }

    /// Publishes terminal state, drains the namespace's gates, and ends its exact provider child.
    ///
    /// Duplicate close callers join the same task. Ended identities remain tombstoned for this runtime generation and
    /// cannot accidentally acquire a fresh capability map.
    public func close(_ namespaceID: BrowserMCPScopedNamespaceID) async throws {
        guard self.slots[namespaceID] != nil else {
            throw BrowserMCPScopedNamespaceRuntimeError.namespaceUnknown
        }
        guard let task = self.beginClose(namespaceID) else { return }
        await task.value
        if case .closing? = self.slots[namespaceID] {
            self.slots[namespaceID] = .ended
        }
    }

    /// Ends every namespace during host-generation retirement without serializing independent drains.
    public func closeAll() async {
        if let retirementTask {
            await retirementTask.value
            return
        }
        guard self.phase == .active else { return }
        self.phase = .retiring
        let namespaceIDs = Array(self.slots.keys)
        let tasks = namespaceIDs.compactMap(self.beginClose)
        let retirementTask = Task { @MainActor in
            for task in tasks {
                await task.value
            }
            for namespaceID in namespaceIDs where self.slots[namespaceID].map(Self.isClosing) == true {
                self.slots[namespaceID] = .ended
            }
            self.phase = .ended
        }
        self.retirementTask = retirementTask
        await retirementTask.value
    }

    private func beginClose(_ namespaceID: BrowserMCPScopedNamespaceID) -> Task<Void, Never>? {
        switch self.slots[namespaceID] {
        case let .active(session):
            let task = Task { @MainActor in
                await session.close()
            }
            self.slots[namespaceID] = .closing(task)
            return task
        case let .closing(existing):
            return existing
        case .ended, nil:
            return nil
        }
    }

    private static func isClosing(_ slot: Slot) -> Bool {
        if case .closing = slot {
            return true
        }
        return false
    }
}

@MainActor
private final class BrowserMCPScopedNamespaceLiveSession: BrowserMCPScopedNamespaceSession {
    private let backgroundContext: MCPToolContext
    private let foregroundContext: MCPToolContext

    init(service: BrowserMCPService, baseContext: MCPToolContext) {
        let owner = MCPToolSnapshotOwner()
        self.backgroundContext = baseContext.browserNamespaceContext(
            service: service,
            owner: owner,
            executionPolicy: .backgroundOnly)
        self.foregroundContext = baseContext.browserNamespaceContext(
            service: service,
            owner: owner,
            executionPolicy: .foregroundAllowed)
    }

    func execute(
        arguments: ToolArguments,
        policy: BrowserMCPScopedNamespaceExecutionPolicy) async throws -> ToolResponse
    {
        let context = switch policy {
        case .backgroundOnly:
            self.backgroundContext
        case .explicitlyForegroundAllowed:
            self.foregroundContext
        }
        return try await context.execute(
            tool: BrowserTool(context: context),
            arguments: arguments)
    }

    func close() async {
        // Both policy views share this exact service, capability session, lifecycle gate, and snapshot owner. Releasing
        // one view drains all BrowserTool work before ending the owned pool child.
        await self.backgroundContext.releaseSnapshotOwner()
    }
}

extension MCPToolContext {
    fileprivate func browserNamespaceContext(
        service: BrowserMCPService,
        owner: MCPToolSnapshotOwner,
        executionPolicy: MCPToolExecutionPolicy) -> Self
    {
        Self(
            automation: self.automation,
            menu: self.menu,
            windows: self.windows,
            applications: self.applications,
            dialogs: self.dialogs,
            dock: self.dock,
            screenCapture: self.screenCapture,
            desktopObservation: self.desktopObservation,
            snapshots: self.snapshots,
            screens: self.screens,
            agent: self.agent,
            permissions: self.permissions,
            clipboard: self.clipboard,
            browser: service,
            permissionsStatusProvider: self.permissionsStatusProvider,
            snapshotMutationCoordinator: self.snapshotMutationCoordinator,
            snapshotExecutionGate: self.snapshotExecutionGate,
            browserMutationExecutionGate: service.browserMutationExecutionGate,
            snapshotOwner: owner,
            executionPolicy: executionPolicy,
            executionHost: .local,
            capturePreflightRefusal: self.capturePreflightRefusal)
    }
}
