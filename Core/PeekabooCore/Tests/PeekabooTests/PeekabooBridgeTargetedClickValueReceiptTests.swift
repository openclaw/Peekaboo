import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import PeekabooFoundationTestSupport
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@Suite(.serialized)
struct PeekabooBridgeTargetedClickValueReceiptTests {
    @Test
    func `exact text field focus click returns an attested value-delivery receipt`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pbor-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        defer { try? FileManager.default.removeItem(at: root) }
        let generation = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        let bounds = CGRect(x: 10, y: 20, width: 600, height: 400)
        let identity = WindowMutationIdentity(
            windowID: 74,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: generation,
            capturedBounds: bounds)
        let exactWindow = try UIAutomationTarget.ExactWindow(identity: identity, bounds: bounds)
        let services = await MainActor.run {
            let services = StubServices()
            services.automationStub.actionOutcome = .confirmedChange(
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                unitCount: .one)
            services.automationStub.supportsTargetedClickAccessibilityValueDelivery = true
            services.automationStub.uiAutomationOutcomeTargetIdentity = DesktopTargetIdentity(
                exactWindow: exactWindow)
            return services
        }
        let server = await MainActor.run {
            PeekabooBridgeServer(
                services: services,
                allowlistedTeams: [],
                allowlistedBundles: [],
                permissionStatusEvaluator: { _ in
                    PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
                })
        }
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [])
        try await host.startChecked()

        do {
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath)
            _ = try await client.handshake(client: Self.clientIdentity)
            let result = try await client.clickWithOutcome(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                expectedWindowIdentity: identity,
                expectedWindowBounds: bounds)
            #expect(result.outcome?.delivery?.mechanism == .accessibilityValue)
            #expect(result.targetIdentity?.exactWindow == exactWindow)
            #expect(await MainActor.run {
                services.automationStub.lastAllowsAccessibilityValueDelivery == true
            })
            let receipt = try #require(await client.lastOperationReceipt())
            #expect(receipt.payload.operation == .exactWindowTargetedClick)
            #expect(receipt.payload.target == .window(identity))
            let evidence = ExactWindowClickEvidence(identity: identity, bounds: bounds)
            let allowedRequest = Self.request(evidence: evidence, policy: true)
            let allowedHash = try PeekabooBridgeOperationReceiptCoding.sha256(allowedRequest)
            #expect(receipt.payload.requestSHA256 == allowedHash)

            let explicitResult = try await client.clickWithOutcome(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                windowEvidence: evidence,
                allowsAccessibilityValueDelivery: true)
            #expect(explicitResult.outcome == result.outcome)
            #expect(explicitResult.targetIdentity == result.targetIdentity)
            let explicitReceipt = try #require(await client.lastOperationReceipt())
            #expect(explicitReceipt.payload.requestSHA256 == receipt.payload.requestSHA256)
            #expect(explicitReceipt.payload.requestID != receipt.payload.requestID)

            await MainActor.run {
                services.automationStub.actionOutcome = .confirmedChange(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    unitCount: .one)
            }
            let remote = await MainActor.run {
                RemoteUIAutomationService(
                    client: client,
                    supportsTargetedClicks: true,
                    supportsProcessGenerationPinnedClicks: true,
                    supportsTargetedClickAccessibilityValueDelivery: true,
                    supportsExactWindowTargetedClicks: true)
            }
            let actionResult = try await remote.clickWithOutcome(
                target: .elementId("field"),
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                windowEvidence: ExactWindowClickEvidence(identity: identity, bounds: bounds),
                allowsAccessibilityValueDelivery: false)
            #expect(actionResult.outcome?.delivery?.mechanism == .accessibilityAction)
            #expect(await MainActor.run {
                services.automationStub.lastAllowsAccessibilityValueDelivery == false
            })
            #expect(actionResult.targetIdentity?.exactWindow == exactWindow)
            #expect(actionResult.outcome?.dispatchState.unitCount == .one)
            let deniedReceipt = try #require(await client.lastOperationReceipt())
            let deniedRequest = Self.request(evidence: evidence, policy: false)
            let deniedHash = try PeekabooBridgeOperationReceiptCoding.sha256(deniedRequest)
            #expect(deniedReceipt.payload.requestSHA256 == deniedHash)
            #expect(deniedReceipt.payload.requestSHA256 != receipt.payload.requestSHA256)
            #expect(deniedReceipt.payload.target == .window(identity))

            // Native positional AXPress reports accepted delivery without a count; the Bridge fills one AX unit.
            await MainActor.run {
                services.automationStub.actionOutcome = .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityAction, mode: .background),
                    evidence: .deliveryAccepted)
            }
            let coordinateTarget = ClickTarget.coordinates(CGPoint(x: 30, y: 40))
            let coordinateResult = try await client.clickWithOutcome(
                target: coordinateTarget,
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                windowEvidence: evidence,
                allowsAccessibilityValueDelivery: false)
            let expectedOutcome = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityAction, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
            #expect(coordinateResult.outcome == expectedOutcome)
            #expect(coordinateResult.targetIdentity?.exactWindow == exactWindow)
            let coordinateReceipt = try #require(await client.lastOperationReceipt())
            #expect(coordinateReceipt.payload.outcome == expectedOutcome.projection)
            #expect(coordinateReceipt.payload.target == .window(identity))
            let coordinateHash = try PeekabooBridgeOperationReceiptCoding.sha256(
                Self.request(evidence: evidence, policy: false, target: coordinateTarget))
            #expect(coordinateReceipt.payload.requestSHA256 == coordinateHash)

            // Positional focus/selection uses the same one-unit normalization without confirming its effect.
            await MainActor.run {
                services.automationStub.actionOutcome = .dispatchedUnverified(
                    delivery: .init(mechanism: .accessibilityValue, mode: .background),
                    evidence: .deliveryAccepted)
            }
            let valueResult = try await client.clickWithOutcome(
                target: coordinateTarget,
                clickType: .single,
                snapshotId: SnapshotReferenceFixtures.first.rawValue,
                windowEvidence: evidence,
                allowsAccessibilityValueDelivery: true)
            let valueOutcome = DesktopActionOutcome.dispatchedUnverified(
                route: .bridge,
                delivery: .init(mechanism: .accessibilityValue, mode: .background),
                evidence: .deliveryAccepted,
                unitCount: .one)
            #expect(valueResult.outcome == valueOutcome)
            #expect(valueResult.targetIdentity?.exactWindow == exactWindow)
            let valueReceipt = try #require(await client.lastOperationReceipt())
            #expect(valueReceipt.payload.outcome == valueOutcome.projection)
            #expect(valueReceipt.payload.target == .window(identity))
            let valueHash = try PeekabooBridgeOperationReceiptCoding.sha256(
                Self.request(evidence: evidence, policy: true, target: coordinateTarget))
            #expect(valueReceipt.payload.requestSHA256 == valueHash)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    private static func request(
        evidence: ExactWindowClickEvidence,
        policy: Bool?,
        target: ClickTarget = .elementId("field")) -> PeekabooBridgeRequest
    {
        .projectedAction(.init(request: .targetedClick(.init(
            target: target,
            clickType: .single,
            snapshotId: SnapshotReferenceFixtures.first.rawValue,
            targetProcessIdentifier: evidence.identity.ownerProcessIdentifier,
            targetWindowID: evidence.identity.windowID,
            expectedWindowIdentity: evidence.identity,
            expectedWindowBounds: evidence.bounds,
            allowsAccessibilityValueDelivery: policy))))
    }

    private static var clientIdentity: PeekabooBridgeClientIdentity {
        PeekabooBridgeClientIdentity(
            bundleIdentifier: "dev.peekaboo.focus-receipt-tests",
            teamIdentifier: nil,
            processIdentifier: getpid(),
            hostname: nil)
    }
}
