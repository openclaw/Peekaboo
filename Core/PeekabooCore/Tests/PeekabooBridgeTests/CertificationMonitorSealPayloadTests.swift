import Foundation
import Testing
@testable import PeekabooBridge

@Suite("Bridge certification monitor seal payload")
struct CertificationMonitorSealPayloadTests {
    @Test
    func `Complete monitor-owned corpus validates with derived commitments and seal`() throws {
        let payload = try Self.payload()
        try payload.validate(context: Self.validationContext())
    }

    @Test
    func `Seal digest tampering fails closed`() throws {
        let payload = try Self.payload()
        let tampered = PeekabooBridgeCertificationMonitorSealPayload(
            evidence: payload.evidence,
            sealReceipt: .init(
                executionNonce: payload.sealReceipt.executionNonce,
                monitorInstanceID: payload.sealReceipt.monitorInstanceID,
                evidenceSHA256: String(repeating: "9", count: 64)))
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try tampered.validate(context: Self.validationContext())
        }
    }

    @Test
    func `Recomputed seal cannot authorize wrong foreground activity source`() throws {
        let payload = try Self.payload(tamper: .activitySource)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try payload.validate(context: Self.validationContext())
        }
    }

    @Test
    func `Recomputed seal cannot authorize producer source drift`() throws {
        let payload = try Self.payload(tamper: .producerSource)
        #expect(throws: PeekabooBridgeOperationReceiptError.self) {
            try payload.validate(context: Self.validationContext())
        }
    }

    @Test
    func `Closed monitor evidence decoder rejects embedded path authority`() throws {
        let payload = try Self.payload()
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        let decoder = JSONDecoder.peekabooBridgeDecoder()
        let data = try encoder.encode(payload)
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var evidence = try #require(root["evidence"] as? [String: Any])
        evidence["sealedEvidencePath"] = "/private/tmp/caller-selected.json"
        root["evidence"] = evidence
        let injected = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        #expect(throws: DecodingError.self) {
            _ = try decoder.decode(PeekabooBridgeCertificationMonitorSealPayload.self, from: injected)
        }
    }

    private enum Tamper {
        case none
        case activitySource
        case producerSource
    }

    private static let executionNonce = String(repeating: "a", count: 64)
    private static let monitorInstanceID = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
    private static let producerSourceCommit = String(repeating: "b", count: 40)
    private static let producerExecutableSHA256 = String(repeating: "c", count: 64)
    private static let producerCodeSignatureHash = String(repeating: "d", count: 40)
    private static let zeroSHA256 = String(repeating: "0", count: 64)

    private static let monitorProcess = PeekabooBridgeCertificationMonitorSealPayload.ProcessIdentity(
        processIdentifier: 42,
        processStartIdentity: 99,
        codeSignatureHash: producerCodeSignatureHash)
    private static let foregroundController = PeekabooBridgeCertificationMonitorSealPayload.ProcessIdentity(
        processIdentifier: 200,
        processStartIdentity: 2000,
        codeSignatureHash: String(repeating: "1", count: 40))
    private static let sentinel = PeekabooBridgeCertificationMonitorSealPayload.WindowTarget(
        processIdentifier: 100,
        processStartIdentity: 1000,
        windowID: 10,
        bounds: .init(x: 10, y: 10, width: 800, height: 600),
        isMinimized: false)
    private static let foregroundTarget = PeekabooBridgeCertificationMonitorSealPayload.WindowTarget(
        processIdentifier: 300,
        processStartIdentity: 3000,
        windowID: 30,
        bounds: .init(x: 900, y: 10, width: 800, height: 600),
        isMinimized: false)

    private static func payload(tamper: Tamper = .none) throws
        -> PeekabooBridgeCertificationMonitorSealPayload
    {
        let sourceCommit = tamper == .producerSource
            ? String(repeating: "8", count: 40)
            : self.producerSourceCommit
        let source = PeekabooBridgeCertificationMonitorSealPayload.Source(
            producerSourceCommit: sourceCommit,
            producerExecutableSHA256: self.producerExecutableSHA256,
            monitorSourceSHA256: String(repeating: "e", count: 64),
            coordinatorSourceSHA256: String(repeating: "f", count: 64))
        let sample = PeekabooBridgeCertificationMonitorSealPayload.MonitorSample(
            frontmostProcessIdentifier: self.sentinel.processIdentifier,
            frontmostWindowID: self.sentinel.windowID,
            clipboardChangeCount: 5,
            clipboardDigest: String(repeating: "6", count: 64))
        let restoration = try PeekabooBridgeCertificationMonitorSealPayload.RestorationSummary(
            backgroundFinalBoundsSlotIDs: [
                "controller-a-final-bounds",
                "controller-b-final-bounds",
            ],
            foregroundPostconditionSHA256: String(repeating: "7", count: 64),
            sentinelSampleSHA256: PeekabooBridgeCertificationMonitorSealPayload
                .derivedMonitorSampleSHA256(for: sample),
            foregroundRestored: true,
            sentinelRestored: true)

        let placeholder = Self.evidence(
            source: source,
            sample: sample,
            restoration: restoration,
            fences: Self.fences(
                baselineCommitment: self.zeroSHA256,
                historyCommitment: self.zeroSHA256,
                tamper: tamper),
            baselineCommitment: self.zeroSHA256,
            historyCommitment: self.zeroSHA256)
        let baselineCommitment = try PeekabooBridgeCertificationMonitorSealPayload
            .derivedBaselineCommitmentSHA256(for: placeholder)
        let historySeed = Self.evidence(
            source: source,
            sample: sample,
            restoration: restoration,
            fences: Self.fences(
                baselineCommitment: baselineCommitment,
                historyCommitment: self.zeroSHA256,
                tamper: tamper),
            baselineCommitment: baselineCommitment,
            historyCommitment: self.zeroSHA256)
        let historyCommitment = try PeekabooBridgeCertificationMonitorSealPayload
            .derivedHistoryCommitmentSHA256(for: historySeed)
        let evidence = Self.evidence(
            source: source,
            sample: sample,
            restoration: restoration,
            fences: Self.fences(
                baselineCommitment: baselineCommitment,
                historyCommitment: historyCommitment,
                tamper: tamper),
            baselineCommitment: baselineCommitment,
            historyCommitment: historyCommitment)
        let evidenceSHA256 = try PeekabooBridgeCertificationMonitorSealPayload
            .derivedEvidenceSHA256(for: evidence)
        return .init(
            evidence: evidence,
            sealReceipt: .init(
                executionNonce: self.executionNonce,
                monitorInstanceID: self.monitorInstanceID,
                evidenceSHA256: evidenceSHA256))
    }

    private static func evidence(
        source: PeekabooBridgeCertificationMonitorSealPayload.Source,
        sample: PeekabooBridgeCertificationMonitorSealPayload.MonitorSample,
        restoration: PeekabooBridgeCertificationMonitorSealPayload.RestorationSummary,
        fences: [PeekabooBridgeCertificationMonitorSealPayload.Fence],
        baselineCommitment: String,
        historyCommitment: String) -> PeekabooBridgeCertificationMonitorSealPayload.Evidence
    {
        .init(
            executionNonce: self.executionNonce,
            monitorInstanceID: self.monitorInstanceID,
            source: source,
            monitorProcess: self.monitorProcess,
            sentinel: self.sentinel,
            foregroundController: self.foregroundController,
            foregroundTarget: self.foregroundTarget,
            producerSets: self.producerSets(),
            fences: fences,
            baselineSample: sample,
            finalSample: sample,
            foregroundPlan: self.foregroundPlan(),
            violationRecords: [],
            contaminationRecords: [],
            baselineCommitmentSHA256: baselineCommitment,
            historyCommitmentSHA256: historyCommitment,
            crashEvidence: .init(
                scanDomain: .currentUserDiagnosticReports,
                prefixes: ["Peekaboo"],
                baseline: [],
                final: [],
                newReports: []),
            restoration: restoration)
    }

    private static func producerSets() -> PeekabooBridgeCertificationMonitorSealPayload.ProducerSets {
        let baseline = [
            PeekabooBridgeCertificationMonitorSealPayload.AllowedProducer(
                processIdentifier: 10,
                processStartIdentity: 10,
                role: .bridge),
            PeekabooBridgeCertificationMonitorSealPayload.AllowedProducer(
                processIdentifier: 20,
                processStartIdentity: 20,
                role: .bridge),
        ]
        let foreground = PeekabooBridgeCertificationMonitorSealPayload.AllowedProducer(
            processIdentifier: self.foregroundController.processIdentifier,
            processStartIdentity: self.foregroundController.processStartIdentity,
            role: .foregroundController)
        return .init(
            baseline: .init(
                revision: 1,
                executionNonce: self.executionNonce,
                monitorInstanceID: self.monitorInstanceID,
                producers: baseline,
                foreground: .init(active: false, target: nil)),
            grant: .init(
                revision: 2,
                executionNonce: self.executionNonce,
                monitorInstanceID: self.monitorInstanceID,
                producers: baseline + [foreground],
                foreground: .init(active: true, target: self.foregroundTarget)),
            revoke: .init(
                revision: 3,
                executionNonce: self.executionNonce,
                monitorInstanceID: self.monitorInstanceID,
                producers: baseline,
                foreground: .init(active: false, target: nil)))
    }

    private static func foregroundPlan() -> PeekabooBridgeCertificationMonitorSealPayload.ForegroundPlan {
        let marker = "peekaboo-foreground-postcondition:\(self.executionNonce)"
        return .init(
            requestMarker: marker,
            expectedValueSHA256: PeekabooBridgeOperationReceiptCoding.sha256(Data(marker.utf8)),
            baselineValueSHA256: String(repeating: "5", count: 64),
            observer: .init(
                processIdentifier: 400,
                processStartIdentity: 4000,
                codeSignatureHash: String(repeating: "2", count: 40)),
            observerBuild: .init(
                sourceCommit: String(repeating: "3", count: 40),
                executableSHA256: String(repeating: "4", count: 64),
                signingIdentifier: "boo.peekaboo.peekaboo-certification-controller",
                teamIdentifier: "FWJYW4S8P8"),
            semanticElement: .init(role: "AXTextField", identifier: "certification-field", title: nil),
            target: self.foregroundTarget)
    }

    private static func fences(
        baselineCommitment: String,
        historyCommitment: String,
        tamper: Tamper) -> [PeekabooBridgeCertificationMonitorSealPayload.Fence]
    {
        let definitions: [(
            PeekabooBridgeCertificationMonitorSealPayload.FenceName,
            UInt64,
            PeekabooBridgeCertificationMonitorSealPayload.MonitorPhase,
            Bool)] = [
            (.baselineStable, 1, .setup, false),
            (.grantStable, 2, .setup, true),
            (.operationsStart, 2, .running, true),
            (.operationsComplete, 2, .running, true),
            (.revokeStable, 3, .running, false),
            (.finalStable, 3, .complete, false),
        ]
        return definitions.enumerated().map { index, definition in
            let (name, revision, phase, active) = definition
            let requiresActivity = name == .operationsComplete
            let sourceProcess = tamper == .activitySource ? 999 : self.foregroundController.processIdentifier
            return .init(
                name: name,
                heartbeat: .init(
                    sequence: UInt64(index + 1),
                    monotonicMicroseconds: UInt64((index + 1) * 1_000_000),
                    wallClockMilliseconds: Int64((index + 1) * 1000),
                    lastCleanSequence: UInt64(index + 1),
                    contaminationRetries: 0,
                    contaminationBlocked: false,
                    inputAttributionAvailable: true,
                    allowedProducerRevision: revision,
                    phase: phase,
                    cursorMovementObserved: index >= 2,
                    pendingActivationCount: 0,
                    pendingFocusedWindowChange: false,
                    authorizationEpoch: UInt64(index + 1),
                    transitionAcknowledged: false,
                    foregroundActive: active,
                    foregroundTargetProcessIdentifier: active
                        ? self.foregroundTarget.processIdentifier
                        : nil,
                    foregroundTargetWindowID: active ? self.foregroundTarget.windowID : nil,
                    attributedForegroundEventCount: requiresActivity ? 1 : 0,
                    attributedForegroundSourceProcessIdentifiers: requiresActivity ? [sourceProcess] : [],
                    foregroundActivityObserved: requiresActivity,
                    executionNonce: self.executionNonce,
                    monitorInstanceID: self.monitorInstanceID,
                    historyCommitmentSHA256: name == .finalStable
                        ? historyCommitment
                        : baselineCommitment))
        }
    }

    private static func validationContext() -> PeekabooBridgeCertificationPayloadValidationContext {
        .init(
            request: .init(
                kind: .monitorSeal,
                executionNonce: self.executionNonce,
                monitorInstanceID: self.monitorInstanceID,
                producerSocketPath: "/private/tmp/certification-monitor.sock",
                expectedProducer: .init(
                    processIdentifier: self.monitorProcess.processIdentifier,
                    processStartIdentity: self.monitorProcess.processStartIdentity,
                    codeSignatureHash: self.monitorProcess.codeSignatureHash),
                timeoutMilliseconds: 1000,
                maximumResponseBytes: 1024 * 1024),
            producer: .init(
                processIdentifier: self.monitorProcess.processIdentifier,
                processIdentifierVersion: 1,
                processStartIdentity: self.monitorProcess.processStartIdentity,
                codeSignatureHash: self.monitorProcess.codeSignatureHash,
                signingIdentifier: "boo.peekaboo.background-computer-use-probe",
                teamIdentifier: "FWJYW4S8P8",
                sourceCommit: self.producerSourceCommit,
                executableSHA256: self.producerExecutableSHA256),
            listenerAttestation: .init(
                listenerInstanceID: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
                publicKey: Data(repeating: 0, count: 32),
                host: .init(
                    processIdentifier: 7,
                    processStartIdentity: 8,
                    codeSignatureHash: String(repeating: "f", count: 40)),
                createdAtUnixMilliseconds: 1000,
                receiptArchiveDirectory: "/private/tmp/receipts",
                signature: Data()))
    }
}
