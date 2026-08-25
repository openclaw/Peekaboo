import Darwin
import Foundation
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

struct NativeBrowserConnectionBindingTests {
    @Test
    func `native browser connection binding owns protocol 1 34`() {
        let version = PeekabooBridgeProtocolVersion(major: 1, minor: 34)
        #expect(PeekabooBridgeConstants.protocolVersion == version)
        #expect(PeekabooBridgeConstants.nativeBrowserConnectionBindingVersion == version)
        #expect(PeekabooBridgeHostCapability.nativeBrowserConnectionBinding ==
            "nativeBrowserConnectionBinding")
    }

    @Test
    @MainActor
    func `current Bridge signs pre and post approval connect failures canonically`() async throws {
        let failures = [
            DesktopActionFailure.preDispatchRefusal(
                reason: .targetUnavailable,
                message: "authority unavailable"),
            DesktopActionFailure.indeterminate(
                delivery: .init(mechanism: .browserProtocol, mode: .foreground),
                evidence: .completionUnknown,
                unitCount: .one,
                message: "approval completion unknown"),
        ]

        for failure in failures {
            let socketPath = "/tmp/peekaboo-browser-binding-outcome-\(UUID().uuidString).sock"
            let services = StubServices()
            services.browserConnectFailure = failure
            let server = PeekabooBridgeServer(
                services: services,
                hostKind: .onDemand,
                allowlistedTeams: [],
                allowlistedBundles: [])
            let host = PeekabooBridgeHost(
                socketPath: socketPath,
                server: server,
                allowedTeamIDs: [],
                requestTimeoutSec: 2)
            try await host.startChecked()
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
            let handshake = try await client.handshake(client: .init(
                bundleIdentifier: "dev.peekaboo.browser-binding-outcome",
                teamIdentifier: nil,
                processIdentifier: getpid()))
            #expect(handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) == true)

            do {
                _ = try await client.browserConnectResult(channel: "stable")
                Issue.record("Expected signed browser connect failure")
            } catch let received as DesktopActionFailure {
                #expect(received.outcome.routed(to: .local) == failure.outcome)
            }
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .browserConnect)
            #expect(receipt.payload.outcome == failure.outcome.routed(to: .bridge).projection)
            await host.stop()
        }
    }

    @Test
    @MainActor
    func `protocol 1 33 server refuses channel connect before provider entry`() async throws {
        let socketPath = "/tmp/peekaboo-browser-binding-downgrade-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let protocol133 = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let handshake = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.browser-binding-downgrade",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: protocol133)
        #expect(handshake.negotiatedVersion == protocol133)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.nativeBrowserConnectionBinding) != true)

        do {
            _ = try await client.send(.browserConnect(.init(channel: "stable")))
            Issue.record("Expected protocol downgrade refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(services.lastBrowserConnectTarget == nil)
        await host.stop()
    }

    @Test
    @MainActor
    func `new client refuses downgraded channel connect before provider entry`() async throws {
        let protocol133 = PeekabooBridgeProtocolVersion(major: 1, minor: 33)
        let socketPath = "/tmp/peekaboo-browser-binding-client-downgrade-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .onDemand,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.browser-binding-old-host",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: protocol133)

        do {
            _ = try await client.browserConnectResult(channel: "stable")
            Issue.record("Expected client-side capability refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(services.lastBrowserConnectTarget == nil)
        await host.stop()
    }

    @Test
    func `legacy handshake decoder ignores native browser capability from new host`() throws {
        let current = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            supportedOperations: [.browserConnect],
            hostCapabilities: [PeekabooBridgeHostCapability.nativeBrowserConnectionBinding])
        let encoded = try JSONEncoder.peekabooBridgeEncoder().encode(current)
        let decoded = try JSONDecoder.peekabooBridgeDecoder().decode(
            LegacyBrowserHandshake.self,
            from: encoded)

        #expect(decoded.negotiatedVersion == .init(major: 1, minor: 34))
        #expect(decoded.supportedOperations == [.browserConnect])
    }
}

private struct LegacyBrowserHandshake: Decodable {
    let negotiatedVersion: PeekabooBridgeProtocolVersion
    let supportedOperations: [PeekabooBridgeOperation]
}
