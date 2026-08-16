import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeClientTransportSafetyTests {
    @Test
    func `attested listener drift refuses mutation before request bytes are written`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-attested-listener-drift-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ScriptedBridgePeer(scripts: [
            [.respond(.handshake(Self.attestedHandshake(authority: authority, session: session.attestation)))],
            [.close],
        ])
        let identityProvider = DriftingListenerIdentityProvider()
        let client = PeekabooBridgeClient(
            socketPath: peer.socketPath,
            requestTimeoutSec: 1,
            operationClientInstanceID: clientInstanceID,
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
        _ = try await client.handshake(client: Self.clientIdentity)

        do {
            try await client.sendExpectOK(.requestPostEventPermission)
            Issue.record("Expected attested listener drift to refuse mutation dispatch")
        } catch let failure as DesktopActionFailure {
            Self.expectPreDispatchTransportUnavailable(failure)
        }
        await peer.waitUntilFinished()
        #expect(identityProvider.lookupCount == 2)
        #expect(await peer.acceptedConnectionCount == 2)
        let requests = await peer.requests
        #expect(requests.count == 2)
        #expect(requests.last?.isEmpty == true)
    }

    @Test
    func `attested connect failure is retry safe because no mutation bytes were dispatched`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-attested-connect-failure-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(Self.attestedHandshake(authority: authority, session: session.attestation)),
        ])
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 1,
            operationClientInstanceID: clientInstanceID)
        _ = try await client.handshake(client: Self.clientIdentity)
        await peer.waitUntilFinished()

        do {
            try await client.sendExpectOK(.requestPostEventPermission)
            Issue.record("Expected attested connect failure before mutation dispatch")
        } catch let failure as DesktopActionFailure {
            Self.expectPreDispatchTransportUnavailable(failure)
        }
    }

    @Test
    func `incomplete mutation write is retry safe because the host cannot decode a strict prefix`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-attested-incomplete-write-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let text = String(repeating: "x", count: 8 * 1024 * 1024)
        let handshake = Self.attestedHandshake(
            authority: authority,
            session: session.attestation,
            supportedOperation: .typeActions)
        let peer = try PrefixClosingBridgePeer(handshake: handshake, prefixLimit: 4096)
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 2,
            operationClientInstanceID: clientInstanceID)
        _ = try await client.handshake(client: Self.clientIdentity)
        let request = PeekabooBridgeRequest.typeActions(.init(
            actions: [.text(text)],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil))

        do {
            try await client.sendExpectOK(request)
            Issue.record("Expected the incomplete request write to fail before dispatch")
        } catch let failure as DesktopActionFailure {
            Self.expectPreDispatchTransportUnavailable(failure)
        }
        await peer.waitUntilFinished()

        let prefix = await peer.receivedPrefix
        #expect(!prefix.isEmpty)
        #expect(prefix.count < text.utf8.count)
        #expect(throws: (any Error).self) {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: prefix)
        }
    }

    @Test
    func `cancelling an incomplete mutation write stays a retry safe pre dispatch cancellation`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-attested-cancelled-write-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let clientInstanceID = UUID()
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            clientInstanceID: clientInstanceID)
        let text = String(repeating: "x", count: 8 * 1024 * 1024)
        let handshake = Self.attestedHandshake(
            authority: authority,
            session: session.attestation,
            supportedOperation: .typeActions)
        let peer = try PrefixClosingBridgePeer(
            handshake: handshake,
            prefixLimit: 4096,
            closeDelaySeconds: 1)
        let client = TrustedBridgeClientFixture.make(
            socketPath: peer.socketPath,
            requestTimeoutSec: 10,
            operationClientInstanceID: clientInstanceID)
        _ = try await client.handshake(client: Self.clientIdentity)
        let request = PeekabooBridgeRequest.typeActions(.init(
            actions: [.text(text)],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil))

        let requestTask = Task { try await client.sendExpectOK(request) }
        await peer.waitUntilPrefixReceived()
        requestTask.cancel()
        do {
            try await requestTask.value
            Issue.record("Expected cancellation while the incomplete request write was blocked")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .requestCancelled)
        }
        await peer.waitUntilFinished()

        let prefix = await peer.receivedPrefix
        #expect(!prefix.isEmpty)
        #expect(prefix.count < text.utf8.count)
        #expect(throws: (any Error).self) {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: prefix)
        }
    }

    @Test
    func `projected legacy mutation rejects a wrong response family without an outcome`() async throws {
        let peer = try Self.projectedReceiptlessPeer(response: .projectedAction(.init(
            response: .bool(true),
            outcome: nil)))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        do {
            try await client.sendExpectOK(Self.moveMouseRequest)
            Issue.record("Expected wrong-family projected response to be indeterminate")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `raw legacy mutation rejects a wrong response family without an outcome`() async throws {
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(Self.rawLegacyHandshake),
            .bool(true),
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateRawLegacy(client)

        do {
            try await client.sendExpectOK(Self.moveMouseRequest)
            Issue.record("Expected wrong-family raw legacy response to be indeterminate")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        }
        await peer.waitUntilFinished()
    }

    @Test(arguments: [false, true])
    func `receiptless mutation preserves a typed retry-safe error`(projected: Bool) async throws {
        let expected = PeekabooBridgeErrorEnvelope(
            code: .permissionDenied,
            message: "Legacy host denied input delivery")
        let response: PeekabooBridgeResponse = projected
            ? .projectedAction(.init(response: .error(expected), outcome: nil))
            : .error(expected)
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(projected ? Self.projectedReceiptlessHandshake : Self.rawLegacyHandshake),
            response,
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        if projected {
            try await Self.negotiateReceiptless(client)
        } else {
            try await Self.negotiateRawLegacy(client)
        }

        do {
            try await client.sendExpectOK(Self.moveMouseRequest)
            Issue.record("Expected the typed legacy error")
        } catch let actual as PeekabooBridgeErrorEnvelope {
            #expect(actual.code == expected.code)
            #expect(actual.message == expected.message)
            #expect(!actual.operationMayHaveCompleted)
        }
        await peer.waitUntilFinished()
    }

    @Test
    func `receiptless browser success requires every requested mutation to complete`() async throws {
        let receipt = Self.browserConnectionReceipt
        let request = PeekabooBridgeRequest.browserExecute(.init(
            calls: [
                .init(toolName: "click", arguments: [:]),
                .init(toolName: "fill", arguments: [:]),
            ],
            channel: receipt.channel,
            expectedConnectionReceipt: receipt))
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            route: .bridge,
            delivery: .init(mechanism: .browserProtocol, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let response = PeekabooBridgeBrowserToolResponse(
            content: [],
            isError: false,
            meta: nil,
            connectionReceipt: receipt,
            completedCallCount: 1,
            dispatchedCallCount: 1)
        let peer = try Self.projectedReceiptlessPeer(response: .projectedAction(.init(
            response: .browserToolResponse(response),
            outcome: outcome.projection)))
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        try await Self.negotiateReceiptless(client)

        do {
            _ = try await client.sendCarryingActionOutcome(request)
            Issue.record("Expected truncated browser batch success to be indeterminate")
        } catch let failure as DesktopActionFailure {
            Self.expectResponseLostFailure(failure)
        }
        await peer.waitUntilFinished()
    }

    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    private static let moveMouseRequest = PeekabooBridgeRequest.moveMouse(.init(
        to: CGPoint(x: 10, y: 20),
        duration: 0,
        steps: 1,
        profile: .linear))

    private static let browserConnectionReceipt = PeekabooBridgeBrowserConnectionReceipt(
        channel: "chrome",
        processIdentifier: 42,
        processStartIdentity: 9001,
        bundleIdentifier: "com.google.Chrome")

    private static let receiptlessProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 28)

    private static let rawLegacyProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 22)

    private static let projectedReceiptlessHandshake = BridgeTestFixtures.handshake(
        negotiatedVersion: Self.receiptlessProtocolVersion,
        supportedOperations: [.moveMouse, .browserExecute],
        hostCapabilities: [PeekabooBridgeHostCapability.desktopActionOutcomeProjection])

    private static let rawLegacyHandshake = BridgeTestFixtures.handshake(
        negotiatedVersion: Self.rawLegacyProtocolVersion,
        supportedOperations: [.moveMouse])

    private static func projectedReceiptlessPeer(
        response: PeekabooBridgeResponse) throws -> ScriptedBridgePeer
    {
        try ScriptedBridgePeer(responses: [
            .handshake(self.projectedReceiptlessHandshake),
            response,
        ])
    }

    private static func negotiateReceiptless(_ client: PeekabooBridgeClient) async throws {
        _ = try await client.handshake(
            client: self.clientIdentity,
            protocolVersion: self.receiptlessProtocolVersion)
    }

    private static func negotiateRawLegacy(_ client: PeekabooBridgeClient) async throws {
        _ = try await client.handshake(
            client: self.clientIdentity,
            protocolVersion: self.rawLegacyProtocolVersion)
    }

    private static func attestedHandshake(
        authority: PeekabooBridgeOperationReceiptAuthority,
        session: PeekabooBridgeOperationSessionAttestation,
        supportedOperation: PeekabooBridgeOperation = .requestPostEventPermission)
        -> PeekabooBridgeHandshakeResponse
    {
        let listener = authority.attestation
        return BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.attestedOperationReceiptVersion,
            hostKind: .gui,
            build: "attested-listener-drift-test",
            supportedOperations: [supportedOperation],
            permissions: .init(screenRecording: true, accessibility: true, postEvent: true),
            enabledOperations: [supportedOperation],
            hostIdentity: .init(
                processIdentifier: listener.host.processIdentifier,
                processStartIdentity: listener.host.processStartIdentity,
                bundleIdentifier: "dev.peekaboo.test-host",
                bundleShortVersion: "1",
                bundleVersion: "1",
                codeSignatureHash: listener.host.codeSignatureHash),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.desktopActionOutcomeProjection,
            ],
            operationAttestation: listener,
            operationSessionAttestation: session)
    }

    private static func expectResponseLostFailure(_ failure: DesktopActionFailure) {
        #expect(failure.outcome.route == .bridge)
        #expect(failure.outcome.state == .indeterminate)
        #expect(failure.outcome.evidence == .responseLost)
        #expect(failure.outcome.retrySafety == .unsafe)
        #expect(failure.outcome.projection.requiresFreshObservation)
        #expect(failure.causeDescription?.contains("response family") == true ||
            failure.causeDescription?.contains("action state") == true)
    }

    private static func expectPreDispatchTransportUnavailable(_ failure: DesktopActionFailure) {
        #expect(failure.outcome.route == .bridge)
        #expect(failure.outcome.state == .refused)
        #expect(failure.outcome.dispatchState == .none)
        #expect(failure.outcome.retrySafety == .safe)
        #expect(failure.outcome.refusalReason == .transportSessionUnavailable)
    }
}

private final class DriftingListenerIdentityProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var lookupCount: Int {
        self.lock.withLock { self.count }
    }

    func identity(fd: Int32) throws -> PeekabooBridgeLivePeerIdentity {
        let identity = try PeekabooBridgeSocketIO.livePeerIdentity(fd: fd)
        let shouldDrift = self.lock.withLock {
            self.count += 1
            return self.count > 1
        }
        guard shouldDrift else { return identity }
        return PeekabooBridgeLivePeerIdentity(
            auditToken: identity.auditToken,
            processIdentifier: identity.processIdentifier,
            processIdentifierVersion: identity.processIdentifierVersion,
            effectiveUserIdentifier: identity.effectiveUserIdentifier,
            processStartIdentity: identity.processStartIdentity + 1,
            codeSignatureHash: identity.codeSignatureHash)
    }
}

private final class PrefixClosingBridgePeer: @unchecked Sendable {
    let socketPath: String

    private let state: State
    private let task: Task<Void, Never>

    var receivedPrefix: Data {
        get async { await self.state.receivedPrefix }
    }

    init(
        handshake: PeekabooBridgeHandshakeResponse,
        prefixLimit: Int,
        closeDelaySeconds: TimeInterval = 0) throws
    {
        let socketPath = "/tmp/pb-prefix-closing-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            try Self.bindAndListen(listener: listener, socketPath: socketPath)
        } catch {
            close(listener)
            throw error
        }

        let state = State()
        self.socketPath = socketPath
        self.state = state
        self.task = Task.detached {
            defer {
                close(listener)
                try? FileManager.default.removeItem(atPath: socketPath)
            }
            guard let handshakeClient = Self.acceptClient(listener) else { return }
            _ = Self.readToEOF(handshakeClient)
            if let response = try? JSONEncoder.peekabooBridgeEncoder().encode(
                PeekabooBridgeResponse.handshake(handshake))
            {
                Self.write(response, to: handshakeClient)
            }
            close(handshakeClient)

            guard let mutationClient = Self.acceptClient(listener) else { return }
            var receiveBufferBytes = Int32(prefixLimit)
            _ = setsockopt(
                mutationClient,
                SOL_SOCKET,
                SO_RCVBUF,
                &receiveBufferBytes,
                socklen_t(MemoryLayout.size(ofValue: receiveBufferBytes)))
            let prefix = Self.readPrefix(mutationClient, maximumByteCount: prefixLimit)
            await state.record(prefix)
            if closeDelaySeconds > 0 {
                try? await Task.sleep(for: .seconds(closeDelaySeconds))
            }
            var resetOnClose = linger(l_onoff: 1, l_linger: 0)
            _ = setsockopt(
                mutationClient,
                SOL_SOCKET,
                SO_LINGER,
                &resetOnClose,
                socklen_t(MemoryLayout.size(ofValue: resetOnClose)))
            close(mutationClient)
        }
    }

    func waitUntilFinished() async {
        await self.task.value
    }

    func waitUntilPrefixReceived() async {
        await self.state.waitUntilPrefixReceived()
    }

    private static func bindAndListen(listener: Int32, socketPath: String) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let copied = socketPath.withCString { strlcpy(&address.sun_path.0, $0, capacity) }
        guard copied < capacity else { throw POSIXError(.ENAMETOOLONG) }
        let length = socklen_t(MemoryLayout.size(ofValue: address))
        let bindResult = withUnsafePointer(to: &address) {
            Darwin.bind(listener, UnsafePointer<sockaddr>(OpaquePointer($0)), length)
        }
        guard bindResult == 0, listen(listener, 2) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func acceptClient(_ listener: Int32) -> Int32? {
        while true {
            let client = accept(listener, nil, nil)
            if client >= 0 {
                return client
            }
            if errno != EINTR {
                return nil
            }
        }
    }

    private static func readToEOF(_ descriptor: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return data
            }
        }
    }

    private static func readPrefix(_ descriptor: Int32, maximumByteCount: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: maximumByteCount)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                return Data(buffer.prefix(count))
            }
            if count < 0, errno == EINTR {
                continue
            }
            return Data()
        }
    }

    private static func write(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

    private actor State {
        private(set) var receivedPrefix = Data()
        private var didReceivePrefix = false
        private var prefixWaiters: [CheckedContinuation<Void, Never>] = []

        func record(_ prefix: Data) {
            self.receivedPrefix = prefix
            self.didReceivePrefix = true
            self.prefixWaiters.forEach { $0.resume() }
            self.prefixWaiters.removeAll()
        }

        func waitUntilPrefixReceived() async {
            guard !self.didReceivePrefix else { return }
            await withCheckedContinuation { continuation in
                self.prefixWaiters.append(continuation)
            }
        }
    }
}
