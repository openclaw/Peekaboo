import Darwin
import Foundation
import PeekabooCore
import PeekabooFoundation

enum CaptureActionOutcomeSemantics {
    static let childDelivery = DesktopActionOutcome.Delivery(
        mechanism: .capturePipeline,
        mode: .background
    )

    static var completedChildOutcome: DesktopActionOutcome {
        .dispatchedUnverified(
            route: .local,
            delivery: self.childDelivery,
            evidence: .deliveryAccepted,
            unitCount: .one
        )
    }

    static var uncertainChildOutcome: DesktopActionOutcome {
        .indeterminate(
            route: .local,
            delivery: self.childDelivery,
            evidence: .completionUnknown,
            unitCount: .one
        )
    }

    static func aggregate(
        focusOutcome: DesktopActionOutcome?,
        childOutcome: DesktopActionOutcome
    ) -> DesktopActionOutcome? {
        var sequence = DesktopActionSequenceAccumulator()
        if let focusOutcome {
            sequence.record(.reportedOutcome(focusOutcome, defaultDispatchedUnitCount: .one))
        }
        sequence.record(.reportedOutcome(childOutcome, defaultDispatchedUnitCount: .one))
        let resolution = sequence.successResolution()
        if let outcome = resolution.outcome {
            return outcome
        }
        return nil
    }

    static func focusOnlyFailureOutcome(_ focusOutcome: DesktopActionOutcome) -> DesktopActionOutcome {
        .indeterminate(
            route: focusOutcome.route,
            delivery: focusOutcome.delivery,
            evidence: .completionUnknown,
            unitCount: focusOutcome.dispatchState.unitCount ?? .one
        )
    }

    static func failureAggregate(
        focusOutcome: DesktopActionOutcome?,
        childOutcome: DesktopActionOutcome
    ) -> DesktopActionOutcome {
        if let aggregate = self.aggregate(focusOutcome: focusOutcome, childOutcome: childOutcome) {
            return aggregate
        }
        guard let focusOutcome else { return childOutcome }
        let focusUnits = focusOutcome.dispatchState.unitCount?.rawValue ?? 1
        let childUnits = childOutcome.dispatchState.unitCount?.rawValue ?? 1
        let (combinedUnits, unitCountOverflow) = focusUnits.addingReportingOverflow(childUnits)
        let unitCount = unitCountOverflow ? nil : DesktopActionOutcome.DispatchUnitCount(combinedUnits)
        let delivery = DesktopActionOutcome.Delivery(
            mechanism: .composite,
            mode: focusOutcome.delivery?.mode == .foreground || childOutcome.delivery?.mode == .foreground
                ? .foreground
                : .background
        )
        let hasSingleRoute = focusOutcome.route == childOutcome.route
        return .indeterminate(
            route: childOutcome.route,
            delivery: hasSingleRoute ? delivery : nil,
            evidence: .completionUnknown,
            unitCount: unitCount
        )
    }

    static func isCanonicalChildOutcome(_ outcome: DesktopActionOutcome) -> Bool {
        (outcome == self.completedChildOutcome || outcome == self.uncertainChildOutcome) &&
            outcome.delivery == self.childDelivery
    }

    static func isCanonicalAggregate(
        _ outcome: DesktopActionOutcome?,
        focusOutcome: DesktopActionOutcome?,
        childOutcome: DesktopActionOutcome
    ) -> Bool {
        self.isCanonicalChildOutcome(childOutcome) &&
            outcome == self.aggregate(focusOutcome: focusOutcome, childOutcome: childOutcome)
    }
}

struct CaptureActionCommandResult: Codable {
    let commandSucceeded: Bool
    let focusOutcome: DesktopActionOutcome?
    let childOutcome: DesktopActionOutcome
    let outcome: DesktopActionOutcome?
    let action: CaptureActionProcessResult
    let capture: CaptureSessionResult
    let validation: CaptureActionArtifactValidation
    let manifest: CaptureActionManifestReceipt?

    var success: Bool {
        self.commandSucceeded
    }

    init(
        commandSucceeded: Bool,
        focusOutcome: DesktopActionOutcome?,
        childOutcome: DesktopActionOutcome,
        outcome: DesktopActionOutcome?,
        action: CaptureActionProcessResult,
        capture: CaptureSessionResult,
        validation: CaptureActionArtifactValidation,
        manifest: CaptureActionManifestReceipt?
    ) {
        precondition(
            CaptureActionOutcomeSemantics.isCanonicalAggregate(
                outcome,
                focusOutcome: focusOutcome,
                childOutcome: childOutcome
            ),
            "Capture action results require canonical focus and child outcomes"
        )
        precondition(childOutcome == CaptureActionOutcomeSemantics.completedChildOutcome)
        precondition(capture.options.captureFocus != .background || focusOutcome == nil)
        precondition(validation.isCanonical)
        precondition(
            commandSucceeded == (action.succeeded && validation.ok && manifest != nil),
            "Capture action success must match action, validation, and manifest state"
        )
        self.commandSucceeded = commandSucceeded
        self.focusOutcome = focusOutcome
        self.childOutcome = childOutcome
        self.outcome = outcome
        self.action = action
        self.capture = capture
        self.validation = validation
        self.manifest = manifest
    }

    private enum CodingKeys: String, CodingKey {
        case success
        case focusOutcome
        case childOutcome
        case outcome
        case action
        case capture
        case validation
        case manifest
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encodedSuccess = try container.decode(Bool.self, forKey: .success)
        self.focusOutcome = try container.decodeIfPresent(DesktopActionOutcome.self, forKey: .focusOutcome)
        self.childOutcome = try container.decode(DesktopActionOutcome.self, forKey: .childOutcome)
        self.outcome = try container.decodeIfPresent(DesktopActionOutcome.self, forKey: .outcome)
        self.action = try container.decode(CaptureActionProcessResult.self, forKey: .action)
        self.capture = try container.decode(CaptureSessionResult.self, forKey: .capture)
        self.validation = try container.decode(CaptureActionArtifactValidation.self, forKey: .validation)
        self.manifest = try container.decodeIfPresent(CaptureActionManifestReceipt.self, forKey: .manifest)
        let expectedSuccess = self.action.succeeded && self.validation.ok && self.manifest != nil
        guard self.validation.isCanonical,
              CaptureActionOutcomeSemantics.isCanonicalAggregate(
                  self.outcome,
                  focusOutcome: self.focusOutcome,
                  childOutcome: self.childOutcome
              ),
              self.childOutcome == CaptureActionOutcomeSemantics.completedChildOutcome,
              self.capture.options.captureFocus != .background || self.focusOutcome == nil,
              encodedSuccess == expectedSuccess
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .outcome,
                in: container,
                debugDescription: "Capture action fields contradict canonical result semantics"
            )
        }
        self.commandSucceeded = encodedSuccess
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.success, forKey: .success)
        try container.encodeIfPresent(self.focusOutcome, forKey: .focusOutcome)
        try container.encode(self.childOutcome, forKey: .childOutcome)
        try container.encodeIfPresent(self.outcome, forKey: .outcome)
        try container.encode(self.action, forKey: .action)
        try container.encode(self.capture, forKey: .capture)
        try container.encode(self.validation, forKey: .validation)
        try container.encodeIfPresent(self.manifest, forKey: .manifest)
    }

    var failureMessage: String {
        if self.action.timedOut {
            return "Action timed out after \(self.action.timeoutSeconds)s"
        }
        if !self.action.processGroupCleaned {
            return "Action process group could not be fully terminated"
        }
        if !self.action.succeeded {
            return "Action exited with status \(self.action.exitCode)"
        }
        if let failure = self.validation.missing.first {
            return "Capture validation failed: \(failure)"
        }
        return "Capture validation failed"
    }
}

struct CaptureActionArtifactValidation: Codable {
    let ok: Bool
    let checked: [String]
    let missing: [String]

    var isCanonical: Bool {
        self.ok == self.missing.isEmpty &&
            !self.checked.isEmpty &&
            Set(self.checked).count == self.checked.count
    }
}

nonisolated struct CaptureActionProcessResult: Codable, Sendable {
    let command: [String]
    let processIdentifier: pid_t
    let processStartIdentity: UInt64
    let processStartIdentityDecimal: String
    let exitCode: Int32
    let timedOut: Bool
    let processGroupCleaned: Bool
    let timeoutSeconds: TimeInterval
    let durationMs: Int
    let stdout: String
    let stderr: String
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    /// Process-local scheduling boundary used by `capture action`; deliberately omitted from Codable output.
    let completedAtMonotonicNanoseconds: UInt64?

    init(
        command: [String],
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        exitCode: Int32,
        timedOut: Bool,
        processGroupCleaned: Bool,
        timeoutSeconds: TimeInterval,
        durationMs: Int,
        stdout: String,
        stderr: String,
        stdoutTruncated: Bool,
        stderrTruncated: Bool,
        completedAtMonotonicNanoseconds: UInt64? = nil
    ) {
        precondition(
            processIdentifier > 0 && processStartIdentity > 0 &&
                completedAtMonotonicNanoseconds.map { $0 > 0 } != false
        )
        self.command = command
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.processStartIdentityDecimal = String(processStartIdentity)
        self.exitCode = exitCode
        self.timedOut = timedOut
        self.processGroupCleaned = processGroupCleaned
        self.timeoutSeconds = timeoutSeconds
        self.durationMs = durationMs
        self.stdout = stdout
        self.stderr = stderr
        self.stdoutTruncated = stdoutTruncated
        self.stderrTruncated = stderrTruncated
        self.completedAtMonotonicNanoseconds = completedAtMonotonicNanoseconds
    }

    private enum CodingKeys: String, CodingKey {
        case command
        case processIdentifier
        case processStartIdentity
        case processStartIdentityDecimal
        case exitCode
        case timedOut
        case processGroupCleaned
        case timeoutSeconds
        case durationMs
        case stdout
        case stderr
        case stdoutTruncated
        case stderrTruncated
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let processIdentifier = try container.decode(pid_t.self, forKey: .processIdentifier)
        let processStartIdentity = try container.decode(UInt64.self, forKey: .processStartIdentity)
        let processStartIdentityDecimal = try container.decode(
            String.self,
            forKey: .processStartIdentityDecimal
        )
        let timeoutSeconds = try container.decode(TimeInterval.self, forKey: .timeoutSeconds)
        let durationMs = try container.decode(Int.self, forKey: .durationMs)
        guard processIdentifier > 0,
              processStartIdentity > 0,
              processStartIdentityDecimal == String(processStartIdentity),
              timeoutSeconds.isFinite,
              timeoutSeconds >= 0,
              durationMs >= 0
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentity,
                in: container,
                debugDescription: "Capture action process result has invalid custody fields"
            )
        }
        self.command = try container.decode([String].self, forKey: .command)
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.processStartIdentityDecimal = processStartIdentityDecimal
        self.exitCode = try container.decode(Int32.self, forKey: .exitCode)
        self.timedOut = try container.decode(Bool.self, forKey: .timedOut)
        self.processGroupCleaned = try container.decode(Bool.self, forKey: .processGroupCleaned)
        self.timeoutSeconds = timeoutSeconds
        self.durationMs = durationMs
        self.stdout = try container.decode(String.self, forKey: .stdout)
        self.stderr = try container.decode(String.self, forKey: .stderr)
        self.stdoutTruncated = try container.decode(Bool.self, forKey: .stdoutTruncated)
        self.stderrTruncated = try container.decode(Bool.self, forKey: .stderrTruncated)
        self.completedAtMonotonicNanoseconds = nil
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.command, forKey: .command)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(self.processStartIdentity, forKey: .processStartIdentity)
        try container.encode(self.processStartIdentityDecimal, forKey: .processStartIdentityDecimal)
        try container.encode(self.exitCode, forKey: .exitCode)
        try container.encode(self.timedOut, forKey: .timedOut)
        try container.encode(self.processGroupCleaned, forKey: .processGroupCleaned)
        try container.encode(self.timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(self.durationMs, forKey: .durationMs)
        try container.encode(self.stdout, forKey: .stdout)
        try container.encode(self.stderr, forKey: .stderr)
        try container.encode(self.stdoutTruncated, forKey: .stdoutTruncated)
        try container.encode(self.stderrTruncated, forKey: .stderrTruncated)
    }

    var succeeded: Bool {
        !self.timedOut && self.processGroupCleaned && self.exitCode == 0
    }
}
