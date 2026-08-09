import Foundation
import PeekabooAutomationKit
import Testing
@testable import PeekabooBridge

struct PeekabooBridgeQuitIdentityTests {
    @Test
    func `quit compatibility begins with the pinned receipt protocol`() {
        let operations: Set<PeekabooBridgeOperation> = [.quitApplication, .findApplication]

        let legacy = PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeProtocolVersion(major: 1, minor: 15))
        let pinned = PeekabooBridgeOperation.compatible(
            operations,
            with: PeekabooBridgeConstants.processGenerationPinnedApplicationQuitVersion)

        #expect(!legacy.contains(.quitApplication))
        #expect(legacy.contains(.findApplication))
        #expect(pinned.contains(.quitApplication))
    }

    @Test
    func `old client handshake never receives quit while pinned client does`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-quit-handshake-\(UUID().uuidString).sock"
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: StubApplicationService()),
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)

        let legacy = try await client.handshake(
            client: identity,
            protocolVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 15))
        let pinned = try await client.handshake(
            client: identity,
            protocolVersion: PeekabooBridgeConstants.processGenerationPinnedApplicationQuitVersion)

        #expect(!legacy.supportedOperations.contains(.quitApplication))
        #expect(legacy.enabledOperations?.contains(.quitApplication) == false)
        #expect(pinned.supportedOperations.contains(.quitApplication))
        #expect(pinned.enabledOperations?.contains(.quitApplication) == true)
        await host.stop()
    }

    @Test
    func `host without identity-aware application service never advertises or accepts quit`() async throws {
        let applications = await MainActor.run { UnpinnedQuitApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let handshake = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: .init(
                bundleIdentifier: "dev.peekaboo.tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            requestedHostKind: .gui))
        let handshakeResponse = try await self.response(for: handshake, server: server)

        guard case let .handshake(capabilities) = handshakeResponse else {
            Issue.record("Expected handshake response")
            return
        }
        let enabledOperations = capabilities.enabledOperations ?? []
        #expect(!capabilities.supportedOperations.contains(.quitApplication))
        #expect(!enabledOperations.contains(.quitApplication))

        let quitResponse = try await self.response(
            for: .quitApplication(.init(
                identifier: "PID:123",
                force: true,
                expectedIdentity: .init(processIdentifier: 123, processStartIdentity: 456))),
            server: server)
        guard case let .error(error) = quitResponse else {
            Issue.record("Expected unsupported quit response")
            return
        }
        #expect(error.code == .operationNotSupported)
        #expect(await MainActor.run { applications.quitRequests }.isEmpty)
    }

    @Test
    func `direct client quit overloads require explicit negotiated capability before transport`() async throws {
        let client = PeekabooBridgeClient(
            socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
            requestTimeoutSec: 0.1)
        let calls: [@Sendable () async throws -> Bool] = [
            { try await client.quitApplication(identifier: "TextEdit", force: false) },
            { try await client.quitApplication(request: .init(
                identifier: "PID:123",
                force: false,
                expectedIdentity: .init(processIdentifier: 123, processStartIdentity: 456))) },
        ]

        for call in calls {
            do {
                _ = try await call()
                Issue.record("Expected pinned-quit capability preflight")
            } catch let error as PeekabooBridgeErrorEnvelope {
                #expect(error.code == .operationNotSupported)
                #expect(error.message.contains("process-generation-pinned"))
            }
        }
    }

    @Test
    func `Bridge rejects quit without process generation before service dispatch`() async throws {
        let applications = await MainActor.run { StubApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let request = PeekabooBridgeRequest.quitApplication(PeekabooBridgeQuitAppRequest(
            identifier: "PID:123",
            force: true))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)

        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: responseData)

        guard case let .error(envelope) = response else {
            Issue.record("Expected missing process identity to fail, got \(response)")
            return
        }
        #expect(envelope.code == .invalidRequest)
        #expect(envelope.message.contains("process-generation identity"))
        #expect(envelope.message.contains("update the client"))
        #expect(await MainActor.run { applications.quitRequests }.isEmpty)
    }

    @Test
    func `Bridge rejects host self quit before service dispatch`() async throws {
        let applications = await MainActor.run { StubApplicationService() }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: StubServices(applications: applications),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [])
        }
        let request = PeekabooBridgeRequest.quitApplication(PeekabooBridgeQuitAppRequest(
            identifier: "PID:\(getpid())",
            force: true,
            expectedIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: 456)))

        let response = try await self.response(for: request, server: server)

        guard case let .error(envelope) = response else {
            Issue.record("Expected host self quit to fail, got \(response)")
            return
        }
        #expect(envelope.code == .operationNotSupported)
        #expect(envelope.message == "A runtime host cannot quit itself")
        #expect(await MainActor.run { applications.quitRequests }.isEmpty)
    }

    private func response(
        for request: PeekabooBridgeRequest,
        server: PeekabooBridgeServer) async throws -> PeekabooBridgeResponse
    {
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(data, peer: nil)
        return try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: responseData)
    }
}

@MainActor
private final class UnpinnedQuitApplicationService: StubApplicationService {
    override var supportsProcessGenerationPinnedApplicationQuit: Bool {
        false
    }
}
