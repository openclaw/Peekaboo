import Foundation
import PeekabooFoundation
import Testing
@testable import PeekabooAutomationKit
@testable import PeekabooBridge

@Suite(.serialized)
@MainActor
struct PeekabooBridgeSetValueHostClientTests {
    @Test
    func `production signing accepts exact readbacks and never attests lossy coercion`() async throws {
        let root = URL(fileURLWithPath: "/tmp/pksv-\(UUID().uuidString)", isDirectory: true)
        let socketPath = root.appendingPathComponent("bridge.sock").path
        let archiveNamespace = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekabooOperationReceipts", isDirectory: true)
            .appendingPathComponent(
                PeekabooBridgeOperationReceiptCoding.sha256(Data(socketPath.utf8)),
                isDirectory: true)
        try #require(!FileManager.default.fileExists(atPath: root.path))
        try #require(!FileManager.default.fileExists(atPath: archiveNamespace.path))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: archiveNamespace)
        }
        let store = DesktopMutationWatermarkStore(directoryURL: root.appendingPathComponent("watermarks"))
        let snapshots = InMemorySnapshotManager(desktopMutationWatermarkStore: store)
        let automation = WitnessResultAutomation()
        let identity = try DesktopTargetIdentity(processIdentity: .init(
            processIdentifier: getpid(),
            processStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid()))))
        let ownSignature = try #require(PeekabooBridgeCodeSignatureIdentity
            .codeSignatureHash(processIdentifier: getpid()))
        automation.uiAutomationOutcomeTargetIdentity = identity
        automation.actionOutcome = .confirmedChange(
            delivery: .init(mechanism: .accessibilityValue, mode: .background), unitCount: .one)
        let services = StubServices(automation: automation, snapshots: snapshots)
        let server = PeekabooBridgeServer(
            services: services,
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.setValue],
            hostIdentity: .init(
                processIdentifier: getpid(),
                processStartIdentity: identity.processIdentity.processStartIdentity,
                bundleIdentifier: nil,
                bundleShortVersion: nil,
                bundleVersion: nil,
                codeSignatureHash: ownSignature),
            desktopMutationWatermarkStore: store,
            desktopOperationLaneCoordinator: .init(coordinationRootURL: root.appendingPathComponent("lanes")),
            postEventAccessEvaluator: { true },
            permissionStatusEvaluator: { _ in
                .init(screenRecording: true, accessibility: true, appleScript: false, postEvent: true)
            })
        let host = PeekabooBridgeHost(
            socketPath: socketPath, server: server, allowedTeamIDs: [], requestTimeoutSec: 2)
        do {
            try await host.startChecked()
            let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
            let handshake = try await client.handshake(client: Self.clientIdentity)
            let attestation = try #require(handshake.operationAttestation)
            let archive = URL(fileURLWithPath: attestation.receiptArchiveDirectory, isDirectory: true)
            try #require(archive.deletingLastPathComponent().standardizedFileURL == archiveNamespace
                .standardizedFileURL)
            #expect(handshake.enabledOperations?.contains(.setValue) == true)
            let positives: [(UIElementValue, ElementValueVerification)] = [
                (.bool(false), .init(
                    attribute: .value, resolvedKind: .bool, readback: .double(0), legacyPresentation: "false")),
                (.bool(true), .init(
                    attribute: .value, resolvedKind: .bool, readback: .double(1), legacyPresentation: "true")),
                (.int(58), .init(attribute: .value, resolvedKind: .double, readback: .double(57.99999999999999))),
            ]
            for (requested, observation) in positives {
                automation.observation = observation
                let before = automation.invocationCount
                let result = try await client.setValueWithOutcome(
                    target: "synthetic-control", value: requested, snapshotId: "synthetic-snapshot")
                #expect(automation.invocationCount == before + 1)
                #expect(automation.lastValue == requested)
                #expect(result.outcome?.state == .confirmedChange)
                #expect(result.targetIdentity == identity)
                #expect(result.payload.valueVerification == observation)
                let bundle = try #require(await client.lastOperationReceiptBundle())
                try bundle.validateIntegrity()
                #expect(bundle.operationAttestation == attestation)
                #expect(bundle.receipt.payload.outcome?.state == .confirmedChange)
            }
            let negatives: [(UIElementValue, ElementValueVerification)] = [
                (.bool(false), .init(attribute: .value, resolvedKind: .bool, readback: .double(0.5))),
                (.bool(true), .init(attribute: .value, resolvedKind: .bool, readback: .double(1.5))),
                (.string("1.0000000000000001"), .init(attribute: .value, resolvedKind: .int, readback: .int(1))),
            ]
            for (requested, observation) in negatives {
                // Fresh clients cannot accidentally retain one of the earlier successful receipts.
                let rejectedClient = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
                let rejectedHandshake = try await rejectedClient.handshake(client: Self.clientIdentity)
                #expect(rejectedHandshake.negotiatedVersion == handshake.negotiatedVersion)
                #expect(rejectedHandshake.enabledOperations?.contains(.setValue) == true)
                #expect(await rejectedClient.lastOperationReceiptBundle() == nil)
                let session = try #require(rejectedHandshake.operationSessionAttestation)
                let receiptFile = archive.appendingPathComponent("sessions")
                    .appendingPathComponent(session.sessionID.uuidString.lowercased())
                    .appendingPathComponent("0.json")
                #expect(!FileManager.default.fileExists(atPath: receiptFile.path))
                automation.observation = observation
                let before = automation.invocationCount
                var rejected = false
                do {
                    _ = try await rejectedClient.setValueWithOutcome(
                        target: "synthetic-control", value: requested, snapshotId: "synthetic-snapshot")
                    Issue.record("Invalid injected readback returned success")
                } catch {
                    rejected = true
                    if let failure = error as? DesktopActionFailure {
                        #expect(failure.outcome.state == .indeterminate || failure.outcome.state == .refused)
                    }
                    print("Synthetic value rejection: \(String(describing: type(of: error)))")
                }
                #expect(rejected)
                #expect(automation.invocationCount == before + 1)
                #expect(automation.lastValue == requested)
                let retained = await rejectedClient.lastOperationReceiptBundle()
                if let retained {
                    try retained.validateIntegrity()
                    #expect(retained.receipt.payload.outcome?.state == .indeterminate ||
                        retained.receipt.payload.outcome?.state == .refused)
                }
                let archived = FileManager.default.fileExists(atPath: receiptFile.path)
                if archived {
                    let receipt = try JSONDecoder.peekabooBridgeDecoder().decode(
                        PeekabooBridgeOperationReceipt.self, from: Data(contentsOf: receiptFile))
                    try receipt.validateSignature(publicKey: attestation.publicKey)
                    #expect(receipt.payload.outcome?.state == .indeterminate || receipt.payload.outcome?
                        .state == .refused)
                }
                print("Synthetic rejected value receipt: retained=\(retained != nil), archived=\(archived)")
            }
            #expect(automation.invocationCount == positives.count + negatives.count)
        } catch {
            await host.stop()
            throw error
        }
        await host.stop()
    }

    private static var clientIdentity: PeekabooBridgeClientIdentity {
        .init(bundleIdentifier: "dev.peekaboo.synthetic-value-tests", teamIdentifier: nil, processIdentifier: getpid())
    }
}

@MainActor
private final class WitnessResultAutomation: StubAutomationService {
    var observation = ElementValueVerification(attribute: .value, resolvedKind: .bool, readback: .bool(false))
    private(set) var invocationCount = 0
    private(set) var lastValue: UIElementValue?

    override func setValue(
        target: String,
        value: UIElementValue,
        snapshotId _: String?) async throws -> ElementActionResult
    {
        self.invocationCount += 1
        self.lastValue = value
        return ElementActionResult(
            target: target,
            actionName: "AXSetValue",
            anchorPoint: nil,
            newValue: self.observation.displayString,
            valueVerification: self.observation)
    }
}
