import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

// This suite intentionally keeps the complete targeted-click wire/permission matrix together.
// swiftlint:disable:next type_body_length
struct PeekabooBridgeTargetedClickTests {
    private let exactIdentity = WindowMutationIdentity(
        windowID: 42,
        ownerProcessIdentifier: 9001,
        ownerProcessStartIdentity: 1)
    private let exactBounds = CGRect(x: 0, y: 0, width: 100, height: 100)
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.targeted-click-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    @Test
    @MainActor
    func `stateless click payload version and background capability are negotiated separately`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let foregroundRequest = PeekabooBridgeRequest.click(.init(
            target: .coordinates(.zero),
            clickType: .middle,
            snapshotId: nil))
        let backgroundRequest = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .triple,
            snapshotId: "snapshot",
            targetProcessIdentifier: self.exactIdentity.ownerProcessIdentifier,
            targetWindowID: self.exactIdentity.windowID,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))
        let legacy = PeekabooBridgeNegotiatedSessionCapabilities(
            protocolVersion: .init(major: 1, minor: 29),
            statelessClickVariants: false,
            exactWindowHeldPointerLifecycle: false)
        for request in [foregroundRequest, backgroundRequest] {
            await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                _ = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(legacy) {
                    try await server.route(request, peer: nil)
                }
            }
        }

        let currentForegroundOnly = PeekabooBridgeNegotiatedSessionCapabilities(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            statelessClickVariants: false,
            exactWindowHeldPointerLifecycle: true)
        _ = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(currentForegroundOnly) {
            try await server.route(foregroundRequest, peer: nil)
        }
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(currentForegroundOnly) {
                try await server.route(backgroundRequest, peer: nil)
            }
        }
        #expect(services.automationStub.lastClick?.type == .middle)
        #expect(services.automationStub.lastProcessTargetedClick == nil)
    }

    private static let legacyUnprojectedProtocolVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 22)
    private static let legacyUnprojectedHandshake = BridgeTestFixtures.handshake(
        negotiatedVersion: Self.legacyUnprojectedProtocolVersion,
        supportedOperations: [.targetedClick])

    private func decode(_ data: Data) throws -> PeekabooBridgeResponse {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
    }

    private func legacyUnprojectedClient(socketPath: String) async throws -> PeekabooBridgeClient {
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        // Targeted click exists in 1.22, the final version before canonical outcome projection.
        _ = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: Self.legacyUnprojectedProtocolVersion)
        return client
    }

    @Test
    @MainActor
    func `stateless click capability requires an attested protocol 1 30 session`() async throws {
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 29)
        let currentServer = PeekabooBridgeServer(
            services: StubServices(),
            allowlistedTeams: [],
            allowlistedBundles: [])

        #expect(PeekabooBridgeConstants.statelessClickVariantVersion == .init(major: 1, minor: 30))

        let handshakeRequest = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: previous,
            client: Self.clientIdentity))
        let response = try await self.decode(currentServer.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(handshakeRequest),
            peer: nil))
        guard case let .handshake(handshake) = response else {
            Issue.record("Expected legacy handshake response")
            return
        }
        #expect(handshake.negotiatedVersion == previous)
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.statelessClickVariants) == false)

        let currentRequest = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: Self.clientIdentity))
        let currentResponse = try await self.decode(currentServer.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(currentRequest),
            peer: nil))
        guard case let .handshake(currentHandshake) = currentResponse else {
            Issue.record("Expected current handshake response")
            return
        }
        #expect(currentHandshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.statelessClickVariants) == false)
    }

    @Test
    @MainActor
    func `protocol 1 29 client refuses middle click before transport or receipt reservation`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-legacy-click-\(UUID().uuidString).sock"
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 29)
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: previous...previous,
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity, protocolVersion: previous)

        do {
            _ = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: .middle,
                snapshotId: "snapshot",
                expectedWindowIdentity: self.exactIdentity,
                expectedWindowBounds: self.exactBounds)
            Issue.record("Expected protocol capability refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
            #expect(failure.outcome.retrySafety == .safe)
        }
        #expect(services.automationStub.lastProcessTargetedClick == nil)
        #expect(await client.lastOperationReceiptBundle() == nil)
    }

    @Test
    @MainActor
    func `foreground middle click requires protocol 1 30 but not background capability`() async throws {
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 29)
        let legacyServices = StubServices()
        let legacySocket = "/tmp/peekaboo-bridge-legacy-foreground-click-\(UUID().uuidString).sock"
        let legacyServer = PeekabooBridgeServer(
            services: legacyServices,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: previous...previous,
            allowedOperations: [.click],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let legacyHost = PeekabooBridgeHost(socketPath: legacySocket, server: legacyServer, allowedTeamIDs: [])
        try await legacyHost.startChecked()
        let legacyClient = TrustedBridgeClientFixture.make(socketPath: legacySocket, requestTimeoutSec: 2)
        _ = try await legacyClient.handshake(client: Self.clientIdentity, protocolVersion: previous)

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await legacyClient.clickWithOutcome(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .middle,
                snapshotId: nil)
        }
        #expect(legacyServices.automationStub.lastClick == nil)
        await legacyHost.stop()

        let currentServices = StubServices()
        currentServices.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        let currentSocket = "/tmp/peekaboo-bridge-current-foreground-click-\(UUID().uuidString).sock"
        let currentServer = PeekabooBridgeServer(
            services: currentServices,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.click],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let currentHost = PeekabooBridgeHost(socketPath: currentSocket, server: currentServer, allowedTeamIDs: [])
        try await currentHost.startChecked()
        defer { Task { await currentHost.stop() } }
        let currentClient = TrustedBridgeClientFixture.make(socketPath: currentSocket, requestTimeoutSec: 2)
        let handshake = try await currentClient.handshake(client: Self.clientIdentity)
        #expect(handshake.negotiatedVersion == PeekabooBridgeConstants.protocolVersion)
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.statelessClickVariants) == false)

        _ = try await currentClient.clickWithOutcome(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .middle,
            snapshotId: nil)
        #expect(currentServices.automationStub.lastClick?.type == .middle)
    }

    @Test
    @MainActor
    func `receiptless foreground middle click binds to authenticated protocol 1 30 peer`() async throws {
        let services = StubServices()
        services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .globalEvents, mode: .foreground),
            evidence: .deliveryAccepted)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.click],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            },
            processStartIdentityProvider: { $0 == 4242 ? 7 : nil })
        let liveIdentity = PeekabooBridgeLivePeerIdentity(
            auditToken: Data(repeating: 1, count: 32),
            processIdentifier: 4242,
            processIdentifierVersion: 3,
            effectiveUserIdentifier: getuid(),
            processStartIdentity: 7,
            codeSignatureHash: String(repeating: "a", count: 64))
        let peer = PeekabooBridgePeer(
            liveIdentity: liveIdentity,
            bundleIdentifier: nil,
            teamIdentifier: nil)
        let handshake = try await server.route(.handshake(.init(
            protocolVersion: PeekabooBridgeConstants.protocolVersion,
            client: Self.clientIdentity)), peer: peer)
        guard case let .handshake(response) = handshake.response else {
            Issue.record("Expected receiptless current handshake")
            return
        }
        #expect(response.operationSessionAttestation == nil)

        _ = try await server.route(.click(.init(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .middle,
            snapshotId: nil)), peer: peer)
        #expect(services.automationStub.lastClick?.type == .middle)

        let unrelatedPeer = PeekabooBridgePeer(
            liveIdentity: PeekabooBridgeLivePeerIdentity(
                auditToken: Data(repeating: 2, count: 32),
                processIdentifier: 4242,
                processIdentifierVersion: 3,
                effectiveUserIdentifier: getuid(),
                processStartIdentity: 7,
                codeSignatureHash: nil),
            bundleIdentifier: nil,
            teamIdentifier: nil)
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await server.route(.click(.init(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .triple,
                snapshotId: nil)), peer: unrelatedPeer)
        }

        let authorityRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-receiptless-mode-switch-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: authorityRoot) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: authorityRoot.appendingPathComponent("bridge.sock").path)
        let attestedClient = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.receiptless-mode-switch",
            teamIdentifier: nil,
            processIdentifier: liveIdentity.processIdentifier)
        let attestedHandshake = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(
            authority)
        {
            try await server.route(.handshake(.init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: attestedClient,
                operationClientInstanceID: UUID())), peer: peer)
        }
        guard case let .handshake(attestedResponse) = attestedHandshake.response else {
            Issue.record("Expected attested current handshake")
            return
        }
        #expect(attestedResponse.operationSessionAttestation != nil)
        #expect(server.receiptlessNegotiations[liveIdentity] == nil)
        await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            _ = try await server.route(.click(.init(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .middle,
                snapshotId: nil)), peer: peer)
        }
    }

    @Test
    @MainActor
    func `protocol 1 30 signs exact middle and triple click receipts with truthful units`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-current-click-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.statelessClickVariants) == true)
        let signedIdentity = WindowMutationIdentity(
            windowID: self.exactIdentity.windowID,
            ownerProcessIdentifier: self.exactIdentity.ownerProcessIdentifier,
            ownerProcessStartIdentity: self.exactIdentity.ownerProcessStartIdentity,
            capturedBounds: self.exactBounds)

        for (clickType, units) in [(ClickType.middle, 3), (.triple, 7)] {
            services.automationStub.actionOutcome = .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(units))
            let result = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: clickType,
                snapshotId: "snapshot",
                expectedWindowIdentity: signedIdentity,
                expectedWindowBounds: self.exactBounds)

            #expect(result.outcome?.dispatchState.unitCount?.rawValue == units)
            #expect(result.outcome?.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
            #expect(result.targetIdentity?.exactWindow?.identity == signedIdentity)
            #expect(services.automationStub.lastProcessTargetedClick?.type == clickType)
            let bundle = try #require(await client.lastOperationReceiptBundle())
            try bundle.validate()
            #expect(bundle.receipt.payload.target == .window(signedIdentity))
            #expect(bundle.receipt.payload.outcome?.dispatchState.unitCount?.rawValue == units)
        }

        let downgraded = try await client.handshake(
            client: Self.clientIdentity,
            protocolVersion: .init(major: 1, minor: 29))
        #expect(downgraded.hostCapabilities?.contains(PeekabooBridgeHostCapability.statelessClickVariants) == false)
        do {
            _ = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: .middle,
                snapshotId: "snapshot",
                expectedWindowIdentity: signedIdentity,
                expectedWindowBounds: self.exactBounds)
            Issue.record("Expected downgraded client refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.refusalReason == .runtimeIncompatible)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(services.automationStub.lastProcessTargetedClick?.type == .triple)
    }

    @Test
    @MainActor
    func `signed middle click preserves post-dispatch indeterminacy and exact target`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-indeterminate-click-\(UUID().uuidString).sock"
        let identity = WindowMutationIdentity(
            windowID: self.exactIdentity.windowID,
            ownerProcessIdentifier: self.exactIdentity.ownerProcessIdentifier,
            ownerProcessStartIdentity: self.exactIdentity.ownerProcessStartIdentity,
            capturedBounds: self.exactBounds)
        let services = StubServices()
        services.automationStub.actionOutcome = .indeterminate(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .completionUnknown,
            unitCount: .init(3))
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: true)
            })
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)

        do {
            _ = try await client.clickWithOutcome(
                target: .elementId("B1"),
                clickType: .middle,
                snapshotId: "snapshot",
                expectedWindowIdentity: identity,
                expectedWindowBounds: self.exactBounds)
            Issue.record("Expected retry-unsafe indeterminate click")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.dispatchState.unitCount?.rawValue == 3)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.escalation == .observeBeforeRetry)
        }
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.target == .window(identity))
        #expect(bundle.receipt.payload.outcome?.state == .indeterminate)
        #expect(bundle.receipt.payload.outcome?.dispatchState.unitCount?.rawValue == 3)
    }

    @Test
    @MainActor
    func `middle and triple clicks require post event permission before service dispatch`() async throws {
        for clickType in [ClickType.middle, .triple] {
            let services = StubServices()
            let server = PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: false, accessibility: true, postEvent: false)
                })
            let request = PeekabooBridgeRequest.targetedClick(.init(
                target: .elementId("B1"),
                clickType: clickType,
                snapshotId: "snapshot",
                targetProcessIdentifier: self.exactIdentity.ownerProcessIdentifier,
                targetWindowID: self.exactIdentity.windowID,
                expectedWindowIdentity: self.exactIdentity,
                expectedWindowBounds: self.exactBounds))
            let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
            let responseData = await PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.current) {
                await server.decodeAndHandle(requestData, peer: nil)
            }
            let response = try self.decode(responseData)

            guard case let .error(envelope) = response else {
                Issue.record("Expected Event Synthesizing refusal")
                continue
            }
            #expect(envelope.code == .permissionDenied)
            #expect(envelope.permission == .postEvent)
            #expect(services.automationStub.lastProcessTargetedClick == nil)
        }
    }

    @Test
    @MainActor
    func `targeted click operation reflects exact window requirement`() {
        let processRequest = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001))
        let windowRequest = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            targetWindowID: 42,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))

        #expect(processRequest.operation == .targetedClick)
        #expect(windowRequest.operation == .exactWindowTargetedClick)

        let services = PeekabooServices()
        #expect(services.ownsDesktopOperationLane(for: processRequest.operation))
        #expect(services.ownsDesktopOperationLane(for: windowRequest.operation))
    }

    @Test
    @MainActor
    func `exact window click requires exact window allowlist operation`() async throws {
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            targetWindowID: 42,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let permissions = PermissionsStatus(
            screenRecording: false,
            accessibility: true,
            appleScript: false,
            postEvent: false)

        let targetedOnly = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.targetedClick],
            permissionStatusEvaluator: { _ in permissions })
        let rejected = try await self.decode(targetedOnly.decodeAndHandle(requestData, peer: nil))
        guard case let .error(envelope) = rejected else {
            Issue.record("Expected exact-window request to be rejected, got \(rejected)")
            return
        }
        #expect(envelope.code == .operationNotSupported)

        let exactOnly = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.exactWindowTargetedClick],
            permissionStatusEvaluator: { _ in permissions })
        let accepted = try await self.decode(exactOnly.decodeAndHandle(requestData, peer: nil))
        guard case .ok = accepted else {
            Issue.record("Expected exact-window request to succeed, got \(accepted)")
            return
        }
    }

    @Test
    @MainActor
    func `automation targeted click is forwarded`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })

        let request = PeekabooBridgeRequest.targetedClick(
            PeekabooBridgeTargetedClickRequest(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001))
        let requestData = try JSONEncoder.peekabooBridgeEncoder().encode(request)
        let responseData = await server.decodeAndHandle(requestData, peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }

        let lastClick = services.automationStub.lastProcessTargetedClick
        if case let .elementId(id) = lastClick?.target {
            #expect(id == "B1")
        } else {
            Issue.record("Expected element click, got \(String(describing: lastClick?.target))")
        }
        #expect(lastClick?.type == .single)
        #expect(lastClick?.targetProcessIdentifier == 9001)
        #expect(lastClick?.targetWindowID == nil)
    }

    @Test
    @MainActor
    func `automation targeted click preserves exact window`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: 9001,
            targetWindowID: 42,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        #expect(services.automationStub.lastProcessTargetedClick?.targetWindowID == 42)
    }

    @Test
    @MainActor
    func `remote targeted click preserves actionable snapshot failures`() async throws {
        let cases: [(PeekabooError, PeekabooBridgeErrorCode, PeekabooBridgeErrorKind, String)] = [
            (.snapshotStale("window moved"), .invalidRequest, .snapshotStale, "window moved"),
            (.snapshotNotFound("expired"), .notFound, .snapshotNotFound, "expired"),
        ]
        for (error, expectedCode, expectedKind, expectedContext) in cases {
            let services = StubServices()
            services.automationStub.targetedClickError = error
            let server = PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: true,
                        appleScript: false,
                        postEvent: true)
                })
            let request = PeekabooBridgeRequest.targetedClick(.init(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001,
                targetWindowID: 42,
                expectedWindowIdentity: self.exactIdentity,
                expectedWindowBounds: self.exactBounds))

            let responseData = try await server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(request),
                peer: nil)
            guard case let .error(envelope) = try self.decode(responseData) else {
                Issue.record("Expected bridge error for \(error)")
                continue
            }
            #expect(envelope.code == expectedCode)
            #expect(envelope.message == error.localizedDescription)
            #expect(envelope.kind == expectedKind)
            #expect(envelope.context == expectedContext)
        }
    }

    @Test
    @MainActor
    func `remote targeted click restores snapshot errors from bridge envelopes`() async throws {
        let cases: [(PeekabooError, PeekabooBridgeErrorCode, PeekabooBridgeErrorKind, String)] = [
            (.snapshotStale("window moved"), .invalidRequest, .snapshotStale, "window moved"),
            (.snapshotNotFound("expired"), .notFound, .snapshotNotFound, "expired"),
        ]
        for (sourceError, code, expectedKind, context) in cases {
            let peer = try ScriptedBridgePeer(responses: [
                .handshake(Self.legacyUnprojectedHandshake),
                BridgeTestFixtures.errorResponse(
                    code: code,
                    message: sourceError.localizedDescription,
                    details: "\(sourceError)",
                    kind: expectedKind,
                    context: context),
            ])
            let client = try await self.legacyUnprojectedClient(socketPath: peer.socketPath)
            let remote = RemoteUIAutomationService(
                client: client,
                supportsTargetedClicks: true)

            do {
                try await remote.click(
                    target: .elementId("B1"),
                    clickType: .single,
                    snapshotId: "snapshot",
                    targetProcessIdentifier: getpid())
                Issue.record("Expected snapshot error")
            } catch let error as PeekabooError {
                switch (expectedKind, error) {
                case let (.snapshotStale, .snapshotStale(reason)):
                    #expect(reason == "window moved")
                case let (.snapshotNotFound, .snapshotNotFound(snapshotId)):
                    #expect(snapshotId == "expired")
                default:
                    Issue.record("Unexpected snapshot error: \(error)")
                }
            } catch {
                Issue.record("Unexpected bridge error: \(error)")
            }
            await peer.waitUntilFinished()
        }
    }

    @Test
    @MainActor
    func `real click service preserves stale snapshot diagnostic through bridge facade`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-real-stale-\(UUID().uuidString).sock"
        let services = PeekabooServices(
            snapshotManager: InMemorySnapshotManager(),
            inputPolicy: UIInputPolicy(defaultStrategy: .synthOnly))
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.legacyUnprojectedClient(socketPath: socketPath)
        let remote = RemoteUIAutomationService(
            client: client,
            supportsTargetedClicks: true,
            supportsExactWindowTargetedClicks: true)

        do {
            try await remote.click(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "expired-snapshot",
                targetProcessIdentifier: getpid())
            Issue.record("Expected stale snapshot error")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.message.contains("target element is no longer available"))
            #expect(failure.causeDescription == #"snapshotStale("target element is no longer available")"#)
        } catch {
            Issue.record("Unexpected bridge error: \(error)")
        }
    }

    @Test
    @MainActor
    func `targeted click is disabled when both delivery permissions are missing`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: false,
                    appleScript: false,
                    postEvent: false)
            })

        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)
        let handshakeRequest = PeekabooBridgeRequest.handshake(
            .init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

        let handshakeData = try JSONEncoder.peekabooBridgeEncoder().encode(handshakeRequest)
        let handshakeResponseData = await server.decodeAndHandle(handshakeData, peer: nil)
        let handshakeResponse = try self.decode(handshakeResponseData)

        guard case let .handshake(handshake) = handshakeResponse else {
            Issue.record("Expected handshake response, got \(handshakeResponse)")
            return
        }

        #expect(handshake.supportedOperations.contains(.targetedClick))
        #expect(handshake.enabledOperations?.contains(.targetedClick) == false)
        #expect(handshake.supportedOperations.contains(.exactWindowTargetedClick))
        #expect(handshake.enabledOperations?.contains(.exactWindowTargetedClick) == false)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.targetedClick.rawValue] == [.accessibility])
        #expect(handshake.permissionTags[PeekabooBridgeOperation.exactWindowTargetedClick.rawValue] == [.accessibility])
        #expect(handshake.supportedOperations.contains(.quitApplication))
        #expect(handshake.enabledOperations?.contains(.quitApplication) == true)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.quitApplication.rawValue] == [])
        #expect(handshake.enabledOperations?.contains(.hideApplication) == true)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.hideApplication.rawValue] == [])
    }

    @Test
    @MainActor
    func `targeted click requires accessibility now that delivery is AX-only`() async throws {
        // Positioned pid-routed mouse events mis-deliver at the window corner, so the synthetic
        // path was removed; Event Synthesizing permission alone no longer enables targeted clicks.
        for (accessibility, postEvent, expectedEnabled) in [
            (true, false, true),
            (true, true, true),
            (false, true, false),
        ] {
            let server = PeekabooBridgeServer(
                services: StubServices(),
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { postEvent },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: accessibility,
                        appleScript: false,
                        postEvent: postEvent)
                })
            let identity = PeekabooBridgeClientIdentity(
                bundleIdentifier: "dev.peeka.cli",
                teamIdentifier: "TEAMID",
                processIdentifier: getpid(),
                hostname: Host.current().name)
            let request = PeekabooBridgeRequest.handshake(.init(
                protocolVersion: PeekabooBridgeConstants.protocolVersion,
                client: identity,
                requestedHostKind: .gui))

            let responseData = try await server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(request),
                peer: nil)
            let response = try self.decode(responseData)
            guard case let .handshake(handshake) = response else {
                Issue.record("Expected handshake response, got \(response)")
                continue
            }

            #expect(handshake.enabledOperations?.contains(.targetedClick) == expectedEnabled)
            #expect(handshake.enabledOperations?.contains(.exactWindowTargetedClick) == expectedEnabled)
        }
    }

    @Test
    @MainActor
    func `protocol 1_8 targeted click retains its post event permission contract`() async throws {
        let server = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let identity = PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peeka.cli",
            teamIdentifier: "TEAMID",
            processIdentifier: getpid(),
            hostname: Host.current().name)
        let request = PeekabooBridgeRequest.handshake(.init(
            protocolVersion: .init(major: 1, minor: 8),
            client: identity,
            requestedHostKind: .gui))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        guard case let .handshake(handshake) = try self.decode(responseData) else {
            Issue.record("Expected handshake response")
            return
        }

        #expect(handshake.supportedOperations.contains(.targetedClick))
        #expect(handshake.enabledOperations?.contains(.targetedClick) == false)
        #expect(handshake.permissionTags[PeekabooBridgeOperation.targetedClick.rawValue] == [.postEvent])
    }

    @Test
    @MainActor
    func `accessibility-only host accepts single element targeted click`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001))

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil)
        let response = try self.decode(responseData)

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        #expect(services.automationStub.lastProcessTargetedClick?.type == .single)
    }

    @Test
    @MainActor
    func `accessibility-only host refuses PID only coordinate targeted clicks`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let payload = PeekabooBridgeTargetedClickRequest(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .single,
            snapshotId: nil,
            targetProcessIdentifier: 9001)

        let responseData = try await server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.targetedClick(payload)),
            peer: nil)
        let response = try self.decode(responseData)

        guard case let .error(error) = response else {
            Issue.record("Expected invalid request response, got \(response)")
            return
        }
        #expect(error.code == .invalidRequest)
        #expect(error.message.contains("PID-only"))
        #expect(services.automationStub.lastProcessTargetedClick == nil)
    }

    @Test
    @MainActor
    func `post event only host rejects targeted clicks with accessibility permission`() async throws {
        let requests: [PeekabooBridgeTargetedClickRequest] = [
            .init(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 9001),
            .init(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001),
        ]

        for payload in requests {
            let services = StubServices()
            let server = PeekabooBridgeServer(
                services: services,
                hostKind: .gui,
                allowlistedTeams: [],
                allowlistedBundles: [],
                postEventAccessEvaluator: { true },
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: false,
                        accessibility: false,
                        appleScript: false,
                        postEvent: true)
                })
            let responseData = try await server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(PeekabooBridgeRequest.targetedClick(payload)),
                peer: nil)
            let response = try self.decode(responseData)

            guard case let .error(envelope) = response else {
                Issue.record("Expected permission error, got \(response)")
                continue
            }
            #expect(envelope.code == .permissionDenied)
            #expect(envelope.permission == .accessibility)
            #expect(services.automationStub.lastProcessTargetedClick == nil)
        }
    }

    @Test
    @MainActor
    func `remote accessibility-only host allows element right click`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-right-click-\(UUID().uuidString).sock"
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.legacyUnprojectedClient(socketPath: socketPath)

        let remote = RemoteUIAutomationService(
            client: client,
            supportsTargetedClicks: true,
            targetedClickRequiresEventSynthesizingPermission: true)

        try await remote.click(
            target: .elementId("B1"),
            clickType: .right,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001)

        #expect(services.automationStub.lastProcessTargetedClick?.type == .right)
    }

    @Test
    @MainActor
    func `remote element right click preserves synthetic permission denial in canonical failure`() async throws {
        let socketPath = "/tmp/peekaboo-bridge-right-click-\(UUID().uuidString).sock"
        let services = StubServices()
        services.automationStub.targetedClickError = PeekabooError.permissionDeniedEventSynthesizing
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: false,
                    postEvent: false)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = try await self.legacyUnprojectedClient(socketPath: socketPath)

        let remote = RemoteUIAutomationService(
            client: client,
            supportsTargetedClicks: true,
            targetedClickRequiresEventSynthesizingPermission: true)

        do {
            try await remote.click(
                target: .query("Save"),
                clickType: .right,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001)
            Issue.record("Expected Event Synthesizing permission error")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.message == PeekabooError.permissionDeniedEventSynthesizing.localizedDescription)
            #expect(failure.causeDescription == "permissionDeniedEventSynthesizing")
        }
    }

    @Test
    @MainActor
    func `remote coordinate click is not preflight-rejected on an accessibility-only host`() async {
        // Current hosts deliver coordinate targeted clicks through accessibility, so the client
        // must not reject them for missing Event Synthesizing even when the legacy availability
        // flag is set. The request must reach transport (and here fail against a missing socket)
        // rather than throw `permissionDeniedEventSynthesizing` up front.
        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(
                socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                requestTimeoutSec: 0.1),
            supportsTargetedClicks: true,
            targetedClickRequiresEventSynthesizingPermission: true)

        do {
            try await remote.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                targetProcessIdentifier: 9001)
            Issue.record("Expected a transport error against the missing socket")
        } catch PeekabooError.permissionDeniedEventSynthesizing {
            Issue.record("Coordinate click must not be preflight-rejected for Event Synthesizing")
        } catch {
            // Expected: the request reached transport and failed to connect to the missing socket.
        }
    }

    @Test
    @MainActor
    func `remote exact window click rejects an older bridge before transport`() async {
        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(
                socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                requestTimeoutSec: 0.1),
            supportsTargetedClicks: true,
            supportsExactWindowTargetedClicks: false)

        do {
            try await remote.click(
                target: .coordinates(CGPoint(x: 10, y: 20)),
                clickType: .single,
                snapshotId: nil,
                expectedWindowIdentity: WindowMutationIdentity(
                    windowID: 42,
                    ownerProcessIdentifier: 9001,
                    ownerProcessStartIdentity: 1),
                expectedWindowBounds: CGRect(x: 0, y: 0, width: 100, height: 100))
            Issue.record("Expected exact-window capability error")
        } catch PeekabooError.serviceUnavailable {
            // Expected before the missing socket is contacted.
        } catch {
            Issue.record("Unexpected transport or capability error: \(error)")
        }
    }

    @Test
    func `pointer operations declare their actual permissions`() {
        #expect(PeekabooBridgeOperation.targetedHotkey.requiredPermissions == [.postEvent])
        #expect(PeekabooBridgeOperation.targetedClick.requiredPermissions == [.accessibility])
        #expect(PeekabooBridgeOperation.exactWindowTargetedClick.requiredPermissions == [.accessibility])
        #expect(PeekabooBridgeOperation.click.requiredPermissions == [.postEvent])
        #expect(PeekabooBridgeOperation.moveMouse.requiredPermissions == [.postEvent])
        #expect(PeekabooBridgeOperation.drag.requiredPermissions == [.postEvent])
        #expect(PeekabooBridgeOperation.swipe.requiredPermissions == [.postEvent])
        #expect(PeekabooBridgeOperation.scroll.requiredPermissions == [.postEvent])
        #expect(PeekabooBridgeOperation.targetedScroll.requiredPermissions == [.accessibility])
        #expect(!PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .elementId("B1"),
            clickType: .right))
        #expect(!PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .query("Save"),
            clickType: .right))
        #expect(PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .coordinates(CGPoint(x: 10, y: 20)),
            clickType: .right))
        #expect(PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .elementId("B1"),
            clickType: .double))
        #expect(PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .elementId("B1"),
            clickType: .middle))
        #expect(PeekabooBridgeTargetedClickRequest.requiresPostEventPermission(
            target: .query("Save"),
            clickType: .triple))
    }

    @Test
    @MainActor
    func `scroll bridge permission follows explicit delivery mode`() async throws {
        let background = PeekabooBridgeRequest.targetedScroll(PeekabooBridgeScrollRequest(request: ScrollRequest(
            direction: .down,
            amount: 1,
            target: "S1")))
        let foreground = PeekabooBridgeRequest.scroll(PeekabooBridgeScrollRequest(request: ScrollRequest(
            direction: .down,
            amount: 1,
            foreground: true)))

        let postEventOnly = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { true },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: false, postEvent: true)
            })
        let backgroundResponse = try await self.decode(postEventOnly.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(background),
            peer: nil))
        guard case let .error(backgroundError) = backgroundResponse else {
            Issue.record("Expected background scroll permission error")
            return
        }
        #expect(backgroundError.code == .versionMismatch)
        #expect(backgroundError.permission == nil)

        let accessibilityOnly = PeekabooBridgeServer(
            services: StubServices(),
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [],
            postEventAccessEvaluator: { false },
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: false, accessibility: true, postEvent: false)
            })
        let foregroundResponse = try await self.decode(accessibilityOnly.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(foreground),
            peer: nil))
        guard case let .error(foregroundError) = foregroundResponse else {
            Issue.record("Expected foreground scroll permission error")
            return
        }
        #expect(foregroundError.permission == .postEvent)
    }

    @Test
    @MainActor
    func `remote background scroll rejects stale bridge capability before transport`() async {
        let remote = RemoteUIAutomationService(
            client: PeekabooBridgeClient(
                socketPath: "/tmp/peekaboo-missing-\(UUID().uuidString).sock",
                requestTimeoutSec: 0.1),
            supportsTargetedScroll: false)

        do {
            try await remote.scroll(ScrollRequest(direction: .down, amount: 1, target: "S1"))
            Issue.record("Expected targeted-scroll capability error")
        } catch let error as PeekabooError {
            #expect(error.localizedDescription.contains("exact-window background scroll receipts"))
        } catch {
            Issue.record("Unexpected transport error: \(error)")
        }
    }

    @Test
    func `element action operations require accessibility permission`() {
        #expect(PeekabooBridgeOperation.setValue.requiredPermissions == [.accessibility])
        #expect(PeekabooBridgeOperation.performAction.requiredPermissions == [.accessibility])
    }

    @Test
    func `desktop observation operation requires screen recording permission`() {
        #expect(PeekabooBridgeOperation.desktopObservation.requiredPermissions == [.screenRecording])
    }

    @Test
    func `native application lifecycle operations do not require AppleScript permission`() {
        #expect(PeekabooBridgeOperation.activateApplication.requiredPermissions.isEmpty)
        #expect(PeekabooBridgeOperation.quitApplication.requiredPermissions.isEmpty)
        #expect(PeekabooBridgeOperation.hideApplication.requiredPermissions.isEmpty)
        #expect(PeekabooBridgeOperation.unhideApplication.requiredPermissions.isEmpty)
        #expect(PeekabooBridgeOperation.hideOtherApplications.requiredPermissions.isEmpty)
        #expect(PeekabooBridgeOperation.showAllApplications.requiredPermissions.isEmpty)
    }
}
