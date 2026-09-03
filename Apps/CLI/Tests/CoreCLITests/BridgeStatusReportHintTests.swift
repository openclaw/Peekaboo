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
        permissions: PermissionsStatus,
        selectionEligible: Bool = false,
        rejection: BridgeCandidateRejectionReport? = nil
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
            result: .success(BridgeHandshakeReport(from: handshake)),
            selectionEligible: selectionEligible,
            rejection: rejection
        )
    }

    private func report(
        selected: BridgeSelectionReport = .local(),
        candidates: [BridgeCandidateReport]
    ) -> BridgeStatusReport {
        BridgeStatusReport(
            remoteSkipped: false,
            remoteSkipReason: nil,
            selected: selected,
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
    func `unauthorized implicit GUI rejection is visible without verbose diagnostics`() throws {
        let socketPath = "/tmp/gui.sock"
        let failure = BridgeCandidateErrorReport.bridgeEnvelope(PeekabooBridgeErrorEnvelope(
            code: .unauthorizedClient,
            message: "Team TEST is not authorized"
        ))
        let rejection = try #require(BridgeCandidateRejectionReport.bridgeFailure(failure))
        let status = self.report(candidates: [BridgeCandidateReport(
            socketPath: socketPath,
            result: .failure(failure),
            selectionEligible: true,
            rejection: rejection
        )])

        #expect(status.localFallbackWarningLines.count == 2)
        #expect(status.localFallbackWarningLines[0].contains("using local (in-process) fallback"))
        #expect(status.localFallbackWarningLines[1].contains(socketPath))
        #expect(status.localFallbackWarningLines[1].contains("unauthorizedClient"))

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(status)) as? [String: Any]
        )
        let candidates = try #require(object["candidates"] as? [[String: Any]])
        let candidate = try #require(candidates.first)
        #expect(Set(object.keys) == ["remoteSkipped", "selected", "candidates", "client"])
        #expect(Set(candidate.keys) == ["socketPath", "result"])
        #expect(candidate["selectionEligible"] == nil)
        #expect(candidate["rejection"] == nil)
        #expect(object["fallback"] == nil)
    }

    @Test
    func `permission and capability rejections retain the resolver decision`() async throws {
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: "/tmp/gui.sock",
            requireReusableDaemon: false,
            requiredHostKind: .gui,
            requiresValidatedHistoricalDaemon: false
        )
        var options = CommandRuntimeOptions()
        options.requiredElementActionOperations = [.setValue]

        let missingPermissionHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            supportedOperations: [.setValue, .performAction],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: false,
                appleScript: false,
                postEvent: true
            ),
            hostCapabilities: [
                PeekabooBridgeHostCapability.attestedOperationReceipts,
                PeekabooBridgeHostCapability.setValueResultTargetBinding,
                PeekabooBridgeHostCapability.processGenerationBoundElementMutations,
            ]
        )
        let permissionEvaluation = await RuntimeHostResolver.evaluateRemoteCandidate(
            candidate,
            handshake: missingPermissionHandshake,
            options: options
        )
        #expect(permissionEvaluation.validation == nil)
        #expect(permissionEvaluation.rejection == .missingPermissions([.accessibility]))
        let permissionRejection = try #require(permissionEvaluation.rejection)
        let permissionReport = BridgeCandidateRejectionReport.runtime(
            permissionRejection,
            handshake: missingPermissionHandshake
        )
        #expect(permissionReport.code == "missingPermissions")
        #expect(permissionReport.message.contains("Accessibility"))

        let missingCapabilityHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            supportedOperations: [],
            permissions: PermissionsStatus(
                screenRecording: true,
                accessibility: true,
                appleScript: false,
                postEvent: true
            )
        )
        let capabilityEvaluation = await RuntimeHostResolver.evaluateRemoteCandidate(
            candidate,
            handshake: missingCapabilityHandshake,
            options: options
        )
        #expect(capabilityEvaluation.validation == nil)
        #expect(capabilityEvaluation.rejection == .requirementsNotMet)
        let capabilityRejection = try #require(capabilityEvaluation.rejection)
        let capabilityReport = BridgeCandidateRejectionReport.runtime(
            capabilityRejection,
            handshake: missingCapabilityHandshake
        )
        #expect(capabilityReport.code == "requirementsNotMet")

        let wrongHostKindHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .helper,
            supportedOperations: [.setValue, .performAction]
        )
        let hostKindEvaluation = await RuntimeHostResolver.evaluateRemoteCandidate(
            candidate,
            handshake: wrongHostKindHandshake,
            options: CommandRuntimeOptions()
        )
        #expect(hostKindEvaluation.validation == nil)
        #expect(hostKindEvaluation.rejection == .hostKindMismatch(expected: .gui))
        let hostKindRejection = try #require(hostKindEvaluation.rejection)
        let hostKindReport = BridgeCandidateRejectionReport.runtime(
            hostKindRejection,
            handshake: wrongHostKindHandshake
        )
        #expect(hostKindReport.code == "hostKindMismatch")
        #expect(hostKindReport.message == "Host kind helper does not match required gui role.")
    }

    @Test
    func `successful implicit GUI selection has no fallback warning`() async {
        let socketPath = "/tmp/gui.sock"
        let candidate = RuntimeHostResolver.ImplicitRemoteCandidate(
            socketPath: socketPath,
            requireReusableDaemon: false,
            requiredHostKind: .gui,
            requiresValidatedHistoricalDaemon: false
        )
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "4.2.0",
            supportedOperations: [.permissionsStatus]
        )
        let evaluation = await RuntimeHostResolver.evaluateRemoteCandidate(
            candidate,
            handshake: handshake,
            options: CommandRuntimeOptions()
        )
        #expect(evaluation.validation != nil)
        #expect(evaluation.rejection == nil)

        let handshakeReport = BridgeHandshakeReport(from: handshake)
        let status = self.report(
            selected: .remote(socketPath: socketPath, handshake: handshakeReport),
            candidates: [BridgeCandidateReport(
                socketPath: socketPath,
                result: .success(handshakeReport),
                selectionEligible: true
            )]
        )
        #expect(status.localFallbackWarningLines.isEmpty)
        #expect(status.selected.source == .remote)
        #expect(status.selected.socketPath == socketPath)
    }

    @Test
    func `JSON encoding preserves the established full status report`() throws {
        let socketPath = "/tmp/gui.sock"
        let handshake = BridgeTestFixtures.handshake(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "4.2.0",
            supportedOperations: PeekabooBridgeOperation.allCases,
            hostCapabilities: [
                PeekabooBridgeHostCapability.backgroundBridgeHost,
                PeekabooBridgeHostCapability.attestedOperationReceipts,
            ]
        )
        let handshakeReport = BridgeHandshakeReport(from: handshake)
        let status = self.report(
            selected: .remote(socketPath: socketPath, handshake: handshakeReport),
            candidates: [BridgeCandidateReport(
                socketPath: socketPath,
                result: .success(handshakeReport),
                selectionEligible: true
            )]
        )

        let data = try JSONEncoder().encode(status)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let selected = try #require(object["selected"] as? [String: Any])
        let selectedHandshake = try #require(selected["handshake"] as? [String: Any])
        let candidates = try #require(object["candidates"] as? [[String: Any]])
        let encodedCandidate = try #require(candidates.first)
        let candidateResult = try #require(encodedCandidate["result"] as? [String: Any])
        let success = try #require(candidateResult["success"] as? [String: Any])
        let candidateHandshake = try #require(success["_0"] as? [String: Any])

        #expect(Set(object.keys) == ["remoteSkipped", "selected", "candidates", "client"])
        #expect(Set(encodedCandidate.keys) == ["socketPath", "result"])
        #expect(selectedHandshake["supportedOperations"] is [String])
        #expect(candidateHandshake["supportedOperations"] is [String])
        #expect(selectedHandshake["permissionTags"] is [String: Any])
        #expect(candidateHandshake["permissionTags"] is [String: Any])
        #expect(object["fallback"] == nil)
        #expect(object["diagnostics"] == nil)

        let decoded = try JSONDecoder().decode(BridgeStatusReport.self, from: data)
        #expect(decoded.candidates.first?.selectionEligible == false)
        #expect(decoded.candidates.first?.rejection == nil)
    }

    @Test
    func `Bridge report preserves typed capture readiness`() throws {
        let handshake = PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "fixture",
            supportedOperations: [.desktopObservation],
            screenCaptureKitReadiness: .init(state: .blocked, failure: .init(
                kind: .uncoordinatedProcesses,
                stage: .preparation,
                message: "Synthetic coordination blocker",
                blockers: [.init(processIdentifier: 4242, processStartIdentity: 9001)]
            ))
        )
        let data = try JSONEncoder().encode(BridgeHandshakeReport(from: handshake))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let readiness = try #require(object["screenCaptureKitReadiness"] as? [String: Any])
        #expect(readiness["state"] as? String == "blocked")
        let failure = try #require(readiness["failure"] as? [String: Any])
        let blockers = try #require(failure["blockers"] as? [[String: Any]])
        #expect(blockers.first?["processIdentifier"] as? Int == 4242)
        #expect(blockers.first?["processStartIdentity"] as? Int == 9001)
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
