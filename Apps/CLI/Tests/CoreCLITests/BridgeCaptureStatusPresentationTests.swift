import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

struct BridgeCaptureStatusPresentationTests {
    @Test
    func `granted permissions do not hide blocked preparation in either human surface`() {
        let report = BridgeHandshakeReport(from: self.handshake(readiness: self.blockedReadiness))
        let socket = "/synthetic/capture-status.sock"
        let candidate = BridgeCandidateReport(socketPath: socket, result: .success(report))
        let selected = BridgeSelectionReport.remote(socketPath: socket, handshake: report)

        #expect(report.humanSummary.hasPrefix("handshake succeeded"))
        for summary in [report.humanSummary, candidate.humanSummary, selected.humanSummary] {
            #expect(summary.contains(report.humanSummary))
            #expect(summary.contains("ops: 2/2 enabled"))
            #expect(summary.contains("perm: SR=Y AX=Y ES=Y"))
            #expect(summary.contains("capture support: SCK ownership=advertised, classic=advertised"))
            #expect(summary.contains("desktop observation=enabled"))
            #expect(summary.contains("SCK preparation: blocked"))
            #expect(!summary.contains("ready to attempt"))
            #expect(!summary.contains(" — OK"))
        }
    }

    @Test(arguments: ["missing", "empty", "ownership", "classic", "both", "legacy"])
    func `capture support follows policy rather than granted permissions`(scenario: String) {
        let (capabilities, ownership, classic): ([String]?, Bool, Bool) = switch scenario {
        case "missing": (nil, false, false)
        case "empty": ([], false, false)
        case "ownership": ([PeekabooBridgeHostCapability.screenCaptureKitOwnershipEnforcement], true, false)
        case "classic": ([PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit], false, true)
        case "legacy": ([PeekabooBridgeHostCapability.screenCaptureKitProcessOwnership], true, true)
        default: (Self.captureCapabilities, true, true)
        }
        let handshake = self.handshake(capabilities: capabilities)
        let summary = BridgeHandshakeReport(from: handshake).humanSummary
        let ownershipLabel = ownership ? "advertised" : "unproven"
        let classicLabel = classic ? "advertised" : "unproven"

        #expect(BridgeCapabilityPolicy.supportsScreenCaptureKitProcessOwnership(for: handshake) == ownership)
        #expect(BridgeCapabilityPolicy.supportsClassicCaptureWithoutScreenCaptureKit(for: handshake) == classic)
        #expect(summary.contains("capture support: SCK ownership=\(ownershipLabel), classic=\(classicLabel)"))
        #expect(summary.contains("perm: SR=Y AX=Y ES=Y"))
        #expect(summary.contains("SCK preparation: unknown (not reported)"))
    }

    @Test(arguments: [
        "ready", "blocked", "unavailable", "unknown", "missing", "missingTimestamp", "readyWithFailure", "futureState",
    ])
    func `preparation requires complete readiness and never invents authority`(scenario: String) throws {
        let readiness: ScreenCaptureKitReadiness?
        let expected: String
        switch scenario {
        case "ready":
            readiness = .init(state: .ready, observedAt: Self.observedAt)
            expected = "ready to attempt"
        case "blocked":
            readiness = self.blockedReadiness
            expected = "blocked"
        case "unavailable":
            readiness = .init(state: .unavailable, observedAt: Self.observedAt)
            expected = "unavailable"
        case "unknown":
            readiness = .init(state: .unknown, observedAt: Self.observedAt)
            expected = "unknown"
        case "missingTimestamp":
            readiness = try JSONDecoder().decode(
                ScreenCaptureKitReadiness.self, from: Data(#"{"state":"ready"}"#.utf8)
            )
            expected = "unknown (incomplete readiness)"
        case "readyWithFailure":
            readiness = .init(state: .ready, observedAt: Self.observedAt, failure: self.blockedReadiness.failure)
            expected = "unknown (incomplete readiness)"
        case "futureState":
            readiness = try JSONDecoder().decode(
                ScreenCaptureKitReadiness.self, from: Data(#"{"state":"future"}"#.utf8)
            )
            expected = "unknown"
        default:
            readiness = nil
            expected = "unknown (not reported)"
        }
        let summary = BridgeHandshakeReport(from: self.handshake(readiness: readiness)).humanSummary

        #expect(summary.contains("SCK preparation: \(expected)"))
        #expect(summary.contains("ready to attempt") == (readiness?.permitsAttempt == true))
        if expected == "unknown" {
            #expect(!summary.contains("SCK preparation: unknown ("))
        }
    }

    @Test(arguments: ["enabled", "disabled", "unreported", "unsupported"])
    func `desktop observation availability remains separate from capture support`(scenario: String) {
        let supported: [PeekabooBridgeOperation] = scenario == "unsupported"
            ? [.permissionsStatus] : [.permissionsStatus, .desktopObservation]
        let enabled: [PeekabooBridgeOperation]? = switch scenario {
        case "enabled": [.desktopObservation]
        case "unreported": nil
        default: []
        }
        let report = BridgeHandshakeReport(from: self.handshake(supported: supported, enabled: enabled))
        let advertised = scenario == "unsupported" ? "unproven" : "advertised"

        #expect(report.humanSummary.contains("desktop observation=\(scenario)"))
        #expect(report.humanSummary.contains("SCK ownership=\(advertised), classic=\(advertised)"))
        let ops = enabled.map { "ops: \($0.count)/\(supported.count) enabled" } ?? "ops: \(supported.count)"
        #expect(report.humanSummary.contains(ops))
    }

    @Test(arguments: [false, true])
    func `denied or missing permissions do not rewrite capability and readiness facts`(missing: Bool) {
        let permissions: PermissionsStatus? = missing ? nil : .init(
            screenRecording: false, accessibility: false, postEvent: false
        )
        let report = BridgeHandshakeReport(from: self.handshake(
            permissions: permissions,
            readiness: .init(state: .ready, observedAt: Self.observedAt)
        ))

        #expect(report.humanSummary.contains(missing ? "perm: unknown" : "perm: SR=N AX=N ES=N"))
        #expect(!report.humanSummary.contains("perm: SR=Y"))
        #expect(report.humanSummary.contains("SCK ownership=advertised, classic=advertised"))
        #expect(report.humanSummary.contains("SCK preparation: ready to attempt"))
    }

    @Test(arguments: [false, true])
    func `human presentation adds no JSON fields and survives roundtrip`(captureFields: Bool) throws {
        let report = BridgeHandshakeReport(from: self.handshake(
            capabilities: captureFields ? Self.captureCapabilities : nil,
            readiness: captureFields ? self.blockedReadiness : nil
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var keys: Set = [
            "negotiatedVersion", "hostKind", "build", "supportedOperations", "permissions",
            "enabledOperations", "permissionTags", "hostIdentity",
        ]
        if captureFields {
            keys.formUnion(["hostCapabilities", "screenCaptureKitReadiness"])
        }
        #expect(Set(object.keys) == keys)
        let decoded = try JSONDecoder().decode(BridgeHandshakeReport.self, from: data)
        #expect(try encoder.encode(decoded) == data)
        #expect(decoded.humanSummary == report.humanSummary)
        #expect(decoded.screenCaptureKitReadiness == report.screenCaptureKitReadiness)
        #expect(decoded.hostCapabilities == report.hostCapabilities)

        let candidate = BridgeCandidateReport(socketPath: "/synthetic/capture-status.sock", result: .success(report))
        let candidateData = try encoder.encode(candidate)
        let candidateObject = try #require(JSONSerialization.jsonObject(with: candidateData) as? [String: Any])
        #expect(Set(candidateObject.keys) == ["socketPath", "result"])
        let decodedCandidate = try JSONDecoder().decode(BridgeCandidateReport.self, from: candidateData)
        #expect(try encoder.encode(decodedCandidate) == candidateData)
        #expect(decodedCandidate.humanSummary == candidate.humanSummary)

        let selected = BridgeSelectionReport.remote(socketPath: candidate.socketPath, handshake: report)
        let selectedData = try encoder.encode(selected)
        let selectedObject = try #require(JSONSerialization.jsonObject(with: selectedData) as? [String: Any])
        #expect(Set(selectedObject.keys) == ["source", "socketPath", "handshake"])
        let decodedSelection = try JSONDecoder().decode(BridgeSelectionReport.self, from: selectedData)
        #expect(try encoder.encode(decodedSelection) == selectedData)
        #expect(decodedSelection.humanSummary == selected.humanSummary)
    }

    @Test
    func `local skipped and failed summaries do not acquire capture claims`() {
        let socket = "/synthetic/capture-status.sock"
        let error = BridgeCandidateErrorReport(
            kind: "bridge", code: "timeout", message: "Synthetic timeout", details: nil, hint: nil
        )

        #expect(BridgeSelectionReport.local().humanSummary == "local (in-process)")
        #expect(BridgeCandidateReport(socketPath: socket, result: .skipped).humanSummary == "\(socket) — skipped")
        #expect(BridgeCandidateReport(socketPath: socket, result: .failure(error)).humanSummary ==
            "\(socket) — timeout: Synthetic timeout")
    }

    private static let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private static let captureCapabilities = [
        PeekabooBridgeHostCapability.screenCaptureKitOwnershipEnforcement,
        PeekabooBridgeHostCapability.classicCaptureWithoutScreenCaptureKit,
    ]

    private var blockedReadiness: ScreenCaptureKitReadiness {
        .init(state: .blocked, observedAt: Self.observedAt, failure: .init(
            kind: .uncoordinatedProcesses,
            stage: .preparation,
            message: "Synthetic preparation blocker",
            blockers: [.init(processIdentifier: 4242, processStartIdentity: 9001)]
        ))
    }

    private func handshake(
        permissions: PermissionsStatus? = .init(screenRecording: true, accessibility: true, postEvent: true),
        supported: [PeekabooBridgeOperation] = [.permissionsStatus, .desktopObservation],
        enabled: [PeekabooBridgeOperation]? = [.permissionsStatus, .desktopObservation],
        capabilities: [String]? = BridgeCaptureStatusPresentationTests.captureCapabilities,
        readiness: ScreenCaptureKitReadiness? = nil
    ) -> PeekabooBridgeHandshakeResponse {
        PeekabooBridgeHandshakeResponse(
            negotiatedVersion: PeekabooBridgeConstants.protocolVersion,
            hostKind: .gui,
            build: "synthetic-build",
            supportedOperations: supported,
            permissions: permissions,
            enabledOperations: enabled,
            hostIdentity: .init(
                processIdentifier: 4242,
                processStartIdentity: 9001,
                bundleIdentifier: "example.bridge",
                bundleShortVersion: "1.0",
                bundleVersion: "1",
                codeSignatureHash: "abcdef"
            ),
            hostCapabilities: capabilities,
            screenCaptureKitReadiness: readiness
        )
    }
}
