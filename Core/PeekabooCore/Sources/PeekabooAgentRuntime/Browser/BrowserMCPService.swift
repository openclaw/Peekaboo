import AppKit
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

public struct BrowserMCPProviderSessionEpoch: Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
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

    public init(
        isConnected: Bool,
        toolCount: Int,
        detectedBrowsers: [DetectedBrowser],
        connectionReceipt: BrowserMCPConnectionReceipt? = nil,
        providerSessionEpoch: BrowserMCPProviderSessionEpoch? = nil,
        error: String? = nil)
    {
        self.isConnected = isConnected
        self.toolCount = toolCount
        self.detectedBrowsers = detectedBrowsers
        self.connectionReceipt = connectionReceipt
        self.providerSessionEpoch = providerSessionEpoch
        self.error = error
    }
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

struct BrowserMCPNativeWindowBoundActionResult: Sendable {
    let actionResult: DesktopActionResult<ToolResponse>
    let nativeWindowReceipt: BrowserNativeWindowReceipt
}

struct BrowserMCPNativeWindowBoundExecutionRequest: Sendable {
    let calls: [BrowserMCPMappedCall]
    let channel: BrowserMCPChannel?
    let sessionBinding: BrowserMCPExecutionSessionBinding
    let elementPreflight: BrowserMCPElementPreflight?
    let pageReference: String
    let deadline: ContinuousClock.Instant
}

protocol BrowserMCPNativeWindowBindingProviding: BrowserMCPAtomicSessionActionProviding {
    var nativeWindowBindingCapabilitySession: BrowserToolCapabilitySession? { get }

    @MainActor
    func bindNativeWindowHoldingCapabilityGate(
        pageReference: String,
        target: BrowserNativeWindowTarget,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        deadline: ContinuousClock.Instant) async throws -> BrowserNativeWindowBindingProof

    @MainActor
    func executeNativeWindowBoundSequenceWithOutcomeHoldingCapabilityGate(
        _ request: BrowserMCPNativeWindowBoundExecutionRequest) async throws
        -> BrowserMCPNativeWindowBoundActionResult
}

protocol BrowserMCPAuthenticatedSessionEnding: BrowserMCPClientProviding {
    @MainActor
    func endAuthenticatedBrowserSession() async
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

public final class BrowserMCPService: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    BrowserMCPAtomicSessionActionProviding,
    BrowserMCPConnectionResultProviding, BrowserMCPAuthenticatedSessionEnding,
    BrowserMCPNativeWindowBindingProviding, @unchecked Sendable
{
    public let supportsNativeBrowserConnectionBinding: Bool

    private static let serverName = "chrome-devtools"

    @MainActor private var sessionManager: BrowserMCPSessionManager?
    @MainActor private var authenticatedSessionPool: BrowserMCPAuthenticatedSessionPool?
    private let sessionCapabilities: BrowserToolCapabilitySession?
    private let sessionMutationGate: MCPToolSnapshotExecutionGate?
    private let nativeWindowBindingDependencies: BrowserNativeWindowBindingCoordinator.Dependencies
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
        self.nativeWindowBindingDependencies = .live
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
        self.nativeWindowBindingDependencies = .live
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
        self.nativeWindowBindingDependencies = .live
        self.authenticatedSessionPool = BrowserMCPAuthenticatedSessionPool { serverName in
            BrowserMCPSessionManager(serverName: serverName, manager: manager)
        }
    }

    @MainActor
    init(
        sessionManager: BrowserMCPSessionManager,
        ownedSession: (
            pool: BrowserMCPAuthenticatedSessionPool,
            id: BrowserMCPAuthenticatedSessionPool.SessionID)? = nil,
        sessionCapabilities: BrowserToolCapabilitySession? = nil,
        sessionMutationGate: MCPToolSnapshotExecutionGate? = nil,
        nativeWindowBindingDependencies: BrowserNativeWindowBindingCoordinator.Dependencies = .live)
    {
        self.supportsNativeBrowserConnectionBinding = sessionManager.supportsNativeBrowserConnectionBinding
        self.sessionManager = sessionManager
        self.authenticatedSessionPool = nil
        self.ownedSession = ownedSession
        self.sessionCapabilities = sessionCapabilities
        self.sessionMutationGate = sessionMutationGate
        self.nativeWindowBindingDependencies = nativeWindowBindingDependencies
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
    func endAuthenticatedSession(_ sessionID: BrowserMCPAuthenticatedSessionPool.SessionID) async {
        await self.authenticatedSessionPool?.end(sessionID)
    }

    @MainActor
    func endAuthenticatedSession(named name: String) async {
        await self.authenticatedSessionPool?.end(named: name)
    }

    @MainActor
    func endAuthenticatedBrowserSession() async {
        guard let ownedSession else { return }
        await ownedSession.pool.end(ownedSession.id)
        if self.ownedSession?.id == ownedSession.id {
            self.ownedSession = nil
        }
    }

    var browserCapabilitySession: BrowserToolCapabilitySession? {
        self.sessionCapabilities
    }

    var nativeWindowBindingCapabilitySession: BrowserToolCapabilitySession? {
        self.supportsNativeBrowserConnectionBinding ? self.sessionCapabilities : nil
    }

    var browserMutationExecutionGate: MCPToolSnapshotExecutionGate? {
        self.sessionMutationGate
    }

    @MainActor
    func bindNativeWindowHoldingCapabilityGate(
        pageReference: String,
        target: BrowserNativeWindowTarget,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        deadline: ContinuousClock.Instant) async throws -> BrowserNativeWindowBindingProof
    {
        guard let capabilities = self.nativeWindowBindingCapabilitySession else {
            throw BrowserNativeWindowBindingCoordinatorError.controlUnavailable
        }
        return try await BrowserNativeWindowBindingCoordinator.bindHoldingCapabilityGate(
            pageReference: pageReference,
            nativeTarget: target,
            context: .init(
                sessionBinding: expectedSessionBinding,
                capabilities: capabilities,
                manager: self.resolvedSessionManager(),
                deadline: deadline),
            dependencies: self.nativeWindowBindingDependencies)
    }

    @MainActor
    func executeNativeWindowBoundSequenceWithOutcomeHoldingCapabilityGate(
        _ request: BrowserMCPNativeWindowBoundExecutionRequest) async throws
        -> BrowserMCPNativeWindowBoundActionResult
    {
        guard let capabilities = self.nativeWindowBindingCapabilitySession else {
            throw BrowserNativeWindowBindingCoordinatorError.controlUnavailable
        }
        do {
            let bound = try await self.resolvedSessionManager().executeNativeWindowBoundSequence(
                request,
                capabilities: capabilities,
                receiptProviders: self.nativeWindowBindingDependencies.receiptProviders)
            let projected = try Self.projectExecutionResult(bound.result, calls: request.calls)
            return BrowserMCPNativeWindowBoundActionResult(
                actionResult: DesktopActionResult(
                    payload: BrowserMCPExecutionEvidence.attachingNativeWindowReceipt(
                        to: projected.payload,
                        receipt: bound.nativeWindowReceipt),
                    outcome: projected.outcome),
                nativeWindowReceipt: bound.nativeWindowReceipt)
        } catch BrowserMCPConnectionError.expectedConnectionReceiptMismatch,
            BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
        {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact browser provider session changed before bound tool dispatch.",
                hint: "Refresh browser status and bind the page to its native window again.")
        } catch BrowserMCPConnectionError.receiptBindingUnsupported {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The browser provider cannot atomically execute a native-window-bound action.",
                hint: "Update the runtime host before retrying native browser window binding.")
        }
    }

    @MainActor
    public func status(channel: BrowserMCPChannel? = nil) async -> BrowserMCPStatus {
        let status = await self.resolvedSessionManager().status(channel: channel)
        self.reconcileTargetOwnership(with: status)
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
        let result: DesktopActionResult<BrowserMCPStatus>
        do {
            let reservation: BrowserMCPSessionManager.TargetReservation? = if let ownedSession = self.ownedSession {
                { receipt in try ownedSession.pool.bind(ownedSession.id, to: receipt) }
            } else if let pool = self.authenticatedSessionPool {
                { receipt in try pool.bindRoot(to: receipt) }
            } else {
                nil
            }
            result = try await manager.connectWithOutcome(
                channel: channel,
                browserURL: browserURL,
                reserveTarget: reservation)
        } catch {
            await self.reconcileTargetOwnership(with: manager.status(channel: nil))
            throw error
        }
        if let ownedSession = self.ownedSession,
           let receipt = result.payload.connectionReceipt
        {
            do {
                try ownedSession.pool.bind(ownedSession.id, to: receipt)
            } catch {
                await self.resolvedSessionManager().disconnect()
                ownedSession.pool.unbind(ownedSession.id)
                throw error
            }
        } else if let pool = self.authenticatedSessionPool,
                  let receipt = result.payload.connectionReceipt
        {
            do {
                try pool.bindRoot(to: receipt)
            } catch {
                await self.resolvedSessionManager().disconnect()
                pool.unbindRoot()
                throw error
            }
        }
        return result
    }

    @MainActor
    public func disconnect() async {
        await self.resolvedSessionManager().disconnect()
        if let ownedSession = self.ownedSession {
            ownedSession.pool.unbind(ownedSession.id)
        } else {
            self.authenticatedSessionPool?.unbindRoot()
        }
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
                connectionPolicy: .requireExistingLiveReceipt).payload
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
                connectionPolicy: .requireExistingLiveReceipt).payload
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
    private func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding?,
        elementPreflight: BrowserMCPElementPreflight? = nil) async throws -> DesktopActionResult<ToolResponse>
    {
        let manager = self.resolvedSessionManager()
        let effectiveConnectionPolicy = self.usesTargetOwnershipPool
            ? BrowserMCPExecutionConnectionPolicy.requireExistingLiveReceipt
            : connectionPolicy
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
                connectionPolicy: effectiveConnectionPolicy)
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
                        connectionPolicy: .allowAutoConnect)
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
        return try Self.projectExecutionResult(result, calls: calls)
    }

    private static func projectExecutionResult(
        _ result: BrowserMCPExecutionResult,
        calls: [BrowserMCPMappedCall]) throws -> DesktopActionResult<ToolResponse>
    {
        let semantics = calls.map(Self.actionSemantics)
        let plannedMutationCount = semantics.count(where: { $0 == .mutating })
        let projected = try result.projectingMutationProgress(for: calls)
        let executionOutcome: DesktopActionOutcome? = if plannedMutationCount > 0 {
            projected.actionFailure?.outcome ?? Self.successOutcome(
                calls: calls,
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
    private func reconcileTargetOwnership(with status: BrowserMCPStatus) {
        guard self.usesTargetOwnershipPool, !status.isConnected else { return }
        if let ownedSession = self.ownedSession {
            ownedSession.pool.unbind(ownedSession.id)
        } else {
            self.authenticatedSessionPool?.unbindRoot()
        }
    }

    @MainActor
    private func reconcileTargetOwnershipAfterExecutionFailure() async {
        guard self.usesTargetOwnershipPool else { return }
        let status = await self.resolvedSessionManager().status(channel: nil)
        self.reconcileTargetOwnership(with: status)
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

    private static func successOutcome(
        calls: [BrowserMCPMappedCall],
        dispatchedCallCount: Int) -> DesktopActionOutcome
    {
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(dispatchedCallCount) else {
            preconditionFailure("A successful browser execution must dispatch at least one call")
        }
        return .dispatchedUnverified(
            delivery: BrowserMCPPageRoutingContract.executionDelivery(for: calls),
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
        "--experimentalInteropTools",
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
    case sessionEnded
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
        case .sessionEnded:
            "This authenticated browser session has ended and cannot be reused. Start a new session."
        case .targetLocked:
            "A different browser target is already connected. " +
                "Disconnect it before selecting another channel or endpoint."
        }
    }
}
