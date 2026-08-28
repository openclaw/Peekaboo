import Foundation
import PeekabooAgentRuntime
import PeekabooBridge
import PeekabooFoundation

@MainActor
extension PeekabooServices: PeekabooBridgeBrowserSessionBootstrapProviding {
    public var browserSessionBootstrapProvider: (any PeekabooBridgeBrowserSessionBootstrapProviding)? {
        self.supportsBrowserSessionBootstrap ? self : nil
    }

    public var supportsBrowserSessionBootstrap: Bool {
        self.rootBrowserSessionProvider?.supportsAuthenticatedSessionBootstrap == true
    }

    public func authorizeBrowserConnectionHandoff(
        _ connectionReceipt: PeekabooBridgeBrowserConnectionReceipt) async throws -> UUID
    {
        let root = try self.requiredRootBrowserSessionProvider()
        return try await root.storeConnectionHandoffAuthorization(
            connectionReceipt: Self.browserReceipt(from: connectionReceipt))
    }

    public func discardBrowserConnectionHandoffAuthorization(_ authorizationID: UUID) async {
        self.rootBrowserSessionProvider?.discardConnectionHandoffAuthorization(authorizationID)
    }

    public func bootstrapBrowserSession(_ context: PeekabooBridgeBrowserSessionBootstrapContext) async throws {
        let root = try self.requiredRootBrowserSessionProvider()
        let name = Self.browserSessionName(context.sessionID)
        guard root.existingAuthenticatedSession(named: name) == nil else {
            throw Self.invalidBrowserSession("Browser session already exists")
        }
        switch (context.handoffAuthorizationID, context.connectionReceipt) {
        case (nil, nil):
            _ = try root.createAuthenticatedSession(named: name)
        case let (authorizationID?, connectionReceipt?):
            _ = try await root.transferConnection(
                toAuthenticatedSessionNamed: name,
                authorizationID: authorizationID,
                expectedConnectionReceipt: Self.browserReceipt(from: connectionReceipt))
        case (nil, .some), (.some, nil):
            throw Self.invalidBrowserSession("Browser handoff context is incomplete")
        }
    }

    public func browserSessionStatus(
        sessionID: UUID,
        channel: String?) async throws -> PeekabooBridgeBrowserStatus
    {
        let session = try self.existingBrowserSession(sessionID)
        return try await Self.bridgeStatus(from: session.status(channel: Self.browserChannel(from: channel)))
    }

    public func browserSessionConnect(
        sessionID: UUID,
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        let session = try self.existingBrowserSession(sessionID)
        do {
            let result = try await session.connectWithOutcome(
                channel: Self.browserChannel(from: channel),
                browserURL: browserURL)
            return DesktopActionResult(
                payload: Self.bridgeStatus(from: result.payload),
                outcome: result.outcome)
        } catch BrowserMCPConnectionError.targetLocked {
            throw Self.browserTargetLockedFailure()
        }
    }

    public func browserSessionExecute(
        sessionID: UUID,
        request: PeekabooBridgeBrowserExecuteRequest,
        expectedConnectionReceipt: PeekabooBridgeBrowserConnectionReceipt) async throws
        -> PeekabooBridgeBrowserExecutionResult
    {
        guard request.sessionID == sessionID,
              request.expectedConnectionReceipt == expectedConnectionReceipt,
              request.connectionPolicy == .requireExistingLiveReceipt,
              !request.resolvedCalls.isEmpty,
              request.elementPreflight?.isCanonical != false,
              let expectedEpoch = request.expectedProviderSessionEpoch
        else {
            throw Self.invalidBrowserSession("Scoped browser execution binding is incomplete")
        }
        let session = try self.existingBrowserSession(sessionID)
        let calls = request.resolvedCalls.map { call in
            BrowserMCPMappedCall(
                toolName: call.toolName,
                arguments: call.arguments.mapValues { $0.toAny() })
        }
        let binding = try BrowserMCPExecutionSessionBinding(
            connectionReceipt: Self.browserReceipt(from: expectedConnectionReceipt),
            providerSessionEpoch: BrowserMCPProviderSessionEpoch(rawValue: expectedEpoch))
        let preflight = request.elementPreflight.map {
            BrowserMCPElementPreflight(
                providerPageID: $0.providerPageID,
                providerUIDs: Set($0.providerUIDs))
        }
        let result: BrowserMCPExecutionResult
        do {
            result = try await session.executeSequenceResult(
                calls,
                channel: Self.browserChannel(from: request.channel),
                expectedSessionBinding: binding,
                elementPreflight: preflight)
        } catch BrowserMCPConnectionError.expectedConnectionReceiptMismatch,
            BrowserMCPConnectionError.expectedProviderSessionEpochMismatch
        {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "The exact scoped browser provider session changed before tool dispatch.",
                hint: "Refresh scoped browser status and obtain fresh page and element references.")
        }
        let projected = request.isReadOnly ? result : try result.projectingMutationProgress(for: calls)
        return try PeekabooBridgeBrowserExecutionResult(
            response: Self.bridgeToolResponse(from: projected.response),
            connectionReceipt: Self.bridgeReceipt(from: projected.connectionReceipt),
            completedCallCount: projected.completedCallCount,
            dispatchedCallCount: projected.dispatchedCallCount,
            actionFailure: projected.actionFailure,
            providerSessionEpoch: projected.providerSessionEpoch?.rawValue)
    }

    public func disconnectBrowserSession(_ sessionID: UUID) async throws {
        let session: any BrowserMCPClientProviding = try self.existingBrowserSession(sessionID)
        guard let resultProvider = session as? any BrowserMCPDisconnectResultProviding else {
            throw DesktopActionFailure.preDispatchRefusal(
                reason: .operationUnsupported,
                message: "The scoped browser provider cannot confirm disconnect cleanup.",
                hint: "Update the runtime host before retrying this scoped browser disconnect.")
        }
        let status = try await resultProvider.disconnectWithResult()
        guard status.observation == .confirmed,
              !status.isConnected,
              status.toolCount == 0,
              status.connectionReceipt == nil,
              status.providerSessionEpoch == nil
        else {
            throw DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .background),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "Scoped browser disconnect did not confirm provider cleanup.",
                hint: "Check this exact browser session status before deciding whether to retry.")
        }
    }

    public func invalidateBrowserSession(_ sessionID: UUID) async -> Bool {
        guard let root = self.rootBrowserSessionProvider else { return false }
        return await root.endAuthenticatedSession(named: Self.browserSessionName(sessionID))
    }

    private var rootBrowserSessionProvider: BrowserMCPService? {
        guard let root = self.browser as? BrowserMCPService,
              root.supportsAuthenticatedSessionBootstrap
        else { return nil }
        return root
    }

    private func requiredRootBrowserSessionProvider() throws -> BrowserMCPService {
        guard let root = self.rootBrowserSessionProvider else {
            throw PeekabooBridgeErrorEnvelope(
                code: .operationNotSupported,
                message: "This Bridge host has no local browser session provider")
        }
        return root
    }

    private func existingBrowserSession(_ sessionID: UUID) throws -> BrowserMCPService {
        let root = try self.requiredRootBrowserSessionProvider()
        guard let session = root.existingAuthenticatedSession(named: Self.browserSessionName(sessionID)) else {
            throw Self.invalidBrowserSession("Browser session is unknown, ended, or unavailable")
        }
        return session
    }

    private static func browserSessionName(_ sessionID: UUID) -> String {
        "bridge:\(sessionID.uuidString.lowercased())"
    }

    private static func invalidBrowserSession(_ message: String) -> PeekabooBridgeErrorEnvelope {
        PeekabooBridgeErrorEnvelope(
            code: .invalidRequest,
            message: message,
            context: PeekabooBridgeBrowserSessionErrorContext.invalid)
    }
}
