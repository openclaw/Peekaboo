import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
@MainActor
struct PeekabooBridgeCompositeTypeDeliveryTests {
    private static let snapshotID = SnapshotReferenceFixtures.first.rawValue
    private static let previousVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 35)
    private static let featureVersion = PeekabooBridgeProtocolVersion(major: 1, minor: 36)
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.composite-type-delivery-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    @Test
    func `protocol 1 36 gates AX-capable background type requests`() {
        let operations: Set<PeekabooBridgeOperation> = [
            .targetedTypeActions,
            .exactWindowTargetedTypeActions,
            .exactWindowPixelFocusType,
        ]
        let processIdentity = ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: 71)
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let windowIdentity = WindowMutationIdentity(
            windowID: 91,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: 71,
            capturedBounds: bounds)
        let plain = PeekabooBridgeRequest.targetedTypeActions(.init(
            actions: [.text("plain")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: getpid(),
            expectedProcessIdentity: processIdentity))
        let eventOnly = PeekabooBridgeRequest.targetedTypeActions(.init(
            actions: [.key(.return)],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: getpid(),
            expectedProcessIdentity: processIdentity))
        let clear = PeekabooBridgeRequest.exactWindowTargetedTypeActions(.init(
            actions: [.clear, .text("literal")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: Self.snapshotID,
            expectedWindowIdentity: windowIdentity,
            expectedWindowBounds: bounds,
            expectedFocusedElement: nil))
        let pixelClear = PeekabooBridgeRequest.exactWindowPixelFocusType(.init(request: .init(
            point: CGPoint(x: 30, y: 40),
            actions: [.clear],
            cadence: .fixed(milliseconds: 0),
            snapshotID: Self.snapshotID,
            windowIdentity: windowIdentity,
            windowBounds: bounds)))

        #expect(PeekabooBridgeConstants.protocolVersion >= Self.featureVersion)
        #expect(PeekabooBridgeConstants.compositeTypeDeliveryVersion == Self.featureVersion)
        #expect(PeekabooBridgeOperation.compatible(operations, with: Self.previousVersion) == operations)
        #expect(plain.minimumNegotiatedProtocolVersion == Self.featureVersion)
        #expect(eventOnly.minimumNegotiatedProtocolVersion == nil)
        #expect(clear.minimumNegotiatedProtocolVersion == Self.featureVersion)
        #expect(pixelClear.minimumNegotiatedProtocolVersion == Self.featureVersion)
    }

    @Test
    func `protocol 1 35 session dispatches event-only type but refuses AX-capable input before service entry`()
        async throws
    {
        let automation = CompositeTypeAutomationService()
        let services = StubServices(automation: automation)
        let identity = try ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid())))
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .processTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        automation.uiAutomationOutcomeTargetIdentity = try DesktopTargetIdentity(
            processIdentity: identity)
        let fixture = try await self.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...Self.featureVersion,
            allowedOperations: [.targetedTypeActions])
        defer { Task { await fixture.host.stop() } }

        let handshake = try await fixture.client.handshake(
            client: Self.clientIdentity,
            protocolVersion: Self.previousVersion)
        #expect(handshake.supportedOperations.contains(.targetedTypeActions))
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.compositeTypeDelivery) != true)

        let eventOnly = try await fixture.client.typeActionsWithOutcome(
            [.key(.return)],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            expectedProcessIdentity: identity)
        #expect(eventOnly.payload.totalCharacters == 0)
        #expect(eventOnly.payload.keyPresses == 1)
        #expect(automation.targetedTypeCallCount == 1)

        let refusedActions: [[TypeAction]] = [[.text("x")], [.clear, .text("x")]]
        for actions in refusedActions {
            do {
                _ = try await fixture.client.typeActionsWithOutcome(
                    actions,
                    cadence: .fixed(milliseconds: 0),
                    snapshotId: nil,
                    expectedProcessIdentity: identity)
                Issue.record("Expected protocol 1.35 AX-capable typing to refuse before transport")
            } catch let failure as DesktopActionFailure {
                #expect(failure.outcome.state == .refused)
                #expect(failure.outcome.dispatchState == .none)
                #expect(failure.outcome.refusalReason == .runtimeIncompatible)
                #expect(failure.outcome.retrySafety == .safe)
            }
        }
        #expect(automation.targetedTypeCallCount == 1)
        await fixture.host.stop()
    }

    @Test
    func `current server rejects an old clear session before its handler`() throws {
        let automation = CompositeTypeAutomationService()
        let services = StubServices(automation: automation)
        let identity = try ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid())))
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.targetedTypeActions])
        let request = PeekabooBridgeRequest.targetedTypeActions(.init(
            actions: [.clear],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))

        do {
            try PeekabooBridgeRequestContext.$negotiatedSessionCapabilities.withValue(.init(
                protocolVersion: Self.previousVersion,
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                compositeTypeDelivery: false))
            {
                let permissions = PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    postEvent: true)
                try server.validateOperationAccess(
                    for: request,
                    peer: nil,
                    permissions: permissions,
                    effectiveOps: server.effectiveAllowedOperations(
                        for: request,
                        permissions: permissions))
            }
            Issue.record("Expected old-session server admission refusal")
        } catch let envelope as PeekabooBridgeErrorEnvelope {
            #expect(envelope.code == .operationNotSupported)
        }
        #expect(automation.targetedTypeCallCount == 0)
    }

    @Test
    func `old attested clear session receives a signed no-dispatch refusal`() async throws {
        let root = URL(
            fileURLWithPath: "/tmp/peekaboo-composite-type-session-\(UUID().uuidString)",
            isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("authority.sock").path)
        let session = try await OperationReceiptSessionFixture.make(
            authority: authority,
            negotiatedCapabilities: .init(
                protocolVersion: Self.previousVersion,
                statelessClickVariants: true,
                exactWindowHeldPointerLifecycle: true,
                compositeTypeDelivery: false))
        let automation = CompositeTypeAutomationService()
        let services = StubServices(automation: automation)
        let identity = try ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid())))
        let inner = PeekabooBridgeRequest.targetedTypeActions(.init(
            actions: [.clear],
            cadence: .fixed(milliseconds: 0),
            snapshotId: nil,
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))
        let request = PeekabooBridgeRequest.projectedAction(.init(request: inner))
        let payload = session.request(authority: authority, sequence: 0, request: request)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.targetedTypeActions])

        let data = try await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            try await server.handleAttestedOperation(payload, peer: session.peer)
        }
        guard case let .attestedOperation(attested) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self,
            from: data)
        else {
            Issue.record("Expected a signed old-session refusal")
            return
        }
        let bundle = try OperationReceiptSessionFixture.bundle(
            authority: authority,
            sessionAttestation: session.attestation,
            receipt: attested.receipt,
            request: request,
            response: attested.response)
        try bundle.validateIntegrity()
        let outcome = try #require(bundle.receipt.payload.outcome)
        #expect(outcome.state == .refused)
        #expect(outcome.dispatchState == .none)
        #expect(outcome.refusalReason == .runtimeIncompatible)
        #expect(outcome.retrySafety == .safe)
        #expect(automation.targetedTypeCallCount == 0)
    }

    @Test
    func `current host omits type delivery capability when its provider cannot attest it`() async throws {
        let automation = CompositeTypeAutomationService()
        automation.compositeTypeDeliverySupported = false
        let services = StubServices(automation: automation)
        let identity = try ApplicationProcessIdentity(
            processIdentifier: getpid(),
            processStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid())))
        let fixture = try await self.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...Self.featureVersion,
            allowedOperations: [.targetedTypeActions])
        defer { Task { await fixture.host.stop() } }
        let handshake = try await fixture.client.handshake(client: Self.clientIdentity)

        #expect(handshake.supportedOperations.contains(.targetedTypeActions))
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.compositeTypeDelivery) != true)
        await #expect(throws: DesktopActionFailure.self) {
            _ = try await fixture.client.typeActionsWithOutcome(
                [.text("x")],
                cadence: .fixed(milliseconds: 0),
                snapshotId: nil,
                expectedProcessIdentity: identity)
        }
        #expect(automation.targetedTypeCallCount == 0)
        await fixture.host.stop()
    }

    @Test
    func `current host omits type delivery capability without an outcome provider`() async throws {
        let automation = NonOutcomeCompositeTypeAutomationService()
        let services = StubServices(automation: automation)
        let fixture = try await self.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...Self.featureVersion,
            allowedOperations: [.exactWindowTargetedTypeActions])
        defer { Task { await fixture.host.stop() } }
        let handshake = try await fixture.client.handshake(client: Self.clientIdentity)

        #expect(handshake.supportedOperations.contains(.exactWindowTargetedTypeActions))
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.compositeTypeDelivery) != true)
        await fixture.host.stop()
    }

    @Test
    func `protocol 1 36 signs exact AX clear composite typing and keyboard fallback counts`() async throws {
        let automation = CompositeTypeAutomationService()
        let services = StubServices(automation: automation)
        let target = try self.exactTarget()
        let fixture = try await self.startHost(
            services: services,
            supportedVersions: PeekabooBridgeConstants.minimumProtocolVersion...Self.featureVersion,
            allowedOperations: [.exactWindowTargetedTypeActions])
        defer { Task { await fixture.host.stop() } }
        let handshake = try await fixture.client.handshake(client: Self.clientIdentity)
        #expect(handshake.hostCapabilities?.contains(PeekabooBridgeHostCapability.compositeTypeDelivery) == true)

        automation.typeResultOverride = TypeResult(totalCharacters: 0, keyPresses: 0)
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .accessibilityValue, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        automation.uiAutomationOutcomeTargetIdentity = DesktopTargetIdentity(
            exactWindow: target.exactWindow)
        let clear = try await fixture.client.typeActionsWithOutcome(
            [.clear],
            cadence: .fixed(milliseconds: 0),
            snapshotId: Self.snapshotID,
            target: target.keyboardTarget)
        #expect(clear.payload.totalCharacters == 0)
        #expect(clear.payload.keyPresses == 0)
        #expect(clear.outcome?.delivery == .init(mechanism: .accessibilityValue, mode: .background))
        #expect(clear.outcome?.dispatchState.unitCount == .one)

        automation.typeResultOverride = TypeResult(totalCharacters: 1, keyPresses: 1)
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .composite, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(2))
        let composite = try await fixture.client.typeActionsWithOutcome(
            [.clear, .text("x")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: Self.snapshotID,
            target: target.keyboardTarget)
        #expect(composite.payload.totalCharacters == 1)
        #expect(composite.payload.keyPresses == 1)
        #expect(composite.outcome?.delivery == .init(mechanism: .composite, mode: .background))
        #expect(composite.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))

        automation.typeResultOverride = TypeResult(totalCharacters: 1, keyPresses: 3)
        automation.actionOutcome = .dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(3))
        let fallback = try await fixture.client.typeActionsWithOutcome(
            [.clear, .text("x")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: Self.snapshotID,
            target: target.keyboardTarget)
        #expect(fallback.payload.totalCharacters == 1)
        #expect(fallback.payload.keyPresses == 3)
        #expect(fallback.outcome?.delivery == .init(mechanism: .windowTargetedEvents, mode: .background))
        #expect(fallback.outcome?.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(3))
        #expect(automation.exactTypeCallCount == 3)
        await fixture.host.stop()
    }

    private func startHost(
        services: StubServices,
        supportedVersions: ClosedRange<PeekabooBridgeProtocolVersion>,
        allowedOperations: Set<PeekabooBridgeOperation>) async throws
        -> (host: PeekabooBridgeHost, client: PeekabooBridgeClient)
    {
        let socketPath = "/tmp/peekaboo-composite-type-\(UUID().uuidString).sock"
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            supportedVersions: supportedVersions,
            allowedOperations: allowedOperations,
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()
        return (
            host,
            TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2))
    }

    private func exactTarget() throws -> (
        exactWindow: UIAutomationTarget.ExactWindow,
        keyboardTarget: ExactWindowKeyboardTarget)
    {
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = WindowMutationIdentity(
            windowID: 999_999,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds)
        let focused = FocusedElementIdentity(
            processIdentifier: getpid(),
            windowID: identity.windowID,
            role: "AXTextField",
            identifier: "editor",
            frame: CGRect(x: 30, y: 40, width: 120, height: 30))
        return try (
            UIAutomationTarget.ExactWindow(
                identity: identity,
                bounds: bounds,
                focusedElement: focused),
            ExactWindowKeyboardTarget(
                windowIdentity: identity,
                windowBounds: bounds,
                focusedElement: focused))
    }
}

@MainActor
private final class CompositeTypeAutomationService: StubAutomationService {
    var compositeTypeDeliverySupported = true
    override var supportsExactWindowCompositeTypeDelivery: Bool {
        self.compositeTypeDeliverySupported
    }

    let exactWindowCompositeTypeDeliveryUnavailableReason: String? = nil
    var typeResultOverride: TypeResult?
    private(set) var targetedTypeCallCount = 0
    private(set) var exactTypeCallCount = 0

    override func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedProcessIdentity _: ApplicationProcessIdentity) async throws -> TypeResult
    {
        self.targetedTypeCallCount += 1
        return self.typeResultOverride ?? BridgeTestFixtures.typeResult(for: actions)
    }

    override func typeActions(
        _ actions: [TypeAction],
        cadence _: TypingCadence,
        snapshotId _: String?,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws -> TypeResult
    {
        self.exactTypeCallCount += 1
        return self.typeResultOverride ?? BridgeTestFixtures.typeResult(for: actions)
    }
}

@MainActor
private final class NonOutcomeCompositeTypeAutomationService: ExactWindowTargetedKeyboardServiceProtocol {
    private let base = StubAutomationService()

    let supportsExactWindowTargetedKeyboard = true
    let exactWindowTargetedKeyboardUnavailableReason: String? = nil
    let supportsExactWindowCompositeTypeDelivery = true
    let exactWindowCompositeTypeDeliveryUnavailableReason: String? = nil

    func detectElements(
        in imageData: Data,
        snapshotId: String?,
        windowContext: WindowContext?) async throws -> ElementDetectionResult
    {
        try await self.base.detectElements(
            in: imageData,
            snapshotId: snapshotId,
            windowContext: windowContext)
    }

    func click(target: ClickTarget, clickType: ClickType, snapshotId: String?) async throws {
        try await self.base.click(target: target, clickType: clickType, snapshotId: snapshotId)
    }

    func type(
        text: String,
        target: String?,
        clearExisting: Bool,
        typingDelay: Int,
        snapshotId: String?) async throws
    {
        try await self.base.type(
            text: text,
            target: target,
            clearExisting: clearExisting,
            typingDelay: typingDelay,
            snapshotId: snapshotId)
    }

    func typeActions(
        _ actions: [TypeAction],
        cadence: TypingCadence,
        snapshotId: String?) async throws -> TypeResult
    {
        try await self.base.typeActions(actions, cadence: cadence, snapshotId: snapshotId)
    }

    func scroll(_ request: ScrollRequest) async throws {
        try await self.base.scroll(request)
    }

    func hotkey(keys: String, holdDuration: Int) async throws {
        try await self.base.hotkey(keys: keys, holdDuration: holdDuration)
    }

    func swipe(
        from: CGPoint,
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        try await self.base.swipe(from: from, to: to, duration: duration, steps: steps, profile: profile)
    }

    func hasAccessibilityPermission() async -> Bool {
        await self.base.hasAccessibilityPermission()
    }

    func waitForElement(
        target: ClickTarget,
        timeout: TimeInterval,
        snapshotId: String?) async throws -> WaitForElementResult
    {
        try await self.base.waitForElement(target: target, timeout: timeout, snapshotId: snapshotId)
    }

    func drag(_ request: DragOperationRequest) async throws {
        try await self.base.drag(request)
    }

    func moveMouse(
        to: CGPoint,
        duration: Int,
        steps: Int,
        profile: MouseMovementProfile) async throws
    {
        try await self.base.moveMouse(to: to, duration: duration, steps: steps, profile: profile)
    }

    func getFocusedElement() -> UIFocusInfo? {
        self.base.getFocusedElement()
    }

    func findElement(
        matching criteria: UIElementSearchCriteria,
        in appName: String?) async throws -> DetectedElement
    {
        try await self.base.findElement(matching: criteria, in: appName)
    }
}
