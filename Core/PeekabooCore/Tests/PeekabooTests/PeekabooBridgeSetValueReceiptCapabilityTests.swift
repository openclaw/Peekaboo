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
            #expect(server.hostCapabilities.contains(
                PeekabooBridgeHostCapability.setValueResultTargetBinding) == false)
            #expect(handshake.hostCapabilities?.contains(
                PeekabooBridgeHostCapability.setValueResultTargetBinding) == false)
            #expect(handshake.supportedOperations.contains(.performAction))
            #expect(!handshake.supportedOperations.contains(.setValue))
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
        #expect(!server.hostCapabilities.contains(
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations))
        #expect(!server.hostCapabilities.contains(
            PeekabooBridgeHostCapability.setValueResultTargetBinding))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.setValueResultTargetBinding) == false)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations) == false)
        #expect(!handshake.supportedOperations.contains(.setValue))
        #expect(!handshake.supportedOperations.contains(.performAction))
        #expect(handshake.enabledOperations?.contains(.setValue) == false)
        #expect(handshake.enabledOperations?.contains(.performAction) == false)
        #expect(!server.allowedOperationsToAdvertise().contains(.setValue))
        #expect(!server.allowedOperationsToAdvertise().contains(.performAction))
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

        for request in [
            PeekabooBridgeRequest.setValue(.init(
                target: "T1",
                value: .string("updated"),
                snapshotId: "snapshot")),
            PeekabooBridgeRequest.performAction(.init(
                target: "B1",
                actionName: "AXPress",
                snapshotId: "snapshot")),
        ] {
            let error = await Self.routeFailure(
                request,
                server: server,
                capabilities: .current)
            #expect(error?.actionOutcome?.state == .refused)
            #expect(error?.actionOutcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        }
        #expect(services.automationStub.lastSetValue == nil)
        #expect(services.automationStub.lastPerformAction == nil)
        await host.stop()
    }

    @Test
    func `current host keeps actions but prunes set value without result target binding`() async throws {
        let services = try Self.services()
        services.automationStub.supportsSetValueResultTargetBinding = false
        let server = Self.currentServer(services: services)
        let socketPath = "/tmp/peekaboo-set-value-unbound-result-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let handshake = try await TrustedBridgeClientFixture.make(
            socketPath: socketPath,
            requestTimeoutSec: 2).handshake(client: Self.clientIdentity)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations) == true)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.setValueResultTargetBinding) == false)
        #expect(!handshake.supportedOperations.contains(.setValue))
        #expect(handshake.supportedOperations.contains(.performAction))
        #expect(handshake.enabledOperations?.contains(.setValue) == false)
        #expect(handshake.enabledOperations?.contains(.performAction) == true)
        #expect(!server.allowedOperationsToAdvertise().contains(.setValue))
        #expect(server.allowedOperationsToAdvertise().contains(.performAction))

        let error = await Self.routeFailure(
            .setValue(.init(target: "T1", value: .string("updated"), snapshotId: "snapshot")),
            server: server,
            capabilities: .current)
        #expect(error?.actionOutcome?.state == .refused)
        #expect(error?.actionOutcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(services.automationStub.lastSetValue == nil)
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

    @Test
    func `current host prunes element mutations from downgraded handshakes`() async throws {
        let services = try Self.services()
        let socketPath = "/tmp/peekaboo-element-mutation-downgrade-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.setValue, .performAction])
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }

        let handshake = try await TrustedBridgeClientFixture.make(
            socketPath: socketPath,
            requestTimeoutSec: 2).handshake(
            client: Self.clientIdentity,
            protocolVersion: .init(major: 1, minor: 36))

        #expect(handshake.negotiatedVersion == .init(major: 1, minor: 36))
        #expect(!handshake.supportedOperations.contains(.setValue))
        #expect(!handshake.supportedOperations.contains(.performAction))
        #expect(handshake.enabledOperations?.contains(.setValue) == false)
        #expect(handshake.enabledOperations?.contains(.performAction) == false)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations) == false)
        #expect(services.automationStub.lastSetValue == nil)
        #expect(services.automationStub.lastPerformAction == nil)
        await host.stop()
    }

    @Test
    func `current server refuses downgraded attested and receiptless direct element mutation wires`() async throws {
        let services = try Self.services()
        let server = Self.currentServer(services: services)
        let requests: [PeekabooBridgeRequest] = [
            .setValue(.init(target: "T1", value: .string("updated"), snapshotId: "snapshot")),
            .performAction(.init(target: "B1", actionName: "AXPress", snapshotId: "snapshot")),
        ]

        for request in requests {
            let rawData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
            let rawResponseData = await server.decodeAndHandle(rawData, peer: nil)
            let rawResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: rawResponseData)
            guard case let .error(rawError) = rawResponse else {
                Issue.record("Expected a receiptless direct-wire refusal")
                continue
            }
            #expect(rawError.code == .operationNotSupported)

            let attestedError = await Self.routeFailure(
                request,
                server: server,
                capabilities: .init(
                    protocolVersion: .init(major: 1, minor: 36),
                    statelessClickVariants: false,
                    exactWindowHeldPointerLifecycle: false))
            #expect(attestedError?.actionOutcome?.state == .refused)
            #expect(attestedError?.actionOutcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
            #expect(attestedError?.actionOutcome?.retrySafety == .safe)

            let receiptlessCurrentError = await Self.routeFailure(
                request,
                server: server,
                capabilities: .current,
                usesAttestedResultSemantics: false)
            #expect(receiptlessCurrentError?.code == .operationNotSupported)
        }
        #expect(services.automationStub.lastSetValue == nil)
        #expect(services.automationStub.lastPerformAction == nil)
    }

    @Test
    func `current server prunes receiptless element action providers before advertisement or dispatch`() async {
        let automation = BridgeReceiptlessElementActionAutomationService(accessibilityGranted: true)
        let services = StubServices(automation: automation)
        let server = Self.currentServer(services: services)

        #expect(!server.hostCapabilities.contains(
            PeekabooBridgeHostCapability.processGenerationBoundElementMutations))
        #expect(!server.hostCapabilities.contains(
            PeekabooBridgeHostCapability.setValueResultTargetBinding))
        #expect(!server.allowedOperationsToAdvertise().contains(.setValue))
        #expect(!server.allowedOperationsToAdvertise().contains(.performAction))

        for request in [
            PeekabooBridgeRequest.setValue(.init(
                target: "T1",
                value: .string("updated"),
                snapshotId: "snapshot")),
            PeekabooBridgeRequest.performAction(.init(
                target: "B1",
                actionName: "AXPress",
                snapshotId: "snapshot")),
        ] {
            let error = await Self.routeFailure(
                request,
                server: server,
                capabilities: .current)
            #expect(error?.actionOutcome?.state == DesktopActionOutcome.State.refused)
            #expect(error?.actionOutcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        }
        #expect(automation.setValueCallCount == 0)
        #expect(automation.performActionCallCount == 0)
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

    private static func currentServer(services: any PeekabooBridgeServiceProviding) -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.setValue, .performAction],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
    }

    private static func routeFailure(
        _ request: PeekabooBridgeRequest,
        server: PeekabooBridgeServer,
        capabilities: PeekabooBridgeNegotiatedSessionCapabilities,
        usesAttestedResultSemantics: Bool = true) async -> PeekabooBridgeErrorEnvelope?
    {
        await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(capabilities) {
            await PeekabooBridgeRequestContext.$usesAttestedOperationResultSemantics.withValue(
                usesAttestedResultSemantics)
            {
                do {
                    _ = try await server.route(request, peer: nil)
                    Issue.record("Expected the direct server request to fail before provider dispatch")
                    return nil
                } catch let error as PeekabooBridgeErrorEnvelope {
                    return error
                } catch {
                    Issue.record("Unexpected direct server error: \(error)")
                    return nil
                }
            }
        }
    }
}

@MainActor
private final class BridgeReceiptlessElementActionAutomationService: MockAutomationService,
ElementActionAutomationServiceProtocol {
    let supportsSetValueResultTargetBinding = true
    let supportsProcessGenerationBoundElementMutations = true
    private(set) var setValueCallCount = 0
    private(set) var performActionCallCount = 0

    func setValue(target: String, value _: UIElementValue, snapshotId _: String?) async throws
        -> ElementActionResult
    {
        self.setValueCallCount += 1
        return ElementActionResult(target: target, actionName: "AXSetValue", anchorPoint: nil)
    }

    func performAction(target: String, actionName: String, snapshotId _: String?) async throws
        -> ElementActionResult
    {
        self.performActionCallCount += 1
        return ElementActionResult(target: target, actionName: actionName, anchorPoint: nil)
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
