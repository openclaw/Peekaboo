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
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations) == true)

        let result = try await client.setValueWithOutcome(
            target: "T1",
            value: .string("updated"),
            snapshotId: "snapshot")

        let expectedTarget = try #require(services.automationStub.uiAutomationOutcomeTargetIdentity)
        #expect(result.payload.target == "T1")
        #expect(result.outcome?.route == .bridge)
        #expect(result.targetIdentity == expectedTarget)
        #expect(services.automationStub.lastSetValue?.target == "T1")
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.operation == .setValue)
        #expect(bundle.receipt.payload.target == .process(expectedTarget.processIdentity))
        #expect(bundle.receipt.payload.outcome == result.outcome?.projection)
        await host.stop()
    }

    @Test
    func `representative pre 1 37 hosts refuse both element mutations before wire dispatch`() async throws {
        for minor in [32, 34, 35, 36] {
            let oldVersion = PeekabooBridgeProtocolVersion(major: 1, minor: minor)
            let services = try Self.services()
            let decodes = ElementMutationDecodeProbe()
            let socketPath = "/tmp/peekaboo-element-mutation-old-\(minor)-\(UUID().uuidString).sock"
            let server = PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...oldVersion,
                allowedOperations: [.setValue, .performAction])
            server.setRequestDecodeObserverForTesting { decodes.record() }
            let host = PeekabooBridgeHost(
                socketPath: socketPath,
                server: server,
                allowedTeamIDs: [],
                requestTimeoutSec: 2)
            try await host.startChecked()

            do {
                let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
                let handshake = try await client.handshake(
                    client: Self.clientIdentity,
                    protocolVersion: oldVersion)
                #expect(handshake.negotiatedVersion == oldVersion)
                #expect(handshake.hostCapabilities?.contains(
                    PeekabooBridgeHostCapability.processGenerationBoundElementMutations) == false)
                let handshakeDecodeCount = decodes.count

                for operation in [
                    {
                        try await client.setValueWithOutcome(
                            target: "T1",
                            value: .string("updated"),
                            snapshotId: "snapshot")
                    },
                    {
                        try await client.performActionWithOutcome(
                            target: "B1",
                            actionName: "AXPress",
                            snapshotId: "snapshot")
                    },
                ] {
                    let failure = await #expect(throws: DesktopActionFailure.self) {
                        _ = try await operation()
                    }
                    #expect(failure?.outcome.state == .refused)
                    #expect(failure?.outcome.route == .bridge)
                    #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
                    #expect(failure?.outcome.retrySafety == .safe)
                    #expect(failure?.outcome.refusalReason == .runtimeIncompatible)
                }
                #expect(decodes.count == handshakeDecodeCount)
                #expect(services.automationStub.lastSetValue == nil)
                #expect(services.automationStub.lastPerformAction == nil)
            } catch {
                await host.stop()
                throw error
            }
            await host.stop()
        }
    }

    @Test
    func `fixed host returns signed process target for perform action`() async throws {
        let services = try Self.services()
        services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let socketPath = "/tmp/peekaboo-action-generation-bound-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.performAction])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()

        do {
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
            let handshake = try await client.handshake(client: Self.clientIdentity)
            #expect(handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations) == true)
            let result = try await client.performActionWithOutcome(
                target: "B1",
                actionName: "AXPress",
                snapshotId: "snapshot")
            let expectedTarget = try #require(services.automationStub.uiAutomationOutcomeTargetIdentity)
            #expect(result.targetIdentity == expectedTarget)
            let bundle = try #require(await client.lastOperationReceiptBundle())
            try bundle.validate()
            #expect(bundle.receipt.payload.operation == .performAction)
            #expect(bundle.receipt.payload.target == .process(expectedTarget.processIdentity))
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `capability claiming host cannot return targetless element mutation success`() async throws {
        let services = try Self.services()
        services.automationStub.actionOutcome = .confirmedNoChange()
        services.automationStub.uiAutomationOutcomeTargetIdentity = nil
        let socketPath = "/tmp/peekaboo-targetless-element-result-\(UUID().uuidString).sock"
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

        do {
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
            _ = try await client.handshake(client: Self.clientIdentity)
            let failure = await #expect(throws: DesktopActionFailure.self) {
                _ = try await client.setValueWithOutcome(
                    target: "T1",
                    value: .string("updated"),
                    snapshotId: "snapshot")
            }
            #expect(failure?.outcome.state == .indeterminate)
            #expect(failure?.outcome.dispatchState.mutationDispatched == true)
            #expect(failure?.outcome.retrySafety == .unsafe)
            #expect(failure?.targetReceipt == nil)
            #expect(services.automationStub.lastSetValue?.target == "T1")
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    @Test
    func `host omits element mutation capabilities when its provider does not claim them`() async throws {
        let services = try Self.services()
        services.automationStub.supportsSetValueResultTargetBinding = true
        services.automationStub.supportsProcessGenerationBoundElementMutations = false
        let decodes = ElementMutationDecodeProbe()
        let socketPath = "/tmp/peekaboo-set-value-unbound-provider-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.setValue, .performAction])
        server.setRequestDecodeObserverForTesting { decodes.record() }
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
            PeekabooBridgeHostCapability.setValueResultTargetBinding) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations) == false)
        let handshakeDecodeCount = decodes.count

        for operation in [
            {
                try await client.setValueWithOutcome(
                    target: "T1",
                    value: .string("updated"),
                    snapshotId: "snapshot")
            },
            {
                try await client.performActionWithOutcome(
                    target: "B1",
                    actionName: "AXPress",
                    snapshotId: "snapshot")
            },
        ] {
            let failure = await #expect(throws: DesktopActionFailure.self) {
                _ = try await operation()
            }
            #expect(failure?.outcome.state == .refused)
            #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(failure?.outcome.retrySafety == .safe)
            #expect(failure?.outcome.refusalReason == .runtimeIncompatible)
        }
        #expect(decodes.count == handshakeDecodeCount)
        #expect(services.automationStub.lastSetValue == nil)
        #expect(services.automationStub.lastPerformAction == nil)
        await host.stop()
    }

    @Test
    func `current server refuses both element mutations when the negotiated provider capability is absent`() throws {
        let services = try Self.services()
        services.automationStub.supportsSetValueResultTargetBinding = true
        services.automationStub.supportsProcessGenerationBoundElementMutations = false
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.setValue, .performAction])
        let capabilities = PeekabooBridgeNegotiatedSessionCapabilities(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            statelessClickVariants: false,
            exactWindowHeldPointerLifecycle: false,
            processGenerationBoundElementMutations: false)
        let requests: [PeekabooBridgeRequest] = [
            .setValue(.init(target: "T1", value: .string("updated"), snapshotId: "snapshot")),
            .performAction(.init(target: "B1", actionName: "AXPress", snapshotId: "snapshot")),
        ]

        for request in requests {
            let failure = PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(capabilities) {
                PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(true) {
                    #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                        try server.validateOperationAccess(
                            for: PeekabooBridgeOperationResultSemantics.semanticPlan(for: request),
                            permissions: PermissionsStatus(
                                screenRecording: true,
                                accessibility: true,
                                postEvent: true),
                            effectiveOps: [request.operation])
                    }
                }
            }
            #expect(failure?.code == .operationNotSupported)
        }
        #expect(services.automationStub.lastSetValue == nil)
        #expect(services.automationStub.lastPerformAction == nil)
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

private final class ElementMutationDecodeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var invocationCount = 0

    var count: Int {
        self.lock.withLock { self.invocationCount }
    }

    func record() {
        self.lock.withLock { self.invocationCount += 1 }
    }
}
