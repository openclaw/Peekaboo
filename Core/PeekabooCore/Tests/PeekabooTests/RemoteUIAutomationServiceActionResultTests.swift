import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
@MainActor
struct RemoteUIAutomationServiceActionResultTests {
    @Test
    func `remote held pointer capability defaults closed and accepts negotiated support`() {
        let client = PeekabooBridgeClient(
            socketPath: "/tmp/peekaboo-unused-held-capability-\(UUID().uuidString).sock",
            requestTimeoutSec: 1)
        let unsupported = RemoteUIAutomationService(client: client)
        let supported = RemoteUIAutomationService(
            client: client,
            supportsExactWindowHeldPointerLifecycle: true)

        #expect(!unsupported.supportsExactWindowHeldPointerLifecycle)
        #expect(supported.supportsExactWindowHeldPointerLifecycle)
    }

    @Test
    func `remote global pointer automation preserves canonical results and signed global receipts`() async throws {
        let fixture = try await Self.makeFixture()
        defer { Task { await fixture.host.stop() } }
        let pointerProvider: any UIAutomationGlobalPointerActionResultProviding = fixture.remote

        let drag = try await pointerProvider.dragWithOutcome(.init(
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 30, y: 40),
            duration: 0,
            steps: 1,
            modifiers: nil,
            profile: .linear))
        try await Self.expectGlobalPointerResult(drag, operation: .drag, client: fixture.client)

        let move = try await pointerProvider.moveMouseWithOutcome(
            to: CGPoint(x: 50, y: 60),
            duration: 0,
            steps: 1,
            profile: .linear)
        try await Self.expectGlobalPointerResult(move, operation: .moveMouse, client: fixture.client)

        await fixture.host.stop()
    }

    @Test
    func `legacy remote global pointer automation keeps receiptless success compatibility`() async throws {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: .init(major: 1, minor: 22),
            supportedOperations: [.drag, .moveMouse])
        let peer = try ScriptedBridgePeer(responses: [
            .handshake(handshake),
            .ok,
            .ok,
        ])
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.remote-global-pointer-legacy-tests",
            teamIdentifier: nil,
            processIdentifier: getpid()))
        let remote = RemoteUIAutomationService(client: client)

        let drag = try await remote.dragWithOutcome(.init(
            from: CGPoint(x: 10, y: 20),
            to: CGPoint(x: 30, y: 40),
            duration: 0,
            steps: 1,
            modifiers: nil,
            profile: .linear))
        let move = try await remote.moveMouseWithOutcome(
            to: CGPoint(x: 50, y: 60),
            duration: 0,
            steps: 1,
            profile: .linear)

        #expect(drag.outcome == nil)
        #expect(drag.targetIdentity == nil)
        #expect(move.outcome == nil)
        #expect(move.targetIdentity == nil)
        await peer.waitUntilFinished()
    }

    @Test
    func `remote drag cancellation remains retry unsafe with a signed global receipt`() async throws {
        let fixture = try await Self.makeFixture()
        defer { Task { await fixture.host.stop() } }
        fixture.services.automationStub.dragError = CancellationError()

        do {
            _ = try await fixture.remote.dragWithOutcome(.init(
                from: CGPoint(x: 10, y: 20),
                to: CGPoint(x: 30, y: 40),
                duration: 0,
                steps: 1,
                modifiers: nil,
                profile: .linear))
            Issue.record("Expected post-admission drag cancellation to remain indeterminate")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate)
            #expect(failure.outcome.route == .bridge)
            #expect(failure.outcome.evidence == .completionUnknown)
            #expect(failure.outcome.retrySafety == .unsafe)
            #expect(failure.outcome.dispatchState.mutationDispatched)

            let receipt = try #require(await fixture.client.lastOperationReceipt())
            #expect(receipt.payload.operation == .drag)
            #expect(receipt.payload.target == .global)
            #expect(receipt.payload.outcome == failure.outcome.projection)
        }

        await fixture.host.stop()
    }

    @Test
    func `remote automation preserves canonical results exact targets and signed receipts`() async throws {
        let fixture = try await Self.makeFixture()
        defer { Task { await fixture.host.stop() } }

        let outcomeProvider: any UIAutomationActionOutcomeProviding = fixture.remote
        let accessibilityDelivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityAction,
            mode: .background)
        let windowDelivery = DesktopActionOutcome.Delivery(
            mechanism: .windowTargetedEvents,
            mode: .background)
        let valueDelivery = DesktopActionOutcome.Delivery(
            mechanism: .accessibilityValue,
            mode: .background)

        fixture.services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: accessibilityDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let click = try await outcomeProvider.clickWithOutcome(
            target: .query("Save"),
            clickType: .single,
            snapshotId: "S1",
            expectedWindowIdentity: fixture.windowIdentity,
            expectedWindowBounds: fixture.windowBounds)
        try await Self.expect(
            click,
            outcome: fixture.services.automationStub.actionOutcome,
            target: fixture.target,
            operation: .exactWindowTargetedClick,
            client: fixture.client)

        fixture.services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: accessibilityDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let type = try await outcomeProvider.typeWithOutcome(
            text: "hello",
            target: "T1",
            clearExisting: true,
            typingDelay: 0,
            snapshotId: "S1")
        try await Self.expect(
            type,
            outcome: fixture.services.automationStub.actionOutcome,
            target: fixture.target,
            operation: .type,
            client: fixture.client)

        fixture.services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: windowDelivery,
            evidence: .deliveryAccepted,
            unitCount: DesktopActionOutcome.DispatchUnitCount(5))
        let typeActions = try await outcomeProvider.typeActionsWithOutcome(
            [.text("world")],
            cadence: .fixed(milliseconds: 0),
            snapshotId: "S1",
            expectedWindowIdentity: fixture.windowIdentity,
            expectedWindowBounds: fixture.windowBounds)
        try await Self.expect(
            typeActions,
            outcome: fixture.services.automationStub.actionOutcome,
            target: fixture.target,
            operation: .exactWindowTargetedTypeActions,
            client: fixture.client)

        fixture.services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: accessibilityDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let scroll = try await outcomeProvider.scrollWithOutcome(ScrollRequest(
            direction: .down,
            amount: 3,
            target: "T1",
            snapshotId: "S1"))
        try await Self.expect(
            scroll,
            outcome: fixture.services.automationStub.actionOutcome,
            target: fixture.target,
            operation: .targetedScroll,
            client: fixture.client)

        fixture.services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: windowDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let hotkey = try await outcomeProvider.hotkeyWithOutcome(
            keys: "cmd,s",
            holdDuration: 0,
            expectedWindowIdentity: fixture.windowIdentity,
            expectedWindowBounds: fixture.windowBounds)
        try await Self.expect(
            hotkey,
            outcome: fixture.services.automationStub.actionOutcome,
            target: fixture.target,
            operation: .exactWindowTargetedHotkey,
            client: fixture.client)

        fixture.services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: valueDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let setValue = try await outcomeProvider.setValueWithOutcome(
            target: "T1",
            value: .string("updated"),
            snapshotId: "S1")
        try await Self.expect(
            setValue,
            outcome: fixture.services.automationStub.actionOutcome,
            target: fixture.target,
            operation: .setValue,
            client: fixture.client)

        fixture.services.automationStub.actionOutcome = .dispatchedUnverified(
            delivery: accessibilityDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one)
        let action = try await outcomeProvider.performActionWithOutcome(
            target: "B1",
            actionName: "AXPress",
            snapshotId: "S1")
        try await Self.expect(
            action,
            outcome: fixture.services.automationStub.actionOutcome,
            target: fixture.target,
            operation: .performAction,
            client: fixture.client)

        await fixture.host.stop()
    }

    @Test
    func `remote automation turns a returned non success result into an exact attributed failure`() async throws {
        let fixture = try await Self.makeFixture()
        defer { Task { await fixture.host.stop() } }
        let returnedOutcome = DesktopActionOutcome.partial(
            delivery: .init(mechanism: .accessibilityAction, mode: .background),
            unitCount: .one)
        fixture.services.automationStub.actionOutcome = returnedOutcome

        do {
            _ = try await fixture.remote.clickWithOutcome(
                target: .query("Save"),
                clickType: .single,
                snapshotId: "S1",
                expectedWindowIdentity: fixture.windowIdentity,
                expectedWindowBounds: fixture.windowBounds)
            Issue.record("Expected the returned partial result to cross Bridge as a canonical failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome == returnedOutcome.routed(to: .bridge))
            #expect(failure.targetReceipt == DesktopActionTargetReceipt(
                processIdentifier: fixture.windowIdentity.ownerProcessIdentifier,
                processStartIdentity: fixture.windowIdentity.ownerProcessStartIdentity,
                windowID: fixture.windowIdentity.windowID))
        }

        let receipt = try #require(await fixture.client.lastOperationReceipt())
        #expect(receipt.payload.operation == .exactWindowTargetedClick)
        #expect(receipt.payload.target == .window(fixture.windowIdentity))
        #expect(receipt.payload.outcome == returnedOutcome.routed(to: .bridge).projection)
        await fixture.host.stop()
    }

    private static func expect(
        _ result: UIAutomationActionResult<some Sendable>,
        outcome: DesktopActionOutcome,
        target: DesktopTargetIdentity,
        operation: PeekabooBridgeOperation,
        client: PeekabooBridgeClient) async throws
    {
        let routedOutcome = outcome.routed(to: .bridge)
        #expect(result.outcome == routedOutcome)
        #expect(result.targetIdentity == target)
        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.operation == operation)
        #expect(try receipt.payload.target == .window(#require(target.exactWindow).identity))
        #expect(receipt.payload.outcome == routedOutcome.projection)
    }

    private static func expectGlobalPointerResult(
        _ result: UIAutomationActionResult<Void>,
        operation: PeekabooBridgeOperation,
        client: PeekabooBridgeClient) async throws
    {
        let outcome = try #require(result.outcome)
        #expect(outcome.state == .dispatchedUnverified)
        #expect(outcome.route == .bridge)
        #expect(outcome.delivery == .init(mechanism: .globalEvents, mode: .foreground))
        #expect(outcome.dispatchState.unitCount == .one)
        #expect(result.targetIdentity == nil)

        let receipt = try #require(await client.lastOperationReceipt())
        #expect(receipt.payload.operation == operation)
        #expect(receipt.payload.target == .global)
        #expect(receipt.payload.outcome == outcome.projection)
    }

    private static func makeFixture() async throws -> Fixture {
        let processIdentifier = getpid()
        let processStartIdentity = try #require(
            SystemIdentityResolver.processStartIdentity(processIdentifier))
        let windowBounds = CGRect(x: 0, y: 0, width: 800, height: 600)
        let windowIdentity = WindowMutationIdentity(
            windowID: 999_999,
            ownerProcessIdentifier: processIdentifier,
            ownerProcessStartIdentity: processStartIdentity,
            capturedBounds: windowBounds)
        let target = try DesktopTargetIdentity(exactWindow: .init(
            identity: windowIdentity,
            bounds: windowBounds))
        let services = StubServices()
        services.automationStub.uiAutomationOutcomeTargetIdentity = target
        let socketPath = "/tmp/peekaboo-remote-ui-results-\(UUID().uuidString).sock"
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
                    postEvent: true)
            },
            windowOwnerProcessIdentifierProvider: { _ in processIdentifier },
            windowBoundsProvider: { _ in windowBounds },
            processStartIdentityProvider: { _ in processStartIdentity })
        let host = PeekabooBridgeHost(
            socketPath: socketPath,
            server: server,
            allowedTeamIDs: [],
            requestTimeoutSec: 2)
        try await host.startChecked()

        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.remote-ui-result-tests",
            teamIdentifier: nil,
            processIdentifier: processIdentifier))
        let remote = RemoteElementActionUIAutomationService(
            client: client,
            supportsTargetedHotkeys: true,
            supportsProcessGenerationPinnedHotkeys: true,
            supportsTargetedTypeActions: true,
            supportsProcessGenerationPinnedTypeActions: true,
            supportsTargetedClicks: true,
            supportsProcessGenerationPinnedClicks: true,
            supportsExactWindowTargetedClicks: true,
            supportsTargetedScroll: true,
            supportsExactWindowTargetedKeyboard: true)
        return Fixture(
            services: services,
            host: host,
            client: client,
            remote: remote,
            windowIdentity: windowIdentity,
            windowBounds: windowBounds,
            target: target)
    }
}

@MainActor
private struct Fixture {
    let services: StubServices
    let host: PeekabooBridgeHost
    let client: PeekabooBridgeClient
    let remote: RemoteElementActionUIAutomationService
    let windowIdentity: WindowMutationIdentity
    let windowBounds: CGRect
    let target: DesktopTargetIdentity
}
