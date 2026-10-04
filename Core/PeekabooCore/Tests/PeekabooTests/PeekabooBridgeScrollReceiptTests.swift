import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooBridgeScrollReceiptTests {
    private static let previousProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 34)

    @Test(arguments: BridgeTestFixtures.scrollHandshakeCases)
    func `Scroll handshake eligibility preserves protocol and capability boundaries`(
        fixture: BridgeTestFixtures.ScrollHandshakeCase)
    {
        #expect(fixture.handshake.supportsTargetedScroll == fixture.targetedScroll)
        #expect(fixture.handshake.supportsRequestPinnedExactWindowScrollReceipt == fixture.requestPinnedScroll)
        #expect(fixture.handshake.supportsBackgroundCoordinateScroll == fixture.coordinateScroll)
    }

    @Test(arguments: [false, true])
    func `coordinate scroll refuses old or capability-missing hosts before transport`(oldHost: Bool) async throws {
        let version = oldHost ? PeekabooBridgeProtocolVersion(major: 1, minor: 42) : PeekabooBridgeConstants
            .protocolVersion
        let fixture = try await Self.makeFixture(
            serviceSupportsCoordinates: oldHost,
            supportedVersions: version...version,
            requestedVersion: version)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.handshake.hostCapabilities?
            .contains(PeekabooBridgeHostCapability.backgroundCoordinateScroll) != true)
        let failure = await #expect(throws: DesktopActionFailure.self) {
            _ = try await fixture.client.scrollWithOutcome(.init(
                direction: .down,
                amount: 1,
                point: CGPoint(x: 45, y: 67),
                snapshotId: "snapshot",
                expectedWindow: fixture.exactWindow))
        }
        #expect(failure?.outcome.refusalReason == .runtimeIncompatible)
        #expect(failure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(failure?.outcome.retrySafety == .safe)
        #expect(await MainActor.run { fixture.services.automationStub.scrollRequests.isEmpty })
        #expect(await fixture.client.lastOperationReceipt() == nil)
        await fixture.host.stop()
    }

    @Test
    func `coordinate scroll retains the requested point and signed exact-window outcome`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await MainActor.run {
            fixture.services.automationStub.uiAutomationOutcomeTargetIdentity = DesktopTargetIdentity(
                exactWindow: fixture.exactWindow)
            fixture.services.automationStub.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
        }
        #expect(fixture.handshake.hostCapabilities?
            .contains(PeekabooBridgeHostCapability.backgroundCoordinateScroll) == true)
        let result = try await fixture.client.scrollWithOutcome(.init(
            direction: .right,
            amount: 1,
            point: CGPoint(x: 45, y: 67),
            snapshotId: "snapshot",
            expectedWindow: fixture.exactWindow))
        #expect(result.outcome?.state == .dispatchedUnverified)
        #expect(result.outcome?.retrySafety == .unsafe)
        #expect(result.targetIdentity?.exactWindow == fixture.exactWindow)
        let request = try #require(await MainActor.run { fixture.services.automationStub.scrollRequests.last })
        #expect(request.point == CGPoint(x: 45, y: 67) && request.target == nil)
        let receipt = try #require(await fixture.client.lastOperationReceipt())
        #expect(receipt.payload.operation == .targetedScroll)
        #expect(receipt.payload.target == .window(fixture.identity))
        #expect(receipt.payload.targetAttributionFailure == nil)
        await fixture.host.stop()
    }

    @Test
    func `targeted scroll plan is pinned to complete request window evidence`() throws {
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let expectedWindow = try UIAutomationTarget.ExactWindow(
            identity: .init(
                windowID: 42,
                ownerProcessIdentifier: 123,
                ownerProcessStartIdentity: 456,
                capturedBounds: bounds),
            bounds: bounds)
        let request = PeekabooBridgeRequest.targetedScroll(.init(request: .init(
            direction: .down,
            amount: 3,
            target: "S1",
            snapshotId: "snapshot",
            expectedWindow: expectedWindow)))
        let plan = PeekabooBridgeOperationResultSemantics.semanticPlan(for: request)

        #expect(plan.target.policy == .requestPinned)
        #expect(try PeekabooBridgeOperationTargetAttribution.resolveRequest(plan)?.exactWindow == expectedWindow)
    }

    @Test
    func `post dispatch failure retains request pinned exact target`() async throws {
        let fixture = try await Self.makeFixture(failure: .indeterminate(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .completionUnknown,
            unitCount: .one,
            message: "Accessibility scroll bar value did not change after dispatch"))
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(fixture.handshake.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        #expect(fixture.handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt) == true)

        do {
            _ = try await fixture.client.scrollWithOutcome(.init(
                direction: .down,
                amount: 1,
                target: "S1",
                snapshotId: "snapshot",
                expectedWindow: fixture.exactWindow))
            Issue.record("Expected retry-unsafe scroll failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.message.contains("scroll bar value did not change"))
            #expect(failure.outcome.dispatchState.mutationDispatched)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.targetReceipt == DesktopTargetIdentity(
                exactWindow: fixture.exactWindow).actionTargetReceipt)
        }
        let receipt = try #require(await fixture.client.lastOperationReceipt())
        #expect(receipt.payload.operation == .targetedScroll)
        #expect(receipt.payload.target == .window(fixture.identity))
        #expect(receipt.payload.targetAttributionFailure == nil)
        await fixture.host.stop()
    }

    @Test(arguments: [false, true])
    func `background scroll refusal stays retry safe through a real bridge round trip`(staleTarget: Bool) async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reason: DesktopActionOutcome.RefusalReason = staleTarget ? .targetUnavailable : .operationUnsupported
        await MainActor.run {
            fixture.services.automationStub.uiAutomationOutcomeScript.appendFailure(
                DesktopActionFailure.preDispatchRefusal(
                    reason: reason,
                    message: staleTarget ? "Captured wheel point is outside the exact window." :
                        "Background scroll has no supported route for the observed target.",
                    standardErrorCode: staleTarget ? .snapshotStale : nil)
                    .attributed(to: DesktopTargetIdentity(exactWindow: fixture.exactWindow).actionTargetReceipt),
                for: .scroll)
        }

        do {
            _ = try await fixture.client.scrollWithOutcome(.init(
                direction: .up,
                amount: 10,
                target: "S1",
                snapshotId: "snapshot",
                expectedWindow: fixture.exactWindow))
            Issue.record("Expected pre-dispatch scroll refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == reason)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
            #expect(failure.standardErrorCode == (staleTarget ? .snapshotStale : nil))
            #expect(failure.targetReceipt == DesktopTargetIdentity(
                exactWindow: fixture.exactWindow).actionTargetReceipt)
        }
        let receipt = try #require(await fixture.client.lastOperationReceipt())
        // No-dispatch envelopes stay targetless; the failure retains the service's validated target.
        #expect(receipt.payload.target == nil)
        #expect(receipt.payload.targetAttributionFailure == nil)
        #expect(receipt.payload.outcome?.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(receipt.payload.outcome?.state == .refused)
        await fixture.host.stop()
    }

    @Test
    func `negotiated downgrade strips exact scroll receipt capability`() async throws {
        let fixture = try await Self.makeFixture(
            supportedVersions: Self.previousProtocolVersion...Self.previousProtocolVersion,
            requestedVersion: Self.previousProtocolVersion)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(fixture.handshake.negotiatedVersion == Self.previousProtocolVersion)
        #expect(fixture.handshake.supportedOperations.contains(.targetedScroll))
        #expect(fixture.handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt) != true)
        #expect(await fixture.client.requestPinnedExactWindowScrollReceiptEnabled == false)
        await fixture.host.stop()
    }

    @Test
    func `current handshake derives exact scroll capability from service`() async throws {
        let fixture = try await Self.makeFixture(
            serviceSupportsReceipt: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        #expect(fixture.handshake.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        #expect(fixture.handshake.supportedOperations.contains(.targetedScroll))
        #expect(fixture.handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.requestPinnedExactWindowScrollReceipt) != true)
        #expect(await fixture.client.requestPinnedExactWindowScrollReceiptEnabled == false)
        await fixture.host.stop()
    }

    @Test
    func `new client refuses previous host before targeted scroll transport`() async throws {
        let fixture = try await Self.makeFixture(
            supportedVersions: Self.previousProtocolVersion...Self.previousProtocolVersion,
            requestedVersion: Self.previousProtocolVersion)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try await fixture.client.scrollWithOutcome(.init(
                direction: .down,
                amount: 1,
                target: "S1",
                snapshotId: "snapshot",
                expectedWindow: fixture.exactWindow))
            Issue.record("Expected the downgraded host to be refused before scroll transport")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(await MainActor.run {
            fixture.services.automationStub.uiAutomationOutcomeScript.callCount(for: .scroll)
        } == 0)
        #expect(await fixture.client.lastOperationReceipt() == nil)
        await fixture.host.stop()
    }

    @Test(arguments: [false, true])
    @MainActor
    func `previous client receives signed runtime refusal from current host`(coordinates: Bool) async throws {
        let root = URL(fileURLWithPath: "/tmp/pbsr-old-client-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let services = StubServices()
        let server = Self.server(services: services)
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            negotiatedCapabilities: .init(
                protocolVersion: coordinates ? .init(major: 1, minor: 42) : Self.previousProtocolVersion,
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                requestPinnedExactWindowScrollReceipt: coordinates))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: .targetedScroll(.init(request: .init(
            direction: .down,
            amount: 1,
            target: coordinates ? nil : "S1",
            point: coordinates ? CGPoint(x: 45, y: 67) : nil,
            snapshotId: "snapshot")))))
        let payload = session.request(authority: authority, sequence: 0, request: request)
        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await server.handleAttestedOperation(payload, peer: session.peer)
        }
        guard case let .attestedOperation(attested) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: data),
            case let .projectedAction(projected) = attested.response,
            case let .error(envelope) = projected.response
        else {
            Issue.record("Expected a signed projected runtime refusal")
            return
        }

        #expect(envelope.code == .versionMismatch)
        if coordinates {
            #expect(envelope.message.contains("coordinate scroll"))
        }
        #expect(envelope.desktopActionFailure?.outcome.refusalReason == .runtimeIncompatible)
        #expect(envelope.desktopActionFailure?.outcome.dispatchState == DesktopActionOutcome.DispatchState.none)
        #expect(attested.receipt.payload.target == nil)
        #expect(attested.receipt.payload.outcome?.state == .refused)
        #expect(services.automationStub.uiAutomationOutcomeScript.callCount(for: .scroll) == 0)
    }

    @Test
    func `missing exact request target refuses before provider dispatch`() async throws {
        let fixture = try await Self.makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        do {
            _ = try await fixture.client.scrollWithOutcome(.init(
                direction: .down,
                amount: 1,
                target: "S1",
                snapshotId: "snapshot"))
            Issue.record("Expected missing exact-target refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(await MainActor.run {
            fixture.services.automationStub.uiAutomationOutcomeScript.callCount(for: .scroll)
        } == 0)
        #expect(await fixture.client.lastOperationReceipt() == nil)
        await fixture.host.stop()
    }

    private struct Fixture {
        let root: URL
        let identity: WindowMutationIdentity
        let exactWindow: UIAutomationTarget.ExactWindow
        let services: StubServices
        let host: PeekabooBridgeHost
        let client: PeekabooBridgeClient
        let handshake: PeekabooBridgeHandshakeResponse
    }

    private static func makeFixture(
        failure: DesktopActionFailure? = nil,
        serviceSupportsReceipt: Bool = true,
        serviceSupportsCoordinates: Bool = true,
        supportedVersions: ClosedRange<PeekabooBridgeProtocolVersion> = PeekabooBridgeConstants.supportedProtocolRange,
        requestedVersion: PeekabooBridgeProtocolVersion = PeekabooBridgeConstants
            .protocolVersion) async throws -> Fixture
    {
        let root = URL(fileURLWithPath: "/tmp/pbsr-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 73,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds)
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
        let services = await MainActor.run {
            let services = StubServices()
            services.automationStub.supportsRequestPinnedExactWindowScrollReceipt = serviceSupportsReceipt
            services.automationStub.supportsBackgroundCoordinateScroll = serviceSupportsCoordinates
            if let failure {
                services.automationStub.uiAutomationOutcomeScript.appendFailure(failure, for: .scroll)
            }
            return services
        }
        let server = await MainActor.run {
            Self.server(services: services, supportedVersions: supportedVersions)
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.scroll-receipt-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil), protocolVersion: requestedVersion)
        return Fixture(
            root: root,
            identity: identity,
            exactWindow: exactWindow,
            services: services,
            host: host,
            client: client,
            handshake: handshake)
    }

    @MainActor
    private static func server(
        services: StubServices,
        supportedVersions: ClosedRange<PeekabooBridgeProtocolVersion> = PeekabooBridgeConstants.supportedProtocolRange)
        -> PeekabooBridgeServer
    {
        PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: supportedVersions,
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
    }
}
