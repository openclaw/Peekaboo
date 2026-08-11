import Foundation
import PeekabooBridge
import PeekabooBridgeTestSupport
import PeekabooCore
import Testing
@testable import PeekabooCLI

struct BridgeStatusReportHintTests {
    private func candidate(
        socketPath: String,
        hostKind: PeekabooBridgeHostKind,
        permissions: PermissionsStatus
    ) -> BridgeCandidateReport {
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 1),
            hostKind: hostKind,
            build: nil,
            supportedOperations: [],
            permissions: permissions
        )
        return BridgeCandidateReport(
            socketPath: socketPath,
            result: .success(BridgeHandshakeReport(from: handshake))
        )
    }

    private func report(candidates: [BridgeCandidateReport]) -> BridgeStatusReport {
        BridgeStatusReport(
            remoteSkipped: false,
            remoteSkipReason: nil,
            selected: .local(),
            candidates: candidates,
            client: BridgeClientReport(identity: PeekabooBridgeClientIdentity(
                bundleIdentifier: nil,
                teamIdentifier: nil,
                processIdentifier: 1,
                hostname: nil
            ))
        )
    }

    @Test
    func `every denied candidate gets its own grant hint`() {
        let status = self.report(candidates: [
            self.candidate(
                socketPath: "/tmp/gui.sock",
                hostKind: .gui,
                permissions: PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: true,
                    postEvent: false
                )
            ),
            self.candidate(
                socketPath: "/tmp/helper.sock",
                hostKind: .helper,
                permissions: PermissionsStatus(
                    screenRecording: false,
                    accessibility: true,
                    appleScript: true,
                    postEvent: true
                )
            ),
        ])

        // `bridge status` prints a perm line per candidate, so a first-match-only hint would leave the
        // second host's denial visible but unexplained.
        let hints = status.bridgeDeniedPermissionsHints
        #expect(hints.count == 2)
        #expect(hints[0].contains("/tmp/gui.sock"))
        #expect(hints[0].contains("Event Synthesizing"))
        #expect(hints[0].contains("--capture-engine cg") == false)
        #expect(hints[1].contains("/tmp/helper.sock"))
        #expect(hints[1].contains("Screen Recording"))
        #expect(hints[1].contains("--capture-engine cg"))
    }

    @Test
    func `current native permissions produce no hints`() {
        let status = self.report(candidates: [
            self.candidate(
                socketPath: "/tmp/gui.sock",
                hostKind: .gui,
                permissions: PermissionsStatus(
                    screenRecording: true,
                    accessibility: true,
                    appleScript: false,
                    postEvent: true
                )
            ),
        ])

        #expect(status.bridgeDeniedPermissionsHints.isEmpty)
        guard case let .success(handshake) = status.candidates[0].result else {
            Issue.record("Expected a successful Bridge candidate")
            return
        }
        #expect(!status.candidates[0].humanSummary.contains("AS="))
        #expect(handshake.permissions?.appleScript == false)
    }

    @Test
    func `Bridge report preserves host generation build and launch capabilities`() throws {
        let identity = PeekabooBridgeHostIdentity(
            processIdentifier: 4242,
            processStartIdentity: 9_876_543,
            bundleIdentifier: "boo.peekaboo.mac",
            bundleShortVersion: "4.0.0",
            bundleVersion: "400",
            codeSignatureHash: "abcdef"
        )
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeProtocolVersion(major: 1, minor: 21),
            hostKind: .gui,
            build: "4.0.0 (400)",
            supportedOperations: [],
            hostIdentity: identity,
            hostCapabilities: [PeekabooBridgeHostCapability.backgroundBridgeHost]
        )
        let report = BridgeHandshakeReport(from: handshake)
        let selection = BridgeSelectionReport.remote(socketPath: "/tmp/gui.sock", handshake: report)

        #expect(report.hostIdentity == identity)
        #expect(report.hostCapabilities == [PeekabooBridgeHostCapability.backgroundBridgeHost])
        #expect(selection.humanSummary.contains("pid=4242"))

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        )
        #expect((object["hostIdentity"] as? [String: Any])?["processIdentifier"] as? Int == 4242)
        #expect(object["hostCapabilities"] as? [String] == [PeekabooBridgeHostCapability.backgroundBridgeHost])
    }
}
