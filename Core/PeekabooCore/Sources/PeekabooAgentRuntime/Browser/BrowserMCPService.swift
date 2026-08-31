import AppKit
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

public struct BrowserMCPProviderSessionEpoch: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct BrowserMCPExecutionSessionBinding: Equatable, Sendable {
    public let connectionReceipt: BrowserMCPConnectionReceipt
    public let providerSessionEpoch: BrowserMCPProviderSessionEpoch

    public init(
        connectionReceipt: BrowserMCPConnectionReceipt,
        providerSessionEpoch: BrowserMCPProviderSessionEpoch)
    {
        self.connectionReceipt = connectionReceipt
        self.providerSessionEpoch = providerSessionEpoch
    }
}

public struct BrowserMCPElementPreflight: Equatable, Sendable {
    public let providerPageID: Int
    public let providerUIDs: Set<String>

    public init(providerPageID: Int, providerUIDs: Set<String>) {
        self.providerPageID = providerPageID
        self.providerUIDs = providerUIDs
    }
}

public struct BrowserMCPStatus: Sendable {
    public let isConnected: Bool
    public let toolCount: Int
    public let detectedBrowsers: [DetectedBrowser]
    public let connectionReceipt: BrowserMCPConnectionReceipt?
    public let providerSessionEpoch: BrowserMCPProviderSessionEpoch?
    public let error: String?
    public let observation: BrowserMCPStatusObservation

    public init(
        isConnected: Bool,
        toolCount: Int,
        detectedBrowsers: [DetectedBrowser],
        connectionReceipt: BrowserMCPConnectionReceipt? = nil,
        providerSessionEpoch: BrowserMCPProviderSessionEpoch? = nil,
        error: String? = nil,
        observation: BrowserMCPStatusObservation = .confirmed)
    {
        self.isConnected = isConnected
        self.toolCount = toolCount
        self.detectedBrowsers = detectedBrowsers
        self.connectionReceipt = connectionReceipt
        self.providerSessionEpoch = providerSessionEpoch
        self.error = error
        self.observation = observation
    }
}

public enum BrowserMCPStatusObservation: String, Sendable {
    case confirmed
    case indeterminate
}

public struct DetectedBrowser: Sendable, Equatable {
    public let name: String
    public let bundleIdentifier: String
    public let processIdentifier: Int32
    public let processStartIdentity: UInt64?
    public let version: String?
    public let channel: BrowserMCPChannel

    public init(
        name: String,
        bundleIdentifier: String,
        processIdentifier: Int32,
        processStartIdentity: UInt64? = nil,
        version: String?,
        channel: BrowserMCPChannel)
    {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.version = version
        self.channel = channel
    }
}

public struct BrowserMCPConnectionReceipt: Sendable, Hashable {
    public let channel: BrowserMCPChannel?
    public let processIdentifier: Int32?
    public let processStartIdentity: UInt64?
    public let bundleIdentifier: String?
    public let browserURL: String?
    public let webSocketDebuggerURL: String?
    public let devToolsBrowserID: String?
    public let browserVersion: String?
    public let protocolVersion: String?

    public init(
        channel: BrowserMCPChannel? = nil,
        processIdentifier: Int32? = nil,
        processStartIdentity: UInt64? = nil,
        bundleIdentifier: String? = nil,
        browserURL: String? = nil,
        webSocketDebuggerURL: String? = nil,
        devToolsBrowserID: String? = nil,
        browserVersion: String? = nil,
        protocolVersion: String? = nil)
    {
        self.channel = channel
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.bundleIdentifier = bundleIdentifier
        self.browserURL = browserURL
        self.webSocketDebuggerURL = webSocketDebuggerURL
        self.devToolsBrowserID = devToolsBrowserID
        self.browserVersion = browserVersion
        self.protocolVersion = protocolVersion
    }
}

/// One browser response paired with the exact persistent connection that dispatched it.
///
/// Callers that need target attribution must use the receipt-bound execution API instead of
/// inferring the target from a status read performed before an unpinned call.
public struct BrowserMCPExecutionResult: Sendable {
    public let response: ToolResponse
    public let connectionReceipt: BrowserMCPConnectionReceipt
    public let providerSessionEpoch: BrowserMCPProviderSessionEpoch?
    /// Foreground setup performed implicitly before the requested calls.
    let connectionOutcome: DesktopActionOutcome?
    public let completedCallCount: Int
    public let dispatchedCallCount: Int
    public let actionFailure: DesktopActionFailure?
    let failureStage: BrowserMCPExecutionFailureStage?
    let providerReturnedError: Bool

    public init(
        response: ToolResponse,
        connectionReceipt: BrowserMCPConnectionReceipt,
        providerSessionEpoch: BrowserMCPProviderSessionEpoch? = nil,
        completedCallCount: Int,
        dispatchedCallCount: Int,
        actionFailure: DesktopActionFailure? = nil)
    {
        precondition(completedCallCount >= 0)
        precondition(dispatchedCallCount >= completedCallCount)
        self.response = response
        self.connectionReceipt = connectionReceipt
        self.providerSessionEpoch = providerSessionEpoch
        self.connectionOutcome = nil
        self.completedCallCount = completedCallCount
        self.dispatchedCallCount = dispatchedCallCount
        self.actionFailure = actionFailure
        self.failureStage = nil
        self.providerReturnedError = false
    }

    init(
        response: ToolResponse,
        connectionReceipt: BrowserMCPConnectionReceipt,
        providerSessionEpoch: BrowserMCPProviderSessionEpoch?,
        connectionOutcome: DesktopActionOutcome? = nil,
        completedCallCount: Int,
        dispatchedCallCount: Int,
        actionFailure: DesktopActionFailure?,
        failureStage: BrowserMCPExecutionFailureStage?,
        providerReturnedError: Bool = false)
    {
        precondition(completedCallCount >= 0)
        precondition(dispatchedCallCount >= completedCallCount)
        self.response = response
        self.connectionReceipt = connectionReceipt
        self.providerSessionEpoch = providerSessionEpoch
        self.connectionOutcome = connectionOutcome
        self.completedCallCount = completedCallCount
        self.dispatchedCallCount = dispatchedCallCount
        self.actionFailure = actionFailure
        self.failureStage = failureStage
        self.providerReturnedError = providerReturnedError
    }
}

enum BrowserMCPExecutionFailureStage: Sendable, Equatable {
    case call(index: Int)
    case connectionValidation
}

public enum BrowserMCPChannel: String, Sendable, CaseIterable, Codable, Hashable {
    case stable
    case beta
    case dev
    case canary

    static func infer(bundleIdentifier: String?, applicationName _: String) -> Self? {
        guard let identity = ChromeChannelIdentity(exactBundleIdentifier: bundleIdentifier) else { return nil }
        return Self(rawValue: identity.rawValue)
    }
}

public enum BrowserMCPExecutionConnectionPolicy: Sendable, Equatable {
    case allowAutoConnect
    case requireExistingLiveReceipt
}

enum BrowserMCPLaunchTarget: Sendable, Equatable {
    case exactWebSocket(String)
    case isolated(BrowserMCPChannel)
    case autoConnect(BrowserMCPChannel)
}

public protocol BrowserMCPClientProviding: AnyObject, Sendable {
    var supportsNativeBrowserConnectionBinding: Bool { get }

    @MainActor
    func status(channel: BrowserMCPChannel?) async -> BrowserMCPStatus
    @MainActor
    func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus
    @MainActor
    func connect(channel: BrowserMCPChannel?, browserURL: String?) async throws -> BrowserMCPStatus
    @MainActor
    func disconnect() async
    @MainActor
    func execute(toolName: String, arguments: [String: Any], channel: BrowserMCPChannel?) async throws -> ToolResponse
    @MainActor
    func executeSequence(_ calls: [BrowserMCPMappedCall], channel: BrowserMCPChannel?) async throws -> ToolResponse
    @MainActor
    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
}

extension BrowserMCPClientProviding {
    public var supportsNativeBrowserConnectionBinding: Bool {
        false
    }
}

/// Additive browser client surface for callers that need canonical desktop-action semantics.
///
/// Legacy clients can continue conforming only to ``BrowserMCPClientProviding``. Receipt-aware
/// clients implement this protocol so callers do not have to infer retry safety from MCP text.
public protocol BrowserMCPActionResultProviding: BrowserMCPClientProviding {
    @MainActor
    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    @MainActor
    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
}

public protocol BrowserMCPConnectionResultProviding: BrowserMCPClientProviding {
    @MainActor
    func connectWithOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
}

/// Additive browser disconnect surface for providers that can confirm cleanup.
///
/// Legacy clients retain the nonthrowing ``BrowserMCPClientProviding/disconnect()`` contract. Providers that own
/// persistent browser children implement this protocol so callers can distinguish confirmed cleanup from an
/// indeterminate transport or provider-removal failure.
public protocol BrowserMCPDisconnectResultProviding: BrowserMCPClientProviding {
    @MainActor
    func disconnectWithResult() async throws -> BrowserMCPStatus
}

/// A remote, receipt-aware provider that can request one authenticated cross-process browser handoff.
/// Complete receipt bytes remain process-private and are never projected into an MCP tool response.
@MainActor
public protocol BrowserMCPConnectionHandoffProviding: BrowserMCPConnectionResultProviding,
BrowserMCPDisconnectResultProviding {
    func connectWithHandoffOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>

    func takeConnectionHandoffReceiptBundleData() -> Data?
}

/// Local provider surface that binds dispatch to one exact MCP child epoch as well as its browser target.
/// Remote Bridge clients intentionally do not conform until their authenticated wire session carries this epoch.
public protocol BrowserMCPAtomicSessionActionProviding: BrowserMCPActionResultProviding {
    @MainActor
    func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
}

protocol BrowserMCPAuthenticatedSessionEnding: BrowserMCPClientProviding {
    @MainActor
    @discardableResult
    func endAuthenticatedBrowserSession() async -> Bool
}

extension BrowserMCPActionResultProviding {
    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
    {
        guard connectionPolicy == .allowAutoConnect else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The browser provider cannot enforce existing-connection-only execution.",
                hint: "Update the runtime host before retrying this background-only browser action.")
        }
        return try await self.executeSequenceWithOutcome(calls, channel: channel)
    }
}

extension BrowserMCPClientProviding {
    @MainActor
    public func connect(channel: BrowserMCPChannel?, browserURL: String?) async throws -> BrowserMCPStatus {
        guard browserURL == nil else {
            throw BrowserMCPConnectionError.explicitEndpointUnsupported
        }
        return try await self.connect(channel: channel)
    }

    @MainActor
    public func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        guard let first = calls.first else {
            throw BrowserMCPConnectionError.connectionLost("the browser action sequence was empty")
        }
        var response = try await self.execute(
            toolName: first.toolName,
            arguments: first.arguments,
            channel: channel)
        for call in calls.dropFirst() where !response.isError {
            response = try await self.execute(
                toolName: call.toolName,
                arguments: call.arguments,
                channel: channel)
        }
        return response
    }

    @MainActor
    public func executeSequence(
        _: [BrowserMCPMappedCall],
        channel _: BrowserMCPChannel?,
        expectedConnectionReceipt _: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
    {
        throw BrowserMCPConnectionError.receiptBindingUnsupported
    }
}

private enum BrowserMCPStoredConnectionHandoffAuthorization {
    case ready(
        authorization: BrowserMCPConnectionHandoffAuthorization,
        boundName: String?)
    case inFlight(
        authorization: BrowserMCPConnectionHandoffAuthorization,
        name: String,
        attemptID: UUID)

    var authorization: BrowserMCPConnectionHandoffAuthorization {
        switch self {
        case let .ready(authorization, _), let .inFlight(authorization, _, _):
            authorization
        }
    }

    var unclaimedAuthorization: BrowserMCPConnectionHandoffAuthorization? {
        guard case let .ready(authorization, boundName) = self, boundName == nil else { return nil }
        return authorization
    }
}

public final class BrowserMCPService: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    BrowserMCPAtomicSessionActionProviding,
    BrowserMCPConnectionResultProviding, BrowserMCPDisconnectResultProviding,
    BrowserMCPAuthenticatedSessionEnding, @unchecked Sendable
{
    public let supportsNativeBrowserConnectionBinding: Bool

    private static let serverName = "chrome-devtools"

    @MainActor private var sessionManager: BrowserMCPSessionManager?
    @MainActor private var authenticatedSessionPool: BrowserMCPAuthenticatedSessionPool?
    @MainActor private var connectionHandoffAuthorizations:
        [UUID: BrowserMCPStoredConnectionHandoffAuthorization] = [:]
    @MainActor private var authenticatedSessionCleanupRetry: (id: UUID, task: Task<Bool, Never>)?
    private let sessionCapabilities: BrowserToolCapabilitySession?
    private let sessionMutationGate: MCPToolSnapshotExecutionGate?
    @MainActor private var ownedSession: (
        pool: BrowserMCPAuthenticatedSessionPool,
        id: BrowserMCPAuthenticatedSessionPool.SessionID)?

    public init() {
        self.supportsNativeBrowserConnectionBinding = BrowserMCPEnvironmentOptions(
            environment: ProcessInfo.processInfo.environment).supportsNativeBrowserConnectionBinding
        self.sessionManager = nil
        self.ownedSession = nil
        self.sessionCapabilities = nil
        self.sessionMutationGate = nil
        self.authenticatedSessionPool = BrowserMCPAuthenticatedSessionPool { serverName in
            BrowserMCPSessionManager(serverName: serverName)
        }
    }

    @MainActor
    init(authenticatedSessionPool: BrowserMCPAuthenticatedSessionPool) {
        self.supportsNativeBrowserConnectionBinding = true
        self.sessionManager = nil
        self.ownedSession = nil
        self.sessionCapabilities = nil
        self.sessionMutationGate = nil
        self.authenticatedSessionPool = authenticatedSessionPool
    }

    @MainActor
    public init(manager: TachikomaMCPClientManager) {
        let sessionManager = BrowserMCPSessionManager(serverName: Self.serverName, manager: manager)
        self.supportsNativeBrowserConnectionBinding = sessionManager.supportsNativeBrowserConnectionBinding
        self.sessionManager = sessionManager
        self.ownedSession = nil
        self.sessionCapabilities = nil
        self.sessionMutationGate = nil
        self.authenticatedSessionPool = BrowserMCPAuthenticatedSessionPool { serverName in
            BrowserMCPSessionManager(serverName: serverName, manager: manager)
        }
    }

    @MainActor
    init(
        sessionManager: BrowserMCPSessionManager,
        authenticatedSessionPool: BrowserMCPAuthenticatedSessionPool? = nil,
        ownedSession: (
            pool: BrowserMCPAuthenticatedSessionPool,
            id: BrowserMCPAuthenticatedSessionPool.SessionID)? = nil,
        sessionCapabilities: BrowserToolCapabilitySession? = nil,
        sessionMutationGate: MCPToolSnapshotExecutionGate? = nil)
    {
        self.supportsNativeBrowserConnectionBinding = sessionManager.supportsNativeBrowserConnectionBinding
        self.sessionManager = sessionManager
        self.authenticatedSessionPool = authenticatedSessionPool
        self.ownedSession = ownedSession
        self.sessionCapabilities = sessionCapabilities
        self.sessionMutationGate = sessionMutationGate
    }

    /// Creates a version-neutral process-local browser service for one explicitly authenticated caller session.
    /// Bridge transport does not invoke this API until it can carry an authenticated caller/session namespace.
    @MainActor
    func authenticatedSession(
        _ sessionID: BrowserMCPAuthenticatedSessionPool.SessionID) -> BrowserMCPService?
    {
        guard let pool = self.authenticatedSessionPool,
              let manager = pool.manager(for: sessionID),
              let capabilities = pool.capabilities(for: sessionID),
              let mutationGate = pool.mutationGate(for: sessionID)
        else { return nil }
        return BrowserMCPService(
            sessionManager: manager,
            ownedSession: (pool: pool, id: sessionID),
            sessionCapabilities: capabilities,
            sessionMutationGate: mutationGate)
    }

    @MainActor
    func authenticatedSession(named name: String) -> BrowserMCPService? {
        guard let pool = self.authenticatedSessionPool,
              let sessionID = pool.sessionID(named: name),
              let manager = pool.manager(for: sessionID),
              let capabilities = pool.capabilities(for: sessionID),
              let mutationGate = pool.mutationGate(for: sessionID)
        else { return nil }
        return BrowserMCPService(
            sessionManager: manager,
            ownedSession: (pool: pool, id: sessionID),
            sessionCapabilities: capabilities,
            sessionMutationGate: mutationGate)
    }

    @MainActor
    public var supportsAuthenticatedSessionBootstrap: Bool {
        self.ownedSession == nil && self.authenticatedSessionPool != nil
    }

    @MainActor
    public func createAuthenticatedSession(named name: String) throws -> BrowserMCPService {
        guard self.supportsAuthenticatedSessionBootstrap,
              let session = self.authenticatedSession(named: name)
        else {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
        return session
    }

    @MainActor
    public func existingAuthenticatedSession(named name: String) -> BrowserMCPService? {
        guard self.supportsAuthenticatedSessionBootstrap,
              let pool = self.authenticatedSessionPool,
              let sessionID = pool.existingSessionID(named: name),
              let manager = pool.existingManager(for: sessionID),
              let capabilities = pool.capabilities(for: sessionID),
              let mutationGate = pool.mutationGate(for: sessionID)
        else { return nil }
        return BrowserMCPService(
            sessionManager: manager,
            ownedSession: (pool: pool, id: sessionID),
            sessionCapabilities: capabilities,
            sessionMutationGate: mutationGate)
    }

    /// Captures a host-private, provider-generation-bound authorization for a later scoped handoff.
    @MainActor
    public func authorizeConnectionHandoff(
        connectionReceipt: BrowserMCPConnectionReceipt) async throws -> BrowserMCPConnectionHandoffAuthorization
    {
        try await self.resolvedSessionManager().authorizeConnectionHandoff(receipt: connectionReceipt)
    }

    /// Moves one already-authorized exact root connection into a caller-scoped provider child.
    ///
    /// The binding is host-private authority. Wire adapters must resolve an authenticated opaque claim to this
    /// value instead of accepting a caller-supplied receipt, provider epoch, or DevTools endpoint.
    @MainActor
    public func transferConnection(
        toAuthenticatedSessionNamed name: String,
        authorization: BrowserMCPConnectionHandoffAuthorization) async throws -> BrowserMCPService
    {
        var sourceEpochEnded = false
        defer {
            if sourceEpochEnded {
                self.discardConnectionHandoffAuthorizations(boundTo: authorization.sourceBinding)
            }
        }
        return try await self.transferConnection(
            toAuthenticatedSessionNamed: name,
            authorization: authorization,
            onSourceEpochEnded: { sourceEpochEnded = true },
            onRetryableDestinationFailure: {})
    }

    @MainActor
    private func transferConnection(
        toAuthenticatedSessionNamed name: String,
        authorization: BrowserMCPConnectionHandoffAuthorization,
        onSourceEpochEnded: @MainActor @escaping () -> Void,
        onRetryableDestinationFailure: @MainActor @escaping () -> Void) async throws -> BrowserMCPService
    {
        guard let pool = self.authenticatedSessionPool,
              self.ownedSession == nil,
              let sessionID = pool.sessionID(named: name),
              let destinationManager = pool.manager(for: sessionID)
        else {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
        let sourceManager = self.resolvedSessionManager()
        return try await pool.withHandoffLifecycle(sessionID) {
            @MainActor
            func destinationService() throws -> BrowserMCPService {
                guard let capabilities = pool.capabilities(for: sessionID),
                      let mutationGate = pool.mutationGate(for: sessionID)
                else {
                    throw BrowserMCPConnectionError.sessionEnded
                }
                return BrowserMCPService(
                    sessionManager: destinationManager,
                    ownedSession: (pool: pool, id: sessionID),
                    sessionCapabilities: capabilities,
                    sessionMutationGate: mutationGate)
            }

            let target: BrowserMCPAuthorizedHandoffTarget
            switch try pool.prepareHandoff(sessionID, authorization: authorization) {
            case .start:
                do {
                    try await destinationManager.preflightHandoffDestination()
                    target = try await sourceManager.drainConnectionForHandoff(
                        authorization: authorization)
                    onSourceEpochEnded()
                    do {
                        try await pool.commitRootHandoff(
                            to: sessionID,
                            authorization: authorization,
                            target: target)
                        sourceManager.settleDrainedSourceHandoff(authorization: authorization)
                    } catch {
                        pool.requireSourceRecovery(for: sessionID)
                        throw BrowserMCPConnectionError.handoffRecoveryRequired(
                            "source teardown completed, but destination ownership could not be committed")
                    }
                } catch let BrowserMCPHandoffSourceDrainError.sourceStillLive(cause) {
                    pool.cancelPendingHandoff(for: sessionID)
                    throw cause
                } catch let BrowserMCPHandoffSourceDrainError.recoveryRequired(cause) {
                    pool.requireSourceRecovery(for: sessionID)
                    throw BrowserMCPConnectionError.handoffRecoveryRequired(cause.localizedDescription)
                } catch let error as BrowserMCPConnectionError {
                    if case .handoffRecoveryRequired = error {
                        throw error
                    }
                    pool.cancelPendingHandoff(for: sessionID)
                    throw error
                } catch {
                    pool.cancelPendingHandoff(for: sessionID)
                    throw error
                }
            case let .bootstrap(retryTarget):
                target = retryTarget
            case .connected:
                return try destinationService()
            }

            do {
                try await destinationManager.bootstrapAuthorizedHandoff(target)
                try pool.resolveHandoff(for: sessionID, as: .connected)
                return try destinationService()
            } catch let failure as BrowserMCPHandoffDestinationError {
                if failure.cleanupConfirmed {
                    if pool.resolveRetryableHandoffIfNotEnding(for: sessionID) {
                        onRetryableDestinationFailure()
                    }
                    throw failure.cause
                }
                try? pool.resolveHandoff(for: sessionID, as: .recoveryRequired)
                throw BrowserMCPConnectionError.handoffRecoveryRequired(
                    failure.cause.localizedDescription)
            }
        }
    }

    @MainActor
    func endAuthenticatedSession(_ sessionID: BrowserMCPAuthenticatedSessionPool.SessionID) async {
        await self.authenticatedSessionPool?.end(sessionID)
    }

    @MainActor
    @discardableResult
    public func endAuthenticatedSession(named name: String) async -> Bool {
        guard let pool = self.authenticatedSessionPool else { return true }
        self.discardConnectionHandoffAuthorizations(boundTo: name)
        if let recovery = pool.sourceRecovery(named: name),
           await self.resolvedSessionManager().recoverSourceHandoff(
               authorization: recovery.authorization)
        {
            pool.confirmSourceRecovery(for: recovery.sessionID)
        }
        return await pool.end(named: name)
    }

    @MainActor
    @discardableResult
    public func endAuthenticatedBrowserSession() async -> Bool {
        guard let ownedSession else { return true }
        let cleanupConfirmed = await ownedSession.pool.endAndConfirm(ownedSession.id)
        if cleanupConfirmed, self.ownedSession?.id == ownedSession.id {
            self.ownedSession = nil
        }
        return cleanupConfirmed
    }

    var browserCapabilitySession: BrowserToolCapabilitySession? {
        self.sessionCapabilities
    }

    var browserMutationExecutionGate: MCPToolSnapshotExecutionGate? {
        self.sessionMutationGate
    }

    @MainActor
    public func status(channel: BrowserMCPChannel? = nil) async -> BrowserMCPStatus {
        let authorizationSnapshot = self.unclaimedConnectionHandoffAuthorizationSnapshot()
        let status = await self.resolvedSessionManager().status(
            channel: channel,
            releaseTargetWhenDisconnected: self.targetOwnershipRelease())
        self.pruneConnectionHandoffAuthorizations(authorizationSnapshot, after: status)
        return status
    }

    @MainActor
    public func connect(channel: BrowserMCPChannel? = nil) async throws -> BrowserMCPStatus {
        try await self.connect(channel: channel, browserURL: nil)
    }

    @MainActor
    public func connect(
        channel: BrowserMCPChannel? = nil,
        browserURL: String?) async throws -> BrowserMCPStatus
    {
        try await self.connectWithOutcome(channel: channel, browserURL: browserURL).payload
    }

    @MainActor
    public func connectWithOutcome(
        channel: BrowserMCPChannel? = nil,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        let manager = self.resolvedSessionManager()
        let authorizationSnapshot = self.unclaimedConnectionHandoffAuthorizationSnapshot()
        let result: DesktopActionResult<BrowserMCPStatus>
        do {
            if self.sessionCapabilities != nil {
                try manager.preflightAuthenticatedCapabilityConnect(browserURL: browserURL)
            }
            result = try await manager.connectWithOutcome(
                channel: channel,
                browserURL: browserURL,
                reserveTarget: self.targetOwnershipReservation())
        } catch {
            await self.reconcileTargetOwnershipAfterFailure(using: manager)
            throw error
        }
        self.pruneConnectionHandoffAuthorizations(authorizationSnapshot, after: result.payload)
        return result
    }

    @MainActor
    public func execute(
        toolName: String,
        arguments: [String: Any],
        channel: BrowserMCPChannel? = nil) async throws -> ToolResponse
    {
        if self.usesTargetOwnershipPool {
            return try await self.executeSequenceWithOutcome(
                [BrowserMCPMappedCall(toolName: toolName, arguments: arguments)],
                channel: channel,
                connectionPolicy: self.requiresExistingLiveReceipt
                    ? .requireExistingLiveReceipt
                    : .allowAutoConnect).payload
        }
        return try await self.resolvedSessionManager().execute(
            toolName: toolName,
            arguments: arguments,
            channel: channel)
    }

    @MainActor
    public func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        if self.usesTargetOwnershipPool {
            return try await self.executeSequenceWithOutcome(
                calls,
                channel: channel,
                connectionPolicy: self.requiresExistingLiveReceipt
                    ? .requireExistingLiveReceipt
                    : .allowAutoConnect).payload
        }
        return try await self.resolvedSessionManager().executeSequence(calls, channel: channel)
    }

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        try await self.executeSequenceWithOutcome(
            calls,
            channel: channel,
            connectionPolicy: .requireExistingLiveReceipt)
    }

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
    {
        do {
            let result = try await self.executeSequenceWithOutcome(
                calls,
                channel: channel,
                connectionPolicy: connectionPolicy,
                expectedSessionBinding: nil)
            if result.payload.isError {
                await self.reconcileTargetOwnershipAfterExecutionFailure()
            }
            return result
        } catch {
            await self.reconcileTargetOwnershipAfterExecutionFailure()
            throw error
        }
    }

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
    {
        do {
            let result = try await self.executeSequenceWithOutcome(
                calls,
                channel: channel,
                connectionPolicy: .requireExistingLiveReceipt,
                expectedSessionBinding: expectedSessionBinding,
                elementPreflight: elementPreflight)
            if result.payload.isError {
                await self.reconcileTargetOwnershipAfterExecutionFailure()
            }
            return result
        } catch {
            await self.reconcileTargetOwnershipAfterExecutionFailure()
            throw error
        }
    }

    @MainActor
    public func executeSequenceResult(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> BrowserMCPExecutionResult
    {
        do {
            let result = try await self.resolvedSessionManager().executeSequence(
                calls,
                channel: channel,
                expectedSessionBinding: expectedSessionBinding,
                elementPreflight: elementPreflight)
            if result.response.isError || result.actionFailure != nil {
                await self.reconcileTargetOwnershipAfterExecutionFailure()
            }
            return result
        } catch {
            await self.reconcileTargetOwnershipAfterExecutionFailure()
            throw error
        }
    }

    @MainActor
    private func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding?,
        elementPreflight: BrowserMCPElementPreflight? = nil) async throws -> DesktopActionResult<ToolResponse>
    {
        let manager = self.resolvedSessionManager()
        let effectiveConnectionPolicy = self.requiresExistingLiveReceipt
            ? BrowserMCPExecutionConnectionPolicy.requireExistingLiveReceipt
            : connectionPolicy
        let targetReservation = effectiveConnectionPolicy == .allowAutoConnect
            ? self.targetOwnershipReservation()
            : nil
        let semantics = calls.map(Self.actionSemantics)
        let plannedMutationCount = semantics.count(where: { $0 == .mutating })
        let result: BrowserMCPExecutionResult
        if let expectedSessionBinding {
            do {
                result = try await manager.executeSequence(
                    calls,
                    channel: channel,
                    expectedSessionBinding: expectedSessionBinding,
                    elementPreflight: elementPreflight)
            } catch BrowserMCPConnectionError.expectedConnectionReceiptMismatch,
                BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
            {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .targetUnavailable,
                    message: "The exact browser provider session changed before tool dispatch.",
                    hint: "Refresh browser status and obtain new page and snapshot references.")
            } catch BrowserMCPConnectionError.receiptBindingUnsupported {
                throw DesktopActionFailure.preDispatchRefusal(
                    reason: .operationUnsupported,
                    message: "The browser provider cannot atomically bind execution to its child session.",
                    hint: "Update the runtime host before retrying capability-bound browser execution.")
            }
        } else if plannedMutationCount == 0 {
            result = try await manager.executeSequenceResult(
                calls,
                channel: channel,
                connectionPolicy: effectiveConnectionPolicy,
                reserveTarget: targetReservation)
        } else {
            switch effectiveConnectionPolicy {
            case .allowAutoConnect:
                let status = try await manager.statusForExecution(channel: channel)
                if status.isConnected, let receipt = status.connectionReceipt {
                    do {
                        result = try await manager.executeSequence(
                            calls,
                            channel: channel,
                            expectedConnectionReceipt: receipt)
                    } catch BrowserMCPConnectionError.expectedConnectionReceiptMismatch {
                        throw DesktopActionFailure.preDispatchRefusal(
                            reason: .targetUnavailable,
                            message: "The exact browser connection changed before tool dispatch.",
                            hint: "Refresh browser status and retry against its new connection receipt.")
                    } catch BrowserMCPConnectionError.receiptBindingUnsupported {
                        throw DesktopActionFailure.preDispatchRefusal(
                            reason: .operationUnsupported,
                            message: "The browser provider cannot atomically bind execution to a connection receipt.",
                            hint: "Update the runtime host before retrying target-attested browser execution.")
                    }
                } else {
                    result = try await manager.executeSequenceResult(
                        calls,
                        channel: channel,
                        connectionPolicy: .allowAutoConnect,
                        reserveTarget: targetReservation)
                }
            case .requireExistingLiveReceipt:
                let status: BrowserMCPStatus
                do {
                    status = try await manager.statusForExecution(channel: channel)
                } catch let error as CancellationError {
                    throw BrowserMCPSessionManager.preDispatchFailure(error)
                }
                guard status.isConnected, let receipt = status.connectionReceipt else {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "Browser execution requires a live exact connection receipt.",
                        hint: "Connect the intended browser and retry.")
                }
                do {
                    result = try await manager.executeSequence(
                        calls,
                        channel: channel,
                        expectedConnectionReceipt: receipt)
                } catch BrowserMCPConnectionError.expectedConnectionReceiptMismatch {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .targetUnavailable,
                        message: "The exact browser connection changed before tool dispatch.",
                        hint: "Refresh browser status and retry against its new connection receipt.")
                } catch BrowserMCPConnectionError.receiptBindingUnsupported {
                    throw DesktopActionFailure.preDispatchRefusal(
                        reason: .operationUnsupported,
                        message: "The browser provider cannot atomically bind execution to a connection receipt.",
                        hint: "Update the runtime host before retrying target-attested browser execution.")
                }
            }
        }
        let projected = try result.projectingMutationProgress(for: calls)
        let executionOutcome: DesktopActionOutcome? = if plannedMutationCount > 0 {
            projected.actionFailure?.outcome ?? Self.successOutcome(
                dispatchedCallCount: plannedMutationCount)
        } else if projected.connectionOutcome != nil {
            projected.actionFailure?.outcome
        } else {
            nil
        }
        let outcome = Self.combinedExecutionOutcome(
            connection: projected.connectionOutcome,
            execution: executionOutcome)
        let publishesExecutionEvidence = outcome != nil ||
            (!projected.response.isError && projected.actionFailure == nil)
        let payload = if publishesExecutionEvidence {
            BrowserMCPExecutionEvidence.attaching(
                to: projected.response,
                connectionReceipt: projected.connectionReceipt,
                providerSessionEpoch: result.providerSessionEpoch,
                completedCallCount: plannedMutationCount == 0
                    ? result.completedCallCount
                    : projected.completedCallCount,
                dispatchedCallCount: plannedMutationCount == 0
                    ? result.dispatchedCallCount
                    : projected.dispatchedCallCount)
        } else {
            projected.response
        }
        return DesktopActionResult(
            payload: payload,
            outcome: outcome)
    }

    @MainActor
    public func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
    {
        do {
            let result = try await self.resolvedSessionManager().executeSequence(
                calls,
                channel: channel,
                expectedConnectionReceipt: expectedConnectionReceipt)
            if result.response.isError || result.actionFailure != nil {
                await self.reconcileTargetOwnershipAfterExecutionFailure()
            }
            return result
        } catch {
            await self.reconcileTargetOwnershipAfterExecutionFailure()
            throw error
        }
    }

    @MainActor
    private var usesTargetOwnershipPool: Bool {
        self.ownedSession != nil || self.authenticatedSessionPool != nil
    }

    @MainActor
    private var requiresExistingLiveReceipt: Bool {
        self.ownedSession != nil
    }

    @MainActor
    private func targetOwnershipReservation() -> BrowserMCPSessionManager.TargetReservation? {
        if let ownedSession = self.ownedSession {
            return { receipt in try ownedSession.pool.bind(ownedSession.id, to: receipt) }
        }
        guard let pool = self.authenticatedSessionPool else { return nil }
        return { receipt in try pool.bindRoot(to: receipt) }
    }

    @MainActor
    private func targetOwnershipRelease() -> BrowserMCPSessionManager.TargetRelease? {
        guard self.usesTargetOwnershipPool else { return nil }
        if let ownedSession = self.ownedSession {
            return { ownedSession.pool.unbind(ownedSession.id) }
        }
        guard let pool = self.authenticatedSessionPool else { return nil }
        return { pool.unbindRoot() }
    }

    @MainActor
    private func reconcileTargetOwnershipAfterExecutionFailure() async {
        guard self.usesTargetOwnershipPool else { return }
        await self.reconcileTargetOwnershipAfterFailure(using: self.resolvedSessionManager())
    }

    @MainActor
    private func reconcileTargetOwnershipAfterFailure(using manager: BrowserMCPSessionManager) async {
        guard let releaseTarget = self.targetOwnershipRelease() else { return }
        let authorizationSnapshot = self.unclaimedConnectionHandoffAuthorizationSnapshot()
        let reconciliation = Task { @MainActor in
            await manager.status(
                channel: nil,
                releaseTargetWhenDisconnected: releaseTarget)
        }
        let status = await reconciliation.value
        self.pruneConnectionHandoffAuthorizations(authorizationSnapshot, after: status)
    }

    /// Legacy low-level configuration factory retained for source compatibility.
    ///
    /// Passing neither an exact WebSocket nor an explicit isolated/URL environment option selects
    /// upstream ambient auto-connect. Peekaboo product sessions never call this path: standard
    /// channels resolve and attest `DevToolsActivePort`, then use an exact WebSocket configuration.
    @available(
        *,
        deprecated,
        message: "Use chromeDevToolsConfig(webSocketEndpoint:) or isolatedChromeDevToolsConfig(channel:headless:)")
    public static func chromeDevToolsConfig(
        channel: BrowserMCPChannel?,
        webSocketEndpoint: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> MCPServerConfig
    {
        let resolvedChannel = channel ?? .stable
        let target: BrowserMCPLaunchTarget
        if let webSocketEndpoint, !webSocketEndpoint.isEmpty {
            target = .exactWebSocket(webSocketEndpoint)
        } else if let browserURL = environment["PEEKABOO_BROWSER_MCP_BROWSER_URL"], !browserURL.isEmpty {
            return self.chromeDevToolsConfig(
                browserURL: browserURL,
                headless: self.environmentFlag("PEEKABOO_BROWSER_MCP_HEADLESS", environment: environment))
        } else if self.environmentFlag("PEEKABOO_BROWSER_MCP_ISOLATED", environment: environment) {
            target = .isolated(resolvedChannel)
        } else {
            target = .autoConnect(resolvedChannel)
        }
        return self.chromeDevToolsConfig(
            target: target,
            headless: self.environmentFlag("PEEKABOO_BROWSER_MCP_HEADLESS", environment: environment))
    }

    /// Creates a Chrome DevTools MCP configuration that can attach only to one pre-resolved WebSocket.
    public static func chromeDevToolsConfig(webSocketEndpoint: String) -> MCPServerConfig {
        self.chromeDevToolsConfig(
            target: .exactWebSocket(webSocketEndpoint),
            headless: false)
    }

    /// Creates an explicitly isolated Chrome profile for deterministic tests and opt-in standalone use.
    public static func isolatedChromeDevToolsConfig(
        channel: BrowserMCPChannel,
        headless: Bool = false) -> MCPServerConfig
    {
        self.chromeDevToolsConfig(
            target: .isolated(channel),
            headless: headless)
    }

    private static func successOutcome(dispatchedCallCount: Int) -> DesktopActionOutcome {
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(dispatchedCallCount) else {
            preconditionFailure("A successful browser execution must dispatch at least one call")
        }
        return .dispatchedUnverified(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: unitCount)
    }

    private static func combinedExecutionOutcome(
        connection: DesktopActionOutcome?,
        execution: DesktopActionOutcome?) -> DesktopActionOutcome?
    {
        guard let connection else { return execution }
        guard let execution else { return connection }

        var sequence = DesktopActionSequenceAccumulator()
        sequence.record(.outcome(connection))
        let isSuccessfulExecution = execution.isAccepted(by: .confirmedOrDispatched)
        if !isSuccessfulExecution,
           let failure = DesktopActionFailure(
               outcome: execution,
               message: "Browser execution failed after implicit connection setup.")
        {
            return sequence.failure(
                combining: failure,
                message: failure.message).outcome
        }
        sequence.record(.outcome(execution))
        let resolution = sequence.successResolution()
        return resolution.outcome ?? .indeterminate(
            route: connection.route,
            evidence: .completionUnknown,
            unitCount: resolution.mutationDisposition.unitCount)
    }

    private static func actionSemantics(_ call: BrowserMCPMappedCall)
        -> BrowserMCPPageRoutingContract.ActionSemantics
    {
        BrowserMCPPageRoutingContract.actionSemantics(
            for: call.toolName,
            arguments: call.arguments) ?? .mutating
    }

    static func chromeDevToolsConfig(
        target: BrowserMCPLaunchTarget,
        headless: Bool) -> MCPServerConfig
    {
        var args = self.chromeDevToolsBaseArguments
        let description: String

        switch target {
        case let .exactWebSocket(webSocketEndpoint):
            args.append("--wsEndpoint=\(webSocketEndpoint)")
            description = "Chrome DevTools automation for an exact browser endpoint"
        case let .isolated(channel):
            args.append("--isolated")
            args.append("--channel=\(channel.rawValue)")
            description = "Chrome DevTools automation for an isolated \(channel.rawValue) Chrome profile"
        case let .autoConnect(channel):
            args.append("--auto-connect")
            args.append("--channel=\(channel.rawValue)")
            description = "Chrome DevTools automation for the running \(channel.rawValue) Chrome profile"
        }

        if headless, case .isolated = target {
            args.append("--headless")
        }

        args.append("--no-usage-statistics")
        args.append("--no-performance-crux")

        return MCPServerConfig(
            transport: "stdio",
            command: "npx",
            args: args,
            enabled: true,
            timeout: 30,
            autoReconnect: false,
            description: description)
    }

    private static let chromeDevToolsBaseArguments = [
        "-y",
        "chrome-devtools-mcp@1.6.0",
        "--experimentalPageIdRouting",
        "--experimentalStructuredContent",
    ]

    static func chromeDevToolsConfig(browserURL: String, headless _: Bool) -> MCPServerConfig {
        var args = self.chromeDevToolsBaseArguments
        args.append("--browserUrl=\(browserURL)")
        args.append("--no-usage-statistics")
        args.append("--no-performance-crux")
        return MCPServerConfig(
            transport: "stdio",
            command: "npx",
            args: args,
            enabled: true,
            timeout: 30,
            autoReconnect: false,
            description: "Chrome DevTools automation for \(browserURL)")
    }

    public static func detectRunningBrowsers(channel: BrowserMCPChannel? = nil) -> [DetectedBrowser] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard !application.isTerminated else { return nil }
            guard let name = application.localizedName else { return nil }
            guard let bundleIdentifier = application.bundleIdentifier else { return nil }
            guard let inferred = BrowserMCPChannel.infer(
                bundleIdentifier: bundleIdentifier,
                applicationName: name)
            else {
                return nil
            }
            if let channel, channel != inferred {
                return nil
            }

            return DetectedBrowser(
                name: name,
                bundleIdentifier: bundleIdentifier,
                processIdentifier: application.processIdentifier,
                processStartIdentity: SystemIdentityResolver.processStartIdentity(application.processIdentifier),
                version: self.version(for: application),
                channel: inferred)
        }
    }

    static func preferredChannel() -> BrowserMCPChannel {
        self.detectRunningBrowsers().first?.channel ?? .stable
    }

    private static func environmentFlag(_ name: String, environment: [String: String]) -> Bool {
        guard let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }

    @MainActor
    private func resolvedSessionManager() -> BrowserMCPSessionManager {
        if let sessionManager {
            return sessionManager
        }
        let sessionManager = BrowserMCPSessionManager(serverName: Self.serverName)
        self.sessionManager = sessionManager
        return sessionManager
    }

    private static func version(for application: NSRunningApplication) -> String? {
        guard let url = application.bundleURL,
              let bundle = Bundle(url: url)
        else {
            return nil
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

extension BrowserMCPService {
    @MainActor
    private func unclaimedConnectionHandoffAuthorizationSnapshot()
        -> [UUID: BrowserMCPConnectionHandoffAuthorization]
    {
        self.connectionHandoffAuthorizations.compactMapValues(\.unclaimedAuthorization)
    }

    @MainActor
    private func pruneConnectionHandoffAuthorizations(
        _ snapshot: [UUID: BrowserMCPConnectionHandoffAuthorization],
        after status: BrowserMCPStatus)
    {
        guard status.observation == .confirmed else { return }
        let currentBinding: BrowserMCPExecutionSessionBinding? = if status.isConnected,
                                                                    let receipt = status.connectionReceipt,
                                                                    let epoch = status.providerSessionEpoch
        {
            BrowserMCPExecutionSessionBinding(
                connectionReceipt: receipt,
                providerSessionEpoch: epoch)
        } else {
            nil
        }
        for (authorizationID, authorization) in snapshot {
            guard self.connectionHandoffAuthorizations[authorizationID]?.unclaimedAuthorization == authorization,
                  authorization.sourceBinding != currentBinding
            else { continue }
            self.connectionHandoffAuthorizations.removeValue(forKey: authorizationID)
        }
    }

    @MainActor
    private func discardUnclaimedConnectionHandoffAuthorizations() {
        self.connectionHandoffAuthorizations = self.connectionHandoffAuthorizations.filter { _, entry in
            entry.unclaimedAuthorization == nil
        }
    }

    @MainActor
    private func discardConnectionHandoffAuthorizations(
        boundTo sourceBinding: BrowserMCPExecutionSessionBinding,
        excluding retainedAuthorizationID: UUID? = nil)
    {
        self.connectionHandoffAuthorizations = self.connectionHandoffAuthorizations.filter { authorizationID, entry in
            authorizationID == retainedAuthorizationID || entry.authorization.sourceBinding != sourceBinding
        }
    }

    @MainActor
    private func discardConnectionHandoffAuthorizations(boundTo name: String) {
        self.connectionHandoffAuthorizations = self.connectionHandoffAuthorizations.filter { _, entry in
            switch entry {
            case let .ready(_, boundName):
                boundName != name
            case let .inFlight(_, currentName, _):
                currentName != name
            }
        }
    }

    @MainActor
    public func storeConnectionHandoffAuthorization(
        connectionReceipt: BrowserMCPConnectionReceipt) async throws -> UUID
    {
        guard self.supportsAuthenticatedSessionBootstrap else {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
        guard self.connectionHandoffAuthorizations.count < 128 else {
            throw BrowserMCPConnectionError.handoffAuthorizationCapacityExceeded
        }
        let authorization = try await self.authorizeConnectionHandoff(connectionReceipt: connectionReceipt)
        guard self.connectionHandoffAuthorizations.count < 128 else {
            throw BrowserMCPConnectionError.handoffAuthorizationCapacityExceeded
        }
        var authorizationID = UUID()
        while self.connectionHandoffAuthorizations[authorizationID] != nil {
            authorizationID = UUID()
        }
        self.connectionHandoffAuthorizations[authorizationID] = .ready(
            authorization: authorization,
            boundName: nil)
        _ = await self.status(channel: nil)
        guard self.connectionHandoffAuthorizations[authorizationID]?.unclaimedAuthorization == authorization else {
            throw BrowserMCPConnectionError.invalidHandoffAuthorization
        }
        return authorizationID
    }

    @MainActor
    public func discardConnectionHandoffAuthorization(_ authorizationID: UUID) {
        self.connectionHandoffAuthorizations.removeValue(forKey: authorizationID)
    }

    @MainActor
    public func transferConnection(
        toAuthenticatedSessionNamed name: String,
        authorizationID: UUID,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt) async throws -> BrowserMCPService
    {
        guard case let .ready(authorization, boundName)? = self.connectionHandoffAuthorizations[authorizationID],
              authorization.connectionReceipt == expectedConnectionReceipt,
              boundName == nil || boundName == name
        else {
            throw BrowserMCPConnectionError.invalidHandoffAuthorization
        }
        let attemptID = UUID()
        self.connectionHandoffAuthorizations[authorizationID] = .inFlight(
            authorization: authorization,
            name: name,
            attemptID: attemptID)
        var sourceEpochEnded = false
        var retryableDestinationFailure = false
        defer {
            if sourceEpochEnded {
                self.discardConnectionHandoffAuthorizations(
                    boundTo: authorization.sourceBinding,
                    excluding: authorizationID)
            }
        }
        do {
            let service = try await self.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorization: authorization,
                onSourceEpochEnded: { sourceEpochEnded = true },
                onRetryableDestinationFailure: {
                    retryableDestinationFailure = true
                })
            self.finishConnectionHandoffAuthorizationAttempt(
                authorizationID,
                attemptID: attemptID,
                authorization: authorization,
                name: name,
                retryable: false)
            return service
        } catch {
            self.finishConnectionHandoffAuthorizationAttempt(
                authorizationID,
                attemptID: attemptID,
                authorization: authorization,
                name: name,
                retryable: retryableDestinationFailure)
            throw error
        }
    }

    @MainActor
    private func finishConnectionHandoffAuthorizationAttempt(
        _ authorizationID: UUID,
        attemptID: UUID,
        authorization: BrowserMCPConnectionHandoffAuthorization,
        name: String,
        retryable: Bool)
    {
        guard case let .inFlight(currentAuthorization, currentName, currentAttemptID)? =
            self.connectionHandoffAuthorizations[authorizationID],
            currentAuthorization == authorization,
            currentName == name,
            currentAttemptID == attemptID
        else { return }
        if retryable {
            self.connectionHandoffAuthorizations[authorizationID] = .ready(
                authorization: authorization,
                boundName: name)
        } else {
            self.connectionHandoffAuthorizations.removeValue(forKey: authorizationID)
        }
    }

    @MainActor
    @discardableResult
    public func retryPendingAuthenticatedSessionCleanup() async -> Bool {
        guard self.ownedSession == nil, let pool = self.authenticatedSessionPool else { return true }
        if let retry = self.authenticatedSessionCleanupRetry {
            return await retry.task.value
        }
        let retryID = UUID()
        let retry = Task { @MainActor in
            for name in pool.pendingCleanupNames {
                if let recovery = pool.sourceRecovery(named: name),
                   await self.resolvedSessionManager().recoverSourceHandoff(
                       authorization: recovery.authorization)
                {
                    pool.confirmSourceRecovery(for: recovery.sessionID)
                }
            }
            let cleanupConfirmed = await pool.retryPendingCleanup()
            if self.authenticatedSessionCleanupRetry?.id == retryID {
                self.authenticatedSessionCleanupRetry = nil
            }
            return cleanupConfirmed
        }
        self.authenticatedSessionCleanupRetry = (retryID, retry)
        return await retry.value
    }

    @MainActor
    var pendingAuthenticatedSessionCleanupCount: Int {
        self.authenticatedSessionPool?.pendingCleanupCount ?? 0
    }
}

extension BrowserMCPService {
    @MainActor
    public func disconnect() async {
        _ = try? await self.disconnectWithResult()
    }

    @MainActor
    public func disconnectWithResult() async throws -> BrowserMCPStatus {
        let manager = self.resolvedSessionManager()
        let releaseTarget = self.targetOwnershipRelease()
        let cleanupConfirmed = await manager.disconnectAndConfirm(releaseTarget: {
            releaseTarget?()
            self.discardUnclaimedConnectionHandoffAuthorizations()
        })
        guard cleanupConfirmed else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Browser disconnect completion is unknown because provider cleanup was not confirmed.",
                hint: "Check browser status before deciding whether to disconnect or reconnect again.")
        }
        return await manager.confirmedDisconnectedStatus(channel: nil)
    }
}

public enum BrowserMCPConnectionError: LocalizedError, Equatable {
    case noBrowser(BrowserMCPChannel)
    case ambiguousBrowsers(BrowserMCPChannel, [Int32])
    case processIdentityUnavailable(Int32)
    case explicitEndpointUnsupported
    case invalidEndpoint(String)
    case channelEndpointUnavailable(BrowserMCPChannel, String)
    case permissionBearingConnectionFailed(String)
    case permissionBearingConnectionCancelled
    case connectionProbeFailed(String)
    case connectionLost(String)
    case expectedConnectionReceiptMismatch
    case expectedProviderSessionEpochMismatch
    case receiptBindingUnsupported
    case handoffRecoveryRequired(String)
    case handoffAuthorizationCapacityExceeded
    case authenticatedSessionCapacityExceeded
    case invalidHandoffAuthorization
    case sessionEnded
    case scopedSessionOpenRecoveryRequired
    case targetLocked

    public var errorDescription: String? {
        switch self {
        case let .noBrowser(channel):
            "No running \(channel.rawValue) Chrome process is available for an exact browser connection."
        case let .ambiguousBrowsers(channel, processIdentifiers):
            "Multiple \(channel.rawValue) Chrome processes are running (PIDs: " +
                processIdentifiers.sorted().map(String.init).joined(separator: ", ") +
                "). Refusing channel-only browser discovery; reconnect with one exact loopback browser URL."
        case let .processIdentityUnavailable(processIdentifier):
            "Chrome PID \(processIdentifier) has no stable process-generation receipt."
        case .explicitEndpointUnsupported:
            "This browser client cannot carry an explicit DevTools endpoint."
        case let .invalidEndpoint(reason):
            "Invalid browser_url: \(reason)"
        case let .channelEndpointUnavailable(channel, reason):
            "The running \(channel.rawValue) Chrome channel did not expose a usable standard-profile DevTools " +
                "WebSocket: \(reason). Enable remote debugging and approve Chrome's prompt, or use one exact " +
                "loopback browser_url for a custom profile."
        case let .permissionBearingConnectionFailed(reason):
            "The permission-bearing Chrome connection did not complete: \(reason)"
        case .permissionBearingConnectionCancelled:
            "The permission-bearing Chrome connection was cancelled after it started."
        case let .connectionProbeFailed(reason):
            "Chrome DevTools MCP started, but its exact read-only connection probe failed: \(reason)"
        case let .connectionLost(reason):
            "The exact browser connection was lost or changed: \(reason). Disconnect and reconnect explicitly."
        case .expectedConnectionReceiptMismatch:
            "The expected browser connection changed before tool dispatch. Refresh browser status and retry."
        case .expectedProviderSessionEpochMismatch:
            "The expected Chrome DevTools MCP child changed before tool dispatch. Refresh browser status and retry."
        case .receiptBindingUnsupported:
            "This browser client cannot atomically bind execution to an exact connection receipt."
        case let .handoffRecoveryRequired(reason):
            "Browser connection handoff requires recovery before the target can be reused: \(reason)"
        case .handoffAuthorizationCapacityExceeded:
            "The bounded browser handoff authorization store is full."
        case .authenticatedSessionCapacityExceeded:
            "The bounded authenticated browser session store is full. End a session, or retry after cleanup completes."
        case .invalidHandoffAuthorization:
            "The browser handoff authorization is missing, consumed, or belongs to another exact connection."
        case .sessionEnded:
            "This authenticated browser session has ended and cannot be reused. Start a new session."
        case .scopedSessionOpenRecoveryRequired:
            "A caller-scoped browser session open remains unresolved. End or retry its owning session before " +
                "starting another browser-enabled session."
        case .targetLocked:
            "A different browser target is already connected. " +
                "Disconnect it before selecting another channel or endpoint."
        }
    }
}
