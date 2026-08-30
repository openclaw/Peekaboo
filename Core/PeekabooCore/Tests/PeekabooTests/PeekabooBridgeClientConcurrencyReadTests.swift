import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

extension PeekabooBridgeClientConcurrencyTests {
    @Test
    func `concurrent receiptless responses stay paired with their exact requests under load`() async throws {
        let application = ServiceApplicationInfo(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            bundleIdentifier: "dev.peekaboo.fixture",
            name: "BridgeFixture",
            activationPolicy: .regular)
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 28),
            supportedOperations: [.getFocusedWindow, .listApplications])
        let peer = try ConcurrentGatedBridgePeer()
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 2)

        let negotiation = Task {
            try await client.handshake(
                client: Self.clientIdentity,
                protocolVersion: .init(major: 1, minor: 28))
        }
        let handshakeRequest = try await peer.nextRequest()
        try Self.requireHandshake(handshakeRequest)
        try await peer.respond(.handshake(handshake), to: handshakeRequest)
        _ = try await negotiation.value

        for _ in 0..<64 {
            let applications = Task { try await client.listApplications() }
            let focusedWindow = Task { try await client.getFocusedWindow() }
            let first = try await peer.nextRequest()
            let second = try await peer.nextRequest()
            let firstRequest = try first.decode()
            let secondRequest = try second.decode()

            #expect(Set([firstRequest.operation, secondRequest.operation]) == [
                .getFocusedWindow,
                .listApplications,
            ])
            try await peer.respond(
                Self.concurrentReadResponse(secondRequest, application: application),
                to: second)
            try await peer.respond(
                Self.concurrentReadResponse(firstRequest, application: application),
                to: first)

            #expect(try await applications.value == [application])
            #expect(try await focusedWindow.value == nil)
        }

        #expect(await peer.acceptedConnectionCount == 129)
        await peer.stop()
    }

    private static func concurrentReadResponse(
        _ request: PeekabooBridgeRequest,
        application: ServiceApplicationInfo) -> PeekabooBridgeResponse
    {
        switch request {
        case .listApplications: .applications([application])
        case .getFocusedWindow: .window(nil)
        default:
            .error(.init(
                code: .invalidRequest,
                message: "Unexpected concurrent read request \(request.operation.rawValue)"))
        }
    }
}
