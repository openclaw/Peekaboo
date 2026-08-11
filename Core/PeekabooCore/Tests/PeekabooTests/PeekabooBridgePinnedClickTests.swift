import CoreGraphics
import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import Testing

struct PeekabooBridgePinnedClickTests {
    private let exactIdentity = WindowMutationIdentity(
        windowID: 42,
        ownerProcessIdentifier: 9001,
        ownerProcessStartIdentity: 1)
    private let exactBounds = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func decode(_ data: Data) throws -> PeekabooBridgeResponse {
        try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeResponse.self, from: data)
    }

    @Test
    @MainActor
    func `automation targeted click forwards process-generation receipt`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let identity = ApplicationProcessIdentity(processIdentifier: 9001, processStartIdentity: 71)
        let request = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: identity.processIdentifier,
            expectedProcessIdentity: identity))

        let response = try await self.decode(server.decodeAndHandle(
            JSONEncoder.peekabooBridgeEncoder().encode(request),
            peer: nil))

        guard case .ok = response else {
            Issue.record("Expected ok response, got \(response)")
            return
        }
        #expect(services.automationStub.lastProcessTargetedClick?.expectedProcessIdentity == identity)
    }

    @Test
    @MainActor
    func `targeted click rejects mismatched or duplicate process receipts before dispatch`() async throws {
        let services = StubServices()
        let server = PeekabooBridgeServer(
            services: services,
            hostKind: .gui,
            allowlistedTeams: [],
            allowlistedBundles: [])
        let mismatch = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            expectedProcessIdentity: .init(processIdentifier: 9002, processStartIdentity: 71)))
        let duplicate = PeekabooBridgeRequest.targetedClick(.init(
            target: .elementId("B1"),
            clickType: .single,
            snapshotId: "snapshot",
            targetProcessIdentifier: 9001,
            expectedProcessIdentity: .init(processIdentifier: 9001, processStartIdentity: 71),
            targetWindowID: 42,
            expectedWindowIdentity: self.exactIdentity,
            expectedWindowBounds: self.exactBounds))

        for request in [mismatch, duplicate] {
            let response = try await self.decode(server.decodeAndHandle(
                JSONEncoder.peekabooBridgeEncoder().encode(request),
                peer: nil))
            guard case let .error(error) = response else {
                Issue.record("Expected invalid request, got \(response)")
                continue
            }
            #expect(error.code == .invalidRequest)
        }
        #expect(services.automationStub.lastProcessTargetedClick?.targetProcessIdentifier == nil)
    }

    @Test
    func `legacy targeted click payload decodes without process receipt`() throws {
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(
            PeekabooBridgeTargetedClickRequest(
                target: .elementId("B1"),
                clickType: .single,
                snapshotId: "snapshot",
                targetProcessIdentifier: 9001))

        let payload = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeTargetedClickRequest.self,
            from: data)

        #expect(payload.expectedProcessIdentity == nil)
    }
}
