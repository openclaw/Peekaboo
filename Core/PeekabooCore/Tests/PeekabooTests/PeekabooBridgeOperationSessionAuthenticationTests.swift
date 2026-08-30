import CryptoKit
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

private func bridgeFallbackVersion(distance: Int) -> PeekabooBridgeProtocolVersion {
    let current = PeekabooBridgeConstants.protocolVersion
    return PeekabooBridgeProtocolVersion(major: current.major, minor: current.minor - distance)
}

@Suite(.serialized)
struct PeekabooBridgeOperationSessionAuthenticationTests {
    @Test
    func `bundled sockets receive release host trust while custom sockets do not`() {
        for path in [
            PeekabooBridgeConstants.peekabooSocketPath,
            PeekabooBridgeConstants.daemonSocketPath,
            PeekabooBridgeConstants.claudeSocketPath,
            PeekabooBridgeConstants.clawdbotSocketPath,
        ] {
            #expect(PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: path) ==
                PeekabooBridgeConstants.trustedReleaseTeamIDs)
        }
        let buildScoped = URL(fileURLWithPath: PeekabooBridgeConstants.daemonSocketPath)
            .deletingLastPathComponent()
            .appendingPathComponent("daemon-0123456789abcdef.sock").path
        #expect(PeekabooBridgeConstants.defaultTrustedHostTeamIDs(socketPath: buildScoped) ==
            PeekabooBridgeConstants.trustedReleaseTeamIDs)
        #expect(PeekabooBridgeConstants.defaultTrustedHostTeamIDs(
            socketPath: "/tmp/custom-peekaboo.sock") == nil)
    }

    @Test
    func `one cold handshake authorizes repeated hot attested requests`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbha-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AuthenticationProbe()
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { fd in
                let identity = try PeekabooBridgeSocketIO.livePeerIdentity(fd: fd)
                probe.recordLiveCapture()
                return identity
            },
            coldPeer: { identity, _ in
                probe.recordColdAuthorization()
                return PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: "dev.peekaboo.hot-auth-tests",
                    teamIdentifier: nil)
            }))
        try await host.startChecked()

        do {
            let clientInstanceID = UUID()
            let client = TrustedBridgeClientFixture.make(
                socketPath: socketPath,
                operationClientInstanceID: clientInstanceID)
            let handshake = try await client.handshake(client: Self.clientIdentity)
            let listener = try #require(handshake.operationAttestation)
            let session = try #require(handshake.operationSessionAttestation)
            let foreignSessionID = UUID()
            let foreignSequence = PeekabooBridgeOperationSessionSequence(0)
            let foreign = PeekabooBridgeAttestedOperationRequest(
                requestID: PeekabooBridgeOperationReceiptCoding.deterministicRequestID(
                    sessionID: foreignSessionID,
                    sequence: foreignSequence),
                sessionID: foreignSessionID,
                sessionSequence: foreignSequence,
                expectedListenerInstanceID: listener.listenerInstanceID,
                clientInstanceID: clientInstanceID,
                client: session.client,
                request: .permissionsStatus)
            let foreignResponse = try Self.exchangeRaw(
                .attestedOperation(foreign),
                socketPath: socketPath)
            guard case let .error(error) = foreignResponse else {
                Issue.record("Expected foreign-session authorization refusal")
                await host.stop()
                return
            }
            #expect(error.code == .unauthorizedClient)

            var requestMilliseconds: [Double] = []
            for _ in 0..<20 {
                let start = Date()
                guard case .permissionsStatus = try await client.send(.permissionsStatus) else {
                    Issue.record("Expected permissions response")
                    continue
                }
                requestMilliseconds.append(Date().timeIntervalSince(start) * 1000)
                #expect(await client.lastOperationReceipt() != nil)
            }
            guard requestMilliseconds.count == 20 else {
                Issue.record("Expected all hot requests to complete")
                await host.stop()
                return
            }
            requestMilliseconds.sort()
            let median = requestMilliseconds[requestMilliseconds.count / 2]
            let percentile95 = requestMilliseconds[Int(Double(requestMilliseconds.count - 1) * 0.95)]
            print(String(format: "hot read-only socket median %.3f ms p95 %.3f ms", median, percentile95))
            #expect(probe.liveCaptureCount == 22)
            #expect(probe.coldAuthorizationCount == 1)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `protocol 1 28 handshake and raw requests remain cold`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pblc-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AuthenticationProbe()
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { fd in
                let identity = try PeekabooBridgeSocketIO.livePeerIdentity(fd: fd)
                probe.recordLiveCapture()
                return identity
            },
            coldPeer: { identity, _ in
                probe.recordColdAuthorization()
                return PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: "dev.peekaboo.hot-auth-tests",
                    teamIdentifier: nil)
            }))
        try await host.startChecked()

        do {
            let client = PeekabooBridgeClient(socketPath: socketPath)
            let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
            let handshake = try await client.handshake(
                client: Self.clientIdentity,
                protocolVersion: version)
            #expect(handshake.negotiatedVersion == version)
            guard case .permissionsStatus = try await client.send(.permissionsStatus) else {
                Issue.record("Expected permissions response")
                await host.stop()
                return
            }
            #expect(await client.lastOperationReceipt() == nil)
            #expect(probe.liveCaptureCount == 2)
            #expect(probe.coldAuthorizationCount == 2)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `custom socket without host trust caps default negotiation at protocol 1 28`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbct-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = PeekabooBridgeClient(socketPath: socketPath)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.negotiatedVersion == .init(major: 1, minor: 28))
        #expect(handshake.operationAttestation == nil)
        #expect(handshake.operationSessionAttestation == nil)
    }

    @Test
    func `custom socket explicit host trust authenticates protocol 1 29`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbet-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion)
        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.attestedOperationReceiptVersion)
        #expect(handshake.operationAttestation != nil)
        #expect(handshake.operationSessionAttestation != nil)
    }

    @Test
    func `untrusted version mismatch cannot downgrade a trusted client to protocol 1 28`() async throws {
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            signingTeamIdentifier: "UNTRUSTED-TEST-HOST")

        do {
            let handshake = Task {
                try await client.handshake(
                    client: Self.clientIdentity,
                    protocolVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion)
            }
            let request = try await peer.nextRequest()
            guard case let .handshake(payload) = try request.decode() else {
                Issue.record("Expected protocol 1.29 handshake request")
                await peer.stop()
                return
            }
            #expect(payload.protocolVersion == PeekabooBridgeConstants.attestedOperationReceiptVersion)
            try await peer.respond(
                .error(.init(code: .versionMismatch, message: "Malicious downgrade response")),
                to: request)
            do {
                _ = try await handshake.value
                Issue.record("Untrusted host forced a protocol 1.28 fallback")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                #expect(envelope.code == .unauthorizedClient)
            }
            #expect(await peer.acceptedConnectionCount == 1)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `trusted explicit protocol 1 28 rejects an untrusted connected host`() async throws {
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            signingTeamIdentifier: "UNTRUSTED-TEST-HOST")

        do {
            let handshake = Task {
                try await client.handshake(
                    client: Self.clientIdentity,
                    protocolVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 28))
            }
            let request = try await peer.nextRequest()
            try await peer.respond(.handshake(Self.legacyHandshake()), to: request)
            do {
                _ = try await handshake.value
                Issue.record("Trusted legacy handshake accepted an untrusted connected host")
            } catch let envelope as PeekabooBridgeErrorEnvelope {
                #expect(envelope.code == .unauthorizedClient)
            }
            #expect(await peer.acceptedConnectionCount == 1)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `trusted protocol fallback authenticates and preserves legacy behavior`() async throws {
        let peer = try ConcurrentGatedBridgePeer()
        let client = TrustedBridgeClientFixture.make(socketPath: peer.socketPath)
        let previousVersion = bridgeFallbackVersion(distance: 1)
        let legacyAttemptVersion = bridgeFallbackVersion(distance: 2)

        do {
            let handshake = Task { try await client.handshake(client: Self.clientIdentity) }
            let currentRequest = try await peer.nextRequest()
            try await peer.respond(
                .error(.init(code: .versionMismatch, message: "Legacy trusted host")),
                to: currentRequest)
            let previousRequest = try await peer.nextRequest()
            guard case let .handshake(previousPayload) = try previousRequest.decode() else {
                Issue.record("Expected the preceding trusted protocol fallback request")
                await peer.stop()
                return
            }
            #expect(previousPayload.protocolVersion == previousVersion)
            try await peer.respond(
                .error(.init(code: .versionMismatch, message: "Preceding protocol unavailable")),
                to: previousRequest)
            let legacyRequest = try await peer.nextRequest()
            guard case let .handshake(legacyPayload) = try legacyRequest.decode() else {
                Issue.record("Expected the second trusted protocol fallback request")
                await peer.stop()
                return
            }
            #expect(legacyPayload.protocolVersion == legacyAttemptVersion)
            try await peer.respond(.handshake(Self.legacyHandshake()), to: legacyRequest)
            let response = try await handshake.value
            #expect(response.negotiatedVersion == .init(major: 1, minor: 28))

            let rawCall = Task { try await client.send(.permissionsStatus) }
            let rawRequest = try await peer.nextRequest()
            guard case .permissionsStatus = try rawRequest.decode() else {
                Issue.record("Trusted legacy fallback did not preserve raw request behavior")
                await peer.stop()
                return
            }
            try await peer.respond(
                .permissionsStatus(.init(screenRecording: true, accessibility: true, postEvent: true)),
                to: rawRequest)
            guard case .permissionsStatus = try await rawCall.value else {
                Issue.record("Expected trusted raw legacy response")
                await peer.stop()
                return
            }
            #expect(await client.lastOperationReceipt() == nil)
            #expect(await peer.acceptedConnectionCount == 4)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    @Test
    func `trusted protocol 1 28 refuses listener identity replacement before mutation bytes`() async throws {
        for drift in LegacyListenerIdentityDrift.allCases {
            let peer = try ConcurrentGatedBridgePeer(socketPathPrefix: "pb-legacy-listener-\(drift.rawValue)")
            let identityProvider = LegacyListenerIdentityProvider(drift: drift)
            let client = PeekabooBridgeClient(
                socketPath: peer.socketPath,
                requestTimeoutSec: 1,
                trustedHostTeamIDs: [TrustedBridgeClientFixture.teamIdentifier],
                hostAuthentication: .init(
                    liveIdentity: { fd in try identityProvider.identity(fd: fd) },
                    signingIdentity: { auditIdentity in
                        guard let hash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                            auditIdentity: auditIdentity)
                        else { return nil }
                        return PeekabooBridgeHost.PeerSigningIdentity(
                            bundleIdentifier: "dev.peekaboo.test-host",
                            teamIdentifier: TrustedBridgeClientFixture.teamIdentifier,
                            codeSignatureHash: hash)
                    }))

            do {
                let handshake = Task {
                    try await client.handshake(
                        client: Self.clientIdentity,
                        protocolVersion: .init(major: 1, minor: 28))
                }
                let handshakeRequest = try await peer.nextRequest()
                try await peer.respond(.handshake(Self.legacyHandshake()), to: handshakeRequest)
                _ = try await handshake.value

                do {
                    try await client.sendExpectOK(.requestPostEventPermission)
                    Issue.record("Legacy listener \(drift.rawValue) replacement reached mutation dispatch")
                } catch let failure as DesktopActionFailure {
                    #expect(failure.outcome.state == .refused)
                    #expect(failure.outcome.dispatchState == .none)
                    #expect(failure.outcome.retrySafety == .safe)
                    #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
                }
                #expect(identityProvider.lookupCount == 2)
                try await Self.expectEmptyReplacementConnection(peer, handshake: handshakeRequest)
                #expect(await peer.acceptedConnectionCount == 2)

                do {
                    try await client.sendExpectOK(.requestPostEventPermission)
                    Issue.record("A replaced legacy listener remained authorized")
                } catch let failure as DesktopActionFailure {
                    #expect(failure.outcome.state == .refused)
                    #expect(failure.outcome.dispatchState == .none)
                    #expect(failure.outcome.retrySafety == .safe)
                    #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
                }
                #expect(identityProvider.lookupCount == 2)
                #expect(await peer.acceptedConnectionCount == 2)
                #expect(await peer.requests == [handshakeRequest.data])
            } catch {
                await peer.stop()
                throw error
            }
            await peer.stop()
        }
    }

    @Test
    func `protocol 1 29 rejects wrong team and same peer without anchored signing`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbwt-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let wrongTeam = TrustedBridgeClientFixture.make(
            socketPath: socketPath,
            signingTeamIdentifier: "OTHER-TEST-HOST")
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await wrongTeam.handshake(client: Self.clientIdentity)
        }

        let untrusted = PeekabooBridgeClient(
            socketPath: socketPath,
            trustedHostTeamIDs: [TrustedBridgeClientFixture.teamIdentifier],
            hostAuthentication: .init(signingIdentity: { _ in nil }))
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await untrusted.handshake(client: Self.clientIdentity)
        }
    }

    @Test
    func `protocol 1 29 rejects a self signed listener that contradicts the socket peer`() async throws {
        let clientInstanceID = UUID()
        let forgedHandshake = try Self.forgedHandshake(clientInstanceID: clientInstanceID)
        let peer = try ScriptedBridgePeer(responses: [.handshake(forgedHandshake)])
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            operationClientInstanceID: clientInstanceID)

        do {
            await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                _ = try await client.handshake(client: Self.clientIdentity)
            }
        }
        await peer.stop()
    }

    @Test
    func `nil CDHash debug client can use protocol 1 28 but cannot create a 1 29 session`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbuc-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: ["SIGNED-CLIENTS-ONLY"])
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { fd in
                try PeekabooBridgeSocketIO.livePeerIdentity(
                    fd: fd,
                    codeSignatureHashProvider: { _ in nil })
            },
            coldPeer: { identity, allowedTeamIDs in
                PeekabooBridgeHost.peerInfoIfAllowed(
                    liveIdentity: identity,
                    allowedTeamIDs: allowedTeamIDs,
                    signingIdentityProvider: { _ in nil },
                    allowUnsignedSocketClients: true)
            }))
        try await host.startChecked()

        do {
            let legacyClient = PeekabooBridgeClient(socketPath: socketPath)
            let legacyVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
            let handshake = try await legacyClient.handshake(
                client: Self.clientIdentity,
                protocolVersion: legacyVersion)
            #expect(handshake.negotiatedVersion == legacyVersion)
            guard case .permissionsStatus = try await legacyClient.send(.permissionsStatus) else {
                Issue.record("Expected a receiptless legacy response")
                await host.stop()
                return
            }
            #expect(await legacyClient.lastOperationReceipt() == nil)

            let currentClient = TrustedBridgeClientFixture.make(socketPath: socketPath)
            do {
                _ = try await currentClient.handshake(client: Self.clientIdentity)
                Issue.record("Expected protocol 1.29 session creation to reject a nil CDHash")
            } catch let error as PeekabooBridgeErrorEnvelope {
                #expect(error.code == .unauthorizedClient)
            }
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `listener restart invalidates stale session before cold recovery handshake`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbrc-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AuthenticationProbe()
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { fd in
                let identity = try PeekabooBridgeSocketIO.livePeerIdentity(fd: fd)
                probe.recordLiveCapture()
                return identity
            },
            coldPeer: { identity, _ in
                probe.recordColdAuthorization()
                return PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: "dev.peekaboo.hot-auth-tests",
                    teamIdentifier: nil)
            }))
        try await host.startChecked()
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)

        do {
            _ = try await client.handshake(client: Self.clientIdentity)
            _ = try await client.send(.permissionsStatus)
            #expect(await host.stop() == .stopped)
            try await host.startChecked()

            do {
                _ = try await client.send(.permissionsStatus)
                Issue.record("Expected the stale listener session to be invalidated")
            } catch {
                #expect(probe.coldAuthorizationCount == 2)
            }
            do {
                _ = try await client.send(.permissionsStatus)
                Issue.record("Expected a later operation to require a fresh handshake")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                #expect(error == .handshakeRequired)
                #expect(probe.coldAuthorizationCount == 2)
            }
            let restarted = try await client.handshake(client: Self.clientIdentity)
            #expect(restarted.operationSessionAttestation?.predecessorSessionID == nil)
            guard case .permissionsStatus = try await client.send(.permissionsStatus) else {
                Issue.record("Expected cold handshake recovery followed by a hot request")
                await host.stop()
                return
            }
            // Recovery first offers the disabled predecessor, then falls back to a fresh session because the
            // restarted listener cannot own that predecessor.
            #expect(probe.coldAuthorizationCount == 4)
            #expect(await client.lastOperationReceipt() != nil)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }
}

extension PeekabooBridgeOperationSessionAuthenticationTests {
    @Test
    func `exact session lookup rejects every live identity mismatch without consuming sequence`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-hot-auth-mismatch-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let exact = try #require(session.peer.liveIdentity)
        #expect(authority.hasProvisionalSession(for: exact))
        let exactAuthorization = try #require(authority.authorizeSession(
            sessionID: session.attestation.sessionID,
            liveIdentity: exact))
        exactAuthorization.pin.release()

        let missingCodeSignatureHash = PeekabooBridgeLivePeerIdentity(
            auditToken: exact.auditToken,
            processIdentifier: exact.processIdentifier,
            processIdentifierVersion: exact.processIdentifierVersion,
            effectiveUserIdentifier: exact.effectiveUserIdentifier,
            processStartIdentity: exact.processStartIdentity,
            codeSignatureHash: nil)
        #expect(!authority.hasProvisionalSession(for: missingCodeSignatureHash))
        #expect(authority.authorizeSession(
            sessionID: session.attestation.sessionID,
            liveIdentity: missingCodeSignatureHash) == nil)

        var changedToken = exact.auditToken
        changedToken[changedToken.startIndex] ^= 0x01
        let mismatches = [
            Self.copy(exact, auditToken: changedToken),
            Self.copy(exact, processIdentifier: exact.processIdentifier + 1),
            Self.copy(exact, processIdentifierVersion: exact.processIdentifierVersion + 1),
            Self.copy(exact, effectiveUserIdentifier: exact.effectiveUserIdentifier + 1),
            Self.copy(exact, processStartIdentity: exact.processStartIdentity + 1),
            Self.copy(exact, codeSignatureHash: "different-cdhash"),
        ]
        for mismatch in mismatches {
            #expect(!authority.hasProvisionalSession(for: mismatch))
            #expect(authority.authorizeSession(
                sessionID: session.attestation.sessionID,
                liveIdentity: mismatch) == nil)
        }
        #expect(authority.authorizeSession(sessionID: UUID(), liveIdentity: exact) == nil)

        let claimed = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        authority.complete(claimed.claim)
    }

    @Test
    func `authorization pin keeps a retired session claimable during prune pressure`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-hot-auth-pin-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 6,
            retainedRetiredSessionCount: 1)
        let predecessor = try await OperationReceiptSessionFixture.make(authority: authority)
        try authority.retireSession(
            predecessor.attestation.sessionID,
            clientInstanceID: predecessor.clientInstanceID,
            peer: predecessor.peer)
        let liveIdentity = try #require(predecessor.peer.liveIdentity)
        let authorization = try #require(authority.authorizeSession(
            sessionID: predecessor.attestation.sessionID,
            liveIdentity: liveIdentity))

        for _ in 0..<2 {
            let pressure = try await OperationReceiptSessionFixture.make(authority: authority)
            try authority.retireSession(
                pressure.attestation.sessionID,
                clientInstanceID: pressure.clientInstanceID,
                peer: pressure.peer)
        }
        #expect(authority.hasProvisionalSession(for: liveIdentity))
        let request = predecessor.request(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        guard case .rolloverRequired = try await authority.claim(request, peer: authorization.peer) else {
            Issue.record("Expected retained predecessor to reach signed rollover")
            authorization.pin.release()
            return
        }
        authorization.pin.release()
    }

    @Test
    func `same PID exec generations reclaim quiescent session capacity`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-hot-auth-exec-reclaim-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path,
            maximumClaimCount: 4,
            maximumSessionCount: 6,
            maximumActiveSessionCountPerPeer: 2,
            retainedRetiredSessionCount: 1)
        let originalPeer = try OperationReceiptSessionFixture.currentPeer()
        _ = try await OperationReceiptSessionFixture.make(authority: authority, peer: originalPeer)
        _ = try await OperationReceiptSessionFixture.make(authority: authority, peer: originalPeer)

        let replacementPeer = try Self.peerByAdvancingPIDVersion(originalPeer, by: 1)
        let firstReplacement = try await OperationReceiptSessionFixture.make(
            authority: authority,
            peer: replacementPeer)
        let secondReplacement = try await OperationReceiptSessionFixture.make(
            authority: authority,
            peer: replacementPeer)
        #expect(firstReplacement.attestation.client == secondReplacement.attestation.client)
        #expect(firstReplacement.attestation.sessionID != secondReplacement.attestation.sessionID)

        let laterPeer = try Self.peerByAdvancingPIDVersion(replacementPeer, by: 1)
        _ = try await OperationReceiptSessionFixture.make(authority: authority, peer: laterPeer)
        let usable = try await OperationReceiptSessionFixture.make(authority: authority, peer: laterPeer)
        let claim = try await usable.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        authority.complete(claim.claim)
    }

    @Test
    func `live peer capture keeps exact generation when CDHash is unavailable`() throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }
        let unsigned = try PeekabooBridgeSocketIO.livePeerIdentity(
            fd: descriptors[0],
            codeSignatureHashProvider: { _ in nil })
        #expect(unsigned.processIdentifier == getpid())
        #expect(unsigned.processIdentifierVersion == unsigned.auditIdentity?.processIdentifierVersion)
        #expect(unsigned.effectiveUserIdentifier == geteuid())
        #expect(unsigned.processStartIdentity > 0)
        #expect(unsigned.codeSignatureHash == nil)
        #expect(unsigned.auditIdentity != nil)

        let start = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let driftProbe = ProcessStartDriftProbe(first: start, second: start + 1)
        #expect(throws: POSIXError.self) {
            try PeekabooBridgeSocketIO.livePeerIdentity(
                fd: descriptors[0],
                processStartIdentityProvider: { _ in driftProbe.next() },
                codeSignatureHashProvider: { _ in "0123456789012345678901234567890123456789" })
        }
        #expect(driftProbe.count == 2)
    }

    @Test
    func `hot live evidence and session lookup remain exact across repeated authorization`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-hot-auth-timing-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer {
            close(descriptors[0])
            close(descriptors[1])
        }

        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let processStartProbe = ProcessStartDriftProbe(first: processStartIdentity, second: processStartIdentity)
        var samples: [Double] = []
        for _ in 0..<200 {
            let start = Date()
            let liveIdentity = try PeekabooBridgeSocketIO.livePeerIdentity(
                fd: descriptors[0],
                processStartIdentityProvider: { _ in processStartProbe.next() })
            guard authority.hasProvisionalSession(for: liveIdentity),
                  let authorization = authority.authorizeSession(
                      sessionID: session.attestation.sessionID,
                      liveIdentity: liveIdentity)
            else {
                Issue.record("Expected exact hot session authorization")
                return
            }
            authorization.pin.release()
            samples.append(Date().timeIntervalSince(start) * 1000)
        }
        samples.sort()
        let median = samples[samples.count / 2]
        let percentile95 = samples[Int(Double(samples.count - 1) * 0.95)]
        print(String(format: "hot peer auth median %.3f ms p95 %.3f ms", median, percentile95))
        #expect(samples.count == 200)
        #expect(processStartProbe.count == 400)

        // Authorization lookup and pin release must not consume replay state.
        let firstClaim = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        #expect(firstClaim.claim.sessionSequence == .init(0))
        authority.complete(firstClaim.claim)
    }

    @Test
    func `malformed duplicate and oversized requests stay bounded without poisoning auth`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbmb-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AuthenticationProbe()
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            maxMessageBytes: 4096,
            allowedTeamIDs: [])
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { fd in
                let identity = try PeekabooBridgeSocketIO.livePeerIdentity(fd: fd)
                probe.recordLiveCapture()
                return identity
            },
            coldPeer: { identity, _ in
                probe.recordColdAuthorization()
                return PeekabooBridgePeer(
                    liveIdentity: identity,
                    bundleIdentifier: nil,
                    teamIdentifier: nil)
            }))
        try await host.startChecked()

        do {
            let malformed = try Self.exchangeRawData(
                Data(#"{"permissionsStatus":"#.utf8),
                socketPath: socketPath)
            guard case let .error(malformedError) = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: malformed)
            else {
                Issue.record("Expected malformed request error")
                await host.stop()
                return
            }
            #expect(malformedError.code == .decodingFailed)

            let duplicate = try Self.exchangeRawData(
                Data(#"{"permissionsStatus":{},"permissionsStatus":{}}"#.utf8),
                socketPath: socketPath)
            guard case let .error(duplicateError) = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: duplicate)
            else {
                Issue.record("Expected duplicate-key request error")
                await host.stop()
                return
            }
            #expect(duplicateError.code == .invalidRequest)

            #expect(throws: (any Error).self) {
                let response = try Self.exchangeRawData(
                    Data(repeating: UInt8(ascii: "x"), count: 4097),
                    socketPath: socketPath)
                guard !response.isEmpty else { throw POSIXError(.EMSGSIZE) }
                _ = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: response)
            }

            let client = PeekabooBridgeClient(socketPath: socketPath)
            let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)
            #expect(try await client.handshake(
                client: Self.clientIdentity,
                protocolVersion: version).negotiatedVersion == version)
            #expect(probe.coldAuthorizationCount == 4)
            #expect(probe.liveCaptureCount == 4)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `unauthorized socket fails before a slow client sends a body`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbuf-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = AuthenticationProbe()
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: ["UNTRUSTED"])
        await host.setAuthenticationForTesting(.init(
            liveIdentity: { fd in
                let identity = try PeekabooBridgeSocketIO.livePeerIdentity(fd: fd)
                probe.recordLiveCapture()
                return identity
            },
            coldPeer: { _, _ in
                probe.recordColdAuthorization()
                return nil
            }))
        try await host.startChecked()

        do {
            let fd = try Self.connectRawClient(to: socketPath, deadline: Date().addingTimeInterval(1))
            defer { close(fd) }
            let responseData = try PeekabooBridgeSocketIO.readAll(
                fd: fd,
                maxBytes: 1024 * 1024,
                deadline: Date().addingTimeInterval(1))
            guard case let .error(error) = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: responseData)
            else {
                Issue.record("Expected immediate unauthorized response")
                await host.stop()
                return
            }
            #expect(error.code == .unauthorizedClient)
            #expect(probe.liveCaptureCount == 1)
            #expect(probe.coldAuthorizationCount == 1)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `single value only decode is the exact value dispatched`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: false, postEvent: true)
                })
        }
        let bytes = try JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.permissionsStatus)
        let request = try await server.decodeRequest(bytes)
        #expect(request.operation == .permissionsStatus)
        let responseData = await server.handleDecoded(request, peer: nil)
        guard case let .permissionsStatus(status) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        else {
            Issue.record("Expected the decoded permissions request to be dispatched unchanged")
            return
        }
        #expect(status.screenRecording)
        #expect(!status.accessibility)
    }

    @Test
    func `handshake payload cannot replace missing trusted peer bundle metadata`() async throws {
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(),
                allowlistedTeams: [],
                allowlistedBundles: ["boo.peekaboo.trusted"])
        }
        let peer = try OperationReceiptSessionFixture.currentPeer()
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: .init(major: 1, minor: 28),
            client: .init(
                bundleIdentifier: "boo.peekaboo.trusted",
                teamIdentifier: nil,
                processIdentifier: getpid())))
        let responseData = await server.handleDecoded(request, peer: peer)
        guard case let .error(error) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: responseData)
        else {
            Issue.record("Expected peer-owned bundle authorization to reject payload fallback")
            return
        }
        #expect(error.code == .unauthorizedClient)
    }

    @Test
    func `unsigned raw success clears stale session only for a later handshake`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-raw-success-session-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        let listener = authority.attestation
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "raw-success-test",
            supportedOperations: [.permissionsStatus],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus],
            hostIdentity: .init(
                processIdentifier: listener.host.processIdentifier,
                processStartIdentity: listener.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.raw-success-test",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: listener.host.codeSignatureHash,
                sourceCommit: String(repeating: "a", count: 40)),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: listener,
            operationSessionAttestation: session.attestation)
        let claimed = try await session.acceptedClaim(
            authority: authority,
            sequence: 0,
            request: .permissionsStatus)
        authority.complete(claimed.claim)
        let successor = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: session.clientInstanceID,
            peer: session.peer,
            replacing: session.attestation.sessionID)
        let successorHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "raw-success-test",
            supportedOperations: [.permissionsStatus],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus],
            hostIdentity: .init(
                processIdentifier: listener.host.processIdentifier,
                processStartIdentity: listener.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.raw-success-test",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: listener.host.codeSignatureHash,
                sourceCommit: String(repeating: "a", count: 40)),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: listener,
            operationSessionAttestation: successor.attestation)
        let peer = try ScriptedBridgePeer(responses: [.handshake(handshake), .ok, .handshake(successorHandshake)])
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            operationClientInstanceID: session.clientInstanceID,
            signingSourceCommit: String(repeating: "a", count: 40))

        do {
            _ = try await client.handshake(client: Self.clientIdentity)
            let authenticatedHost = try #require(await client.authenticatedHostIdentity())
            #expect(authenticatedHost.signingIdentifier == "dev.peekaboo.test-host")
            #expect(authenticatedHost.teamIdentifier == TrustedBridgeClientFixture.teamIdentifier)
            #expect(authenticatedHost.codeSignatureHash == listener.host.codeSignatureHash)
            #expect(authenticatedHost.sourceCommit == String(repeating: "a", count: 40))
            do {
                _ = try await client.send(.permissionsStatus)
                Issue.record("Expected unsigned success to remain an invalid lost response")
            } catch {
                #expect(error is PeekabooBridgeOperationReceiptError)
            }
            do {
                _ = try await client.send(.permissionsStatus)
                Issue.record("Expected a later request to require a cold handshake")
            } catch let error as PeekabooBridgeClientOperationSessionError {
                #expect(error == .handshakeRequired)
            }
            let recovered = try await client.handshake(client: Self.clientIdentity)
            #expect(recovered.operationSessionAttestation?.sessionID == successor.attestation.sessionID)
            #expect(recovered.operationSessionAttestation?.predecessorSessionID == session.attestation.sessionID)
            let requests = await peer.requests
            guard case let .handshake(replacement) = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeRequest.self,
                from: #require(requests.last))
            else {
                Issue.record("Expected the explicit recovery handshake")
                await peer.stop()
                return
            }
            #expect(replacement.replacingOperationSessionID == session.attestation.sessionID)
            #expect(await peer.acceptedConnectionCount == 3)
        } catch {
            await peer.stop()
            throw error
        }
        await peer.stop()
    }

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.hot-auth-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    private static func legacyHandshake() -> PeekabooBridgeHandshakeResponse {
        BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 28),
            hostKind: .gui,
            build: "trusted-legacy-test",
            supportedOperations: [.permissionsStatus, .requestPostEventPermission],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus, .requestPostEventPermission],
            hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])
    }

    private static func forgedHandshake(clientInstanceID: UUID) throws -> PeekabooBridgeHandshakeResponse {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let actualStart = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let actualHash = try #require(PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
            processIdentifier: getpid()))
        let forgedHost = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: getpid() + 1,
            processStartIdentity: actualStart + 1,
            codeSignatureHash: String(repeating: "a", count: 40))
        let listenerUnsigned = PeekabooBridgeListenerAttestation.UnsignedPayload(
            schemaVersion: 1,
            listenerInstanceID: UUID(),
            publicKey: publicKey,
            host: forgedHost,
            createdAtUnixMilliseconds: PeekabooBridgeOperationReceiptCoding.unixMilliseconds(),
            receiptArchiveDirectory: "/tmp/forged-peekaboo-listener")
        let listener = try PeekabooBridgeListenerAttestation(
            listenerInstanceID: listenerUnsigned.listenerInstanceID,
            publicKey: publicKey,
            host: forgedHost,
            createdAtUnixMilliseconds: listenerUnsigned.createdAtUnixMilliseconds,
            receiptArchiveDirectory: listenerUnsigned.receiptArchiveDirectory,
            signature: privateKey.signature(
                for: PeekabooBridgeOperationReceiptCoding.canonicalData(listenerUnsigned)))
        let client = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: actualStart,
            codeSignatureHash: actualHash)
        let sessionUnsigned = PeekabooBridgeOperationSessionAttestation.UnsignedPayload(
            schemaVersion: 1,
            sessionID: UUID(),
            listenerInstanceID: listener.listenerInstanceID,
            listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(publicKey),
            clientInstanceID: clientInstanceID,
            client: client,
            maximumRequestCount: 32,
            remainingClaimCount: 32,
            predecessorSessionID: nil,
            createdAtUnixMilliseconds: PeekabooBridgeOperationReceiptCoding.unixMilliseconds())
        let session = try PeekabooBridgeOperationSessionAttestation(
            sessionID: sessionUnsigned.sessionID,
            listenerInstanceID: sessionUnsigned.listenerInstanceID,
            listenerPublicKeySHA256: sessionUnsigned.listenerPublicKeySHA256,
            clientInstanceID: sessionUnsigned.clientInstanceID,
            client: sessionUnsigned.client,
            maximumRequestCount: sessionUnsigned.maximumRequestCount,
            remainingClaimCount: sessionUnsigned.remainingClaimCount,
            predecessorSessionID: nil,
            createdAtUnixMilliseconds: sessionUnsigned.createdAtUnixMilliseconds,
            signature: privateKey.signature(
                for: PeekabooBridgeOperationReceiptCoding.canonicalData(sessionUnsigned)))
        return BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "forged-listener",
            supportedOperations: [.permissionsStatus],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [.permissionsStatus],
            hostIdentity: .init(
                processIdentifier: forgedHost.processIdentifier,
                processStartIdentity: forgedHost.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.forged",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: forgedHost.codeSignatureHash),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: listener,
            operationSessionAttestation: session)
    }

    private static func peerByAdvancingPIDVersion(
        _ peer: PeekabooBridgePeer,
        by delta: Int32) throws -> PeekabooBridgePeer
    {
        let liveIdentity = try #require(peer.liveIdentity)
        let nextVersion = liveIdentity.processIdentifierVersion + delta
        var token = liveIdentity.auditToken
        var encodedVersion = nextVersion
        let versionData = withUnsafeBytes(of: &encodedVersion) { Data($0) }
        let versionRange = (token.count - versionData.count)..<token.count
        token.replaceSubrange(versionRange, with: versionData)
        let replacement = PeekabooBridgeLivePeerIdentity(
            auditToken: token,
            processIdentifier: liveIdentity.processIdentifier,
            processIdentifierVersion: nextVersion,
            effectiveUserIdentifier: liveIdentity.effectiveUserIdentifier,
            processStartIdentity: liveIdentity.processStartIdentity,
            codeSignatureHash: liveIdentity.codeSignatureHash)
        _ = try #require(replacement.auditIdentity)
        return PeekabooBridgePeer(
            liveIdentity: replacement,
            bundleIdentifier: peer.bundleIdentifier,
            teamIdentifier: peer.teamIdentifier)
    }

    private static func copy(
        _ identity: PeekabooBridgeLivePeerIdentity,
        auditToken: Data? = nil,
        processIdentifier: pid_t? = nil,
        processIdentifierVersion: Int32? = nil,
        effectiveUserIdentifier: uid_t? = nil,
        processStartIdentity: UInt64? = nil,
        codeSignatureHash: String? = nil) -> PeekabooBridgeLivePeerIdentity
    {
        PeekabooBridgeLivePeerIdentity(
            auditToken: auditToken ?? identity.auditToken,
            processIdentifier: processIdentifier ?? identity.processIdentifier,
            processIdentifierVersion: processIdentifierVersion ?? identity.processIdentifierVersion,
            effectiveUserIdentifier: effectiveUserIdentifier ?? identity.effectiveUserIdentifier,
            processStartIdentity: processStartIdentity ?? identity.processStartIdentity,
            codeSignatureHash: codeSignatureHash ?? identity.codeSignatureHash)
    }

    private static func exchangeRaw(
        _ request: PeekabooBridgeRequest,
        socketPath: String) throws -> PeekabooBridgeResponse
    {
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = try self.exchangeRawData(requestData, socketPath: socketPath)
        return try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: responseData)
    }

    private static func exchangeRawData(_ requestData: Data, socketPath: String) throws -> Data {
        let deadline = Date().addingTimeInterval(2)
        let fd = try self.connectRawClient(to: socketPath, deadline: deadline)
        defer { close(fd) }
        try PeekabooBridgeSocketIO.writeAll(fd: fd, data: requestData, deadline: deadline)
        guard shutdown(fd, SHUT_WR) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return try PeekabooBridgeSocketIO.readAll(
            fd: fd,
            maxBytes: 1024 * 1024,
            deadline: deadline)
    }

    private static func connectRawClient(to socketPath: String, deadline: Date) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try PeekabooBridgeSocketIO.configureConnectedSocket(fd)
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
            let capacity = MemoryLayout.size(ofValue: address.sun_path)
            let copied = socketPath.withCString { source in
                strlcpy(&address.sun_path.0, source, capacity)
            }
            guard copied < capacity else { throw POSIXError(.ENAMETOOLONG) }
            let length = socklen_t(MemoryLayout.size(ofValue: address))
            let result = withUnsafePointer(to: &address) { pointer in
                Darwin.connect(fd, UnsafePointer<sockaddr>(OpaquePointer(pointer)), length)
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EALREADY else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
                }
                try PeekabooBridgeSocketIO.finishConnect(fd: fd, deadline: deadline)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }
}

enum TrustedBridgeClientFixture {
    static let teamIdentifier = "PEEKABOO-TEST-HOST"

    static func make(
        socketPath: String,
        maxResponseBytes: Int = 64 * 1024 * 1024,
        requestTimeoutSec: TimeInterval = 10,
        operationReceiptExportDirectory: URL? = nil,
        operationClientInstanceID: UUID = UUID(),
        trustedHostTeamIDs: Set<String> = [TrustedBridgeClientFixture.teamIdentifier],
        signingTeamIdentifier: String = TrustedBridgeClientFixture.teamIdentifier,
        signingSourceCommit: String? = nil) -> PeekabooBridgeClient
    {
        PeekabooBridgeClient(
            socketPath: socketPath,
            maxResponseBytes: maxResponseBytes,
            requestTimeoutSec: requestTimeoutSec,
            operationReceiptExportDirectory: operationReceiptExportDirectory,
            operationClientInstanceID: operationClientInstanceID,
            trustedHostTeamIDs: trustedHostTeamIDs,
            hostAuthentication: .init(signingIdentity: { auditIdentity in
                guard let hash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                    auditIdentity: auditIdentity)
                else { return nil }
                return PeekabooBridgeHost.PeerSigningIdentity(
                    bundleIdentifier: "dev.peekaboo.test-host",
                    teamIdentifier: signingTeamIdentifier,
                    codeSignatureHash: hash,
                    sourceCommit: signingSourceCommit)
            }))
    }
}

extension PeekabooBridgeOperationSessionAuthenticationTests {
    fileprivate static func expectEmptyReplacementConnection(
        _ peer: ConcurrentGatedBridgePeer,
        handshake: ConcurrentGatedBridgePeer.Request) async throws
    {
        let reads = try await peer.waitForReadCompletions(2)
        try #require(reads.count == 2)
        let allReadsReachedEOF = reads.allSatisfy(\.reachedEOF)
        #expect(allReadsReachedEOF)
        #expect(reads.first?.connectionID == handshake.id)
        #expect(reads.map(\.byteCount) == [handshake.data.count, 0])
        #expect(await peer.requests == [handshake.data])
    }
}

private enum LegacyListenerIdentityDrift: String, CaseIterable {
    case processIdentifier = "pid"
    case processStartIdentity = "generation"
    case codeSignatureHash = "cdhash"
}

private final class LegacyListenerIdentityProvider: @unchecked Sendable {
    private let lock = NSLock()
    private let drift: LegacyListenerIdentityDrift
    private var count = 0

    var lookupCount: Int {
        self.lock.withLock { self.count }
    }

    init(drift: LegacyListenerIdentityDrift) {
        self.drift = drift
    }

    func identity(fd: Int32) throws -> PeekabooBridgeLivePeerIdentity {
        let identity = try PeekabooBridgeSocketIO.livePeerIdentity(fd: fd)
        let shouldDrift = self.lock.withLock {
            self.count += 1
            return self.count > 1
        }
        guard shouldDrift else { return identity }

        switch self.drift {
        case .processIdentifier:
            return PeekabooBridgeLivePeerIdentity(
                auditToken: identity.auditToken,
                processIdentifier: identity.processIdentifier + 1,
                processIdentifierVersion: identity.processIdentifierVersion,
                effectiveUserIdentifier: identity.effectiveUserIdentifier,
                processStartIdentity: identity.processStartIdentity,
                codeSignatureHash: identity.codeSignatureHash)
        case .processStartIdentity:
            return PeekabooBridgeLivePeerIdentity(
                auditToken: identity.auditToken,
                processIdentifier: identity.processIdentifier,
                processIdentifierVersion: identity.processIdentifierVersion,
                effectiveUserIdentifier: identity.effectiveUserIdentifier,
                processStartIdentity: identity.processStartIdentity + 1,
                codeSignatureHash: identity.codeSignatureHash)
        case .codeSignatureHash:
            return PeekabooBridgeLivePeerIdentity(
                auditToken: identity.auditToken,
                processIdentifier: identity.processIdentifier,
                processIdentifierVersion: identity.processIdentifierVersion,
                effectiveUserIdentifier: identity.effectiveUserIdentifier,
                processStartIdentity: identity.processStartIdentity,
                codeSignatureHash: identity.codeSignatureHash.map { $0 + "00" } ?? "replacement-cdhash")
        }
    }
}

private final class ProcessStartDriftProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let first: UInt64
    private let second: UInt64
    private var lookupCount = 0

    init(first: UInt64, second: UInt64) {
        self.first = first
        self.second = second
    }

    var count: Int {
        self.lock.withLock { self.lookupCount }
    }

    func next() -> UInt64 {
        self.lock.withLock {
            self.lookupCount += 1
            return self.lookupCount == 1 ? self.first : self.second
        }
    }
}

private final class AuthenticationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var liveCaptures = 0
    private var coldAuthorizations = 0

    var liveCaptureCount: Int {
        self.lock.withLock { self.liveCaptures }
    }

    var coldAuthorizationCount: Int {
        self.lock.withLock { self.coldAuthorizations }
    }

    func recordLiveCapture() {
        self.lock.withLock { self.liveCaptures += 1 }
    }

    func recordColdAuthorization() {
        self.lock.withLock { self.coldAuthorizations += 1 }
    }
}
