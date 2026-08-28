import Foundation
import MCP
import PeekabooAgentRuntime
import PeekabooBridge
import PeekabooFoundation
import TachikomaMCP

public final class RemoteBrowserMCPClient: BrowserMCPClientProviding, BrowserMCPActionResultProviding,
    BrowserMCPAtomicSessionActionProviding, BrowserMCPConnectionResultProviding,
    BrowserMCPConnectionHandoffProviding, BrowserMCPDisconnectResultProviding, BrowserMCPScopedSessionOpening,
    BrowserMCPScopedSessionEnding, @unchecked Sendable
{
    private enum ScopedSessionState: Equatable {
        case active
        case cleanupDebt
        case terminal
        case ended
    }

    private enum ScopedSessionOpenPhase: Equatable {
        case inFlight
        case retryable
        case terminal
    }

    private enum InvalidScopedSessionOpenResolution {
        case resolved
        case retryable
        case terminal
    }

    private struct ScopedSessionOpenAttempt {
        let claimID: UUID
        let handoffPayload: Data?
        var phase: ScopedSessionOpenPhase
        var operationMayHaveCompleted: Bool
    }

    private struct ScopedSessionOpenFailureDisposition {
        let operationMayHaveCompleted: Bool
        let shouldRetryAutomatically: Bool
    }

    private let client: PeekabooBridgeClient
    private let sessionTransport: (any RemoteBrowserMCPSessionTransport)?
    private let sessionHandle: RemoteBrowserMCPSessionHandle?
    @MainActor private var connectionHandoffReceiptBundleData: Data?
    @MainActor private var lastScopedStatus: BrowserMCPStatus?
    @MainActor private var pendingScopedSessionOpenAttempt: ScopedSessionOpenAttempt?
    @MainActor private var scopedSessionState = ScopedSessionState.active
    @MainActor private var scopedSessionEndTask: (id: UUID, task: Task<Bool, Never>)?
    @MainActor private var scopedSessionEndRequestGeneration: UInt64 = 0

    var hasScopedSessionTransport: Bool {
        self.sessionTransport != nil
    }

    @MainActor
    public var browserMCPScopedSessionOpenAttemptRequiresRecovery: Bool {
        self.pendingScopedSessionOpenAttempt != nil
    }

    public init(
        client: PeekabooBridgeClient,
        sessionTransport: (any RemoteBrowserMCPSessionTransport)? = nil)
    {
        self.client = client
        self.sessionTransport = sessionTransport
        self.sessionHandle = nil
    }

    private init(
        client: PeekabooBridgeClient,
        sessionTransport: any RemoteBrowserMCPSessionTransport,
        sessionHandle: RemoteBrowserMCPSessionHandle)
    {
        self.client = client
        self.sessionTransport = sessionTransport
        self.sessionHandle = sessionHandle
    }

    @MainActor
    public func openBrowserMCPScopedSession(
        handoff: BrowserMCPHandoffGrant?) async throws -> any BrowserMCPScopedSessionEnding
    {
        guard self.sessionHandle == nil,
              let sessionTransport = self.sessionTransport
        else {
            throw RemoteBrowserMCPSessionError.unavailable
        }
        let attempt = try self.beginScopedSessionOpenAttempt(handoff: handoff)
        let handle: RemoteBrowserMCPSessionHandle
        var automaticRetryRemaining = true
        while true {
            do {
                handle = try await sessionTransport.openSession(
                    handoff: handoff,
                    claimID: attempt.claimID)
                break
            } catch let error as RemoteBrowserMCPSessionTransportError {
                self.finishScopedSessionOpenAttempt(attempt, retryable: false)
                throw error
            } catch let error as RemoteBrowserMCPSessionError {
                self.finishScopedSessionOpenAttempt(
                    attempt,
                    retryable: self.scopedSessionOpenAttemptMayHaveCompleted(attempt))
                throw error
            } catch {
                let disposition = Self.scopedSessionOpenFailureDisposition(for: error)
                let remainsUnresolved = self.recordScopedSessionOpenFailure(
                    attempt,
                    operationMayHaveCompleted: disposition.operationMayHaveCompleted)
                if automaticRetryRemaining,
                   !Task.isCancelled,
                   disposition.shouldRetryAutomatically
                {
                    automaticRetryRemaining = false
                    continue
                }
                self.finishScopedSessionOpenAttempt(attempt, retryable: remainsUnresolved)
                throw error
            }
        }
        guard handle.isCanonical,
              (handoff == nil) == (handle.targetReceiptSHA256 == nil)
        else {
            _ = self.recordScopedSessionOpenFailure(attempt, operationMayHaveCompleted: true)
            let cleanupResolution = await Self.resolveInvalidScopedSessionOpen(
                handle: handle,
                transport: sessionTransport)
            switch cleanupResolution {
            case .resolved:
                self.finishScopedSessionOpenAttempt(attempt, retryable: false)
            case .retryable:
                self.finishScopedSessionOpenAttempt(attempt, retryable: true)
            case .terminal:
                self.markScopedSessionOpenAttemptTerminal(attempt)
            }
            throw RemoteBrowserMCPSessionError.invalidHandle
        }
        self.finishScopedSessionOpenAttempt(attempt, retryable: false)
        return RemoteBrowserMCPClient(
            client: self.client,
            sessionTransport: sessionTransport,
            sessionHandle: handle)
    }

    @MainActor
    public func status(channel: BrowserMCPChannel?) async -> BrowserMCPStatus {
        if let sessionHandle, let sessionTransport {
            guard self.scopedSessionState == .active else {
                return Self.endedStatus()
            }
            do {
                let status = try await sessionTransport.status(
                    session: sessionHandle,
                    channel: channel)
                try Self.validateScopedStatus(status)
                self.lastScopedStatus = status
                return status
            } catch let error as RemoteBrowserMCPSessionTransportError {
                return self.confirmedTerminalStatus(error: error)
            } catch let error as RemoteBrowserMCPSessionError {
                return await self.confirmedMalformedStatus(
                    error: error,
                    session: sessionHandle,
                    transport: sessionTransport)
            } catch {
                return self.indeterminateStatus(error: error)
            }
        }
        do {
            return try await Self.status(from: self.client.browserStatus(channel: channel?.rawValue))
        } catch {
            return BrowserMCPStatus(
                isConnected: false,
                toolCount: 0,
                detectedBrowsers: [],
                error: error.localizedDescription)
        }
    }

    @MainActor
    public func connect(channel: BrowserMCPChannel?) async throws -> BrowserMCPStatus {
        try await self.connect(channel: channel, browserURL: nil)
    }

    @MainActor
    public func connect(channel: BrowserMCPChannel?, browserURL: String?) async throws -> BrowserMCPStatus {
        try await self.connectWithOutcome(channel: channel, browserURL: browserURL).payload
    }

    @MainActor
    public func connectWithOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        if let sessionHandle, let sessionTransport {
            guard self.scopedSessionState == .active else { throw RemoteBrowserMCPSessionError.ended }
            do {
                let result = try await sessionTransport.connectWithOutcome(
                    session: sessionHandle,
                    channel: channel,
                    browserURL: browserURL)
                try Self.validateScopedStatus(result.payload)
                self.lastScopedStatus = result.payload
                return result
            } catch let error as RemoteBrowserMCPSessionTransportError {
                self.markScopedSessionTerminal()
                throw Self.terminalSessionFailure(error)
            } catch let error as RemoteBrowserMCPSessionError {
                await self.endMalformedScope(
                    session: sessionHandle,
                    transport: sessionTransport)
                throw Self.terminalSessionFailure(error)
            }
        }
        do {
            let result = try await self.client.browserConnectResult(
                channel: channel?.rawValue,
                browserURL: browserURL)
            return try DesktopActionResult(
                payload: Self.status(from: result.payload),
                outcome: result.outcome)
        } catch let failure as DesktopActionFailure where Self.isBrowserTargetLockedFailure(failure) {
            throw BrowserMCPConnectionError.targetLocked
        }
    }

    @MainActor
    public func connectWithHandoffOutcome(
        channel: BrowserMCPChannel?,
        browserURL: String?) async throws -> DesktopActionResult<BrowserMCPStatus>
    {
        self.connectionHandoffReceiptBundleData = nil
        do {
            let handoff = try await self.client.browserConnectHandoffResult(
                channel: channel?.rawValue,
                browserURL: browserURL)
            let encoder = JSONEncoder.peekabooBridgeEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let canonicalBundle = try encoder.encode(handoff.receiptBundle)
            try handoff.receiptBundle.validate()
            self.connectionHandoffReceiptBundleData = canonicalBundle
            return try DesktopActionResult(
                payload: Self.status(from: handoff.result.payload),
                outcome: handoff.result.outcome)
        } catch let failure as DesktopActionFailure where Self.isBrowserTargetLockedFailure(failure) {
            throw BrowserMCPConnectionError.targetLocked
        }
    }

    @MainActor
    public func takeConnectionHandoffReceiptBundleData() -> Data? {
        defer { self.connectionHandoffReceiptBundleData = nil }
        return self.connectionHandoffReceiptBundleData
    }

    @MainActor
    public func endBrowserMCPScopedSession() async -> Bool {
        guard let sessionHandle, let sessionTransport else { return true }
        return await self.finishScopedSessionEnd(
            session: sessionHandle,
            transport: sessionTransport)
    }

    @MainActor
    public func execute(
        toolName: String,
        arguments: [String: Any],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        if self.sessionHandle != nil {
            throw Self.scopedAtomicExecutionRequired()
        }
        let request = try PeekabooBridgeBrowserExecuteRequest(
            toolName: toolName,
            arguments: arguments.mapValues { try PeekabooBridgeJSONValue.fromAny($0) },
            channel: channel?.rawValue)
        let response = try await self.client.browserExecute(request)
        return try Self.toolResponse(from: response)
    }

    @MainActor
    public func executeSequence(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> ToolResponse
    {
        if self.sessionHandle != nil {
            return try await self.executeSequenceWithOutcome(
                calls,
                channel: channel,
                connectionPolicy: .requireExistingLiveReceipt).payload
        }
        let bridgeCalls = try calls.map { call in
            try PeekabooBridgeBrowserToolCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { try PeekabooBridgeJSONValue.fromAny($0) })
        }
        let response = try await self.client.browserExecute(PeekabooBridgeBrowserExecuteRequest(
            calls: bridgeCalls,
            channel: channel?.rawValue))
        return try Self.toolResponse(from: response)
    }

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?) async throws -> DesktopActionResult<ToolResponse>
    {
        try await self.executeSequenceWithOutcome(
            calls,
            channel: channel,
            connectionPolicy: .allowAutoConnect)
    }

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        connectionPolicy: BrowserMCPExecutionConnectionPolicy) async throws -> DesktopActionResult<ToolResponse>
    {
        if self.sessionHandle != nil {
            let status = await self.status(channel: channel)
            guard status.connectionReceipt != nil,
                  status.providerSessionEpoch != nil,
                  let binding = Self.sessionBinding(from: status)
            else {
                throw Self.existingScopedConnectionRequired()
            }
            return try await self.executeSequenceWithOutcome(
                calls,
                channel: channel,
                expectedSessionBinding: binding,
                elementPreflight: nil)
        }
        let bridgeCalls = try calls.map { call in
            try PeekabooBridgeBrowserToolCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { try PeekabooBridgeJSONValue.fromAny($0) })
        }
        let expectedReceipt: PeekabooBridgeBrowserConnectionReceipt?
        let bridgeConnectionPolicy: PeekabooBridgeBrowserExecutionConnectionPolicy?
        switch connectionPolicy {
        case .allowAutoConnect:
            expectedReceipt = nil
            bridgeConnectionPolicy = nil
        case .requireExistingLiveReceipt:
            let status = await self.status(channel: channel)
            guard status.isConnected, let receipt = status.connectionReceipt else {
                throw DesktopActionFailure.preDispatchRefusal(
                    route: .bridge,
                    reason: .targetUnavailable,
                    message: "Browser execution requires an existing live exact connection receipt.",
                    hint: "Connect the intended browser explicitly and retry.")
            }
            expectedReceipt = Self.bridgeReceipt(from: receipt)
            bridgeConnectionPolicy = .requireExistingLiveReceipt
        }
        let result = try await self.client.browserExecuteResult(PeekabooBridgeBrowserExecuteRequest(
            calls: bridgeCalls,
            channel: channel?.rawValue,
            expectedConnectionReceipt: expectedReceipt,
            connectionPolicy: bridgeConnectionPolicy))
        if result.outcome == nil, let failure = result.payload.actionFailure {
            throw failure
        }
        let response = try Self.toolResponse(from: result.payload)
        return DesktopActionResult(payload: response, outcome: result.outcome)
    }

    @MainActor
    public func executeSequenceWithOutcome(
        _ calls: [BrowserMCPMappedCall],
        channel: BrowserMCPChannel?,
        expectedSessionBinding: BrowserMCPExecutionSessionBinding,
        elementPreflight: BrowserMCPElementPreflight?) async throws -> DesktopActionResult<ToolResponse>
    {
        guard let sessionHandle, let sessionTransport else {
            throw Self.scopedAtomicExecutionRequired()
        }
        guard self.scopedSessionState == .active else { throw RemoteBrowserMCPSessionError.ended }
        guard let status = self.lastScopedStatus,
              status.connectionReceipt == expectedSessionBinding.connectionReceipt,
              status.providerSessionEpoch == expectedSessionBinding.providerSessionEpoch
        else {
            throw DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "The exact remote browser provider session changed before tool dispatch.",
                hint: "Refresh browser status and obtain fresh page and element references.")
        }
        do {
            return try await sessionTransport.executeSequenceWithOutcome(
                session: sessionHandle,
                calls: calls,
                channel: channel,
                expectedSessionBinding: expectedSessionBinding,
                elementPreflight: elementPreflight)
        } catch let error as RemoteBrowserMCPSessionTransportError {
            self.markScopedSessionTerminal()
            throw Self.terminalSessionFailure(error)
        }
    }

    @MainActor
    private func indeterminateStatus(error: any Error) -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: self.lastScopedStatus?.detectedBrowsers ?? [],
            connectionReceipt: self.lastScopedStatus?.connectionReceipt,
            providerSessionEpoch: self.lastScopedStatus?.providerSessionEpoch,
            error: error.localizedDescription,
            observation: .indeterminate)
    }

    @MainActor
    private func confirmedTerminalStatus(error: any Error) -> BrowserMCPStatus {
        let detectedBrowsers = self.lastScopedStatus?.detectedBrowsers ?? []
        self.markScopedSessionTerminal()
        return BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: detectedBrowsers,
            error: error.localizedDescription,
            observation: .confirmed)
    }

    @MainActor
    private func confirmedMalformedStatus(
        error: any Error,
        session: RemoteBrowserMCPSessionHandle,
        transport: any RemoteBrowserMCPSessionTransport) async -> BrowserMCPStatus
    {
        let detectedBrowsers = self.lastScopedStatus?.detectedBrowsers ?? []
        await self.endMalformedScope(session: session, transport: transport)
        return BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: detectedBrowsers,
            error: error.localizedDescription,
            observation: .confirmed)
    }

    @MainActor
    private func endMalformedScope(
        session: RemoteBrowserMCPSessionHandle,
        transport: any RemoteBrowserMCPSessionTransport) async
    {
        _ = await self.finishScopedSessionEnd(session: session, transport: transport)
    }

    @MainActor
    private func finishScopedSessionEnd(
        session: RemoteBrowserMCPSessionHandle,
        transport: any RemoteBrowserMCPSessionTransport) async -> Bool
    {
        switch self.scopedSessionState {
        case .active, .cleanupDebt:
            break
        case .terminal, .ended:
            return true
        }
        self.scopedSessionEndRequestGeneration &+= 1
        if let pending = self.scopedSessionEndTask {
            return await pending.task.value
        }
        let requestGeneration = self.scopedSessionEndRequestGeneration
        let endID = UUID()
        let task = Task { @MainActor in
            let cleanupConfirmed = await self.performScopedSessionEnd(
                session: session,
                transport: transport,
                requestGeneration: requestGeneration)
            if self.scopedSessionEndTask?.id == endID {
                self.scopedSessionEndTask = nil
            }
            return cleanupConfirmed
        }
        self.scopedSessionEndTask = (endID, task)
        return await task.value
    }

    @MainActor
    private func performScopedSessionEnd(
        session: RemoteBrowserMCPSessionHandle,
        transport: any RemoteBrowserMCPSessionTransport,
        requestGeneration: UInt64) async -> Bool
    {
        self.lastScopedStatus = nil
        var handledRequestGeneration = requestGeneration
        repeat {
            self.scopedSessionState = .cleanupDebt
            do {
                try await transport.endSession(session)
                self.scopedSessionState = .ended
            } catch let terminal as RemoteBrowserMCPSessionTransportError {
                switch terminal {
                case .invalidSession, .sessionEnded:
                    self.scopedSessionState = .ended
                case .wrongOwner, .hostGenerationChanged:
                    self.scopedSessionState = .terminal
                }
            } catch {
                self.scopedSessionState = .cleanupDebt
            }
            guard self.scopedSessionState == .cleanupDebt,
                  self.scopedSessionEndRequestGeneration != handledRequestGeneration
            else { break }
            handledRequestGeneration = self.scopedSessionEndRequestGeneration
        } while true
        return self.scopedSessionState != .cleanupDebt
    }

    @MainActor
    private func beginScopedSessionOpenAttempt(
        handoff: BrowserMCPHandoffGrant?) throws -> ScopedSessionOpenAttempt
    {
        let payload = handoff?.payload
        if var pending = self.pendingScopedSessionOpenAttempt {
            guard pending.handoffPayload == payload else {
                throw RemoteBrowserMCPSessionError.openAttemptUnresolved
            }
            switch pending.phase {
            case .retryable:
                pending.phase = .inFlight
                self.pendingScopedSessionOpenAttempt = pending
                return pending
            case .inFlight:
                throw RemoteBrowserMCPSessionError.openInProgress
            case .terminal:
                throw RemoteBrowserMCPSessionError.openAttemptUnresolved
            }
        }
        let attempt = ScopedSessionOpenAttempt(
            claimID: UUID(),
            handoffPayload: payload,
            phase: .inFlight,
            operationMayHaveCompleted: false)
        self.pendingScopedSessionOpenAttempt = attempt
        return attempt
    }

    @MainActor
    private func recordScopedSessionOpenFailure(
        _ attempt: ScopedSessionOpenAttempt,
        operationMayHaveCompleted: Bool) -> Bool
    {
        guard var pending = self.pendingScopedSessionOpenAttempt,
              pending.claimID == attempt.claimID
        else {
            return operationMayHaveCompleted
        }
        pending.operationMayHaveCompleted = pending.operationMayHaveCompleted || operationMayHaveCompleted
        self.pendingScopedSessionOpenAttempt = pending
        return pending.operationMayHaveCompleted
    }

    @MainActor
    private func scopedSessionOpenAttemptMayHaveCompleted(_ attempt: ScopedSessionOpenAttempt) -> Bool {
        guard let pending = self.pendingScopedSessionOpenAttempt,
              pending.claimID == attempt.claimID
        else {
            return false
        }
        return pending.operationMayHaveCompleted
    }

    @MainActor
    private func finishScopedSessionOpenAttempt(
        _ attempt: ScopedSessionOpenAttempt,
        retryable: Bool)
    {
        guard self.pendingScopedSessionOpenAttempt?.claimID == attempt.claimID else { return }
        if retryable {
            self.pendingScopedSessionOpenAttempt?.phase = .retryable
        } else {
            self.pendingScopedSessionOpenAttempt = nil
        }
    }

    @MainActor
    private func markScopedSessionOpenAttemptTerminal(_ attempt: ScopedSessionOpenAttempt) {
        guard self.pendingScopedSessionOpenAttempt?.claimID == attempt.claimID else { return }
        self.pendingScopedSessionOpenAttempt?.phase = .terminal
    }

    private static func scopedSessionOpenFailureDisposition(
        for error: any Error) -> ScopedSessionOpenFailureDisposition
    {
        if self.isScopedSessionOpenCancellation(error) {
            return .init(operationMayHaveCompleted: true, shouldRetryAutomatically: false)
        }
        if let urlError = error as? URLError {
            return switch urlError.code {
            case .timedOut, .networkConnectionLost:
                .init(operationMayHaveCompleted: true, shouldRetryAutomatically: true)
            case .badURL, .unsupportedURL, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .notConnectedToInternet, .appTransportSecurityRequiresSecureConnection,
                 .userAuthenticationRequired, .userCancelledAuthentication, .dataNotAllowed,
                 .internationalRoamingOff, .callIsActive:
                .init(operationMayHaveCompleted: false, shouldRetryAutomatically: false)
            default:
                .init(operationMayHaveCompleted: true, shouldRetryAutomatically: false)
            }
        }
        if let posix = error as? POSIXError {
            let retryable = [.ETIMEDOUT, .ECONNRESET, .EPIPE].contains(posix.code)
            return .init(operationMayHaveCompleted: true, shouldRetryAutomatically: retryable)
        }
        if let envelope = error as? PeekabooBridgeErrorEnvelope {
            let responseWasLost = envelope.operationMayHaveCompleted ||
                [.timeout, .internalError, .decodingFailed].contains(envelope.code)
            return .init(
                operationMayHaveCompleted: responseWasLost,
                shouldRetryAutomatically: envelope.operationMayHaveCompleted)
        }
        if let failure = error as? DesktopActionFailure {
            return .init(
                operationMayHaveCompleted: failure.outcome.dispatchState.mutationDispatched,
                shouldRetryAutomatically: failure.outcome.evidence == .responseLost)
        }
        return .init(operationMayHaveCompleted: true, shouldRetryAutomatically: false)
    }

    private static func isScopedSessionOpenCancellation(_ error: any Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        if let posix = error as? POSIXError {
            return posix.code == .ECANCELED
        }
        return false
    }

    @MainActor
    private static func resolveInvalidScopedSessionOpen(
        handle: RemoteBrowserMCPSessionHandle,
        transport: any RemoteBrowserMCPSessionTransport) async -> InvalidScopedSessionOpenResolution
    {
        guard handle.isCanonical else { return .retryable }
        do {
            try await transport.endSession(handle)
            return .resolved
        } catch let terminal as RemoteBrowserMCPSessionTransportError {
            return switch terminal {
            case .invalidSession, .sessionEnded: .resolved
            case .wrongOwner, .hostGenerationChanged: .terminal
            }
        } catch {
            return .retryable
        }
    }

    @MainActor
    private func markScopedSessionTerminal() {
        self.scopedSessionState = .terminal
        self.lastScopedStatus = nil
    }

    private static func validateScopedStatus(_ status: BrowserMCPStatus) throws {
        guard (status.connectionReceipt == nil) == (status.providerSessionEpoch == nil) else {
            throw RemoteBrowserMCPSessionError.invalidStatus
        }
        switch status.observation {
        case .confirmed:
            guard status.isConnected == (status.connectionReceipt != nil) else {
                throw RemoteBrowserMCPSessionError.invalidStatus
            }
        case .indeterminate:
            guard !status.isConnected, status.toolCount == 0 else {
                throw RemoteBrowserMCPSessionError.invalidStatus
            }
        }
    }

    private static func sessionBinding(from status: BrowserMCPStatus) -> BrowserMCPExecutionSessionBinding? {
        guard let connectionReceipt = status.connectionReceipt,
              let providerSessionEpoch = status.providerSessionEpoch
        else { return nil }
        return BrowserMCPExecutionSessionBinding(
            connectionReceipt: connectionReceipt,
            providerSessionEpoch: providerSessionEpoch)
    }

    private static func disconnectedStatus(detectedBrowsers: [DetectedBrowser]) -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: detectedBrowsers)
    }

    private static func endedStatus() -> BrowserMCPStatus {
        BrowserMCPStatus(
            isConnected: false,
            toolCount: 0,
            detectedBrowsers: [],
            error: RemoteBrowserMCPSessionError.ended.localizedDescription)
    }

    private static func scopedAtomicExecutionRequired() -> DesktopActionFailure {
        .preDispatchRefusal(
            route: .bridge,
            reason: .operationUnsupported,
            message: "Caller-scoped remote browser execution requires an exact provider epoch.",
            hint: "Open an authenticated browser session and retry through its capability-bound client.")
    }

    private static func existingScopedConnectionRequired() -> DesktopActionFailure {
        .preDispatchRefusal(
            route: .bridge,
            reason: .targetUnavailable,
            message: "Browser execution requires an existing caller-scoped connection.",
            hint: "Connect this exact foreground-authorized session or provide a valid handoff when it opens.")
    }

    private static func terminalSessionFailure(_ error: any Error) -> DesktopActionFailure {
        .preDispatchRefusal(
            route: .bridge,
            reason: .transportSessionUnavailable,
            message: error.localizedDescription,
            hint: "Open a new authenticated browser session before retrying.")
    }

    static func status(from bridgeStatus: PeekabooBridgeBrowserStatus) throws -> BrowserMCPStatus {
        let detectedBrowsers = try bridgeStatus.detectedBrowsers.map { browser in
            guard let channel = BrowserMCPChannel(rawValue: browser.channel),
                  let identity = ChromeChannelIdentity(rawValue: channel.rawValue),
                  identity.matches(bundleIdentifier: browser.bundleIdentifier)
            else {
                throw BrowserMCPConnectionError.connectionLost(
                    "Bridge reported a browser with a noncanonical channel bundle")
            }
            return DetectedBrowser(
                name: browser.name,
                bundleIdentifier: identity.bundleIdentifier,
                processIdentifier: browser.processIdentifier,
                processStartIdentity: browser.processStartIdentity,
                version: browser.version,
                channel: channel)
        }
        let connectionReceipt = try bridgeStatus.connectionReceipt.map { receipt in
            guard receipt.isCanonicalTarget else {
                throw BrowserMCPConnectionError.connectionLost(
                    "Bridge reported a noncanonical browser connection receipt")
            }
            return Self.runtimeReceipt(from: receipt)
        }
        let providerSessionEpoch = bridgeStatus.providerSessionEpoch.map {
            BrowserMCPProviderSessionEpoch(transportID: $0)
        }
        let observation: BrowserMCPStatusObservation = switch bridgeStatus.observation {
        case .confirmed, nil: .confirmed
        case .indeterminate: .indeterminate
        }
        return BrowserMCPStatus(
            isConnected: bridgeStatus.isConnected,
            toolCount: bridgeStatus.toolCount,
            detectedBrowsers: detectedBrowsers,
            connectionReceipt: connectionReceipt,
            providerSessionEpoch: providerSessionEpoch,
            error: bridgeStatus.error,
            observation: observation)
    }

    private static func isBrowserTargetLockedFailure(_ failure: DesktopActionFailure) -> Bool {
        failure.standardErrorCode == .browserTargetLocked &&
            failure.outcome.state == .refused &&
            failure.outcome.refusalReason == .transportSessionUnavailable &&
            failure.outcome.dispatchState == .none &&
            failure.outcome.retrySafety == .safe
    }

    static func bridgeReceipt(
        from receipt: BrowserMCPConnectionReceipt) -> PeekabooBridgeBrowserConnectionReceipt
    {
        PeekabooBridgeBrowserConnectionReceipt(
            channel: receipt.channel?.rawValue,
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: receipt.browserVersion,
            protocolVersion: receipt.protocolVersion)
    }

    static func toolResponse(from bridgeResponse: PeekabooBridgeBrowserToolResponse) throws -> ToolResponse {
        let content: [MCP.Tool.Content] = try bridgeResponse.content.map { value in
            try self.decode(MCP.Tool.Content.self, from: value)
        }
        let meta: Value? = try bridgeResponse.meta.map { try self.decode(Value.self, from: $0) }
        let structuredContent: Value? = try bridgeResponse.structuredContent.map {
            try self.decode(Value.self, from: $0)
        }
        let response = ToolResponse(
            content: content,
            isError: bridgeResponse.isError,
            meta: meta,
            structuredContent: structuredContent)
        guard let receipt = bridgeResponse.connectionReceipt,
              let completedCallCount = bridgeResponse.completedCallCount,
              let dispatchedCallCount = bridgeResponse.dispatchedCallCount
        else {
            return response
        }
        return BrowserMCPExecutionEvidence.attaching(
            to: response,
            connectionReceipt: Self.runtimeReceipt(from: receipt),
            providerSessionEpoch: bridgeResponse.providerSessionEpoch.map {
                BrowserMCPProviderSessionEpoch(transportID: $0)
            },
            completedCallCount: completedCallCount,
            dispatchedCallCount: dispatchedCallCount)
    }

    static func runtimeReceipt(
        from receipt: PeekabooBridgeBrowserConnectionReceipt) -> BrowserMCPConnectionReceipt
    {
        BrowserMCPConnectionReceipt(
            channel: receipt.channel.flatMap(BrowserMCPChannel.init(rawValue:)),
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            bundleIdentifier: receipt.bundleIdentifier,
            browserURL: receipt.browserURL,
            webSocketDebuggerURL: receipt.webSocketDebuggerURL,
            devToolsBrowserID: receipt.devToolsBrowserID,
            browserVersion: receipt.browserVersion,
            protocolVersion: receipt.protocolVersion)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: PeekabooBridgeJSONValue) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value.toAny(), options: [])
        return try JSONDecoder().decode(type, from: data)
    }
}

extension RemoteBrowserMCPClient {
    @MainActor
    public func disconnect() async {
        _ = try? await self.disconnectWithResult()
    }

    @MainActor
    public func disconnectWithResult() async throws -> BrowserMCPStatus {
        if let sessionHandle, let sessionTransport {
            guard self.scopedSessionState == .active else { return Self.endedStatus() }
            do {
                try await sessionTransport.disconnect(session: sessionHandle)
                let status = Self.disconnectedStatus(
                    detectedBrowsers: self.lastScopedStatus?.detectedBrowsers ?? [])
                self.lastScopedStatus = status
                return status
            } catch let error as RemoteBrowserMCPSessionTransportError {
                return self.confirmedTerminalStatus(error: error)
            } catch {
                throw Self.indeterminateDisconnectFailure(error)
            }
        }
        do {
            try await self.client.browserDisconnect()
            return Self.disconnectedStatus(detectedBrowsers: [])
        } catch let failure as DesktopActionFailure {
            throw failure
        } catch {
            throw Self.indeterminateDisconnectFailure(error)
        }
    }

    private static func indeterminateDisconnectFailure(_ error: any Error) -> DesktopActionFailure {
        .indeterminate(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Browser disconnect completion is unknown after the request entered the provider transport.",
            hint: "Check this exact browser session status before deciding whether to disconnect or reconnect again.",
            causeDescription: error.localizedDescription)
    }
}
