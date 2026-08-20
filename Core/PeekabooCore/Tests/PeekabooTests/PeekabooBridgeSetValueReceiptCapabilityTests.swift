import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
@MainActor
struct PeekabooBridgeSetValueReceiptCapabilityTests {
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.set-value-receipt-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    @Test
    func `protocol 1 31 host refuses set value before dispatch without result target binding`() async throws {
        let oldVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 31)
        let services = try Self.services()
        let socketPath = "/tmp/peekaboo-set-value-old-host-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...oldVersion,
            allowedOperations: [.setValue])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: oldVersion)
        #expect(handshake.negotiatedVersion == oldVersion)
        #expect(handshake.supportedOperations.contains(.setValue))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.setValueResultTargetBinding) == false)

        do {
            _ = try await client.setValue(
                target: "T1",
                value: .string("updated"),
                snapshotId: "snapshot")
            Issue.record("Expected an old host capability refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.message.contains("verifiable set-value result"))
        }
        #expect(services.automationStub.lastSetValue == nil)
        await host.stop()
    }

    @Test
    func `fixed host advertises binding and returns a valid signed set value result`() async throws {
        let services = try Self.services()
        let socketPath = "/tmp/peekaboo-set-value-fixed-host-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.setValue])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.setValueResultTargetBinding) == true)

        let result = try await client.setValue(
            target: "T1",
            value: .string("updated"),
            snapshotId: "snapshot")

        #expect(result.target == "T1")
        #expect(services.automationStub.lastSetValue?.target == "T1")
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.operation == .setValue)
        await host.stop()
    }

    @Test
    func `host omits binding capability when its element provider does not claim it`() async throws {
        let services = try Self.services()
        services.automationStub.supportsSetValueResultTargetBinding = false
        let socketPath = "/tmp/peekaboo-set-value-unbound-provider-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.setValue])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.setValueResultTargetBinding) == false)

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await client.setValue(
                target: "T1",
                value: .string("updated"),
                snapshotId: "snapshot")
        }
        #expect(services.automationStub.lastSetValue == nil)
        await host.stop()
    }

    private static func services() throws -> StubServices {
        let services = StubServices()
        services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        services.automationStub.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid()))))
        return services
    }
}
