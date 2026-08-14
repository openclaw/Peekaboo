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
    func `bundle authorization refusal names the bundle allowlist instead of the team`() throws {
        let refusal = PeekabooBridgeErrorEnvelope(
            code: .unauthorizedClient,
            message: "Bundle boo.peekaboo.boundary-denied is not authorized"
        )

        let report = BridgeCandidateErrorReport
            .bridgeEnvelope(refusal)
        let hint = try #require(report.hint)

        #expect(report.message == refusal.message)
        #expect(hint.contains("bundle/signing identifier"))
        #expect(hint.contains("bundle allowlist"))
        #expect(hint.contains("TeamID") == false)
        #expect(hint.contains("PEEKABOO_ALLOW_UNSIGNED_SOCKET_CLIENTS") == false)
    }

    @Test
    func `team authorization refusal retains the signed-client remediation`() throws {
        let refusal = PeekabooBridgeErrorEnvelope(
            code: .unauthorizedClient,
            message: "Team NOT_ALLOWED is not authorized"
        )

        let hint = try #require(
            BridgeCandidateErrorReport.bridgeEnvelope(refusal).hint
        )

        #expect(hint.contains("allowed TeamID"))
        #expect(hint.contains("intended signed client"))
        #expect(hint.contains("DEBUG host only"))
    }

    @Test
    func `Bridge report preserves host generation build and launch capabilities`() throws {
        let identity = PeekabooBridgeHostIdentity(
            processIdentifier: 4242,
            processStartIdentity: 9_876_543,
            bundleIdentifier: "boo.peekaboo.mac",
            bundleShortVersion: "4.0.0",
            bundleVersion: "400",
            codeSignatureHash: "abcdef",
            sourceCommit: "0123456789abcdef0123456789abcdef01234567"
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
        #expect((object["hostIdentity"] as? [String: Any])?["sourceCommit"] as? String ==
            "0123456789abcdef0123456789abcdef01234567")
        #expect(object["hostCapabilities"] as? [String] == [PeekabooBridgeHostCapability.backgroundBridgeHost])
    }
}
