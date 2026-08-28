import AppKit
import Foundation
import MCP
import PeekabooAutomationKit
import PeekabooFoundation
import TachikomaMCP

// swiftlint:disable file_length

@MainActor
protocol BrowserMCPManaging: AnyObject {
    func hasServer(name: String) -> Bool
    func isServerConnected(name: String) async -> Bool
    func serverToolCount(name: String) async -> Int
    func addServer(name: String, config: MCPServerConfig) async throws
    func removeServer(name: String) async
    func executeTool(serverName: String, toolName: String, arguments: [String: Any]) async throws -> ToolResponse
}

extension TachikomaMCPClientManager: BrowserMCPManaging {
    func hasServer(name: String) -> Bool {
        self.getServerConfig(name: name) != nil
    }

    func serverToolCount(name: String) async -> Int {
        await self.getServerTools(name: name).count
    }
}

private struct BrowserMCPResolvedTarget {
    let receipt: BrowserMCPConnectionReceipt
    let config: MCPServerConfig
    let supportsReceiptBoundExecution: Bool
    let channelEndpoint: BrowserMCPDevToolsEndpoint?
    let codeSignatureIdentity: ChromeProcessCodeSignatureValidator.Identity?
    let targetKind: BrowserMCPConnectionTargetKind
}

private struct BrowserMCPStatusInspection {
    let status: BrowserMCPStatus
    let wasCancelled: Bool
    let cleanupConfirmed: Bool
}

@MainActor
// swiftlint:disable:next type_body_length
final class BrowserMCPSessionManager: @unchecked Sendable {
    typealias BrowserDetector = @MainActor (BrowserMCPChannel?) -> [DetectedBrowser]
    typealias ProcessIdentityProvider = @Sendable (Int32) -> UInt64?
    typealias ProcessBundleIdentifierProvider = @MainActor @Sendable (Int32) -> String?
    typealias ProcessCodeSignatureValidator = @Sendable (
        Int32,
        UInt64,
        ChromeChannelIdentity) -> ChromeProcessCodeSignatureValidator.Identity?
    typealias ConnectionAttemptProvider = @MainActor @Sendable () -> BrowserMCPConnectionAttempt
    typealias PreferredChannelProvider = @MainActor @Sendable () -> BrowserMCPChannel
    typealias IsolatedConnectionProvider = @MainActor @Sendable () -> Bool
    typealias TargetReservation = @MainActor (BrowserMCPConnectionReceipt) throws -> Void
    typealias TargetRelease = @MainActor @Sendable () -> Void

    private let serverName: String
    private let manager: any BrowserMCPManaging
    private let detectedBrowsers: BrowserDetector
    private let processStartIdentity: ProcessIdentityProvider
    private let processBundleIdentifier: ProcessBundleIdentifierProvider
    private let processCodeSignatureValidator: ProcessCodeSignatureValidator
    private let connectionAttempt: ConnectionAttemptProvider
    private let preferredChannel: PreferredChannelProvider
    private let isolatedConnectionRequested: IsolatedConnectionProvider
    private let endpointResolver: BrowserMCPDevToolsEndpointResolver
    private let channelEndpointResolver: BrowserMCPChannelEndpointResolver
    private let uploadStager: BrowserMCPUploadStager
    private let environmentOptions: BrowserMCPEnvironmentOptions
    private let executionGate = MCPToolSnapshotExecutionGate()
    private var connectionReceipt: BrowserMCPConnectionReceipt?
    private var providerSessionEpoch: BrowserMCPProviderSessionEpoch?
    private var connectionSupportsReceiptBoundExecution = false
    private var connectionChannelEndpoint: BrowserMCPDevToolsEndpoint?
    private var connectionCodeSignatureIdentity: ChromeProcessCodeSignatureValidator.Identity?
    private var connectionTargetKind: BrowserMCPConnectionTargetKind?
    private var uploadWorkspace: BrowserMCPUploadWorkspace?
    private var activeUploadID: UUID?
    private var connectionCleanupPending = false
    private var drainedHandoffBinding: BrowserMCPExecutionSessionBinding?
    private var sessionEnded = false

    private static let connectionDelivery = DesktopActionOutcome.Delivery(
        mechanism: .browserProtocol,
        mode: .foreground)

    var supportsNativeBrowserConnectionBinding: Bool {
        self.environmentOptions.supportsNativeBrowserConnectionBinding
    }

    init(
        serverName: String,
        manager: any BrowserMCPManaging = TachikomaMCPClientManager(),
        detectedBrowsers: @escaping BrowserDetector = BrowserMCPService.detectRunningBrowsers,
        processStartIdentity: @escaping ProcessIdentityProvider = { processIdentifier in
            SystemIdentityResolver.processStartIdentity(processIdentifier)
        },
        processBundleIdentifier: @escaping ProcessBundleIdentifierProvider = { processIdentifier in
            NSRunningApplication(processIdentifier: processIdentifier)?.bundleIdentifier
        },
        processCodeSignatureValidator: @escaping ProcessCodeSignatureValidator =
            BrowserMCPSessionManager.validateChromeProcessCodeSignature,
        connectionAttempt: @escaping ConnectionAttemptProvider = BrowserMCPConnectionAttempt.live,
        preferredChannel: @escaping PreferredChannelProvider = BrowserMCPService.preferredChannel,
        isolatedConnectionRequested: IsolatedConnectionProvider? = nil,
        endpointResolver: BrowserMCPDevToolsEndpointResolver = .live,
        channelEndpointResolver: BrowserMCPChannelEndpointResolver = .live,
        uploadStager: BrowserMCPUploadStager = .live,
        environment: [String: String] = ProcessInfo.processInfo.environment)
    {
        let environmentOptions = BrowserMCPEnvironmentOptions(environment: environment)
        self.serverName = serverName
        self.manager = manager
        self.detectedBrowsers = detectedBrowsers
        self.processStartIdentity = processStartIdentity
        self.processBundleIdentifier = processBundleIdentifier
        self.processCodeSignatureValidator = processCodeSignatureValidator
        self.connectionAttempt = connectionAttempt
        self.preferredChannel = preferredChannel
        self.isolatedConnectionRequested = isolatedConnectionRequested ?? { environmentOptions.isolated }
        self.endpointResolver = endpointResolver
        self.channelEndpointResolver = channelEndpointResolver
        self.uploadStager = uploadStager
        self.environmentOptions = environmentOptions
    }

    private nonisolated static func validateChromeProcessCodeSignature(
        _ processIdentifier: Int32,
        _ processStartIdentity: UInt64,
        _ channel: ChromeChannelIdentity) -> ChromeProcessCodeSignatureValidator.Identity?
    {
        ChromeProcessCodeSignatureValidator.live.validate(
            processIdentifier,
            processStartIdentity,
            channel)
    }

    func status(
        channel: BrowserMCPChannel?,
        releaseTargetWhenDisconnected: TargetRelease? = nil) async -> BrowserMCPStatus
    {
        do {
            return try await self.withExecutionGate {
                let inspection = await self.inspectStatusUnlocked(channel: channel)
                if !inspection.status.isConnected, !inspection.wasCancelled, inspection.cleanupConfirmed {
                    releaseTargetWhenDisconnected?()
                }
                return inspection.status
            }
        } catch let error where Self.isCancellation(error) {
            return BrowserMCPStatus(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: self.detectedBrowsers(channel),
                connectionReceipt: self.connectionReceipt,
                providerSessionEpoch: self.providerSessionEpoch,
                error: CancellationError().localizedDescription,
                observation: .indeterminate)
        } catch {
            return BrowserMCPStatus(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: self.detectedBrowsers(channel),
                connectionReceipt: nil,
                error: error.localizedDescription)
        }
    }

    func statusForExecution(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        let inspection = try await self.withExecutionGate {
            await self.inspectStatusUnlocked(channel: channel)
        }
        guard !inspection.wasCancelled else { throw CancellationError() }
        try Task.checkCancellation()
        return inspection.status
    }

    private func inspectStatusUnlocked(channel: BrowserMCPChannel?) async -> BrowserMCPStatusInspection {
        let browsers = self.detectedBrowsers(channel)
        if self.connectionCleanupPending {
            let cleanupConfirmed = await self.clearConnection()
            return BrowserMCPStatusInspection(
                status: BrowserMCPStatus(
                    isConnected: false,
                    toolCount: 0,
                    detectedBrowsers: browsers,
                    connectionReceipt: cleanupConfirmed ? nil : self.connectionReceipt,
                    providerSessionEpoch: cleanupConfirmed ? nil : self.providerSessionEpoch,
                    error: cleanupConfirmed ? nil : "Browser provider cleanup remains pending.",
                    observation: cleanupConfirmed ? .confirmed : .indeterminate),
                wasCancelled: false,
                cleanupConfirmed: cleanupConfirmed)
        }
        guard let receipt = self.connectionReceipt,
              let providerSessionEpoch = self.providerSessionEpoch
        else {
            let cleanupConfirmed = await self.clearConnection()
            return BrowserMCPStatusInspection(
                status: BrowserMCPStatus(
                    isConnected: false,
                    toolCount: 0,
                    detectedBrowsers: browsers,
                    connectionReceipt: nil,
                    error: cleanupConfirmed ? nil : "Browser provider cleanup remains pending."),
                wasCancelled: false,
                cleanupConfirmed: cleanupConfirmed)
        }

        do {
            try await self.validate(receipt)
            guard await self.manager.isServerConnected(name: self.serverName) else {
                throw BrowserMCPConnectionError.connectionLost("the persistent MCP child is no longer connected")
            }
            return await BrowserMCPStatusInspection(
                status: BrowserMCPStatus(
                    isConnected: true,
                    toolCount: self.manager.serverToolCount(name: self.serverName),
                    detectedBrowsers: browsers,
                    connectionReceipt: receipt,
                    providerSessionEpoch: providerSessionEpoch),
                wasCancelled: false,
                cleanupConfirmed: false)
        } catch let error where Self.isCancellation(error) {
            return BrowserMCPStatusInspection(
                status: BrowserMCPStatus(
                    isConnected: false,
                    toolCount: 0,
                    detectedBrowsers: browsers,
                    connectionReceipt: receipt,
                    providerSessionEpoch: providerSessionEpoch,
                    error: CancellationError().localizedDescription,
                    observation: .indeterminate),
                wasCancelled: true,
                cleanupConfirmed: false)
        } catch {
            let cleanupConfirmed = await self.clearConnection()
            return BrowserMCPStatusInspection(
                status: BrowserMCPStatus(
                    isConnected: false,
                    toolCount: 0,
                    detectedBrowsers: browsers,
                    connectionReceipt: cleanupConfirmed ? nil : receipt,
                    providerSessionEpoch: cleanupConfirmed ? nil : providerSessionEpoch,
                    error: error.localizedDescription,
                    observation: cleanupConfirmed ? .confirmed : .indeterminate),
                wasCancelled: false,
                cleanupConfirmed: cleanupConfirmed)
        }
    }

    func connect(channel: BrowserMCPChannel?, browserURL: String? = nil) async throws -> BrowserMCPStatus {
        try await self.connectWithOutcome(channel: channel, browserURL: browserURL).payload
    }

    func preflightAuthenticatedCapabilityConnect(browserURL: String?) throws {
        // Request and environment endpoints take precedence over isolated mode in resolveTarget.
        guard browserURL == nil,
              self.environmentOptions.browserURL == nil,
              self.isolatedConnectionRequested()
        else { return }
        throw DesktopActionFailure.preDispatchRefusal(
            reason: .operationUnsupported,
            message: "Authenticated browser capability sessions cannot use an isolated Chrome child because " +
                "the launched browser has no pinnable identity.",
            hint: "Use a native Chrome channel, or launch headless Chrome separately and connect with its exact " +
                "loopback browser_url.")
    }

    func connectWithOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String? = nil,
        reserveTarget: TargetReservation? = nil) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        let attempt = self.connectionAttempt()
        do {
            return try await BrowserMCPConnectionDeadline.run(until: attempt.deadline) {
                try await self.withExecutionGate {
                    do {
                        return try await self.connectUnlockedWithOutcome(
                            channel: channel,
                            browserURL: browserURL,
                            attempt: attempt,
                            reserveTarget: reserveTarget)
                    } catch let error where Self.isCancellation(error) && !attempt.state.didStartAnyDispatch {
                        throw Self.preDispatchConnectionFailure(CancellationError())
                    } catch BrowserMCPConnectionError.targetLocked {
                        throw BrowserMCPConnectionError.targetLocked
                    } catch let failure as DesktopActionFailure {
                        await self.clearConnection()
                        throw failure
                    } catch {
                        await self.clearConnection()
                        if attempt.state.didStartAnyDispatch {
                            throw Self.indeterminateConnectionFailure(error)
                        }
                        throw Self.preDispatchConnectionFailure(error)
                    }
                }
            }
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch let error where Self.isCancellation(error) && !attempt.state.didStartAnyDispatch {
            throw Self.preDispatchConnectionFailure(CancellationError())
        } catch BrowserMCPConnectionError.targetLocked {
            throw BrowserMCPConnectionError.targetLocked
        } catch {
            if attempt.state.didStartAnyDispatch {
                throw Self.indeterminateConnectionFailure(error)
            }
            throw Self.preDispatchConnectionFailure(error)
        }
    }

    private func connectUnlockedWithOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String? = nil,
        attempt: BrowserMCPConnectionAttempt,
        reserveTarget: TargetReservation? = nil) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        guard !self.connectionCleanupPending, self.drainedHandoffBinding == nil else {
            throw BrowserMCPConnectionError.targetLocked
        }
        if let existing = self.connectionReceipt {
            guard self.connectionReceipt(existing, matchesChannel: channel, browserURL: browserURL) else {
                throw BrowserMCPConnectionError.targetLocked
            }
            try await self.validate(existing)
            guard await self.manager.isServerConnected(name: self.serverName) else {
                await self.clearConnection()
                throw BrowserMCPConnectionError.connectionLost("the persistent MCP child exited")
            }
            let inspection = await self.inspectStatusUnlocked(channel: channel)
            guard !inspection.wasCancelled else { throw CancellationError() }
            let status = inspection.status
            guard status.isConnected else {
                throw BrowserMCPConnectionError.connectionLost(
                    status.error ?? "the existing browser connection could not be verified")
            }
            return DesktopActionResult(payload: status, outcome: .confirmedNoChange())
        }

        let target = try await self.resolveTarget(
            channel: channel,
            browserURL: browserURL,
            attempt: attempt,
            reserveTarget: reserveTarget)
        try reserveTarget?(target.receipt)
        if self.manager.hasServer(name: self.serverName) {
            await self.manager.removeServer(name: self.serverName)
        }
        var connectionAttemptDispatched = false
        do {
            try await self.installProvider(target: target) {
                attempt.state.markConnectionDispatchStarted()
                connectionAttemptDispatched = true
            }
            let status = await self.inspectStatusUnlocked(channel: channel).status
            guard status.isConnected else {
                throw BrowserMCPConnectionError.connectionLost(
                    status.error ?? "the new browser connection could not be verified")
            }
            return DesktopActionResult(
                payload: status,
                outcome: .dispatchedUnverified(
                    delivery: Self.connectionDelivery,
                    evidence: .deliveryAccepted,
                    unitCount: .one))
        } catch let error as BrowserMCPUploadStagingError {
            await self.clearConnection()
            if attempt.state.didStartPermissionDispatch || connectionAttemptDispatched {
                throw Self.indeterminateConnectionFailure(error)
            }
            throw error
        } catch let error as BrowserMCPConnectionError {
            await self.clearConnection()
            if attempt.state.didStartPermissionDispatch || connectionAttemptDispatched {
                throw Self.indeterminateConnectionFailure(error)
            }
            throw error
        } catch {
            await self.clearConnection()
            if Self.isCancellation(error), !attempt.state.didStartAnyDispatch {
                throw Self.preDispatchConnectionFailure(CancellationError())
            }
            if attempt.state.didStartPermissionDispatch || connectionAttemptDispatched {
                throw Self.indeterminateConnectionFailure(error)
            }
            throw BrowserMCPConnectionError.connectionProbeFailed(error.localizedDescription)
        }
    }

    private static func indeterminateConnectionFailure(_ cause: any Error) -> DesktopActionFailure {
        .indeterminate(
            delivery: self.connectionDelivery,
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Browser connection completion is unknown after the provider accepted the request.",
            hint: "Check browser status before deciding whether to reconnect.",
            causeDescription: self.errorDescription(cause))
    }

    private static func preDispatchConnectionFailure(_ cause: any Error) -> DesktopActionFailure {
        let cancelled = cause is CancellationError
        return .preDispatchRefusal(
            reason: cancelled ? .requestCancelled : .targetUnavailable,
            message: cancelled
                ? "Browser connection was cancelled before permission-bearing dispatch."
                : "Browser connection was refused before permission-bearing dispatch.",
            hint: cancelled
                ? "Submit a new request only if the browser connection is still wanted."
                : "Correct the detected browser authority and retry explicitly.",
            causeDescription: self.errorDescription(cause))
    }

    func disconnect(releaseTarget: TargetRelease? = nil) async {
        _ = await self.disconnectAndConfirm(releaseTarget: releaseTarget)
    }

    func disconnectAndConfirm(releaseTarget: TargetRelease? = nil) async -> Bool {
        do {
            return try await self.withExecutionGate {
                let cleanupConfirmed = await self.clearConnection()
                if cleanupConfirmed {
                    releaseTarget?()
                }
                return cleanupConfirmed
            }
        } catch {
            return false
        }
    }

    func confirmedDisconnectedStatus(channel: BrowserMCPChannel?) -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: self.detectedBrowsers(channel))
    }

    func preflightHandoffDestination() async throws {
        try await self.withExecutionGate {
            guard !self.connectionCleanupPending,
                  self.drainedHandoffBinding == nil,
                  self.connectionReceipt == nil,
                  self.providerSessionEpoch == nil,
                  !self.manager.hasServer(name: self.serverName),
                  await !(self.manager.isServerConnected(name: self.serverName))
            else {
                throw BrowserMCPConnectionError.targetLocked
            }
        }
    }

    func authorizeConnectionHandoff(receipt: BrowserMCPConnectionReceipt) async throws
        -> BrowserMCPConnectionHandoffAuthorization
    {
        try await self.withExecutionGate {
            let target = try await self.authorizedHandoffTarget(receipt: receipt)
            guard await self.manager.isServerConnected(name: self.serverName),
                  let providerSessionEpoch = self.providerSessionEpoch
            else {
                throw BrowserMCPConnectionError.connectionLost("the source MCP child is no longer connected")
            }
            _ = target
            return BrowserMCPConnectionHandoffAuthorization(sourceBinding: .init(
                connectionReceipt: receipt,
                providerSessionEpoch: providerSessionEpoch))
        }
    }

    func drainConnectionForHandoff(authorization: BrowserMCPConnectionHandoffAuthorization) async throws
        -> BrowserMCPAuthorizedHandoffTarget
    {
        try await self.withExecutionGate {
            guard self.providerSessionEpoch == authorization.sourceBinding.providerSessionEpoch else {
                throw BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
            }
            let target = try await self.authorizedHandoffTarget(receipt: authorization.connectionReceipt)
            guard await self.manager.isServerConnected(name: self.serverName) else {
                throw BrowserMCPConnectionError.connectionLost("the source MCP child is no longer connected")
            }
            try Task.checkCancellation()

            // Root ownership remains authoritative while cancellation-resistant cleanup runs. The caller transfers
            // that exact reservation only after this post-check confirms the source child is gone.
            let cleanup = Task { @MainActor in
                await self.removeProviderForHandoff()
            }
            guard await cleanup.value else {
                if await self.manager.isServerConnected(name: self.serverName),
                   await (try? self.validate(
                       target.receipt,
                       channelEndpoint: target.channelEndpoint,
                       codeSignatureIdentity: target.codeSignatureIdentity,
                       requireDetectedProcess: false)) != nil
                {
                    throw BrowserMCPHandoffSourceDrainError.sourceStillLive(
                        BrowserMCPConnectionError.connectionLost(
                            "the source MCP child remained live after handoff teardown"))
                }
                throw BrowserMCPHandoffSourceDrainError.recoveryRequired(
                    BrowserMCPConnectionError.connectionLost(
                        "source MCP child teardown could not be confirmed"))
            }
            self.discardConnectionState()
            self.drainedHandoffBinding = authorization.sourceBinding
            return target
        }
    }

    func recoverSourceHandoff(authorization: BrowserMCPConnectionHandoffAuthorization) async -> Bool {
        let cleanup = Task { @MainActor in
            do {
                return try await self.withExecutionGate {
                    if self.drainedHandoffBinding == authorization.sourceBinding {
                        self.drainedHandoffBinding = nil
                        return true
                    }
                    guard self.connectionReceipt == authorization.connectionReceipt,
                          self.providerSessionEpoch == authorization.sourceBinding.providerSessionEpoch
                    else { return false }
                    let confirmed = await self.removeProviderForHandoff()
                    if confirmed {
                        self.discardConnectionState()
                    }
                    return confirmed
                }
            } catch {
                return false
            }
        }
        return await cleanup.value
    }

    func settleDrainedSourceHandoff(authorization: BrowserMCPConnectionHandoffAuthorization) {
        if self.drainedHandoffBinding == authorization.sourceBinding {
            self.drainedHandoffBinding = nil
        }
    }

    func bootstrapAuthorizedHandoff(_ target: BrowserMCPAuthorizedHandoffTarget) async throws {
        do {
            try await self.withExecutionGate {
                do {
                    guard !self.connectionCleanupPending,
                          self.drainedHandoffBinding == nil,
                          self.connectionReceipt == nil,
                          self.providerSessionEpoch == nil,
                          !self.manager.hasServer(name: self.serverName),
                          await !(self.manager.isServerConnected(name: self.serverName))
                    else {
                        throw BrowserMCPConnectionError.targetLocked
                    }
                    try await self.validate(
                        target.receipt,
                        channelEndpoint: target.channelEndpoint,
                        codeSignatureIdentity: target.codeSignatureIdentity,
                        requireDetectedProcess: false)
                    try Task.checkCancellation()
                    guard let webSocketDebuggerURL = target.receipt.webSocketDebuggerURL else {
                        throw BrowserMCPConnectionError.connectionLost(
                            "the handoff receipt omitted its exact DevTools WebSocket")
                    }

                    try await self.installProvider(
                        target: BrowserMCPResolvedTarget(
                            receipt: target.receipt,
                            config: BrowserMCPService.chromeDevToolsConfig(
                                webSocketEndpoint: webSocketDebuggerURL),
                            supportsReceiptBoundExecution: true,
                            channelEndpoint: target.channelEndpoint,
                            codeSignatureIdentity: target.codeSignatureIdentity,
                            targetKind: target.targetKind),
                        onProviderDispatch: {})
                    guard await self.manager.isServerConnected(name: self.serverName) else {
                        throw BrowserMCPConnectionError.connectionLost(
                            "the destination MCP child exited during handoff setup")
                    }
                } catch {
                    throw await self.handoffDestinationFailure(error)
                }
            }
        } catch let failure as BrowserMCPHandoffDestinationError {
            throw failure
        } catch {
            throw await self.handoffDestinationFailure(error)
        }
    }

    func endSession() async -> Bool {
        self.sessionEnded = true
        let cleanup = Task { @MainActor [weak self] in
            guard let self else { return true }
            do {
                try await self.executionGate.acquire()
            } catch {
                return false
            }
            let confirmed = await self.removeProviderForHandoff()
            if confirmed {
                self.discardConnectionState()
            }
            await self.executionGate.release()
            return confirmed
        }
        return await cleanup.value
    }

    func execute(
        toolName: String,
        arguments: [String: Any],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        try await self.executeSequence(
            [BrowserMCPMappedCall(toolName: toolName, arguments: arguments)],
            channel: channel)
    }

    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        let result = try await self.executeSequenceResult(calls, channel: channel)
        if result.providerReturnedError {
            return result.response
        }
        if let failure = result.actionFailure {
            throw failure
        }
        return result.response
    }

    func executeSequenceResult(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy = .allowAutoConnect,
        reserveTarget: TargetReservation? = nil) async throws
        -> BrowserMCPExecutionResult
    {
        try await self.withExecutionGate {
            try await self.executeSequenceUnlocked(
                calls,
                channel: channel,
                expectedConnectionReceipt: nil,
                expectedProviderSessionEpoch: nil,
                connectionPolicy: connectionPolicy,
                reserveTarget: reserveTarget)
        }
    }

    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt) async throws -> BrowserMCPExecutionResult
    {
        do {
            return try await self.withExecutionGate {
                try await self.executeSequenceUnlocked(
                    calls,
                    channel: channel,
                    expectedConnectionReceipt: expectedConnectionReceipt,
                    expectedProviderSessionEpoch: nil,
                    connectionPolicy: .requireExistingLiveReceipt)
            }
        } catch let error where Self.isCancellation(error) {
            throw Self.preDispatchFailure(CancellationError())
        }
    }

    func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> BrowserMCPExecutionResult
    {
        do {
            return try await self.withExecutionGate {
                if let elementPreflight {
                    let preflight = try await self.executeSequenceUnlocked(
                        [BrowserMCPMappedCall(
                            toolName: "take_snapshot",
                            arguments: [
                                "pageId": elementPreflight.providerPageID,
                                "verbose": true,
                            ])],
                        channel: channel,
                        expectedConnectionReceipt: expectedSessionBinding.connectionReceipt,
                        expectedProviderSessionEpoch: expectedSessionBinding.providerSessionEpoch,
                        connectionPolicy: .requireExistingLiveReceipt)
                    let currentUIDs = BrowserMCPProviderSnapshotParser.providerUIDs(in: preflight.response)
                    // chrome-devtools-mcp v1.6.0 preserves a UID only for the same per-page
                    // loaderId/backendNodeId pair. The pinned dependency contract checks that identity rule.
                    guard !preflight.response.isError,
                          preflight.actionFailure == nil,
                          currentUIDs.isSuperset(of: elementPreflight.providerUIDs)
                    else {
                        throw DesktopActionFailure.preDispatchRefusal(
                            reason: .targetUnavailable,
                            message: "Browser element references are stale in the current page document.",
                            hint: "Take a fresh browser snapshot and retry with its new opaque element references.")
                    }
                }
                return try await self.executeSequenceUnlocked(
                    calls,
                    channel: channel,
                    expectedConnectionReceipt: expectedSessionBinding.connectionReceipt,
                    expectedProviderSessionEpoch: expectedSessionBinding.providerSessionEpoch,
                    connectionPolicy: .requireExistingLiveReceipt)
            }
        } catch let error where Self.isCancellation(error) {
            throw Self.preDispatchFailure(CancellationError())
        }
    }

    /// This state machine keeps every post-dispatch boundary in one auditable control flow.
    private func executeSequenceUnlocked(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt?,
        expectedProviderSessionEpoch: BrowserMCPProviderSessionEpoch?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy,
        reserveTarget: TargetReservation? = nil) async throws -> BrowserMCPExecutionResult
    {
        guard !calls.isEmpty else {
            throw BrowserMCPConnectionError.connectionLost("the browser action sequence was empty")
        }
        let preparation = try await self.prepareExecutionReceipt(
            channel: channel,
            expectedConnectionReceipt: expectedConnectionReceipt,
            expectedProviderSessionEpoch: expectedProviderSessionEpoch,
            connectionPolicy: connectionPolicy,
            reserveTarget: reserveTarget)
        let sessionBinding = preparation.sessionBinding
        let receipt = sessionBinding.connectionReceipt

        var completedCallCount = 0
        var dispatchedCallCount = 0
        var response: ToolResponse?
        var actionFailure: DesktopActionFailure?
        var failureStage: BrowserMCPExecutionFailureStage?
        var providerReturnedError = false
        var shouldValidateConnection = true
        for (index, call) in calls.enumerated() {
            let current: ToolResponse
            do {
                current = try await self.execute(call)
            } catch let failure as BrowserMCPCallFailure {
                failureStage = .call(index: index)
                switch failure {
                case let .preDispatch(cause):
                    guard completedCallCount > 0 else {
                        if preparation.connectionOutcome != nil {
                            actionFailure = Self.preDispatchFailure(cause)
                            response = .error(actionFailure?.message ?? "Browser sequence stopped")
                            break
                        }
                        if expectedConnectionReceipt != nil {
                            throw Self.preDispatchFailure(cause)
                        }
                        throw cause
                    }
                    actionFailure = Self.partialSequenceFailure(
                        completedCallCount: completedCallCount,
                        cause: cause)
                    response = .error(actionFailure?.message ?? "Browser sequence stopped")
                case let .mayHaveDispatched(cause):
                    dispatchedCallCount = completedCallCount + 1
                    actionFailure = Self.indeterminateSequenceFailure(
                        dispatchedCallCount: dispatchedCallCount,
                        completedCallCount: completedCallCount,
                        cause: cause)
                    response = .error(actionFailure?.message ?? "Browser sequence completion is unknown")
                    shouldValidateConnection = false
                    await self.clearConnection()
                }
                break
            } catch {
                failureStage = .call(index: index)
                dispatchedCallCount = completedCallCount + 1
                actionFailure = Self.indeterminateSequenceFailure(
                    dispatchedCallCount: dispatchedCallCount,
                    completedCallCount: completedCallCount,
                    cause: error)
                response = .error(actionFailure?.message ?? "Browser sequence completion is unknown")
                shouldValidateConnection = false
                await self.clearConnection()
                break
            }
            completedCallCount += 1
            dispatchedCallCount = completedCallCount
            response = current
            if current.isError {
                providerReturnedError = true
                failureStage = .call(index: index)
                actionFailure = Self.indeterminateSequenceFailure(
                    dispatchedCallCount: dispatchedCallCount,
                    completedCallCount: completedCallCount,
                    causeDescription: "The browser tool returned an error response.")
                break
            }
        }
        if shouldValidateConnection {
            do {
                try await self.validate(receipt)
                guard self.connectionReceipt == receipt,
                      self.providerSessionEpoch == sessionBinding.providerSessionEpoch
                else {
                    throw BrowserMCPConnectionError.connectionLost(
                        "the connection receipt or provider child epoch changed before the browser response completed")
                }
            } catch {
                failureStage = .connectionValidation
                dispatchedCallCount = max(dispatchedCallCount, completedCallCount)
                actionFailure = Self.indeterminateSequenceFailure(
                    dispatchedCallCount: dispatchedCallCount,
                    completedCallCount: completedCallCount,
                    cause: error)
                response = .error(actionFailure?.message ?? "Browser connection completion is unknown")
                await self.clearConnection()
            }
        }
        guard let response,
              dispatchedCallCount > 0 || preparation.connectionOutcome?.dispatchState.mutationDispatched == true
        else {
            throw BrowserMCPConnectionError.connectionLost("the browser action sequence returned no response")
        }
        return BrowserMCPExecutionResult(
            response: response,
            connectionReceipt: receipt,
            providerSessionEpoch: sessionBinding.providerSessionEpoch,
            connectionOutcome: preparation.connectionOutcome,
            completedCallCount: completedCallCount,
            dispatchedCallCount: dispatchedCallCount,
            actionFailure: actionFailure,
            failureStage: failureStage,
            providerReturnedError: providerReturnedError)
    }

    // Connection authority, target locking, and live-receipt validation stay in one pre-dispatch control flow.
    // swiftlint:disable:next cyclomatic_complexity
    private func prepareExecutionReceipt(
        channel: BrowserMCPChannel?,
        expectedConnectionReceipt: BrowserMCPConnectionReceipt?,
        expectedProviderSessionEpoch: BrowserMCPProviderSessionEpoch?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy,
        reserveTarget: TargetReservation?) async throws -> BrowserMCPPreparedExecution
    {
        guard !self.connectionCleanupPending else {
            throw Self.existingConnectionRequiredFailure(
                cause: BrowserMCPConnectionError.connectionLost("browser provider cleanup remains pending"))
        }
        if self.connectionReceipt == nil, expectedConnectionReceipt == nil {
            guard connectionPolicy == .allowAutoConnect else {
                throw Self.existingConnectionRequiredFailure()
            }
            let attempt = self.connectionAttempt()
            let connection: DesktopActionResult<BrowserMCPStatus>
            do {
                connection = try await BrowserMCPConnectionDeadline.run(until: attempt.deadline) {
                    try await self.connectUnlockedWithOutcome(
                        channel: channel,
                        browserURL: nil,
                        attempt: attempt,
                        reserveTarget: reserveTarget)
                }
            } catch let failure as DesktopActionFailure {
                throw failure
            } catch {
                await self.clearConnection()
                if attempt.state.didStartAnyDispatch {
                    throw Self.indeterminateConnectionFailure(error)
                }
                throw Self.preDispatchConnectionFailure(error)
            }
            guard connection.payload.isConnected,
                  let receipt = connection.payload.connectionReceipt,
                  let providerSessionEpoch = connection.payload.providerSessionEpoch,
                  self.connectionReceipt == receipt,
                  self.providerSessionEpoch == providerSessionEpoch
            else {
                throw DesktopActionFailure.indeterminate(
                    delivery: connection.outcome?.delivery ?? Self.connectionDelivery,
                    evidence: .completionUnknown,
                    unitCount: connection.outcome?.dispatchState.unitCount ?? .one,
                    message: "Implicit browser connection lost its exact receipt before tool dispatch.",
                    hint: "Check browser status before deciding whether to reconnect.")
            }
            return BrowserMCPPreparedExecution(
                sessionBinding: .init(
                    connectionReceipt: receipt,
                    providerSessionEpoch: providerSessionEpoch),
                connectionOutcome: connection.outcome)
        }
        guard let receipt = self.connectionReceipt,
              let providerSessionEpoch = self.providerSessionEpoch
        else {
            if expectedConnectionReceipt != nil {
                throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
            }
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure()
            }
            throw BrowserMCPConnectionError.connectionLost("no exact connection receipt exists")
        }
        if let expectedConnectionReceipt, receipt != expectedConnectionReceipt {
            throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
        }
        if let expectedProviderSessionEpoch, providerSessionEpoch != expectedProviderSessionEpoch {
            throw BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
        }
        if expectedConnectionReceipt != nil, !self.connectionSupportsReceiptBoundExecution {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
        if let channel, channel != receipt.channel {
            if expectedConnectionReceipt != nil {
                throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
            }
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure(
                    cause: BrowserMCPConnectionError.targetLocked)
            }
            throw BrowserMCPConnectionError.targetLocked
        }
        do {
            try await self.validate(receipt)
        } catch let error where Self.isCancellation(error) {
            if expectedConnectionReceipt != nil || connectionPolicy == .requireExistingLiveReceipt {
                throw Self.preDispatchFailure(CancellationError())
            }
            throw error
        } catch where expectedConnectionReceipt != nil {
            await self.clearConnection()
            throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
        } catch {
            await self.clearConnection()
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure(cause: error)
            }
            throw error
        }
        guard await self.manager.isServerConnected(name: self.serverName) else {
            await self.clearConnection()
            if expectedConnectionReceipt != nil {
                throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
            }
            let error = BrowserMCPConnectionError.connectionLost("the persistent MCP child exited")
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure(cause: error)
            }
            throw error
        }
        guard self.connectionReceipt == receipt,
              self.providerSessionEpoch == providerSessionEpoch
        else {
            let error = BrowserMCPConnectionError.connectionLost(
                "the connection receipt changed while checking the persistent MCP child")
            if expectedConnectionReceipt != nil {
                throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
            }
            if connectionPolicy == .requireExistingLiveReceipt {
                throw Self.existingConnectionRequiredFailure(cause: error)
            }
            throw error
        }
        return BrowserMCPPreparedExecution(
            sessionBinding: .init(
                connectionReceipt: receipt,
                providerSessionEpoch: providerSessionEpoch),
            connectionOutcome: nil)
    }

    private static func partialSequenceFailure(
        completedCallCount: Int,
        cause: any Error) -> DesktopActionFailure
    {
        self.partialSequenceFailure(
            completedCallCount: completedCallCount,
            causeDescription: self.errorDescription(cause))
    }

    static func preDispatchFailure(_ cause: any Error) -> DesktopActionFailure {
        if let failure = cause as? DesktopActionFailure {
            return failure
        }
        let reason: DesktopActionOutcome.RefusalReason
        let message: String
        let hint: String
        switch cause {
        case is CancellationError:
            reason = .requestCancelled
            message = "Browser execution was cancelled before tool dispatch."
            hint = "Submit a new request only if the browser action is still wanted."
        case is BrowserMCPUploadStagingError:
            reason = .invalidRequest
            message = "Browser upload validation failed before tool dispatch."
            hint = "Correct the upload source and retry the browser call."
        default:
            reason = .targetUnavailable
            message = "Browser execution was refused before tool dispatch."
            hint = "Refresh browser status and retry against its exact connection receipt."
        }
        return .preDispatchRefusal(
            reason: reason,
            message: message,
            hint: hint,
            causeDescription: self.errorDescription(cause))
    }

    private static func existingConnectionRequiredFailure(cause: (any Error)? = nil) -> DesktopActionFailure {
        .preDispatchRefusal(
            reason: .targetUnavailable,
            message: "Browser execution requires an existing live exact connection receipt.",
            hint: "Connect the intended browser explicitly and retry.",
            causeDescription: cause.map(self.errorDescription))
    }

    private static func partialSequenceFailure(
        completedCallCount: Int,
        causeDescription: String) -> DesktopActionFailure
    {
        .partial(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            unitCount: self.dispatchUnitCount(completedCallCount),
            message: "Browser execution stopped after \(completedCallCount) completed tool call(s).",
            hint: "Do not retry the whole sequence; observe the browser and resume only the unfinished suffix.",
            causeDescription: causeDescription)
    }

    private static func indeterminateSequenceFailure(
        dispatchedCallCount: Int,
        completedCallCount: Int? = nil,
        cause: any Error) -> DesktopActionFailure
    {
        self.indeterminateSequenceFailure(
            dispatchedCallCount: dispatchedCallCount,
            completedCallCount: completedCallCount,
            causeDescription: self.errorDescription(cause))
    }

    private static func indeterminateSequenceFailure(
        dispatchedCallCount: Int,
        completedCallCount: Int? = nil,
        causeDescription: String) -> DesktopActionFailure
    {
        let progress = completedCallCount.map {
            "\($0) completed, \(dispatchedCallCount) dispatched or accepted"
        } ?? "\(dispatchedCallCount) dispatched or accepted"
        return .indeterminate(
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: self.dispatchUnitCount(dispatchedCallCount),
            message: "Browser execution stopped with \(progress) tool call(s).",
            hint: "Do not retry the whole sequence; observe the browser before resuming unfinished work.",
            causeDescription: causeDescription)
    }

    private static func dispatchUnitCount(_ count: Int) -> DesktopActionOutcome.DispatchUnitCount {
        guard let unitCount = DesktopActionOutcome.DispatchUnitCount(count) else {
            preconditionFailure("A browser sequence failure must account for at least one dispatched call")
        }
        return unitCount
    }

    private static func errorDescription(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if (error as? URLError)?.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    private func execute(_ call: BrowserMCPMappedCall) async throws -> ToolResponse {
        do {
            try Task.checkCancellation()
        } catch {
            throw BrowserMCPCallFailure.preDispatch(error)
        }
        guard call.toolName == "upload_file" else {
            do {
                return try await self.manager.executeTool(
                    serverName: self.serverName,
                    toolName: call.toolName,
                    arguments: call.arguments)
            } catch {
                throw BrowserMCPCallFailure.mayHaveDispatched(error)
            }
        }
        guard let sourcePath = call.arguments["filePath"] as? String, !sourcePath.isEmpty else {
            throw BrowserMCPCallFailure.preDispatch(
                BrowserMCPUploadStagingError.invalidPath(
                    "upload_file requires a non-empty filePath string"))
        }

        guard let uploadWorkspace = self.uploadWorkspace else {
            throw BrowserMCPCallFailure.preDispatch(
                BrowserMCPConnectionError.connectionLost("the browser upload workspace is unavailable"))
        }
        let stagedUpload: BrowserMCPStagedUpload
        do {
            stagedUpload = try await self.uploadStager.stage(path: sourcePath, in: uploadWorkspace)
            try Task.checkCancellation()
        } catch {
            throw BrowserMCPCallFailure.preDispatch(error)
        }
        var stagedArguments = call.arguments
        stagedArguments["filePath"] = stagedUpload.filePath
        let uploadID = UUID()
        self.activeUploadID = uploadID
        do {
            let response = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await self.manager.executeTool(
                    serverName: self.serverName,
                    toolName: call.toolName,
                    arguments: stagedArguments)
            } onCancel: { [weak self] in
                Task { @MainActor in
                    await self?.cancelUpload(id: uploadID)
                }
            }
            if self.activeUploadID == uploadID {
                self.activeUploadID = nil
            }
            uploadWorkspace.retain(stagedUpload)
            return Self.projectUploadResponse(
                response,
                stagedPath: stagedUpload.filePath,
                sourcePath: sourcePath)
        } catch {
            if self.activeUploadID == uploadID {
                self.activeUploadID = nil
            }
            uploadWorkspace.retain(stagedUpload)
            throw BrowserMCPCallFailure.mayHaveDispatched(Self.projectUploadError(
                error,
                stagedPath: stagedUpload.filePath,
                sourcePath: sourcePath))
        }
    }

    private static func projectUploadResponse(
        _ response: ToolResponse,
        stagedPath: String,
        sourcePath: String) -> ToolResponse
    {
        func project(_ text: String) -> String {
            text.replacingOccurrences(of: stagedPath, with: sourcePath)
        }
        func project(_ value: Value) -> Value {
            switch value {
            case let .object(fields):
                .object(fields.mapValues(project))
            case let .array(values):
                .array(values.map(project))
            case let .string(string):
                .string(project(string))
            case .int, .double, .bool, .null, .data:
                value
            }
        }
        return ToolResponse(
            content: response.content.map {
                BrowserToolCapabilityProjection.projectingContentItem($0, transform: project)
            },
            isError: response.isError,
            meta: response.meta.map(project),
            structuredContent: response.structuredContent.map(project))
    }

    private static func projectUploadError(
        _ error: any Error,
        stagedPath: String,
        sourcePath: String) -> any Error
    {
        let original = self.errorDescription(error)
        let projected = original.replacingOccurrences(of: stagedPath, with: sourcePath)
        guard projected != original else { return error }
        return BrowserMCPProjectedProviderError(message: projected)
    }

    private func cancelUpload(id: UUID) async {
        guard self.activeUploadID == id else { return }
        self.activeUploadID = nil
        await self.clearConnection()
    }

    private func resolveTarget(
        channel: BrowserMCPChannel?,
        browserURL: String?,
        attempt: BrowserMCPConnectionAttempt,
        reserveTarget: TargetReservation? = nil) async throws
        -> BrowserMCPResolvedTarget
    {
        if let browserURL = browserURL ?? self.environmentOptions.browserURL {
            return try await self.resolveExactEndpointTarget(
                browserURL: browserURL,
                channel: channel,
                reserveTarget: reserveTarget)
        }

        let resolvedChannel = channel ?? BrowserMCPService.preferredChannel()
        if self.isolatedConnectionRequested() {
            let receipt = BrowserMCPConnectionReceipt(channel: resolvedChannel)
            try reserveTarget?(receipt)
            return BrowserMCPResolvedTarget(
                receipt: receipt,
                config: BrowserMCPService.isolatedChromeDevToolsConfig(
                    channel: resolvedChannel,
                    headless: self.environmentOptions.headless),
                // The spawned process has no child-reported identity to bind into a signed receipt.
                supportsReceiptBoundExecution: false,
                channelEndpoint: nil,
                codeSignatureIdentity: nil,
                targetKind: .isolated)
        }
        let candidates = self.detectedBrowsers(resolvedChannel)
        guard !candidates.isEmpty else {
            throw BrowserMCPConnectionError.noBrowser(resolvedChannel)
        }
        guard candidates.count == 1, let browser = candidates.first else {
            throw BrowserMCPConnectionError.ambiguousBrowsers(
                resolvedChannel,
                candidates.map(\.processIdentifier))
        }
        guard let channelIdentity = ChromeChannelIdentity(rawValue: resolvedChannel.rawValue),
              channelIdentity.matches(bundleIdentifier: browser.bundleIdentifier),
              BrowserMCPChannel.infer(
                  bundleIdentifier: browser.bundleIdentifier,
                  applicationName: browser.name) == resolvedChannel,
              channelIdentity.matches(bundleIdentifier: self.processBundleIdentifier(browser.processIdentifier))
        else {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                resolvedChannel,
                "the detected and live process bundles do not exactly match the requested Chrome channel")
        }
        guard let processStartIdentity = browser.processStartIdentity,
              self.processStartIdentity(browser.processIdentifier) == processStartIdentity
        else {
            throw BrowserMCPConnectionError.processIdentityUnavailable(browser.processIdentifier)
        }
        guard let codeSignatureIdentity = self.processCodeSignatureValidator(
            browser.processIdentifier,
            processStartIdentity,
            channelIdentity)
        else {
            throw BrowserMCPConnectionError.channelEndpointUnavailable(
                resolvedChannel,
                "the native Chrome process does not have the official Google signing identity")
        }
        let processTarget = BrowserMCPChannelProcessTarget(
            channel: resolvedChannel,
            processIdentifier: browser.processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: channelIdentity.bundleIdentifier)
        try reserveTarget?(BrowserMCPConnectionReceipt(
            channel: resolvedChannel,
            processIdentifier: browser.processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: channelIdentity.bundleIdentifier))
        let endpoint = try await self.channelEndpointResolver.resolve(
            processTarget,
            attempt: attempt,
            reserveAuthority: { reservation in
                try reserveTarget?(BrowserMCPConnectionReceipt(
                    channel: resolvedChannel,
                    processIdentifier: browser.processIdentifier,
                    processStartIdentity: processStartIdentity,
                    bundleIdentifier: channelIdentity.bundleIdentifier,
                    browserURL: reservation.browserURL,
                    webSocketDebuggerURL: reservation.webSocketDebuggerURL,
                    devToolsBrowserID: reservation.browserID))
            })
        guard channelIdentity.matches(bundleIdentifier: self.processBundleIdentifier(browser.processIdentifier)),
              self.processCodeSignatureValidator(
                  browser.processIdentifier,
                  processStartIdentity,
                  channelIdentity) == codeSignatureIdentity
        else {
            throw BrowserMCPConnectionError.permissionBearingConnectionFailed(
                "the live Chrome bundle or signing identity changed during Browser.getVersion")
        }
        let receipt = BrowserMCPConnectionReceipt(
            channel: resolvedChannel,
            processIdentifier: browser.processIdentifier,
            processStartIdentity: processStartIdentity,
            bundleIdentifier: channelIdentity.bundleIdentifier,
            browserURL: endpoint.browserURL,
            webSocketDebuggerURL: endpoint.webSocketDebuggerURL,
            devToolsBrowserID: endpoint.browserID,
            browserVersion: endpoint.browserVersion,
            protocolVersion: endpoint.protocolVersion)
        return BrowserMCPResolvedTarget(
            receipt: receipt,
            config: BrowserMCPService.chromeDevToolsConfig(
                webSocketEndpoint: endpoint.webSocketDebuggerURL),
            supportsReceiptBoundExecution: true,
            channelEndpoint: endpoint,
            codeSignatureIdentity: codeSignatureIdentity,
            targetKind: .nativeChannel)
    }

    private func resolveExactEndpointTarget(
        browserURL: String,
        channel: BrowserMCPChannel?,
        reserveTarget: TargetReservation? = nil) async throws -> BrowserMCPResolvedTarget
    {
        guard let requestedEndpoint = BrowserLoopbackEndpoint(browserURL: browserURL) else {
            throw BrowserMCPConnectionError.invalidEndpoint(
                "browser_url must be an exact loopback HTTP origin with an explicit port")
        }
        try reserveTarget?(BrowserMCPConnectionReceipt(
            channel: channel,
            browserURL: requestedEndpoint.canonicalBrowserURL))
        let endpoint = try await self.endpointResolver.resolve(requestedEndpoint.canonicalBrowserURL)
        let receipt = BrowserMCPConnectionReceipt(
            channel: channel,
            browserURL: endpoint.browserURL,
            webSocketDebuggerURL: endpoint.webSocketDebuggerURL,
            devToolsBrowserID: endpoint.browserID,
            browserVersion: endpoint.browserVersion,
            protocolVersion: endpoint.protocolVersion)
        try reserveTarget?(receipt)
        return BrowserMCPResolvedTarget(
            receipt: receipt,
            config: BrowserMCPService.chromeDevToolsConfig(
                webSocketEndpoint: endpoint.webSocketDebuggerURL),
            supportsReceiptBoundExecution: true,
            channelEndpoint: nil,
            codeSignatureIdentity: nil,
            targetKind: .external)
    }

    private func validate(
        _ receipt: BrowserMCPConnectionReceipt,
        channelEndpoint suppliedChannelEndpoint: BrowserMCPDevToolsEndpoint? = nil,
        codeSignatureIdentity suppliedCodeSignatureIdentity: ChromeProcessCodeSignatureValidator.Identity? = nil,
        requireDetectedProcess: Bool = true)
        async throws
    {
        if receipt.processIdentifier != nil || receipt.processStartIdentity != nil || receipt.bundleIdentifier != nil {
            guard let channel = receipt.channel,
                  let channelIdentity = ChromeChannelIdentity(rawValue: channel.rawValue),
                  let processIdentifier = receipt.processIdentifier,
                  let processStartIdentity = receipt.processStartIdentity,
                  let bundleIdentifier = receipt.bundleIdentifier,
                  bundleIdentifier == channelIdentity.bundleIdentifier,
                  let browserURL = receipt.browserURL,
                  let webSocketDebuggerURL = receipt.webSocketDebuggerURL,
                  let browserID = receipt.devToolsBrowserID,
                  let browserVersion = receipt.browserVersion,
                  let protocolVersion = receipt.protocolVersion,
                  let channelEndpoint = suppliedChannelEndpoint ?? self.connectionChannelEndpoint,
                  let codeSignatureIdentity = suppliedCodeSignatureIdentity ?? self.connectionCodeSignatureIdentity,
                  channelEndpoint.browserURL == browserURL,
                  channelEndpoint.webSocketDebuggerURL == webSocketDebuggerURL,
                  channelEndpoint.browserID == browserID,
                  channelEndpoint.browserVersion == browserVersion,
                  channelEndpoint.protocolVersion == protocolVersion
            else {
                throw BrowserMCPConnectionError.connectionLost(
                    "the process-bound browser receipt is incomplete or has a noncanonical channel bundle")
            }
            guard self.processStartIdentity(processIdentifier) == processStartIdentity else {
                throw BrowserMCPConnectionError.connectionLost(
                    "Chrome PID \(processIdentifier) changed process generation")
            }
            guard channelIdentity.matches(bundleIdentifier: self.processBundleIdentifier(processIdentifier)),
                  self.processCodeSignatureValidator(
                      processIdentifier,
                      processStartIdentity,
                      channelIdentity) == codeSignatureIdentity
            else {
                throw BrowserMCPConnectionError.connectionLost(
                    "Chrome PID \(processIdentifier) changed bundle, channel, or signing identity")
            }
            if requireDetectedProcess,
               !self.detectedBrowsers(channel).contains(where: { browser in
                   browser.processIdentifier == processIdentifier &&
                       browser.processStartIdentity == processStartIdentity &&
                       channelIdentity.matches(bundleIdentifier: browser.bundleIdentifier)
               })
            {
                throw BrowserMCPConnectionError.connectionLost(
                    "Chrome PID \(processIdentifier) changed bundle, channel, or signing identity")
            }
            try await self.channelEndpointResolver.revalidate(
                BrowserMCPChannelProcessTarget(
                    channel: channel,
                    processIdentifier: processIdentifier,
                    processStartIdentity: processStartIdentity,
                    bundleIdentifier: bundleIdentifier),
                expected: channelEndpoint)
            guard self.processCodeSignatureValidator(
                processIdentifier,
                processStartIdentity,
                channelIdentity) == codeSignatureIdentity
            else {
                throw BrowserMCPConnectionError.connectionLost(
                    "Chrome PID \(processIdentifier) changed signing identity during listener validation")
            }
            return
        }
        if let channel = receipt.channel,
           ChromeChannelIdentity(rawValue: channel.rawValue) == nil
        {
            throw BrowserMCPConnectionError.connectionLost("the external browser receipt has an unknown channel")
        }
        if let browserURL = receipt.browserURL {
            let endpoint = try await self.endpointResolver.resolve(browserURL)
            guard endpoint.browserURL == browserURL,
                  endpoint.webSocketDebuggerURL == receipt.webSocketDebuggerURL,
                  endpoint.browserID == receipt.devToolsBrowserID,
                  endpoint.browserVersion == receipt.browserVersion,
                  endpoint.protocolVersion == receipt.protocolVersion
            else {
                throw BrowserMCPConnectionError.connectionLost("the DevTools browser endpoint changed identity")
            }
        }
    }

    private func authorizedHandoffTarget(
        receipt: BrowserMCPConnectionReceipt) async throws
        -> BrowserMCPAuthorizedHandoffTarget
    {
        guard !self.connectionCleanupPending else {
            throw BrowserMCPConnectionError.targetLocked
        }
        guard self.connectionReceipt == receipt else {
            throw BrowserMCPConnectionError.expectedConnectionReceiptMismatch
        }
        guard self.providerSessionEpoch != nil else {
            throw BrowserMCPConnectionError.connectionLost("the source MCP child has no live provider epoch")
        }
        let target = try self.storedHandoffTarget(receipt: receipt)
        try await self.validate(
            target.receipt,
            channelEndpoint: target.channelEndpoint,
            codeSignatureIdentity: target.codeSignatureIdentity,
            requireDetectedProcess: false)
        return target
    }

    private func storedHandoffTarget(receipt: BrowserMCPConnectionReceipt) throws
        -> BrowserMCPAuthorizedHandoffTarget
    {
        guard self.connectionSupportsReceiptBoundExecution,
              let targetKind = self.connectionTargetKind,
              targetKind != .isolated,
              receipt.browserURL != nil,
              receipt.webSocketDebuggerURL != nil
        else {
            throw BrowserMCPConnectionError.receiptBindingUnsupported
        }
        return BrowserMCPAuthorizedHandoffTarget(
            receipt: receipt,
            channelEndpoint: self.connectionChannelEndpoint,
            codeSignatureIdentity: self.connectionCodeSignatureIdentity,
            targetKind: targetKind)
    }

    private func connectionReceipt(
        _ receipt: BrowserMCPConnectionReceipt,
        matchesChannel channel: BrowserMCPChannel?,
        browserURL: String?) -> Bool
    {
        let requestedBrowserURL = browserURL ?? self.environmentOptions.browserURL
        let requestedKind: BrowserMCPConnectionTargetKind = if requestedBrowserURL != nil {
            .external
        } else if self.isolatedConnectionRequested() {
            .isolated
        } else {
            .nativeChannel
        }
        guard requestedKind == self.connectionTargetKind else { return false }

        if let requestedBrowserURL {
            guard receipt.processIdentifier == nil,
                  receipt.processStartIdentity == nil,
                  receipt.bundleIdentifier == nil,
                  let requested = BrowserLoopbackEndpoint(browserURL: requestedBrowserURL),
                  let actualURL = receipt.browserURL,
                  let actual = BrowserLoopbackEndpoint(browserURL: actualURL),
                  receipt.webSocketDebuggerURL != nil,
                  receipt.devToolsBrowserID != nil,
                  receipt.browserVersion != nil,
                  receipt.protocolVersion != nil,
                  requested == actual
            else { return false }
            return channel.map { $0 == receipt.channel } ?? true
        }
        let requestedChannel = channel ?? receipt.channel ?? self.preferredChannel()
        guard receipt.channel == requestedChannel else { return false }
        if requestedKind == .isolated {
            return receipt.processIdentifier == nil &&
                receipt.processStartIdentity == nil &&
                receipt.bundleIdentifier == nil &&
                receipt.browserURL == nil &&
                receipt.webSocketDebuggerURL == nil &&
                receipt.devToolsBrowserID == nil &&
                receipt.browserVersion == nil &&
                receipt.protocolVersion == nil
        }
        guard
            let channelIdentity = ChromeChannelIdentity(rawValue: requestedChannel.rawValue),
            receipt.processIdentifier != nil,
            receipt.processStartIdentity != nil,
            receipt.bundleIdentifier == channelIdentity.bundleIdentifier,
            receipt.browserURL != nil,
            receipt.webSocketDebuggerURL != nil,
            receipt.devToolsBrowserID != nil,
            receipt.browserVersion != nil,
            receipt.protocolVersion != nil
        else { return false }
        return true
    }

    @discardableResult
    private func clearConnection() async -> Bool {
        self.activeUploadID = nil
        let cleanupConfirmed = await self.removeProviderForHandoff()
        if cleanupConfirmed {
            self.discardConnectionState()
        } else {
            self.connectionCleanupPending = true
        }
        return cleanupConfirmed
    }

    private func removeProviderForHandoff() async -> Bool {
        var providerPresent = self.manager.hasServer(name: self.serverName)
        if !providerPresent {
            providerPresent = await self.manager.isServerConnected(name: self.serverName)
        }
        if providerPresent {
            await self.manager.removeServer(name: self.serverName)
        }
        guard !self.manager.hasServer(name: self.serverName) else { return false }
        return await !(self.manager.isServerConnected(name: self.serverName))
    }

    private func handoffDestinationFailure(_ error: any Error) async -> BrowserMCPHandoffDestinationError {
        let cleanup = Task { @MainActor in
            let confirmed = await self.removeProviderForHandoff()
            if confirmed {
                self.discardConnectionState()
            }
            return confirmed
        }
        let cleanupConfirmed = await cleanup.value
        return BrowserMCPHandoffDestinationError(
            cause: error,
            cleanupConfirmed: cleanupConfirmed)
    }

    private func installProvider(
        target: BrowserMCPResolvedTarget,
        onProviderDispatch: @MainActor () -> Void) async throws
    {
        let uploadWorkspace = try await self.uploadStager.createWorkspace()
        var config = target.config
        config.env["TMPDIR"] = uploadWorkspace.rootPath
        self.uploadWorkspace = uploadWorkspace
        // Native channel setup has one owner-controlled identity probe, then this separately
        // owned MCP child opens the session's execution WebSocket. Later validation never probes.
        onProviderDispatch()
        try await self.manager.addServer(name: self.serverName, config: config)
        try Task.checkCancellation()
        let probe = try await self.manager.executeTool(
            serverName: self.serverName,
            toolName: "list_pages",
            arguments: [:])
        try Task.checkCancellation()
        guard !probe.isError else {
            throw BrowserMCPConnectionError.connectionProbeFailed(
                "Chrome DevTools MCP rejected list_pages")
        }
        try await self.validate(
            target.receipt,
            channelEndpoint: target.channelEndpoint,
            codeSignatureIdentity: target.codeSignatureIdentity,
            requireDetectedProcess: false)
        try Task.checkCancellation()
        self.connectionReceipt = target.receipt
        self.providerSessionEpoch = BrowserMCPProviderSessionEpoch()
        self.connectionSupportsReceiptBoundExecution = target.supportsReceiptBoundExecution
        self.connectionChannelEndpoint = target.channelEndpoint
        self.connectionCodeSignatureIdentity = target.codeSignatureIdentity
        self.connectionTargetKind = target.targetKind
    }

    private func discardConnectionState() {
        self.connectionCleanupPending = false
        self.connectionReceipt = nil
        self.providerSessionEpoch = nil
        self.connectionSupportsReceiptBoundExecution = false
        self.connectionChannelEndpoint = nil
        self.connectionCodeSignatureIdentity = nil
        self.connectionTargetKind = nil
        self.activeUploadID = nil
        let uploadWorkspace = self.uploadWorkspace
        self.uploadWorkspace = nil
        uploadWorkspace?.cleanup()
    }

    private func withExecutionGate<Result>(
        _ operation: @MainActor () async throws -> Result) async throws -> Result
    {
        guard !self.sessionEnded else { throw BrowserMCPConnectionError.sessionEnded }
        try await self.executionGate.acquire()
        guard !self.sessionEnded else {
            await self.executionGate.release()
            throw BrowserMCPConnectionError.sessionEnded
        }
        do {
            let result = try await operation()
            await self.executionGate.release()
            return result
        } catch {
            await self.executionGate.release()
            throw error
        }
    }
}
