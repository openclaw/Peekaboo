import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

// This suite keeps the protocol, authority, lifecycle, and routing matrix under one serialized fixture.
// swiftlint:disable type_body_length
@Suite(.serialized)
struct BrowserConnectionHandoffTests {
    @Test
    func `protocol 1 38 owns the distinct browser handoff capability and wire cases`() async throws {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 38)
        #expect(PeekabooBridgeConstants.protocolVersion == version)
        #expect(PeekabooBridgeConstants.browserConnectionHandoffVersion == version)
        #expect(PeekabooBridgeHostCapability.browserConnectionHandoff == "browserConnectionHandoff")
        #expect(PeekabooBridgeClientCapability.browserConnectionHandoff == "browserConnectionHandoff")
        #expect(!PeekabooBridgeOperation.compatible(
            [.browserSessionBootstrap],
            with: .init(major: 1, minor: 37)).contains(.browserSessionBootstrap))

        let ordinary = PeekabooBridgeBrowserChannelRequest(channel: "stable")
        let handoff = PeekabooBridgeBrowserChannelRequest(channel: "stable", requestsHandoff: true)
        #expect(!ordinary.requestsHandoff)
        #expect(handoff.requestsHandoff)
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        let decoder = JSONDecoder.peekabooBridgeDecoder()
        let ordinaryObject = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(ordinary)) as? [String: Any])
        #expect(ordinaryObject["requestsHandoff"] == nil)
        #expect(try decoder.decode(
            PeekabooBridgeBrowserChannelRequest.self,
            from: encoder.encode(handoff)) == handoff)
        let legacy = try decoder.decode(LegacyBrowserChannelRequest.self, from: encoder.encode(handoff))
        #expect(legacy.channel == "stable")
        #expect(legacy.browserURL == nil)
        let epoch = UUID()
        let scopedStatus = PeekabooBridgeBrowserStatus(
            isConnected: true,
            toolCount: 10,
            detectedBrowsers: [],
            connectionReceipt: Self.externalReceipt,
            providerSessionEpoch: epoch,
            observation: .confirmed)
        let legacyStatus = try decoder.decode(
            LegacyBrowserStatus.self,
            from: encoder.encode(scopedStatus))
        #expect(legacyStatus.isConnected)
        #expect(legacyStatus.toolCount == 10)
        let scopedExecute = PeekabooBridgeBrowserExecuteRequest(
            toolName: "take_snapshot",
            arguments: [:],
            expectedConnectionReceipt: Self.externalReceipt,
            connectionPolicy: .requireExistingLiveReceipt,
            sessionID: UUID(),
            expectedProviderSessionEpoch: epoch,
            elementPreflight: .init(providerPageID: 1, providerUIDs: ["bp1"]))
        let legacyExecute = try decoder.decode(
            LegacyBrowserExecuteRequest.self,
            from: encoder.encode(scopedExecute))
        #expect(legacyExecute.toolName == "take_snapshot")
        let autoBound = PeekabooBridgeBrowserExecuteRequest(
            toolName: "take_snapshot",
            arguments: [:],
            channel: "stable",
            sessionID: scopedExecute.sessionID).binding(
            to: Self.externalReceipt,
            providerSessionEpoch: epoch)
        #expect(autoBound.sessionID == scopedExecute.sessionID)
        #expect(autoBound.expectedConnectionReceipt == Self.externalReceipt)
        #expect(autoBound.expectedProviderSessionEpoch == epoch)
        #expect(!PeekabooBridgeBrowserElementPreflight(
            providerPageID: 1,
            providerUIDs: [" bp1"]).isCanonical)
        #expect(!PeekabooBridgeBrowserElementPreflight(
            providerPageID: 1,
            providerUIDs: [String(repeating: "x", count: 1025)]).isCanonical)
        #expect(!PeekabooBridgeBrowserElementPreflight(
            providerPageID: 1,
            providerUIDs: ["bp1", "bp1"]).isCanonical)

        let authority = try Self.authority("wire")
        let peer = try Self.approvedPeer()
        let bundle = try await Self.bundle(authority: authority, peer: peer)
        let claimID = UUID()
        let request = PeekabooBridgeRequest.browserSessionBootstrap(.init(
            receiptBundle: bundle,
            claimID: claimID))
        let decodedRequest = try decoder.decode(PeekabooBridgeRequest.self, from: encoder.encode(request))
        guard case let .browserSessionBootstrap(payload) = decodedRequest else {
            Issue.record("Expected browser bootstrap request")
            return
        }
        #expect(payload.claimID == claimID)
        #expect(payload.receiptBundle == bundle)

        let response = PeekabooBridgeResponse.browserSessionBootstrap(.init(
            sessionID: UUID(),
            claimID: claimID,
            targetReceiptSHA256: "abcd"))
        let decodedResponse = try decoder.decode(PeekabooBridgeResponse.self, from: encoder.encode(response))
        guard case let .browserSessionBootstrap(payload) = decodedResponse else {
            Issue.record("Expected browser bootstrap response")
            return
        }
        #expect(payload.claimID == claimID)
        #expect(payload.targetReceiptSHA256 == "abcd")

        let attestedProjected = PeekabooBridgeResponse.attestedOperation(.init(
            response: .projectedAction(.init(
                response: .browserStatus(.init(
                    isConnected: true,
                    toolCount: 10,
                    detectedBrowsers: [],
                    connectionReceipt: Self.externalReceipt)),
                outcome: Self.connectOutcome().projection)),
            receipt: bundle.receipt))
        let attestedData = try encoder.encode(attestedProjected)
        let decodedAttested = try decoder.decode(PeekabooBridgeResponse.self, from: attestedData)
        guard case let .attestedOperation(attestedEnvelope) = decodedAttested,
              case let .projectedAction(projected) = attestedEnvelope.response,
              case let .browserStatus(status) = projected.response
        else {
            Issue.record("Expected finite attested projected browser response round trip")
            return
        }
        #expect(status.connectionReceipt == Self.externalReceipt)
        #expect(projected.outcome == Self.connectOutcome().projection)
        #expect(try PeekabooBridgeOperationReceiptCoding.canonicalData(decodedAttested) ==
            PeekabooBridgeOperationReceiptCoding.canonicalData(attestedProjected))
        let boxedData = try encoder.encode(PeekabooBridgeResponseCodingBox(attestedProjected))
        let boxedJSON = try #require(String(data: boxedData, encoding: .utf8))
            .replacingOccurrences(of: "\"attestedOperation\"", with: "\"attested_operation\"")
            .replacingOccurrences(of: "\"projectedAction\"", with: "\"projected_action\"")
        let snakeDecoded = try decoder.decode(
            PeekabooBridgeResponseCodingBox.self,
            from: Data(boxedJSON.utf8)).value
        guard case let .attestedOperation(snakeEnvelope) = snakeDecoded,
              case .projectedAction = snakeEnvelope.response
        else {
            Issue.record("Expected finite snake-case recursive response decode")
            return
        }
        let snakeRequest = PeekabooBridgeRequest.attestedOperation(.init(
            requestID: UUID(),
            sessionID: UUID(),
            sessionSequence: .init(0),
            expectedListenerInstanceID: UUID(),
            clientInstanceID: UUID(),
            client: bundle.receipt.payload.client,
            request: .projectedAction(.init(request: .browserConnect(handoff)))))
        let requestBoxData = try encoder.encode(PeekabooBridgeRequestCodingBox(snakeRequest))
        let requestBoxJSON = try #require(String(data: requestBoxData, encoding: .utf8))
            .replacingOccurrences(of: "\"attestedOperation\"", with: "\"attested_operation\"")
            .replacingOccurrences(of: "\"projectedAction\"", with: "\"projected_action\"")
        let snakeRequestDecoded = try decoder.decode(
            PeekabooBridgeRequestCodingBox.self,
            from: Data(requestBoxJSON.utf8)).value
        guard case let .attestedOperation(requestEnvelope) = snakeRequestDecoded,
              case .projectedAction = requestEnvelope.request
        else {
            Issue.record("Expected finite snake-case recursive request decode")
            return
        }
    }

    @Test
    @MainActor
    func `handshake advertises handoff only to an opted in authenticated CLI on protocol 1 38`() async throws {
        let authority = try Self.authority("handshake")
        let peer = try Self.approvedPeer()
        let provider = BootstrapSpy()
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            browserSessionBootstrapProvider: provider)
        let permissions = PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)

        func handshake(capabilities: [String]?, version: PeekabooBridgeProtocolVersion) async throws
            -> PeekabooBridgeHandshakeResponse
        {
            let response = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
                try await server.handleHandshake(
                    .init(
                        protocolVersion: version,
                        client: .init(
                            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
                            teamIdentifier: "FWJYW4S8P8",
                            processIdentifier: getpid()),
                        operationClientInstanceID: UUID(),
                        clientCapabilities: capabilities),
                    peer: peer,
                    permissions: permissions)
            }
            guard case let .handshake(payload) = response else { throw TestFailure() }
            return payload
        }

        let current = try await handshake(
            capabilities: [PeekabooBridgeClientCapability.browserConnectionHandoff],
            version: .init(major: 1, minor: 38))
        #expect(current.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.browserConnectionHandoff) == true)
        #expect(current.supportedOperations.contains(.browserSessionBootstrap))
        #expect(current.enabledOperations?.contains(.browserSessionBootstrap) == true)

        let noOffer = try await handshake(capabilities: [], version: .init(major: 1, minor: 38))
        #expect(noOffer.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.browserConnectionHandoff) != true)
        #expect(!noOffer.supportedOperations.contains(.browserSessionBootstrap))

        let legacy = try await handshake(
            capabilities: [PeekabooBridgeClientCapability.browserConnectionHandoff],
            version: .init(major: 1, minor: 37))
        #expect(legacy.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.browserConnectionHandoff) != true)
        #expect(!legacy.supportedOperations.contains(.browserSessionBootstrap))
    }

    @Test
    @MainActor
    func `handoff intent is refused before browser provider entry when capability was not negotiated`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            browserSessionBootstrapProvider: BootstrapSpy())
        let peer = try Self.approvedPeer()
        let capabilities = PeekabooBridgeNegotiatedSessionCapabilities(
            protocolVersion: .init(major: 1, minor: 38),
            statelessClickVariants: true,
            exactWindowHeldPointerLifecycle: true,
            nativeBrowserConnectionBinding: true,
            browserConnectionHandoff: false)
        let request = PeekabooBridgeRequest.browserConnect(.init(
            channel: "stable",
            requestsHandoff: true))

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(capabilities) {
                try await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                    try await server.route(request, peer: peer)
                }
            }
        }
        #expect(services.lastBrowserConnectTarget == nil)
    }

    @Test
    @MainActor
    func `scoped-only metadata without a session never falls through to root browser services`() async throws {
        let authority = try Self.authority("missing-scope")
        let peer = try Self.approvedPeer()
        let session = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let services = StubServices()
        let spy = BootstrapSpy()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            browserSessionBootstrapProvider: spy)
        let execute = PeekabooBridgeRequest.browserExecute(.init(
            toolName: "take_snapshot",
            arguments: [:],
            expectedConnectionReceipt: Self.externalReceipt,
            connectionPolicy: .requireExistingLiveReceipt,
            expectedProviderSessionEpoch: UUID(),
            elementPreflight: .init(providerPageID: 1, providerUIDs: ["bp1"])))

        let executeResponse = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: session,
            sequence: 0,
            request: execute)
        guard case .error = executeResponse else {
            Issue.record("Expected root execution with scoped metadata to be refused")
            return
        }
        #expect(services.lastBrowserExecute == nil)
        #expect(spy.executeRequests.isEmpty)

        let statusResponse = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: session,
            sequence: 1,
            request: .browserStatus(.init(requestsHandoff: true)))
        guard case .error = statusResponse else {
            Issue.record("Expected sessionless handoff status metadata to be refused")
            return
        }
        #expect(services.lastBrowserStatusChannel == nil)
        #expect(spy.statusRequests.isEmpty)
    }

    @Test
    @MainActor
    func `invalid handoff evidence fails before bootstrap provider entry`() async throws {
        let authority = try Self.authority("invalid-evidence")
        let otherAuthority = try Self.authority("wrong-listener")
        let peer = try Self.approvedPeer()
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let valid = try await Self.bundle(authority: authority, peer: peer)
        let unrequested = try await Self.bundle(
            authority: authority,
            peer: peer,
            requestsHandoff: false)
        let nonforeground = try await Self.bundle(
            authority: authority,
            peer: peer,
            outcome: Self.connectOutcome(mode: .background))
        let noncanonicalReceipt = PeekabooBridgeBrowserConnectionReceipt(
            channel: "stable",
            processIdentifier: getpid(),
            processStartIdentity: SystemIdentityResolver.processStartIdentity(getpid()),
            bundleIdentifier: "com.google.Chrome")
        let noncanonical = try await Self.bundle(
            authority: authority,
            peer: peer,
            receipt: noncanonicalReceipt,
            browserURL: nil)
        let wrongListener = try await Self.bundle(
            authority: otherAuthority,
            peer: peer)
        let tampered = Self.replacing(
            valid,
            canonicalRequest: Data(valid.canonicalRequest.dropLast()))
        let wrongGeneration = Self.replacing(
            valid,
            operationAttestation: .init(
                listenerInstanceID: valid.operationAttestation.listenerInstanceID,
                publicKey: valid.operationAttestation.publicKey,
                host: .init(
                    processIdentifier: valid.operationAttestation.host.processIdentifier,
                    processStartIdentity: valid.operationAttestation.host.processStartIdentity + 1,
                    codeSignatureHash: valid.operationAttestation.host.codeSignatureHash),
                createdAtUnixMilliseconds: valid.operationAttestation.createdAtUnixMilliseconds,
                receiptArchiveDirectory: valid.operationAttestation.receiptArchiveDirectory,
                signature: valid.operationAttestation.signature))
        let cases: [(String, PeekabooBridgeOperationReceiptBundle, Bool)] = [
            ("tampered", tampered, true),
            ("wrong listener", wrongListener, true),
            ("wrong host generation", wrongGeneration, true),
            ("unrequested", unrequested, true),
            ("nonforeground", nonforeground, true),
            ("noncanonical", noncanonical, false),
            ("copied without pending grant", valid, false),
        ]

        for (name, bundle, installPendingGrant) in cases {
            let spy = BootstrapSpy()
            let clock = HandoffClock(bundle.receipt.payload.completedAtUnixMilliseconds)
            let registry = PeekabooBridgeBrowserHandoffGrantRegistry(provider: spy, now: clock.now)
            if installPendingGrant {
                try await registry.reserve(
                    requestID: bundle.receipt.payload.requestID,
                    issuer: peer.browserSessionCaller(
                        clientInstanceID: bundle.receipt.payload.clientInstanceID))
                try registry.attachAuthorization(
                    requestID: bundle.receipt.payload.requestID,
                    authorizationID: UUID())
                try registry.finalize(
                    requestID: bundle.receipt.payload.requestID,
                    receiptBundle: bundle,
                    connectionReceipt: #require(Self.connectionReceipt(in: bundle)))
            }
            do {
                _ = try await registry.bootstrap(
                    request: .init(receiptBundle: bundle, claimID: UUID()),
                    authority: authority,
                    caller: caller)
                Issue.record("Expected \(name) evidence refusal")
            } catch {
                // Each case has a different structural failure; all must fail before the provider.
            }
            #expect(spy.bootstrapContexts.isEmpty, "Provider entered for \(name)")
            #expect(spy.invalidatedSessionIDs.isEmpty, "Cleanup entered before provider for \(name)")
        }
    }

    @Test
    @MainActor
    func `stale and cancelled claims preserve fail closed provider entry semantics`() async throws {
        let authority = try Self.authority("stale-cancel")
        let peer = try Self.approvedPeer()
        let bundle = try await Self.bundle(authority: authority, peer: peer)
        let issuer = try peer.browserSessionCaller(
            clientInstanceID: bundle.receipt.payload.clientInstanceID)
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let clock = HandoffClock(bundle.receipt.payload.completedAtUnixMilliseconds)
        let spy = BootstrapSpy()
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(
            provider: spy,
            lifetimeMilliseconds: 100,
            now: clock.now)
        try await registry.reserve(requestID: bundle.receipt.payload.requestID, issuer: issuer)
        try registry.attachAuthorization(
            requestID: bundle.receipt.payload.requestID,
            authorizationID: UUID())
        try registry.finalize(
            requestID: bundle.receipt.payload.requestID,
            receiptBundle: bundle,
            connectionReceipt: Self.externalReceipt)

        let cancelled = Task { @MainActor in
            try await registry.bootstrap(
                request: .init(receiptBundle: bundle, claimID: UUID()),
                authority: authority,
                caller: caller)
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await cancelled.value
        }
        #expect(spy.bootstrapContexts.isEmpty)
        #expect(spy.discardedHandoffAuthorizationIDs.isEmpty)

        clock.value += 101
        await #expect(throws: (any Error).self) {
            _ = try await registry.bootstrap(
                request: .init(receiptBundle: bundle, claimID: UUID()),
                authority: authority,
                caller: caller)
        }
        #expect(spy.bootstrapContexts.isEmpty)
        #expect(spy.discardedHandoffAuthorizationIDs.count == 1)
    }

    @Test
    @MainActor
    func `concurrent exact claim retry is idempotent and different claim loses`() async throws {
        let authority = try Self.authority("concurrent")
        let peer = try Self.approvedPeer()
        let bundle = try await Self.bundle(authority: authority, peer: peer)
        let issuer = try peer.browserSessionCaller(
            clientInstanceID: bundle.receipt.payload.clientInstanceID)
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let spy = BootstrapSpy(blocksBootstrap: true)
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(provider: spy)
        try await registry.reserve(requestID: bundle.receipt.payload.requestID, issuer: issuer)
        try registry.attachAuthorization(
            requestID: bundle.receipt.payload.requestID,
            authorizationID: UUID())
        try registry.finalize(
            requestID: bundle.receipt.payload.requestID,
            receiptBundle: bundle,
            connectionReceipt: Self.externalReceipt)
        let claimID = UUID()
        let request = PeekabooBridgeBrowserSessionBootstrapRequest(
            receiptBundle: bundle,
            claimID: claimID)

        let first = Task { @MainActor in
            try await registry.bootstrap(request: request, authority: authority, caller: caller)
        }
        while spy.bootstrapContexts.isEmpty {
            await Task.yield()
        }
        let retry = Task { @MainActor in
            try await registry.bootstrap(request: request, authority: authority, caller: caller)
        }
        await #expect(throws: (any Error).self) {
            _ = try await registry.bootstrap(
                request: .init(receiptBundle: bundle, claimID: UUID()),
                authority: authority,
                caller: caller)
        }
        #expect(spy.bootstrapContexts.count == 1)
        first.cancel()
        spy.releaseBootstrap()
        let firstResponse = try await first.value
        let retryResponse = try await retry.value
        #expect(firstResponse == retryResponse)
        #expect(firstResponse.claimID == claimID)
        #expect(spy.bootstrapContexts.count == 1)

        let terminalRetry = try await registry.bootstrap(
            request: request,
            authority: authority,
            caller: caller)
        #expect(terminalRetry == firstResponse)
        #expect(spy.bootstrapContexts.count == 1)
    }

    @Test
    @MainActor
    func `post claim bootstrap failure invalidates and consumes the grant`() async throws {
        let authority = try Self.authority("provider-failure")
        let peer = try Self.approvedPeer()
        let bundle = try await Self.bundle(authority: authority, peer: peer)
        let issuer = try peer.browserSessionCaller(
            clientInstanceID: bundle.receipt.payload.clientInstanceID)
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let spy = BootstrapSpy(failure: TestFailure())
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(provider: spy)
        try await registry.reserve(requestID: bundle.receipt.payload.requestID, issuer: issuer)
        try registry.attachAuthorization(
            requestID: bundle.receipt.payload.requestID,
            authorizationID: UUID())
        try registry.finalize(
            requestID: bundle.receipt.payload.requestID,
            receiptBundle: bundle,
            connectionReceipt: Self.externalReceipt)
        let request = PeekabooBridgeBrowserSessionBootstrapRequest(
            receiptBundle: bundle,
            claimID: UUID())

        await #expect(throws: TestFailure.self) {
            _ = try await registry.bootstrap(request: request, authority: authority, caller: caller)
        }
        #expect(spy.bootstrapContexts.count == 1)
        #expect(spy.invalidatedSessionIDs == spy.bootstrapContexts.map(\.sessionID))
        #expect(await Self.waitUntil { spy.discardedHandoffAuthorizationIDs.count == 1 })
        await #expect(throws: (any Error).self) {
            _ = try await registry.bootstrap(request: request, authority: authority, caller: caller)
        }
        #expect(spy.bootstrapContexts.count == 1)
    }

    @Test
    @MainActor
    func `indeterminate failed-bootstrap cleanup retains bounded capacity until confirmed`() async throws {
        let peer = try Self.approvedPeer()
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let spy = BootstrapSpy(failure: TestFailure())
        spy.invalidationResult = false
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(provider: spy, capacity: 1)
        let authority = try Self.authority("failed-cleanup")

        await #expect(throws: TestFailure.self) {
            _ = try await registry.bootstrap(
                request: .init(claimID: UUID()),
                authority: authority,
                caller: caller)
        }
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await registry.reserve(requestID: UUID(), issuer: caller)
        }
        spy.invalidationResult = true
        try await registry.reserve(requestID: UUID(), issuer: caller)
        #expect(spy.invalidatedSessionIDs.count == 3)
    }

    @Test
    @MainActor
    func `host maintenance retries failed bootstrap cleanup without another Bridge request`() async throws {
        let spy = BootstrapSpy(failure: TestFailure())
        spy.invalidationResult = false
        let caller = try Self.approvedPeer().browserSessionCaller(clientInstanceID: UUID())
        let socketPath = "/tmp/peekaboo-browser-cleanup-reaper-\(UUID().uuidString).sock"
        let server = Self.handoffServer(
            socketPath: socketPath,
            provider: spy,
            processStartIdentity: { _ in caller.process.processStartIdentity },
            processPresence: { _ in true })
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server)
        await host.setBrowserHandoffMaintenanceIntervalForTesting(milliseconds: 10)
        try await host.startChecked()

        await #expect(throws: TestFailure.self) {
            _ = try await server.browserHandoffGrantRegistry.bootstrap(
                request: .init(claimID: UUID()),
                authority: Self.authority("cleanup-reaper"),
                caller: caller)
        }
        #expect(await Self.waitUntil { !spy.invalidatedSessionIDs.isEmpty })
        let attemptsBeforeConfirmation = spy.invalidatedSessionIDs.count
        spy.invalidationResult = true

        #expect(await Self.waitUntil {
            spy.invalidatedSessionIDs.count > attemptsBeforeConfirmation
        })
        #expect(await Self.waitUntil {
            server.browserHandoffGrantRegistry.occupiedCapacityForTesting == 0
        })
        #expect(await host.stop() == .stopped)
    }

    @Test
    @MainActor
    func `blocked failed bootstrap cleanup stays single while host maintenance keeps scanning`() async throws {
        let spy = BootstrapSpy(blocksInvalidation: true, failure: TestFailure())
        let caller = try Self.approvedPeer().browserSessionCaller(clientInstanceID: UUID())
        let socketPath = "/tmp/peekaboo-browser-blocked-cleanup-\(UUID().uuidString).sock"
        let server = Self.handoffServer(
            socketPath: socketPath,
            provider: spy,
            processStartIdentity: { _ in caller.process.processStartIdentity },
            processPresence: { _ in true })
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server)
        await host.setBrowserHandoffMaintenanceIntervalForTesting(milliseconds: 5)
        try await host.startChecked()

        await #expect(throws: TestFailure.self) {
            _ = try await server.browserHandoffGrantRegistry.bootstrap(
                request: .init(claimID: UUID()),
                authority: Self.authority("blocked-cleanup"),
                caller: caller)
        }
        #expect(await Self.waitUntil { spy.invalidatedSessionIDs.count == 1 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(spy.invalidatedSessionIDs.count == 1)

        spy.releaseInvalidation()
        #expect(await Self.waitUntil {
            server.browserHandoffGrantRegistry.occupiedCapacityForTesting == 0
        })
        #expect(await host.stop() == .stopped)
    }

    @Test
    @MainActor
    func `host stop joins its reaper and retires retryable abandoned cleanup`() async throws {
        let peer = try Self.approvedPeer()
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let life = ProcessLifeBox(startIdentity: caller.process.processStartIdentity, presence: true)
        let spy = BootstrapSpy(blocksInvalidation: true)
        let socketPath = "/tmp/peekaboo-browser-reaper-stop-\(UUID().uuidString).sock"
        let server = Self.handoffServer(
            socketPath: socketPath,
            provider: spy,
            processStartIdentity: { _ in life.startIdentity },
            processPresence: { _ in life.presence })
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server)
        await host.setBrowserHandoffMaintenanceIntervalForTesting(milliseconds: 10)
        try await host.startChecked()
        let firstResponse = try await server.browserHandoffGrantRegistry.bootstrap(
            request: .init(claimID: UUID()),
            authority: Self.authority("reaper-stop"),
            caller: caller)
        let secondResponse = try await server.browserHandoffGrantRegistry.bootstrap(
            request: .init(claimID: UUID()),
            authority: Self.authority("reaper-stop-second"),
            caller: caller)

        life.presence = false
        let expectedSessionIDs = Set([firstResponse.sessionID, secondResponse.sessionID])
        #expect(await Self.waitUntil { Set(spy.invalidatedSessionIDs) == expectedSessionIDs })
        let startedAt = ContinuousClock.now
        #expect(await host.stop() == .stopped)
        #expect(startedAt.duration(to: .now) < .seconds(1))

        spy.invalidationResult = false
        spy.releaseInvalidation()
        #expect(await Self.waitUntil {
            spy.invalidatedSessionIDs.count == expectedSessionIDs.count * 2
        })
        spy.invalidationResult = true
        spy.releaseInvalidation()
        #expect(await Self.waitUntil {
            server.browserHandoffGrantRegistry.occupiedCapacityForTesting == 0
        })
        #expect(Set(spy.invalidatedSessionIDs) == expectedSessionIDs)
    }

    @Test
    @MainActor
    func `shutdown reaper times out a noncooperative invalidation and releases server after retry`() async throws {
        let caller = try Self.approvedPeer().browserSessionCaller(clientInstanceID: UUID())
        let life = ProcessLifeBox(startIdentity: caller.process.processStartIdentity, presence: true)
        let spy = SequencedInvalidationSpy()
        let socketPath = "/tmp/peekaboo-browser-bounded-shutdown-\(UUID().uuidString).sock"
        var server: PeekabooBridgeServer? = Self.handoffServer(
            socketPath: socketPath,
            provider: spy,
            processStartIdentity: { _ in life.startIdentity },
            processPresence: { _ in life.presence })
        server?.browserHandoffGrantRegistry.setCleanupAttemptTimeoutForTesting(milliseconds: 100)
        weak let weakServer = server
        var host: PeekabooBridgeHost? = if let server {
            PeekabooBridgeHost(socketPath: socketPath, server: server)
        } else {
            nil
        }
        await host?.setBrowserHandoffMaintenanceIntervalForTesting(milliseconds: 5)
        try await host?.startChecked()
        _ = try await server?.browserHandoffGrantRegistry.bootstrap(
            request: .init(claimID: UUID()),
            authority: Self.authority("bounded-shutdown"),
            caller: caller)

        life.presence = false
        #expect(await Self.waitUntil { spy.invalidationAttemptCount == 1 })
        #expect(await host?.stop() == .stopped)
        host = nil
        server = nil

        #expect(await Self.waitUntil { spy.invalidationAttemptCount == 2 })
        spy.completeInvalidation(attempt: 1, removed: true)
        #expect(await Self.waitUntil { weakServer == nil })
        #expect(spy.invalidatedSessionIDs.count == 2)
        #expect(spy.invalidatedSessionIDs.first == spy.invalidatedSessionIDs.last)

        // The cancelled first call deliberately ignores cancellation and completes after the server is gone.
        spy.completeInvalidation(attempt: 0, removed: true)
    }

    @Test
    @MainActor
    func `late timed out cleanup completion cannot erase a newer generation`() async throws {
        let caller = try Self.approvedPeer().browserSessionCaller(clientInstanceID: UUID())
        let life = ProcessLifeBox(startIdentity: caller.process.processStartIdentity, presence: true)
        let spy = SequencedInvalidationSpy()
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(
            provider: spy,
            capacity: 1,
            cleanupAttemptTimeoutMilliseconds: 20,
            processStartIdentity: { _ in life.startIdentity },
            processPresence: { _ in life.presence })
        let response = try await registry.bootstrap(
            request: .init(claimID: UUID()),
            authority: Self.authority("cleanup-aba"),
            caller: caller)

        life.presence = false
        registry.scheduleMaintenance()
        #expect(await Self.waitUntil { spy.invalidationAttemptCount == 1 })
        for _ in 0..<20 {
            registry.scheduleMaintenance()
        }
        #expect(spy.invalidationAttemptCount == 1)
        #expect(await Self.waitUntil {
            registry.cleanupIsPendingForTesting(sessionID: response.sessionID)
        })
        registry.setCleanupAttemptTimeoutForTesting(milliseconds: 1000)
        registry.scheduleMaintenance()
        #expect(await Self.waitUntil { spy.invalidationAttemptCount == 2 })

        spy.completeInvalidation(attempt: 0, removed: true)
        #expect(await Self.waitUntil {
            registry.activeProviderCleanupCallCountForTesting(sessionID: response.sessionID) == 1
        })
        #expect(registry.occupiedCapacityForTesting == 1)
        for _ in 0..<20 {
            registry.scheduleMaintenance()
        }
        #expect(spy.invalidationAttemptCount == 2)

        spy.completeInvalidation(attempt: 1, removed: true)
        #expect(await Self.waitUntil { registry.occupiedCapacityForTesting == 0 })
        #expect(spy.invalidatedSessionIDs == [response.sessionID, response.sessionID])
    }

    @Test
    @MainActor
    func `late cleanup success settles debt when no newer generation exists`() async throws {
        let caller = try Self.approvedPeer().browserSessionCaller(clientInstanceID: UUID())
        let spy = SequencedInvalidationSpy()
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(
            provider: spy,
            capacity: 1,
            cleanupAttemptTimeoutMilliseconds: 15)
        let response = try await registry.bootstrap(
            request: .init(claimID: UUID()),
            authority: Self.authority("cleanup-late-success"),
            caller: caller)

        let end = Task { @MainActor in
            try await registry.endSession(response.sessionID, caller: caller)
        }
        #expect(await Self.waitUntil { spy.invalidationAttemptCount == 1 })
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await end.value
        }
        spy.completeInvalidation(attempt: 0, removed: true)

        #expect(await Self.waitUntil { registry.occupiedCapacityForTesting == 0 })
        try await registry.endSession(response.sessionID, caller: caller)
        #expect(spy.invalidatedSessionIDs == [response.sessionID])
    }

    @Test
    @MainActor
    func `cleanup retries cap noncooperative calls until an exact session slot returns`() async throws {
        let caller = try Self.approvedPeer().browserSessionCaller(clientInstanceID: UUID())
        let life = ProcessLifeBox(
            startIdentity: caller.process.processStartIdentity,
            presence: true)
        let spy = SequencedInvalidationSpy()
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(
            provider: spy,
            capacity: 1,
            cleanupAttemptTimeoutMilliseconds: 15,
            processStartIdentity: { _ in life.startIdentity },
            processPresence: { _ in life.presence })
        let response = try await registry.bootstrap(
            request: .init(claimID: UUID()),
            authority: Self.authority("cleanup-cap"),
            caller: caller)

        life.presence = false
        #expect(await Self.waitUntil {
            registry.scheduleMaintenance()
            return spy.invalidationAttemptCount == 2
        })
        try await Task.sleep(for: .milliseconds(25))
        for _ in 0..<50 {
            registry.scheduleMaintenance()
        }
        #expect(spy.invalidationAttemptCount == 2)
        #expect(registry.activeProviderCleanupCallCountForTesting(sessionID: response.sessionID) == 2)
        #expect(registry.occupiedCapacityForTesting == 1)

        spy.completeInvalidation(attempt: 0, removed: false)
        #expect(await Self.waitUntil {
            registry.scheduleMaintenance()
            return spy.invalidationAttemptCount == 3
        })
        spy.completeInvalidation(attempt: 1, removed: false)
        spy.completeInvalidation(attempt: 2, removed: true)
        #expect(await Self.waitUntil { registry.occupiedCapacityForTesting == 0 })
        #expect(spy.invalidatedSessionIDs == [response.sessionID, response.sessionID, response.sessionID])
    }

    @Test
    @MainActor
    func `owner death closes admission before draining and ambiguous liveness preserves the session`() async throws {
        let peer = try Self.approvedPeer()
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let life = ProcessLifeBox(
            startIdentity: caller.process.processStartIdentity,
            presence: true)
        let spy = BootstrapSpy()
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(
            provider: spy,
            capacity: 1,
            processStartIdentity: { _ in life.startIdentity },
            processPresence: { _ in life.presence })
        let authority = try Self.authority("owner-reclamation")
        let response = try await registry.bootstrap(
            request: .init(claimID: UUID()),
            authority: authority,
            caller: caller)

        life.startIdentity = nil
        life.presence = nil
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await registry.reserve(requestID: UUID(), issuer: caller)
        }
        #expect(spy.invalidatedSessionIDs.isEmpty)

        let activeOperation = try await registry.authorizeSession(response.sessionID, caller: caller)
        life.presence = false
        let replacement = Task { @MainActor in
            try await registry.reserve(requestID: UUID(), issuer: caller)
        }
        await Task.yield()
        #expect(spy.invalidatedSessionIDs.isEmpty)
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await registry.authorizeSession(response.sessionID, caller: caller)
        }
        registry.completeSessionOperation(activeOperation)
        try await replacement.value
        #expect(spy.invalidatedSessionIDs == [response.sessionID])
    }

    @Test
    @MainActor
    func `bootstrap timeout retains capacity until late provider settlement cleanup is confirmed`() async throws {
        let peer = try Self.approvedPeer()
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let spy = BootstrapSpy(blocksBootstrap: true, blocksInvalidation: true)
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(
            provider: spy,
            capacity: 1,
            lifetimeMilliseconds: 10)
        let authority = try Self.authority("bootstrap-timeout")

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await registry.bootstrap(
                request: .init(claimID: UUID()),
                authority: authority,
                caller: caller)
        }
        #expect(spy.invalidatedSessionIDs.isEmpty)
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await registry.reserve(requestID: UUID(), issuer: caller)
        }

        spy.releaseBootstrap()
        while spy.invalidatedSessionIDs.isEmpty {
            await Task.yield()
        }
        #expect(spy.completedInvalidationCount == 0)
        spy.releaseInvalidation()
        while spy.completedInvalidationCount == 0 {
            await Task.yield()
        }
        #expect(await Self.waitUntil { registry.occupiedCapacityForTesting == 0 })
        try await registry.reserve(requestID: UUID(), issuer: caller)
        #expect(spy.invalidatedSessionIDs == spy.bootstrapContexts.map(\.sessionID))
    }

    @Test
    @MainActor
    func `end becomes terminal before cleanup and concurrent retries coalesce`() async throws {
        let peer = try Self.approvedPeer()
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let claimID = UUID()
        let spy = BootstrapSpy(blocksInvalidation: true)
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(provider: spy)
        let authority = try Self.authority("atomic-end")
        let response = try await registry.bootstrap(
            request: .init(claimID: claimID),
            authority: authority,
            caller: caller)
        let activeOperation = try await registry.authorizeSession(response.sessionID, caller: caller)

        let firstEnd = Task { @MainActor in
            try await registry.endSession(response.sessionID, caller: caller)
        }
        await Task.yield()
        #expect(spy.invalidatedSessionIDs.isEmpty)
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await registry.authorizeSession(response.sessionID, caller: caller)
        }
        registry.completeSessionOperation(activeOperation)
        while spy.invalidatedSessionIDs.isEmpty {
            await Task.yield()
        }
        let retryEnd = Task { @MainActor in
            try await registry.endSession(response.sessionID, caller: caller)
        }
        #expect(spy.invalidatedSessionIDs == [response.sessionID])
        spy.releaseInvalidation()
        try await firstEnd.value
        try await retryEnd.value
        #expect(spy.invalidatedSessionIDs == [response.sessionID])

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await registry.bootstrap(
                request: .init(claimID: claimID),
                authority: authority,
                caller: caller)
        }
        #expect(spy.bootstrapContexts.count == 1)
    }

    @Test
    @MainActor
    func `indeterminate end stays terminal and a confirmed retry tombstones`() async throws {
        let peer = try Self.approvedPeer()
        let caller = try peer.browserSessionCaller(clientInstanceID: UUID())
        let spy = BootstrapSpy()
        spy.invalidationResult = false
        let registry = PeekabooBridgeBrowserHandoffGrantRegistry(provider: spy)
        let authority = try Self.authority("retryable-end")
        let response = try await registry.bootstrap(
            request: .init(claimID: UUID()),
            authority: authority,
            caller: caller)

        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await registry.endSession(response.sessionID, caller: caller)
        }
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await registry.authorizeSession(response.sessionID, caller: caller)
        }
        spy.invalidationResult = true
        try await registry.endSession(response.sessionID, caller: caller)
        #expect(spy.invalidatedSessionIDs == [response.sessionID, response.sessionID])
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await registry.authorizeSession(response.sessionID, caller: caller)
        }
    }

    @Test
    @MainActor
    func `server mints grant only from attested connect and bootstraps through narrow seam`() async throws {
        let authority = try Self.authority("server-e2e")
        let peer = try Self.approvedPeer()
        let connectSession = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let spy = BootstrapSpy()
        let services = StubServices()
        services.browserConnectionReceipt = Self.externalReceipt
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            browserSessionBootstrapProvider: spy)
        let connect = PeekabooBridgeRequest.projectedAction(.init(request: .browserConnect(.init(
            channel: "stable",
            browserURL: Self.externalReceipt.browserURL,
            requestsHandoff: true))))
        let connectPayload = connectSession.request(authority: authority, sequence: 0, request: connect)
        let connectData = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await server.handleAttestedOperation(connectPayload, peer: peer)
        }
        let connectWire = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: connectData)
        guard case let .attestedOperation(connectEnvelope) = connectWire else {
            Issue.record("Expected attested connect response")
            return
        }
        let connectBundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: connectSession.attestation,
            receipt: connectEnvelope.receipt,
            request: connect,
            response: connectEnvelope.response)
        try connectBundle.validate(trustAnchor: .listenerAttestation(authority.attestation))

        let bootstrapSession = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: UUID(),
            peer: peer)
        let claimID = UUID()
        let bootstrap = PeekabooBridgeRequest.browserSessionBootstrap(.init(
            receiptBundle: connectBundle,
            claimID: claimID))
        let bootstrapPayload = bootstrapSession.request(
            authority: authority,
            sequence: 0,
            request: bootstrap)
        let bootstrapData = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await server.handleAttestedOperation(bootstrapPayload, peer: peer)
        }
        let bootstrapWire = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: bootstrapData)
        guard case let .attestedOperation(bootstrapEnvelope) = bootstrapWire,
              case let .browserSessionBootstrap(response) = bootstrapEnvelope.response
        else {
            Issue.record("Expected attested bootstrap response")
            return
        }
        #expect(response.claimID == claimID)
        #expect(spy.bootstrapContexts.count == 1)
        #expect(spy.bootstrapContexts.first?.connectionReceipt == Self.externalReceipt)
        #expect(spy.bootstrapContexts.first?.handoffAuthorizationID == spy.authorizedHandoffs.first?.0)
        let expectedCaller = try peer.browserSessionCaller(
            clientInstanceID: bootstrapSession.clientInstanceID)
        #expect(spy.bootstrapContexts.first?.caller == expectedCaller)
        let bootstrapJSON = try #require(String(data: bootstrapData, encoding: .utf8))
        #expect(!bootstrapJSON.contains("127.0.0.1:9333"))
        #expect(!bootstrapJSON.contains("devtools/browser"))
        if let authorizationID = spy.authorizedHandoffs.first?.0 {
            #expect(!bootstrapJSON.contains(authorizationID.uuidString))
        }
    }

    @Test
    @MainActor
    // swiftlint:disable:next function_body_length
    func `scoped browser wire authenticates owner epoch preflight disconnect and terminal end`() async throws {
        let authority = try Self.authority("scoped-routing")
        let peer = try Self.approvedPeer()
        let owner = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let spy = BootstrapSpy()
        let epoch = UUID()
        spy.scopedStatus = .init(
            isConnected: true,
            toolCount: 12,
            detectedBrowsers: [],
            connectionReceipt: Self.externalReceipt,
            providerSessionEpoch: epoch,
            observation: .confirmed)
        spy.scopedConnectResult = try DesktopActionResult(
            payload: #require(spy.scopedStatus),
            outcome: Self.connectOutcome())
        spy.scopedExecutionResult = .init(
            response: .init(content: [], isError: false, meta: nil),
            connectionReceipt: Self.externalReceipt,
            completedCallCount: 1,
            dispatchedCallCount: 1,
            providerSessionEpoch: epoch)
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            browserSessionBootstrapProvider: spy)

        let emptyClaimID = UUID()
        let bootstrap = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 0,
            request: .browserSessionBootstrap(.init(claimID: emptyClaimID)))
        guard case let .browserSessionBootstrap(handle) = bootstrap else {
            Issue.record("Expected empty scoped browser session")
            return
        }
        #expect(handle.targetReceiptSHA256 == nil)
        #expect(spy.bootstrapContexts.first?.connectionReceipt == nil)

        let connect = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 1,
            request: .projectedAction(.init(request: .browserConnect(.init(
                channel: "stable",
                browserURL: Self.externalReceipt.browserURL,
                sessionID: handle.sessionID)))))
        guard case let .projectedAction(connectProjection) = connect,
              case let .browserStatus(connectStatus) = connectProjection.response
        else {
            Issue.record("Expected scoped browser connect")
            return
        }
        #expect(connectStatus.providerSessionEpoch == epoch)
        #expect(spy.connectRequests.count == 1)

        let status = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 2,
            request: .browserStatus(.init(channel: "stable", sessionID: handle.sessionID)))
        guard case let .browserStatus(scopedStatus) = status else {
            Issue.record("Expected scoped browser status")
            return
        }
        #expect(scopedStatus.providerSessionEpoch == epoch)
        #expect(scopedStatus.observation == .confirmed)
        #expect(spy.statusRequests.count == 1)

        let preflight = PeekabooBridgeBrowserElementPreflight(
            providerPageID: 7,
            providerUIDs: ["be1", "bp1"])
        let execute = PeekabooBridgeRequest.browserExecute(.init(
            toolName: "take_snapshot",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.externalReceipt,
            connectionPolicy: .requireExistingLiveReceipt,
            sessionID: handle.sessionID,
            expectedProviderSessionEpoch: epoch,
            elementPreflight: preflight))
        let execution = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 3,
            request: execute)
        guard case let .browserToolResponse(toolResponse) = execution else {
            Issue.record("Expected scoped browser tool response")
            return
        }
        #expect(toolResponse.providerSessionEpoch == epoch)
        #expect(spy.executeRequests.count == 1)
        #expect(spy.executeRequests.first?.elementPreflight == preflight)

        spy.scopedExecutionError = CancellationError()
        let cancelledExecution = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 4,
            request: execute)
        guard case let .browserToolResponse(cancelledResponse) = cancelledExecution else {
            Issue.record("Expected scoped browser cancellation response")
            return
        }
        #expect(cancelledResponse.isError)
        #expect(cancelledResponse.connectionReceipt == Self.externalReceipt)
        #expect(cancelledResponse.providerSessionEpoch == epoch)
        #expect(spy.executeRequests.count == 2)
        spy.scopedExecutionError = nil

        let wrongOwner = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: UUID(),
            peer: peer)
        let refused = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: wrongOwner,
            sequence: 0,
            request: .browserStatus(.init(sessionID: handle.sessionID)))
        guard case let .error(wrongOwnerError) = refused else {
            Issue.record("Expected wrong-owner scoped status refusal")
            return
        }
        #expect(wrongOwnerError.code == .unauthorizedClient)
        #expect(wrongOwnerError.context == PeekabooBridgeBrowserSessionErrorContext.wrongOwner)
        #expect(spy.statusRequests.count == 1)

        let noncanonicalExecute = PeekabooBridgeRequest.browserExecute(.init(
            toolName: "take_snapshot",
            arguments: [:],
            channel: "stable",
            expectedConnectionReceipt: Self.externalReceipt,
            connectionPolicy: .requireExistingLiveReceipt,
            sessionID: handle.sessionID,
            expectedProviderSessionEpoch: epoch,
            elementPreflight: .init(providerPageID: 7, providerUIDs: ["bp1", "be1"])))
        let preflightRefusal = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 5,
            request: noncanonicalExecute)
        guard case .error = preflightRefusal else {
            Issue.record("Expected noncanonical preflight refusal")
            return
        }
        #expect(spy.executeRequests.count == 2)

        let disconnect = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 6,
            request: .browserSessionControl(.init(sessionID: handle.sessionID, action: .disconnect)))
        guard case .ok = disconnect else { throw TestFailure() }
        #expect(spy.disconnectedSessionIDs == [handle.sessionID])

        let end = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 7,
            request: .browserSessionControl(.init(sessionID: handle.sessionID, action: .end)))
        guard case .ok = end else { throw TestFailure() }
        #expect(spy.invalidatedSessionIDs == [handle.sessionID])

        let repeatedEnd = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 8,
            request: .browserSessionControl(.init(sessionID: handle.sessionID, action: .end)))
        guard case .ok = repeatedEnd else { throw TestFailure() }
        #expect(spy.invalidatedSessionIDs == [handle.sessionID])

        let replayedClaim = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 9,
            request: .browserSessionBootstrap(.init(claimID: emptyClaimID)))
        guard case let .error(replayError) = replayedClaim else {
            Issue.record("Expected ended empty claim replay refusal")
            return
        }
        #expect(replayError.context == PeekabooBridgeBrowserSessionErrorContext.ended)
        #expect(spy.bootstrapContexts.count == 1)

        let afterEnd = try await Self.attestedResponse(
            server: server,
            authority: authority,
            session: owner,
            sequence: 10,
            request: .browserStatus(.init(sessionID: handle.sessionID)))
        guard case let .error(endedError) = afterEnd else {
            Issue.record("Expected ended scoped status refusal")
            return
        }
        #expect(endedError.code == .invalidRequest)
        #expect(endedError.context == PeekabooBridgeBrowserSessionErrorContext.ended)
        #expect(spy.statusRequests.count == 1)
    }

    private static let externalReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "stable",
        browserURL: "http://127.0.0.1:9333/",
        webSocketDebuggerURL: "ws://127.0.0.1:9333/devtools/browser/browser-handoff",
        devToolsBrowserID: "browser-handoff",
        browserVersion: "Chrome/151.0",
        protocolVersion: "1.3")

    private static func connectOutcome(
        mode: DesktopActionOutcome.Delivery.Mode = .foreground) -> DesktopActionOutcome
    {
        .dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: mode),
            evidence: .deliveryAccepted,
            unitCount: .one)
    }

    private static func authority(_ suffix: String) throws -> PeekabooBridgeOperationReceiptAuthority {
        try PeekabooBridgeOperationReceiptAuthority(
            socketPath: "/tmp/peekaboo-browser-handoff-\(suffix)-\(UUID().uuidString).sock")
    }

    @MainActor
    private static func handoffServer(
        socketPath: String,
        provider: any PeekabooBridgeBrowserSessionBootstrapProviding,
        processStartIdentity: @escaping @Sendable (pid_t) -> UInt64?,
        processPresence: @escaping @Sendable (pid_t) -> Bool?) -> PeekabooBridgeServer
    {
        PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [
                .browserStatus,
                .browserConnect,
                .browserDisconnect,
                .browserExecute,
                .browserSessionBootstrap,
                .browserSessionControl,
            ],
            hostIdentity: nil,
            servingSocketPath: socketPath,
            screenCaptureKitProcessCapabilityRegistrar: {},
            screenCaptureKitOwnershipPreparer: {},
            processStartIdentityProvider: processStartIdentity,
            processPresenceProvider: processPresence,
            browserSessionBootstrapProvider: provider)
    }

    @MainActor
    private static func waitUntil(
        timeout: Duration = .seconds(1),
        _ condition: () -> Bool) async -> Bool
    {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    private static func approvedPeer() throws -> PeekabooBridgePeer {
        let base = try OperationReceiptSessionFixture.currentPeer()
        guard let identity = base.liveIdentity else {
            throw TestFailure()
        }
        return PeekabooBridgePeer(
            liveIdentity: identity,
            bundleIdentifier: PeekabooBridgeConstants.cliBundleIdentifier,
            teamIdentifier: "FWJYW4S8P8")
    }

    private static func bundle(
        authority: PeekabooBridgeOperationReceiptAuthority,
        peer: PeekabooBridgePeer,
        requestsHandoff: Bool = true,
        outcome: DesktopActionOutcome = Self.connectOutcome(),
        receipt: PeekabooBridgeBrowserConnectionReceipt = Self.externalReceipt,
        browserURL: String? = Self.externalReceipt.browserURL,
        sequence: UInt64 = 0) async throws -> PeekabooBridgeOperationReceiptBundle
    {
        let session = try await OperationReceiptSessionFixture.make(authority: authority, peer: peer)
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .browserConnect(.init(
            channel: "stable",
            browserURL: browserURL,
            requestsHandoff: requestsHandoff))))
        let response = PeekabooBridgeResponse.projectedAction(.init(
            response: .browserStatus(.init(
                isConnected: true,
                toolCount: 10,
                detectedBrowsers: [],
                connectionReceipt: receipt)),
            outcome: outcome.projection))
        let target: PeekabooBridgeOperationTargetReceipt = if receipt.isCanonicalExternalTarget {
            .browser(receipt)
        } else {
            try .process(#require(receipt.localProcessIdentity))
        }
        return try await session.signedBundle(
            authority: authority,
            sequence: sequence,
            request: request,
            response: response,
            target: target,
            outcome: outcome.projection)
    }

    private static func connectionReceipt(
        in bundle: PeekabooBridgeOperationReceiptBundle) -> PeekabooBridgeBrowserConnectionReceipt?
    {
        guard let response = try? JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: bundle.canonicalResponse)
        else { return nil }
        return response.browserExecutionConnectionReceipt
    }

    private static func replacing(
        _ bundle: PeekabooBridgeOperationReceiptBundle,
        operationAttestation: PeekabooBridgeListenerAttestation? = nil,
        canonicalRequest: Data? = nil) -> PeekabooBridgeOperationReceiptBundle
    {
        PeekabooBridgeOperationReceiptBundle(
            operationAttestation: operationAttestation ?? bundle.operationAttestation,
            operationSessionAttestation: bundle.operationSessionAttestation,
            receipt: bundle.receipt,
            canonicalListenerAttestationPayload: bundle.canonicalListenerAttestationPayload,
            canonicalSessionAttestationPayload: bundle.canonicalSessionAttestationPayload,
            canonicalReceiptPayload: bundle.canonicalReceiptPayload,
            canonicalRequest: canonicalRequest ?? bundle.canonicalRequest,
            canonicalResponse: bundle.canonicalResponse)
    }

    @MainActor
    private static func attestedResponse(
        server: PeekabooBridgeServer,
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: OperationReceiptSessionFixture,
        sequence: UInt64,
        request: PeekabooBridgeRequest) async throws -> PeekabooBridgeResponse
    {
        let payload = session.request(authority: authority, sequence: sequence, request: request)
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await server.handleAttestedOperation(payload, peer: session.peer)
        }
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
        guard case let .attestedOperation(envelope) = response else { throw TestFailure() }
        return envelope.response
    }
}

// swiftlint:enable type_body_length

@MainActor
private final class BootstrapSpy: PeekabooBridgeBrowserSessionBootstrapProviding {
    let supportsBrowserSessionBootstrap = true
    private let blocksBootstrap: Bool
    private let blocksInvalidation: Bool
    private let failure: (any Error)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var invalidationContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var bootstrapContexts: [PeekabooBridgeBrowserSessionBootstrapContext] = []
    private(set) var invalidatedSessionIDs: [UUID] = []
    private(set) var completedInvalidationCount = 0
    var invalidationResult = true
    private(set) var authorizedHandoffs: [(UUID, PeekabooBridgeBrowserConnectionReceipt)] = []
    private(set) var discardedHandoffAuthorizationIDs: [UUID] = []
    var scopedStatus: PeekabooBridgeBrowserStatus?
    var scopedConnectResult: DesktopActionResult<PeekabooBridgeBrowserStatus>?
    var scopedExecutionResult: PeekabooBridgeBrowserExecutionResult?
    var scopedExecutionError: (any Error)?
    private(set) var statusRequests: [(UUID, String?)] = []
    private(set) var connectRequests: [(UUID, String?, String?)] = []
    private(set) var executeRequests: [PeekabooBridgeBrowserExecuteRequest] = []
    private(set) var disconnectedSessionIDs: [UUID] = []

    init(
        blocksBootstrap: Bool = false,
        blocksInvalidation: Bool = false,
        failure: (any Error)? = nil)
    {
        self.blocksBootstrap = blocksBootstrap
        self.blocksInvalidation = blocksInvalidation
        self.failure = failure
    }

    func bootstrapBrowserSession(_ context: PeekabooBridgeBrowserSessionBootstrapContext) async throws {
        self.bootstrapContexts.append(context)
        if self.blocksBootstrap {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        if let failure {
            throw failure
        }
    }

    func authorizeBrowserConnectionHandoff(
        _ connectionReceipt: PeekabooBridgeBrowserConnectionReceipt) async throws -> UUID
    {
        let authorizationID = UUID()
        self.authorizedHandoffs.append((authorizationID, connectionReceipt))
        return authorizationID
    }

    func discardBrowserConnectionHandoffAuthorization(_ authorizationID: UUID) async {
        self.discardedHandoffAuthorizationIDs.append(authorizationID)
    }

    func invalidateBrowserSession(_ sessionID: UUID) async -> Bool {
        self.invalidatedSessionIDs.append(sessionID)
        if self.blocksInvalidation {
            await withCheckedContinuation { continuation in
                self.invalidationContinuations.append(continuation)
            }
        }
        self.completedInvalidationCount += 1
        return self.invalidationResult
    }

    func browserSessionStatus(
        sessionID: UUID,
        channel: String?) async throws -> PeekabooBridgeBrowserStatus
    {
        self.statusRequests.append((sessionID, channel))
        guard let scopedStatus else { throw TestFailure() }
        return scopedStatus
    }

    func browserSessionConnect(
        sessionID: UUID,
        channel: String?,
        browserURL: String?) async throws -> DesktopActionResult<PeekabooBridgeBrowserStatus>
    {
        self.connectRequests.append((sessionID, channel, browserURL))
        guard let scopedConnectResult else { throw TestFailure() }
        return scopedConnectResult
    }

    func browserSessionExecute(
        sessionID _: UUID,
        request: PeekabooBridgeBrowserExecuteRequest,
        expectedConnectionReceipt _: PeekabooBridgeBrowserConnectionReceipt) async throws
        -> PeekabooBridgeBrowserExecutionResult
    {
        self.executeRequests.append(request)
        if let scopedExecutionError {
            throw scopedExecutionError
        }
        guard let scopedExecutionResult else { throw TestFailure() }
        return scopedExecutionResult
    }

    func disconnectBrowserSession(_ sessionID: UUID) async throws {
        self.disconnectedSessionIDs.append(sessionID)
    }

    func releaseBootstrap() {
        self.continuation?.resume()
        self.continuation = nil
    }

    func releaseInvalidation() {
        let continuations = self.invalidationContinuations
        self.invalidationContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }
}

@MainActor
private final class SequencedInvalidationSpy: PeekabooBridgeBrowserSessionBootstrapProviding {
    let supportsBrowserSessionBootstrap = true
    private var invalidationContinuations: [Int: CheckedContinuation<Bool, Never>] = [:]
    private(set) var invalidatedSessionIDs: [UUID] = []

    var invalidationAttemptCount: Int {
        self.invalidatedSessionIDs.count
    }

    func bootstrapBrowserSession(_: PeekabooBridgeBrowserSessionBootstrapContext) async throws {}

    func invalidateBrowserSession(_ sessionID: UUID) async -> Bool {
        let attempt = self.invalidationAttemptCount
        self.invalidatedSessionIDs.append(sessionID)
        return await withCheckedContinuation { continuation in
            self.invalidationContinuations[attempt] = continuation
        }
    }

    func completeInvalidation(attempt: Int, removed: Bool) {
        self.invalidationContinuations.removeValue(forKey: attempt)?.resume(returning: removed)
    }
}

private final class HandoffClock: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Int64

    init(_ value: Int64) {
        self.storedValue = value
    }

    var value: Int64 {
        get { self.lock.withLock { self.storedValue } }
        set { self.lock.withLock { self.storedValue = newValue } }
    }

    var now: @Sendable () -> Int64 {
        { self.value }
    }
}

private final class ProcessLifeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStartIdentity: UInt64?
    private var storedPresence: Bool?

    init(startIdentity: UInt64?, presence: Bool?) {
        self.storedStartIdentity = startIdentity
        self.storedPresence = presence
    }

    var startIdentity: UInt64? {
        get { self.lock.withLock { self.storedStartIdentity } }
        set { self.lock.withLock { self.storedStartIdentity = newValue } }
    }

    var presence: Bool? {
        get { self.lock.withLock { self.storedPresence } }
        set { self.lock.withLock { self.storedPresence = newValue } }
    }
}

private struct TestFailure: Error {}

private struct LegacyBrowserChannelRequest: Decodable {
    let channel: String?
    let browserURL: String?
}

private struct LegacyBrowserStatus: Decodable {
    let isConnected: Bool
    let toolCount: Int
}

private struct LegacyBrowserExecuteRequest: Decodable {
    let toolName: String
}
