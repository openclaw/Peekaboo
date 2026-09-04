import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge

@Suite(.serialized)
@MainActor
struct PeekabooBridgeAttestedFailureTests {
    @Test(arguments: [false, true])
    func `exact window handler failures return signed original errors`(
        peekabooError: Bool) async throws
    {
        let automation = ReceiptFailureAutomationService()
        automation.failure = peekabooError ? PeekabooError.invalidInput("original hotkey failure") :
            ReceiptHandlerError.boom
        let server = Self.server(automation: automation)
        let socketPath = "/tmp/peekaboo-receipt-failure-\(UUID().uuidString).sock"
        let host = PeekabooBridgeHost(socketPath: socketPath, server: server, allowedTeamIDs: [], requestTimeoutSec: 2)
        try await host.startChecked()
        defer { Task { await host.stop() } }
        let client = TrustedBridgeClientFixture.make(socketPath: socketPath, requestTimeoutSec: 2)
        let handshake = try await client.handshake(client: .init(
            bundleIdentifier: "dev.peekaboo.receipt-failure-tests", teamIdentifier: nil, processIdentifier: getpid()))
        let request = try Self.hotkeyRequest()

        do {
            _ = try await client.sendCarryingActionOutcome(request)
            Issue.record("Expected the scripted hotkey failure")
        } catch let failure as DesktopActionFailure {
            #expect(failure.outcome.state == .indeterminate || failure.outcome.state == .refused)
            #expect(failure.localizedDescription.contains("original hotkey failure"))
            #expect(!failure.localizedDescription.contains("required receipt envelope"))
        }
        #expect(automation.callCount == 1)
        let bundle = try #require(await client.lastOperationReceiptBundle())
        try bundle.validate(trustAnchor: .listenerAttestation(#require(handshake.operationAttestation)))
        let wireResponse = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self, from: bundle.canonicalResponse)
        guard case let .projectedAction(carriage) = wireResponse,
              case let .error(envelope) = carriage.response
        else {
            Issue.record("Expected a signed error response")
            return
        }
        #expect(envelope.message.contains("original hotkey failure"))
        #expect(envelope.actionOutcome != nil)
        #expect(bundle.receipt.payload.outcome == envelope.actionOutcome)
        await host.stop()
    }

    @Test(arguments: [false, true], [false, true])
    func `receipt archive failure reports internal error and whether execution occurred`(
        admissionRefused: Bool,
        noDispatchFailure: Bool) async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "peekaboo-receipt-archive-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let authority = try PeekabooBridgeOperationReceiptAuthority(
            socketPath: root.appendingPathComponent("bridge.sock").path)
        let session = try await OperationReceiptSessionFixture.make(authority: authority)
        // An existing destination deterministically fails the archive's exclusive atomic rename.
        let destination = URL(fileURLWithPath: authority.attestation.receiptArchiveDirectory)
            .appendingPathComponent("sessions")
            .appendingPathComponent(session.attestation.sessionID.uuidString.lowercased())
            .appendingPathComponent("0.json")
        try Data("existing receipt".utf8).write(to: destination)
        let automation = ReceiptFailureAutomationService()
        if noDispatchFailure {
            automation.failure = DesktopActionFailure.preDispatchRefusal(
                route: .bridge,
                reason: .targetUnavailable,
                message: "Original refusal before hotkey dispatch")
        }
        let server = Self.server(automation: automation)
        let payload = try session.request(
            authority: authority, sequence: 0, request: .projectedAction(.init(request: Self.hotkeyRequest())))
        let data = await PeekabooBridgeRequestContext.$operationReceiptAuthority.withValue(authority) {
            if admissionRefused {
                return await server.encodeAdmissionRefusal(.attestedOperation(payload), peer: session.peer)
            }
            return await server.handleDecoded(.attestedOperation(payload), peer: session.peer)
        }
        guard case let .error(envelope) = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeResponse.self, from: data)
        else {
            Issue.record("Expected an unsigned receipt-production error")
            return
        }
        #expect(envelope.code == .internalError)
        #expect(envelope.operationMayHaveCompleted == (!admissionRefused && !noDispatchFailure))
        #expect(envelope.message.contains("could not produce a signed receipt for exactWindowTargetedHotkey"))
        #expect(envelope.details?.contains("archive write failed") == true)
        #expect(automation.callCount == (admissionRefused ? 0 : 1))
    }

    private static func server(automation: ReceiptFailureAutomationService) -> PeekabooBridgeServer {
        PeekabooBridgeServer(
            services: StubServices(automation: automation),
            allowlistedTeams: [],
            allowlistedBundles: [],
            allowedOperations: [.exactWindowTargetedHotkey],
            permissionStatusEvaluator: { _ in
                PermissionsStatus(screenRecording: true, accessibility: true, postEvent: true)
            })
    }

    private static func hotkeyRequest() throws -> PeekabooBridgeRequest {
        let bounds = CGRect(x: 10, y: 20, width: 300, height: 200)
        let identity = try WindowMutationIdentity(
            windowID: 999_999,
            ownerProcessIdentifier: getpid(),
            ownerProcessStartIdentity: #require(SystemIdentityResolver.processStartIdentity(getpid())),
            capturedBounds: bounds)
        return .exactWindowTargetedHotkey(.init(
            keys: "cmd,n",
            holdDuration: 0,
            expectedWindowIdentity: identity,
            expectedWindowBounds: bounds))
    }
}

private enum ReceiptHandlerError: Error, LocalizedError {
    case boom

    var errorDescription: String? {
        "original hotkey failure"
    }
}

@MainActor
private final class ReceiptFailureAutomationService: StubAutomationService {
    var failure: any Error = ReceiptHandlerError.boom
    private(set) var callCount = 0

    override func hotkey(
        keys _: String,
        holdDuration _: Int,
        expectedWindowIdentity _: WindowMutationIdentity,
        expectedWindowBounds _: CGRect) async throws
    {
        self.callCount += 1
        throw self.failure
    }
}
