import CoreGraphics
import Foundation
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.serialized)
struct PeekabooBridgeHeldPointerLifecycleTests {
    private static let clientIdentity = PeekabooBridgeClientIdentity(
        bundleIdentifier: "dev.peekaboo.held-pointer-tests",
        teamIdentifier: nil,
        processIdentifier: getpid())

    @Test
    func `protocol 1 29 host is refused before held pointer request dispatch`() async throws {
        let fixture = await self.makeHost(protocolVersion: .init(major: 1, minor: 29))
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)

        #expect(handshake.negotiatedVersion == .init(major: 1, minor: 29))
        #expect(!handshake.supportedOperations.contains(.createExactWindowHeldPointerOwner))
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle) != true)
        await #expect(throws: PeekabooError.self) {
            _ = try await client.createExactWindowHeldPointerOwner()
        }
        #expect(await fixture.automation.createCount == 0)
        await fixture.host.stop()
    }

    @Test
    func `protocol 1 30 transports owner bound down and release lifecycle`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: Self.clientIdentity)
        #expect(handshake.hostCapabilities?.contains(
            PeekabooBridgeHostCapability.exactWindowHeldPointerLifecycle) == true)

        let owner = try await client.createExactWindowHeldPointerOwner()
        let request = fixture.automation.request
        let begin = try await client.beginExactWindowPointerHold(owner: owner, request: request)
        #expect(begin.outcome?.dispatchState.unitCount?.rawValue == 2)
        #expect(begin.targetIdentity?.exactWindow?.identity == request.windowIdentity)

        let release = try await client.releaseExactWindowPointerHold(
            owner: owner,
            receipt: begin.payload)
        #expect(release.payload.reason == .released)
        #expect(release.outcome?.dispatchState.unitCount?.rawValue == 1)
        #expect(release.payload.lifecycleDispatchedUnitCount == 3)
        #expect(await fixture.automation.terminalDispatchCount == 1)
        let retry = try await client.revokeExactWindowPointerHold(
            owner: owner,
            receipt: begin.payload)
        #expect(retry.payload == release.payload)
        #expect(await fixture.automation.terminalDispatchCount == 1)

        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.target == .window(request.windowIdentity))
        await fixture.host.stop()
    }

    @Test
    func `wrong owner receipt refuses with zero terminal dispatch`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()
        let otherOwner = try await client.createExactWindowHeldPointerOwner()
        let begin = try await client.beginExactWindowPointerHold(
            owner: owner,
            request: fixture.automation.request)

        do {
            _ = try await client.releaseExactWindowPointerHold(
                owner: otherOwner,
                receipt: begin.payload)
            Issue.record("Expected wrong-owner refusal")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .refused)
            #expect(failure.outcome.dispatchState == .none)
        }
        #expect(await fixture.automation.terminalDispatchCount == 0)
        _ = try await client.revokeExactWindowPointerHold(owner: owner, receipt: begin.payload)
        #expect(await fixture.automation.terminalDispatchCount == 1)
        await fixture.host.stop()
    }

    @Test
    func `Bridge owner disconnect reaches one terminal cleanup`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()
        _ = try await client.beginExactWindowPointerHold(
            owner: owner,
            request: fixture.automation.request)

        let result = try await client.disconnectExactWindowHeldPointerOwner(owner)
        #expect(result.payload?.reason == .ownerDisconnected)
        #expect(result.outcome?.dispatchState.unitCount?.rawValue == 1)
        #expect(await fixture.automation.terminalDispatchCount == 1)
        await fixture.host.stop()
    }

    @Test
    func `Bridge disconnect closes an idle owner as signed no change`() async throws {
        let fixture = await self.makeHost(protocolVersion: PeekabooBridgeConstants.protocolVersion)
        try await fixture.host.startChecked()
        defer { Task { await fixture.host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: fixture.socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(client: Self.clientIdentity)
        let owner = try await client.createExactWindowHeldPointerOwner()

        let result = try await client.disconnectExactWindowHeldPointerOwner(owner)
        #expect(result.payload == nil)
        #expect(result.outcome?.state == .confirmedNoChange)
        #expect(result.targetIdentity == nil)
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate()
        #expect(bundle.receipt.payload.target == .global)

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await client.disconnectExactWindowHeldPointerOwner(owner)
        }
        await fixture.host.stop()
    }

    private func makeHost(protocolVersion: PeekabooBridgeProtocolVersion) async -> HostFixture {
        await MainActor.run {
            let automation = HeldPointerBridgeAutomationStub()
            let services = StubServices(automation: automation)
            let socketPath = "/tmp/peekaboo-held-pointer-\(UUID().uuidString).sock"
            let server = PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                supportedVersions: protocolVersion...protocolVersion,
                allowedOperations: [
                    .createExactWindowHeldPointerOwner,
                    .beginExactWindowHeldPointer,
                    .releaseExactWindowHeldPointer,
                    .revokeExactWindowHeldPointer,
                    .disconnectExactWindowHeldPointerOwner,
                ],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(
                        screenRecording: true,
                        accessibility: true,
                        postEvent: true)
                })
            return HostFixture(
                socketPath: socketPath,
                host: PeekabooBridgeHost(
                    socketPath: socketPath,
                    server: server,
                    allowedTeamIDs: [],
                    requestTimeoutSec: 2),
                automation: automation)
        }
    }
}

private struct HostFixture: Sendable {
    let socketPath: String
    let host: PeekabooBridgeHost
    let automation: HeldPointerBridgeAutomationStub
}

@MainActor
private final class HeldPointerBridgeAutomationStub: ExactWindowHeldPointerLifecycleServiceProtocol {
    let supportsExactWindowHeldPointerLifecycle = true
    private(set) var createCount = 0
    private(set) var terminalDispatchCount = 0
    private var owners: Set<ExactWindowHeldPointerOwner> = []
    private var active: [ExactWindowHeldPointerOwner: ExactWindowHeldPointerReceipt] = [:]
    private var completed: [ExactWindowHeldPointerOwner: UIAutomationActionResult<ExactWindowHeldPointerTermination>] =
        [:]
    let request: ExactWindowHeldPointerRequest

    init() {
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        self.request = ExactWindowHeldPointerRequest(
            point: CGPoint(x: 50, y: 60),
            windowIdentity: WindowMutationIdentity(
                windowID: 901,
                ownerProcessIdentifier: 77001,
                ownerProcessStartIdentity: 88,
                capturedBounds: bounds),
            windowBounds: bounds,
            button: .left,
            expiresAfterSeconds: 10)
    }

    func createExactWindowHeldPointerOwner(
        boundTo _: ApplicationProcessIdentity?) async throws -> ExactWindowHeldPointerOwner
    {
        self.createCount += 1
        let owner = ExactWindowHeldPointerOwner()
        self.owners.insert(owner)
        return owner
    }

    func beginExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        request: ExactWindowHeldPointerRequest) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerReceipt>
    {
        guard self.owners.contains(owner), self.active[owner] == nil else {
            throw ExactWindowHeldPointerLifecycleError.ownerUnknown
        }
        let receipt = ExactWindowHeldPointerReceipt(
            token: UUID(),
            owner: owner,
            request: request,
            expiresAt: Date().addingTimeInterval(request.expiresAfterSeconds))
        self.active[owner] = receipt
        return try UIAutomationActionResult(
            payload: receipt,
            outcome: .dispatchedUnverified(
                delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .init(2)),
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: request.windowIdentity,
                bounds: request.windowBounds)))
    }

    func releaseExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        try self.terminate(owner: owner, receipt: receipt, reason: .released)
    }

    func revokeExactWindowPointerHold(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        try self.terminate(owner: owner, receipt: receipt, reason: .revoked)
    }

    func disconnectExactWindowHeldPointerOwner(
        _ owner: ExactWindowHeldPointerOwner) async throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination?>
    {
        guard let receipt = self.active[owner] else {
            guard self.owners.remove(owner) != nil else {
                throw ExactWindowHeldPointerLifecycleError.ownerUnknown
            }
            return UIAutomationActionResult(
                payload: nil,
                outcome: .confirmedNoChange(),
                targetIdentity: nil)
        }
        let result = try self.terminate(owner: owner, receipt: receipt, reason: .ownerDisconnected)
        self.owners.remove(owner)
        return UIAutomationActionResult(
            payload: result.payload,
            outcome: result.outcome,
            targetIdentity: result.targetIdentity)
    }

    private func terminate(
        owner: ExactWindowHeldPointerOwner,
        receipt: ExactWindowHeldPointerReceipt,
        reason: ExactWindowHeldPointerTerminalReason) throws
        -> UIAutomationActionResult<ExactWindowHeldPointerTermination>
    {
        guard self.active[owner] == receipt else {
            if let completed = self.completed[owner], completed.payload.receipt == receipt {
                return completed
            }
            throw ExactWindowHeldPointerLifecycleError.ownerMismatch
        }
        self.active.removeValue(forKey: owner)
        self.terminalDispatchCount += 1
        let outcome = DesktopActionOutcome.dispatchedUnverified(
            delivery: .init(mechanism: .windowTargetedEvents, mode: .background),
            evidence: .deliveryAccepted,
            unitCount: .one)
        let terminal = ExactWindowHeldPointerTermination(
            receipt: receipt,
            reason: reason,
            cleanupOutcome: outcome,
            lifecycleDispatchedUnitCount: 3)
        let result = try UIAutomationActionResult(
            payload: terminal,
            outcome: outcome,
            targetIdentity: DesktopTargetIdentity(exactWindow: UIAutomationTarget.ExactWindow(
                identity: receipt.windowIdentity,
                bounds: receipt.windowBounds)))
        self.completed[owner] = result
        return result
    }

    func detectElements(in _: Data, snapshotId _: String?, windowContext _: WindowContext?) async throws
    -> ElementDetectionResult {
        throw PeekabooError.notImplemented("test")
    }

    func click(target _: ClickTarget, clickType _: ClickType, snapshotId _: String?) async throws {}
    func type(
        text _: String,
        target _: String?,
        clearExisting _: Bool,
        typingDelay _: Int,
        snapshotId _: String?) async throws {}
    func typeActions(_: [TypeAction], cadence _: TypingCadence, snapshotId _: String?) async throws -> TypeResult {
        TypeResult(totalCharacters: 0, keyPresses: 0)
    }

    func scroll(_: ScrollRequest) async throws {}
    func hotkey(keys _: String, holdDuration _: Int) async throws {}
    func swipe(
        from _: CGPoint,
        to _: CGPoint,
        duration _: Int,
        steps _: Int,
        profile _: MouseMovementProfile) async throws {}
    func hasAccessibilityPermission() async -> Bool {
        true
    }

    func waitForElement(target _: ClickTarget, timeout _: TimeInterval, snapshotId _: String?) async throws
    -> WaitForElementResult {
        throw PeekabooError.notImplemented("test")
    }

    func drag(_: DragOperationRequest) async throws {}
    func moveMouse(to _: CGPoint, duration _: Int, steps _: Int, profile _: MouseMovementProfile) async throws {}
    func getFocusedElement() -> UIFocusInfo? {
        nil
    }

    func findElement(matching _: UIElementSearchCriteria, in _: String?) async throws -> DetectedElement {
        throw PeekabooError.notImplemented("test")
    }
}
