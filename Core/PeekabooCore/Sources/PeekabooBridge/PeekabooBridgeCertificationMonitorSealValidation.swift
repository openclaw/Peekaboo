import Foundation

extension PeekabooBridgeCertificationMonitorSealPayload {
    func validate(context: PeekabooBridgeCertificationPayloadValidationContext) throws {
        let evidence = self.evidence
        guard self.schemaVersion == 1,
              evidence.schemaVersion == 1,
              evidence.executionNonce == context.request.executionNonce,
              evidence.monitorInstanceID == context.request.monitorInstanceID,
              PeekabooBridgeCertificationValidation.isLowerHex(evidence.executionNonce, count: 64),
              PeekabooBridgeCertificationValidation.isVersion4(evidence.monitorInstanceID)
        else { throw Self.invalid("run identity") }

        try Self.validateSource(evidence.source, context: context)
        try Self.validateProcess(evidence.monitorProcess)
        try Self.validateProcess(evidence.foregroundController)
        guard evidence.monitorProcess.processIdentifier == context.producer.processIdentifier,
              evidence.monitorProcess.processStartIdentity == context.producer.processStartIdentity,
              evidence.monitorProcess.codeSignatureHash == context.producer.codeSignatureHash
        else { throw Self.invalid("monitor process identity") }

        try Self.validateTarget(evidence.sentinel)
        try Self.validateTarget(evidence.foregroundTarget)
        guard evidence.foregroundController.processIdentifier != evidence.monitorProcess.processIdentifier,
              !Self.sameGeneration(evidence.monitorProcess, evidence.sentinel),
              !Self.sameGeneration(evidence.monitorProcess, evidence.foregroundTarget),
              !Self.sameGeneration(evidence.foregroundController, evidence.foregroundTarget),
              !Self.sameGeneration(evidence.foregroundController, evidence.sentinel),
              !Self.sameGeneration(evidence.foregroundTarget, evidence.sentinel)
        else { throw Self.invalid("distinct monitor actors") }

        try Self.validateForegroundPlan(evidence.foregroundPlan, evidence: evidence)
        try Self.validateProducerSets(evidence.producerSets, evidence: evidence)
        try Self.validateFences(evidence.fences, evidence: evidence)
        try Self.validateSample(evidence.baselineSample, sentinel: evidence.sentinel)
        try Self.validateSample(evidence.finalSample, sentinel: evidence.sentinel)
        guard evidence.baselineSample.clipboardChangeCount == evidence.finalSample.clipboardChangeCount,
              evidence.baselineSample.clipboardDigest == evidence.finalSample.clipboardDigest,
              evidence.violationRecords.isEmpty,
              evidence.contaminationRecords.isEmpty
        else { throw Self.invalid("clean monitor interval") }

        try Self.validateCrashEvidence(evidence.crashEvidence)
        try Self.validateRestoration(evidence.restoration, evidence: evidence)
        guard PeekabooBridgeCertificationValidation.isLowerHex(
            evidence.baselineCommitmentSHA256,
            count: 64),
            PeekabooBridgeCertificationValidation.isLowerHex(evidence.historyCommitmentSHA256, count: 64),
            try evidence.baselineCommitmentSHA256 == (Self.baselineCommitment(for: evidence)),
            try evidence.historyCommitmentSHA256 == (Self.historyCommitment(for: evidence))
        else { throw Self.invalid("derived monitor commitments") }

        let receipt = self.sealReceipt
        guard receipt.schemaVersion == 1,
              receipt.executionNonce == evidence.executionNonce,
              receipt.monitorInstanceID == evidence.monitorInstanceID,
              receipt.phase == .sealed,
              PeekabooBridgeCertificationValidation.isLowerHex(receipt.evidenceSHA256, count: 64),
              try receipt.evidenceSHA256 == (Self.aggregateSHA256(domain: "monitor-evidence", value: evidence))
        else { throw Self.invalid("derived monitor seal receipt") }
    }

    private static func validateSource(
        _ source: Source,
        context: PeekabooBridgeCertificationPayloadValidationContext) throws
    {
        guard source.producerSourceCommit == context.producer.sourceCommit,
              source.producerExecutableSHA256 == context.producer.executableSHA256,
              PeekabooBridgeCertificationValidation.isLowerHex(source.producerSourceCommit, count: 40),
              PeekabooBridgeCertificationValidation.isLowerHex(source.producerExecutableSHA256, count: 64),
              PeekabooBridgeCertificationValidation.isLowerHex(source.monitorSourceSHA256, count: 64),
              PeekabooBridgeCertificationValidation.isLowerHex(source.coordinatorSourceSHA256, count: 64)
        else { throw self.invalid("source identity") }
    }

    private static func validateProcess(_ process: ProcessIdentity) throws {
        guard process.processIdentifier > 0,
              process.processStartIdentity > 0,
              process.processStartIdentity <= UInt64(PeekabooBridgeCertificationValidation.maximumSafeInteger),
              PeekabooBridgeCertificationValidation.isLowerHex(process.codeSignatureHash, count: 40)
        else { throw self.invalid("process generation") }
    }

    private static func validateTarget(_ target: WindowTarget) throws {
        let bounds = target.bounds
        guard target.scope == .window,
              target.processIdentifier > 0,
              target.processStartIdentity > 0,
              target.processStartIdentity <= UInt64(PeekabooBridgeCertificationValidation.maximumSafeInteger),
              target.windowID > 0,
              bounds.x.isFinite,
              bounds.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              abs(bounds.x) <= 10_000_000,
              abs(bounds.y) <= 10_000_000,
              bounds.width > 0,
              bounds.height > 0,
              bounds.width <= 10_000_000,
              bounds.height <= 10_000_000
        else { throw Self.invalid("window target") }
    }

    private static func validateForegroundPlan(_ plan: ForegroundPlan, evidence: Evidence) throws {
        try self.validateProcess(plan.observer)
        try self.validateTarget(plan.target)
        let marker = "peekaboo-foreground-postcondition:\(evidence.executionNonce)"
        let expectedMarkerDigest = PeekabooBridgeOperationReceiptCoding.sha256(Data(marker.utf8))
        let build = plan.observerBuild
        let semantic = plan.semanticElement
        guard plan.requestMarker == marker,
              plan.expectedValueSHA256 == expectedMarkerDigest,
              PeekabooBridgeCertificationValidation.isLowerHex(plan.baselineValueSHA256, count: 64),
              plan.baselineValueSHA256 != plan.expectedValueSHA256,
              plan.target == evidence.foregroundTarget,
              !Self.sameGeneration(plan.observer, evidence.foregroundController),
              !Self.sameGeneration(plan.observer, evidence.monitorProcess),
              build.signingIdentifier == "boo.peekaboo.peekaboo-certification-controller",
              build.teamIdentifier == PeekabooBridgeCertificationValidation.foundationTeamIdentifier,
              PeekabooBridgeCertificationValidation.isLowerHex(build.sourceCommit, count: 40),
              PeekabooBridgeCertificationValidation.isLowerHex(build.executableSHA256, count: 64),
              Self.isSafeText(semantic.role, maximumBytes: 256),
              Self.isSafeOptionalText(semantic.identifier, maximumBytes: 1024),
              Self.isSafeOptionalText(semantic.title, maximumBytes: 1024),
              semantic.identifier != nil || semantic.title != nil
        else { throw Self.invalid("foreground semantic plan") }
    }

    private static func validateProducerSets(_ sets: ProducerSets, evidence: Evidence) throws {
        try self.validateProducerSet(sets.baseline, evidence: evidence, revision: 1, active: false)
        try self.validateProducerSet(sets.grant, evidence: evidence, revision: 2, active: true)
        try self.validateProducerSet(sets.revoke, evidence: evidence, revision: 3, active: false)
        let foregroundProducer = AllowedProducer(
            processIdentifier: evidence.foregroundController.processIdentifier,
            processStartIdentity: evidence.foregroundController.processStartIdentity,
            role: .foregroundController)
        var expectedGrant = sets.baseline.producers
        expectedGrant.append(foregroundProducer)
        expectedGrant.sort(by: Self.producerPrecedes)
        guard sets.baseline.producers == sets.revoke.producers,
              sets.grant.producers == expectedGrant,
              !sets.baseline.producers.contains(where: { producer in
                  producer.processIdentifier == foregroundProducer.processIdentifier ||
                      producer.role == .foregroundController
              })
        else { throw Self.invalid("grant and revoke producer history") }
    }

    private static func validateProducerSet(
        _ set: ProducerSet,
        evidence: Evidence,
        revision: UInt64,
        active: Bool) throws
    {
        let processKeys = set.producers.map { "\($0.processIdentifier):\($0.processStartIdentity)" }
        guard set.revision == revision,
              set.executionNonce == evidence.executionNonce,
              set.monitorInstanceID == evidence.monitorInstanceID,
              (1...64).contains(set.producers.count),
              set.producers == set.producers.sorted(by: Self.producerPrecedes),
              Set(processKeys).count == processKeys.count,
              set.producers.allSatisfy({ producer in
                  producer.processIdentifier > 0 && producer.processStartIdentity > 0 &&
                      producer.processStartIdentity <=
                      UInt64(PeekabooBridgeCertificationValidation.maximumSafeInteger)
              }),
              set.foreground.active == active,
              set.foreground.target == (active ? evidence.foregroundTarget : nil)
        else { throw Self.invalid("producer set") }
    }

    private static func validateFences(_ fences: [Fence], evidence: Evidence) throws {
        let expected: [(FenceName, UInt64, MonitorPhase, Bool)] = [
            (.baselineStable, 1, .setup, false),
            (.grantStable, 2, .setup, true),
            (.operationsStart, 2, .running, true),
            (.operationsComplete, 2, .running, true),
            (.revokeStable, 3, .running, false),
            (.finalStable, 3, .complete, false),
        ]
        guard fences.count == expected.count else { throw Self.invalid("six monitor fences") }
        for (index, fence) in fences.enumerated() {
            let (name, revision, phase, active) = expected[index]
            guard fence.name == name else { throw Self.invalid("ordered monitor fences") }
            try Self.validateHeartbeat(
                fence.heartbeat,
                evidence: evidence,
                expectation: .init(
                    revision: revision,
                    phase: phase,
                    foregroundActive: active,
                    activityRequired: name == .operationsComplete,
                    historyCommitment: name == .finalStable
                        ? evidence.historyCommitmentSHA256
                        : evidence.baselineCommitmentSHA256))
            if index > 0 {
                try Self.validateClockStep(previous: fences[index - 1].heartbeat, current: fence.heartbeat)
            }
        }
        guard fences[2].heartbeat.wallClockMilliseconds < fences[3].heartbeat.wallClockMilliseconds
        else { throw Self.invalid("foreground activity interval") }
    }

    private struct HeartbeatExpectation {
        let revision: UInt64
        let phase: MonitorPhase
        let foregroundActive: Bool
        let activityRequired: Bool
        let historyCommitment: String
    }

    private static func validateHeartbeat(
        _ heartbeat: Heartbeat,
        evidence: Evidence,
        expectation: HeartbeatExpectation) throws
    {
        let revision = expectation.revision
        let phase = expectation.phase
        let foregroundActive = expectation.foregroundActive
        let activityRequired = expectation.activityRequired
        let historyCommitment = expectation.historyCommitment
        let sources = heartbeat.attributedForegroundSourceProcessIdentifiers
        let safeMaximum = UInt64(PeekabooBridgeCertificationValidation.maximumSafeInteger)
        let expectedTargetPID = foregroundActive ? evidence.foregroundTarget.processIdentifier : nil
        let expectedTargetWindow = foregroundActive ? evidence.foregroundTarget.windowID : nil
        guard heartbeat.sequence > 0,
              heartbeat.sequence <= safeMaximum,
              heartbeat.monotonicMicroseconds > 0,
              heartbeat.monotonicMicroseconds <= safeMaximum,
              PeekabooBridgeCertificationValidation.isPositiveSafeInteger(heartbeat.wallClockMilliseconds),
              heartbeat.lastCleanSequence == heartbeat.sequence,
              heartbeat.contaminationRetries == 0,
              !heartbeat.contaminationBlocked,
              heartbeat.inputAttributionAvailable,
              heartbeat.allowedProducerRevision == revision,
              heartbeat.phase == phase,
              heartbeat.pendingActivationCount == 0,
              !heartbeat.pendingFocusedWindowChange,
              heartbeat.authorizationEpoch > 0,
              heartbeat.authorizationEpoch <= safeMaximum,
              !heartbeat.transitionAcknowledged,
              heartbeat.foregroundActive == foregroundActive,
              heartbeat.foregroundTargetProcessIdentifier == expectedTargetPID,
              heartbeat.foregroundTargetWindowID == expectedTargetWindow,
              heartbeat.attributedForegroundEventCount >= 0,
              Int64(heartbeat.attributedForegroundEventCount) <=
              PeekabooBridgeCertificationValidation.maximumSafeInteger,
              sources.allSatisfy({ $0 > 0 }),
              sources == sources.sorted(),
              Set(sources).count == sources.count,
              heartbeat.executionNonce == evidence.executionNonce,
              heartbeat.monitorInstanceID == evidence.monitorInstanceID,
              heartbeat.historyCommitmentSHA256 == historyCommitment
        else { throw Self.invalid("stable clean monitor heartbeat") }

        if activityRequired {
            guard heartbeat.attributedForegroundEventCount > 0,
                  sources == [evidence.foregroundController.processIdentifier],
                  heartbeat.foregroundActivityObserved
            else { throw Self.invalid("foreground activity attribution") }
        } else {
            guard heartbeat.attributedForegroundEventCount == 0,
                  sources.isEmpty,
                  !heartbeat.foregroundActivityObserved
            else { throw Self.invalid("inactive monitor fence") }
        }
    }

    private static func validateClockStep(previous: Heartbeat, current: Heartbeat) throws {
        guard current.sequence > previous.sequence,
              current.authorizationEpoch > previous.authorizationEpoch,
              current.monotonicMicroseconds > previous.monotonicMicroseconds,
              current.wallClockMilliseconds >= previous.wallClockMilliseconds
        else { throw self.invalid("monotonic monitor fence order") }
        let monotonicDelta = current.monotonicMicroseconds - previous.monotonicMicroseconds
        let wallDelta = current.wallClockMilliseconds - previous.wallClockMilliseconds
        let (wallMicroseconds, overflow) = wallDelta.multipliedReportingOverflow(by: 1000)
        guard !overflow, wallMicroseconds >= 0 else { throw Self.invalid("monitor clock domain") }
        let wallMagnitude = UInt64(wallMicroseconds)
        let difference = wallMagnitude >= monotonicDelta
            ? wallMagnitude - monotonicDelta
            : monotonicDelta - wallMagnitude
        guard difference <= 2_000_000 else { throw Self.invalid("monitor clock drift") }
    }

    private static func validateSample(_ sample: MonitorSample, sentinel: WindowTarget) throws {
        guard sample.frontmostProcessIdentifier == sentinel.processIdentifier,
              sample.frontmostWindowID == sentinel.windowID,
              PeekabooBridgeCertificationValidation.isNonnegativeSafeInteger(sample.clipboardChangeCount),
              PeekabooBridgeCertificationValidation.isLowerHex(sample.clipboardDigest, count: 64)
        else { throw self.invalid("sentinel sample") }
    }

    private static func validateCrashEvidence(_ crash: CrashEvidence) throws {
        guard crash.schemaVersion == 1,
              crash.scanDomain == .currentUserDiagnosticReports,
              !crash.prefixes.isEmpty,
              crash.prefixes.count <= 32,
              Set(crash.prefixes).count == crash.prefixes.count,
              crash.prefixes.allSatisfy(self.isSafeCrashName),
              crash.baseline == crash.final,
              crash.newReports.isEmpty
        else { throw self.invalid("clean crash evidence") }
        try self.validateCrashEntries(crash.baseline, prefixes: crash.prefixes)
        try self.validateCrashEntries(crash.final, prefixes: crash.prefixes)
    }

    private static func validateCrashEntries(_ entries: [CrashEntry], prefixes: [String]) throws {
        let names = entries.map(\.name)
        let totalBytes = entries.reduce(Int64(0)) { partial, entry in
            let sum = partial.addingReportingOverflow(entry.size)
            return sum.overflow ? Int64.max : sum.partialValue
        }
        guard entries.count <= 256,
              names == names.sorted(),
              Set(names).count == names.count,
              totalBytes <= 256 * 1024 * 1024,
              entries.allSatisfy({ entry in
                  Self.isSafeCrashName(entry.name) &&
                      (0...64 * 1024 * 1024).contains(entry.size) &&
                      PeekabooBridgeCertificationValidation.isPositiveSafeInteger(
                          entry.modifiedAtUnixMilliseconds) &&
                      PeekabooBridgeCertificationValidation.isLowerHex(entry.sha256, count: 64) &&
                      prefixes.contains(where: entry.name.hasPrefix)
              })
        else { throw Self.invalid("crash inventory") }
    }

    private static func validateRestoration(_ restoration: RestorationSummary, evidence: Evidence) throws {
        let slotIDs = restoration.backgroundFinalBoundsSlotIDs
        guard (1...64).contains(slotIDs.count),
              slotIDs == slotIDs.sorted(),
              Set(slotIDs).count == slotIDs.count,
              slotIDs.allSatisfy({ Self.isSafeSlotID($0) && $0.hasSuffix("-final-bounds") }),
              restoration.foregroundRestored,
              restoration.sentinelRestored,
              PeekabooBridgeCertificationValidation.isLowerHex(
                  restoration.foregroundPostconditionSHA256,
                  count: 64),
              restoration.foregroundPostconditionSHA256 == evidence.foregroundPlan.expectedValueSHA256,
              PeekabooBridgeCertificationValidation.isLowerHex(restoration.sentinelSampleSHA256, count: 64),
              try restoration.sentinelSampleSHA256 ==
              (Self.aggregateSHA256(domain: "monitor-sample", value: evidence.finalSample))
        else { throw Self.invalid("restoration summary") }
    }

    private struct BaselineProjection: Encodable {
        let executionNonce: String
        let monitorInstanceID: UUID
        let source: Source
        let monitorProcess: ProcessIdentity
        let sentinel: WindowTarget
        let foregroundController: ProcessIdentity
        let foregroundTarget: WindowTarget
        let producerSet: ProducerSet
        let baselineSample: MonitorSample
        let foregroundPlan: ForegroundPlan
        let crashBaseline: CrashBaselineProjection
    }

    private struct CrashBaselineProjection: Encodable {
        let scanDomain: CrashScanDomain
        let prefixes: [String]
        let baseline: [CrashEntry]
    }

    private struct HistoryProjection: Encodable {
        let executionNonce: String
        let monitorInstanceID: UUID
        let source: Source
        let monitorProcess: ProcessIdentity
        let sentinel: WindowTarget
        let foregroundController: ProcessIdentity
        let foregroundTarget: WindowTarget
        let baselineCommitmentSHA256: String
        let producerSets: ProducerSets
        let fences: [HistoryFenceProjection]
        let baselineSample: MonitorSample
        let finalSample: MonitorSample
        let foregroundPlan: ForegroundPlan
        let violationRecords: [ViolationRecord]
        let contaminationRecords: [ContaminationRecord]
        let crashEvidence: CrashEvidence
        let restoration: RestorationSummary
    }

    private struct HistoryFenceProjection: Encodable {
        let name: FenceName
        let heartbeat: HistoryHeartbeatProjection
    }

    private struct HistoryHeartbeatProjection: Encodable {
        let heartbeat: Heartbeat

        private enum CodingKeys: String, CodingKey {
            case sequence
            case monotonicMicroseconds
            case wallClockMilliseconds
            case lastCleanSequence
            case contaminationRetries
            case contaminationBlocked
            case inputAttributionAvailable
            case allowedProducerRevision
            case phase
            case cursorMovementObserved
            case pendingActivationCount
            case pendingFocusedWindowChange
            case authorizationEpoch
            case transitionAcknowledged
            case foregroundActive
            case foregroundTargetProcessIdentifier
            case foregroundTargetWindowID
            case attributedForegroundEventCount
            case attributedForegroundSourceProcessIdentifiers
            case foregroundActivityObserved
            case executionNonce
            case monitorInstanceID
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(String(self.heartbeat.sequence), forKey: .sequence)
            try container.encode(String(self.heartbeat.monotonicMicroseconds), forKey: .monotonicMicroseconds)
            try container.encode(self.heartbeat.wallClockMilliseconds, forKey: .wallClockMilliseconds)
            try container.encode(String(self.heartbeat.lastCleanSequence), forKey: .lastCleanSequence)
            try container.encode(self.heartbeat.contaminationRetries, forKey: .contaminationRetries)
            try container.encode(self.heartbeat.contaminationBlocked, forKey: .contaminationBlocked)
            try container.encode(self.heartbeat.inputAttributionAvailable, forKey: .inputAttributionAvailable)
            try container.encode(
                String(self.heartbeat.allowedProducerRevision),
                forKey: .allowedProducerRevision)
            try container.encode(self.heartbeat.phase, forKey: .phase)
            try container.encode(self.heartbeat.cursorMovementObserved, forKey: .cursorMovementObserved)
            try container.encode(self.heartbeat.pendingActivationCount, forKey: .pendingActivationCount)
            try container.encode(
                self.heartbeat.pendingFocusedWindowChange,
                forKey: .pendingFocusedWindowChange)
            try container.encode(String(self.heartbeat.authorizationEpoch), forKey: .authorizationEpoch)
            try container.encode(self.heartbeat.transitionAcknowledged, forKey: .transitionAcknowledged)
            try container.encode(self.heartbeat.foregroundActive, forKey: .foregroundActive)
            try container.encode(
                self.heartbeat.foregroundTargetProcessIdentifier,
                forKey: .foregroundTargetProcessIdentifier)
            try container.encode(self.heartbeat.foregroundTargetWindowID, forKey: .foregroundTargetWindowID)
            try container.encode(
                self.heartbeat.attributedForegroundEventCount,
                forKey: .attributedForegroundEventCount)
            try container.encode(
                self.heartbeat.attributedForegroundSourceProcessIdentifiers,
                forKey: .attributedForegroundSourceProcessIdentifiers)
            try container.encode(
                self.heartbeat.foregroundActivityObserved,
                forKey: .foregroundActivityObserved)
            try container.encode(self.heartbeat.executionNonce, forKey: .executionNonce)
            try container.encode(self.heartbeat.monitorInstanceID, forKey: .monitorInstanceID)
        }
    }

    private static func baselineCommitment(for evidence: Evidence) throws -> String {
        try self.aggregateSHA256(
            domain: "monitor-baseline",
            value: BaselineProjection(
                executionNonce: evidence.executionNonce,
                monitorInstanceID: evidence.monitorInstanceID,
                source: evidence.source,
                monitorProcess: evidence.monitorProcess,
                sentinel: evidence.sentinel,
                foregroundController: evidence.foregroundController,
                foregroundTarget: evidence.foregroundTarget,
                producerSet: evidence.producerSets.baseline,
                baselineSample: evidence.baselineSample,
                foregroundPlan: evidence.foregroundPlan,
                crashBaseline: CrashBaselineProjection(
                    scanDomain: evidence.crashEvidence.scanDomain,
                    prefixes: evidence.crashEvidence.prefixes,
                    baseline: evidence.crashEvidence.baseline)))
    }

    private static func historyCommitment(for evidence: Evidence) throws -> String {
        let fences = evidence.fences.map { fence in
            HistoryFenceProjection(
                name: fence.name,
                heartbeat: HistoryHeartbeatProjection(heartbeat: fence.heartbeat))
        }
        return try self.aggregateSHA256(
            domain: "monitor-history",
            value: HistoryProjection(
                executionNonce: evidence.executionNonce,
                monitorInstanceID: evidence.monitorInstanceID,
                source: evidence.source,
                monitorProcess: evidence.monitorProcess,
                sentinel: evidence.sentinel,
                foregroundController: evidence.foregroundController,
                foregroundTarget: evidence.foregroundTarget,
                baselineCommitmentSHA256: evidence.baselineCommitmentSHA256,
                producerSets: evidence.producerSets,
                fences: fences,
                baselineSample: evidence.baselineSample,
                finalSample: evidence.finalSample,
                foregroundPlan: evidence.foregroundPlan,
                violationRecords: evidence.violationRecords,
                contaminationRecords: evidence.contaminationRecords,
                crashEvidence: evidence.crashEvidence,
                restoration: evidence.restoration))
    }

    private static func aggregateSHA256(domain: String, value: some Encodable) throws -> String {
        var data = Data("peekaboo.multi-target-certification.\(domain).v2\0".utf8)
        try data.append(PeekabooBridgeOperationReceiptCoding.canonicalData(value))
        return PeekabooBridgeOperationReceiptCoding.sha256(data)
    }

    static func derivedBaselineCommitmentSHA256(for evidence: Evidence) throws -> String {
        try self.baselineCommitment(for: evidence)
    }

    static func derivedHistoryCommitmentSHA256(for evidence: Evidence) throws -> String {
        try self.historyCommitment(for: evidence)
    }

    static func derivedEvidenceSHA256(for evidence: Evidence) throws -> String {
        try self.aggregateSHA256(domain: "monitor-evidence", value: evidence)
    }

    static func derivedMonitorSampleSHA256(for sample: MonitorSample) throws -> String {
        try self.aggregateSHA256(domain: "monitor-sample", value: sample)
    }

    private static func producerPrecedes(_ lhs: AllowedProducer, _ rhs: AllowedProducer) -> Bool {
        if lhs.processIdentifier != rhs.processIdentifier {
            return lhs.processIdentifier < rhs.processIdentifier
        }
        if lhs.processStartIdentity != rhs.processStartIdentity {
            return lhs.processStartIdentity < rhs.processStartIdentity
        }
        return lhs.role.rawValue < rhs.role.rawValue
    }

    private static func sameGeneration(_ process: ProcessIdentity, _ target: WindowTarget) -> Bool {
        process.processIdentifier == target.processIdentifier &&
            process.processStartIdentity == target.processStartIdentity
    }

    private static func sameGeneration(_ lhs: WindowTarget, _ rhs: WindowTarget) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier &&
            lhs.processStartIdentity == rhs.processStartIdentity
    }

    private static func sameGeneration(_ lhs: ProcessIdentity, _ rhs: ProcessIdentity) -> Bool {
        lhs.processIdentifier == rhs.processIdentifier &&
            lhs.processStartIdentity == rhs.processStartIdentity
    }

    private static func isSafeText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
    }

    private static func isSafeOptionalText(_ value: String?, maximumBytes: Int) -> Bool {
        guard let value else { return true }
        return self.isSafeText(value, maximumBytes: maximumBytes)
    }

    private static func isSafeCrashName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 255 && bytes.allSatisfy { byte in
            (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) ||
                (0x30...0x39).contains(byte) || [0x2E, 0x5F, 0x2D].contains(byte)
        }
    }

    private static func isSafeSlotID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return !bytes.isEmpty && bytes.count <= 64 && bytes.first != 0x2D && bytes.last != 0x2D &&
            bytes.allSatisfy { byte in
                (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) || byte == 0x2D
            }
    }

    private static func invalid(_ field: String) -> PeekabooBridgeOperationReceiptError {
        .receiptMismatch("certification monitor seal \(field)")
    }
}
