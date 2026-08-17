import Foundation
import PeekabooAutomationKit
import PeekabooBridge
import PeekabooFoundation

enum CertificationMutationOutcomePolicy {
    static func requireSuccessfulBackgroundDispatch(
        _ outcome: DesktopActionOutcome.Projection?,
        operation: String
    ) throws {
        guard let outcome,
              outcome.state == .confirmedChange || outcome.state == .dispatchedUnverified,
              outcome.route == .bridge,
              outcome.deliveryMode == .background,
              outcome.mutationDispatched,
              !outcome.retrySafe
        else {
            throw CertificationControllerError.runtimeRefusal(
                "\(operation) did not return a canonical successful background dispatch."
            )
        }
    }
}

struct CertificationProcessReceipt: Codable, Equatable, Sendable {
    let pid: Int32
    let startIdentity: String
    let codeSignatureHash: String

    private enum CodingKeys: String, CodingKey {
        case pid
        case startIdentity = "start_identity"
        case codeSignatureHash = "code_signature_hash"
    }
}

struct CertificationControllerBuildReceipt: Codable, Equatable, Sendable {
    let sourceCommit: String
    let executablePath: String
    let executableSHA256: String
    let teamID: String

    private enum CodingKeys: String, CodingKey {
        case sourceCommit = "source_commit"
        case executablePath = "executable_path"
        case executableSHA256 = "executable_sha256"
        case teamID = "team_id"
    }
}

struct CertificationWindowReceipt: Codable, Equatable, Sendable {
    let scope: String
    let pid: Int32
    let startIdentity: String
    let windowID: Int
    let bounds: CertificationBounds
    let isMinimized: Bool?

    private enum CodingKeys: String, CodingKey {
        case scope
        case pid
        case startIdentity = "start_identity"
        case windowID = "window_id"
        case bounds
        case isMinimized = "is_minimized"
    }

    init(target: CertificationExactTarget) {
        self.scope = "window"
        self.pid = target.processIdentifier
        self.startIdentity = target.processStartIdentityDecimal
        self.windowID = target.windowID
        self.bounds = target.bounds
        self.isMinimized = target.isMinimized
    }

    var processStartIdentity: UInt64? {
        UInt64(self.startIdentity)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.scope, forKey: .scope)
        try container.encode(self.pid, forKey: .pid)
        try container.encode(self.startIdentity, forKey: .startIdentity)
        try container.encode(self.windowID, forKey: .windowID)
        try container.encode(self.bounds, forKey: .bounds)
        try container.encode(self.isMinimized, forKey: .isMinimized)
    }
}

struct CertificationProtocolVersionReceipt: Codable, Equatable, Sendable {
    let major: Int
    let minor: Int
}

struct CertificationHostReceipt: Codable, Equatable, Sendable {
    let process: CertificationProcessReceipt
    let bundleIdentifier: String?
    let bundleShortVersion: String?
    let bundleVersion: String?
    let sourceCommit: String

    private enum CodingKeys: String, CodingKey {
        case process
        case bundleIdentifier = "bundle_identifier"
        case bundleShortVersion = "bundle_short_version"
        case bundleVersion = "bundle_version"
        case sourceCommit = "source_commit"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.process, forKey: .process)
        try container.encode(self.bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(self.bundleShortVersion, forKey: .bundleShortVersion)
        try container.encode(self.bundleVersion, forKey: .bundleVersion)
        try container.encode(self.sourceCommit, forKey: .sourceCommit)
    }
}

struct CertificationSessionReceipt: Codable, Equatable, Sendable {
    let id: String
    let clientInstanceID: String
    let maximumRequestCount: Int
    let initialRemainingClaimCount: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case clientInstanceID = "client_instance_id"
        case maximumRequestCount = "maximum_request_count"
        case initialRemainingClaimCount = "initial_remaining_claim_count"
    }
}

struct CertificationHandshakeReceipt: Codable, Equatable, Sendable {
    let socketPath: String
    let negotiatedVersion: CertificationProtocolVersionReceipt
    let hostKind: String
    let build: String?
    let listenerInstanceID: String
    let host: CertificationHostReceipt
    let session: CertificationSessionReceipt

    private enum CodingKeys: String, CodingKey {
        case socketPath = "socket_path"
        case negotiatedVersion = "negotiated_version"
        case hostKind = "host_kind"
        case build
        case listenerInstanceID = "listener_instance_id"
        case host
        case session
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.socketPath, forKey: .socketPath)
        try container.encode(self.negotiatedVersion, forKey: .negotiatedVersion)
        try container.encode(self.hostKind, forKey: .hostKind)
        try container.encode(self.build, forKey: .build)
        try container.encode(self.listenerInstanceID, forKey: .listenerInstanceID)
        try container.encode(self.host, forKey: .host)
        try container.encode(self.session, forKey: .session)
    }
}

struct CertificationIntervalReceipt: Codable, Equatable, Sendable {
    let startedAtMilliseconds: Int64
    let completedAtMilliseconds: Int64

    private enum CodingKeys: String, CodingKey {
        case startedAtMilliseconds = "started_at_milliseconds"
        case completedAtMilliseconds = "completed_at_milliseconds"
    }
}

struct CertificationBundleReceipt: Codable, Equatable, Sendable {
    let file: String
    let sha256: String
    let requestSHA256: String
    let responseSHA256: String

    private enum CodingKeys: String, CodingKey {
        case file
        case sha256
        case requestSHA256 = "request_sha256"
        case responseSHA256 = "response_sha256"
    }
}

struct CertificationSlotResult: Codable, Equatable, Sendable {
    let status: String
    let totalCharacters: Int?
    let keyPresses: Int?
    let observationFile: String?
    let observationSHA256: String?
    let observedBounds: CertificationBounds?

    private enum CodingKeys: String, CodingKey {
        case status
        case totalCharacters = "total_characters"
        case keyPresses = "key_presses"
        case observationFile = "observation_file"
        case observationSHA256 = "observation_sha256"
        case observedBounds = "observed_bounds"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.status, forKey: .status)
        try container.encode(self.totalCharacters, forKey: .totalCharacters)
        try container.encode(self.keyPresses, forKey: .keyPresses)
        try container.encode(self.observationFile, forKey: .observationFile)
        try container.encode(self.observationSHA256, forKey: .observationSHA256)
        try container.encode(self.observedBounds, forKey: .observedBounds)
    }
}

struct CertificationSlotReceipt: Codable, Equatable, Sendable {
    let slotID: String
    let kind: String
    let operation: String
    let checkpoint: String?
    let marker: String
    let requestID: String
    let sessionID: String
    let sessionSequence: String
    let listenerInstanceID: String
    let target: CertificationWindowReceipt
    let interval: CertificationIntervalReceipt
    let controllerInterval: CertificationIntervalReceipt
    let outcome: DesktopActionOutcome.Projection?
    let result: CertificationSlotResult
    let bundle: CertificationBundleReceipt

    private enum CodingKeys: String, CodingKey {
        case slotID = "slot_id"
        case kind
        case operation
        case checkpoint
        case marker
        case requestID = "request_id"
        case sessionID = "session_id"
        case sessionSequence = "session_sequence"
        case listenerInstanceID = "listener_instance_id"
        case target
        case interval
        case controllerInterval = "controller_interval"
        case outcome
        case result
        case bundle
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.slotID, forKey: .slotID)
        try container.encode(self.kind, forKey: .kind)
        try container.encode(self.operation, forKey: .operation)
        try container.encode(self.checkpoint, forKey: .checkpoint)
        try container.encode(self.marker, forKey: .marker)
        try container.encode(self.requestID, forKey: .requestID)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.sessionSequence, forKey: .sessionSequence)
        try container.encode(self.listenerInstanceID, forKey: .listenerInstanceID)
        try container.encode(self.target, forKey: .target)
        try container.encode(self.interval, forKey: .interval)
        try container.encode(self.controllerInterval, forKey: .controllerInterval)
        try container.encode(self.outcome, forKey: .outcome)
        try container.encode(self.result, forKey: .result)
        try container.encode(self.bundle, forKey: .bundle)
    }
}

struct CertificationControllerReceipt: Codable, Equatable, Sendable {
    let version: Int
    let result: String
    let executionNonce: String
    let monitorInstanceID: String
    let controllerID: String
    let targetID: String
    let controller: CertificationProcessReceipt
    let build: CertificationControllerBuildReceipt
    let handshake: CertificationHandshakeReceipt
    let target: CertificationWindowReceipt
    let interval: CertificationIntervalReceipt
    let slots: [CertificationSlotReceipt]

    private enum CodingKeys: String, CodingKey {
        case version
        case result
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case controllerID = "controller_id"
        case targetID = "target_id"
        case controller
        case build
        case handshake
        case target
        case interval
        case slots
    }
}

enum CertificationObserverMode: String, Codable, Sendable {
    case observeOnly = "observe-only"
}

struct CertificationObserverReadyReceipt: Codable, Equatable, Sendable {
    let version: Int
    let mode: CertificationObserverMode
    let executionNonce: String
    let observerID: String
    let observer: CertificationProcessReceipt
    let observerBuild: CertificationControllerBuildReceipt
    let target: CertificationWindowReceipt
    let focusedElement: CertificationFocusedElementReceipt
    let requestMarker: String
    let baselineValueSHA256: String
    let expectedValueSHA256: String
    let observationPath: String
    let restorationPath: String
    let readyAtMilliseconds: Int64

    private enum CodingKeys: String, CodingKey {
        case version
        case mode
        case executionNonce = "execution_nonce"
        case observerID = "observer_id"
        case observer
        case observerBuild = "observer_build"
        case target
        case focusedElement = "focused_element"
        case requestMarker = "request_marker"
        case baselineValueSHA256 = "baseline_value_sha256"
        case expectedValueSHA256 = "expected_value_sha256"
        case observationPath = "observation_path"
        case restorationPath = "restoration_path"
        case readyAtMilliseconds = "ready_at_milliseconds"
    }
}

struct CertificationFocusedElementReceipt: Codable, Equatable, Sendable {
    let role: String
    let title: String?
    let identifier: String?
    let frame: CertificationBounds

    private enum CodingKeys: String, CodingKey {
        case role
        case title
        case identifier
        case frame
    }

    init(_ identity: FocusedElementIdentity) {
        self.role = identity.role
        self.title = identity.title
        self.identifier = identity.identifier
        self.frame = CertificationBounds(
            x: identity.frame.origin.x,
            y: identity.frame.origin.y,
            width: identity.frame.width,
            height: identity.frame.height
        )
    }

    init(
        identity: FocusedElementIdentity,
        semanticElement: CertificationSemanticElement
    ) {
        self.role = semanticElement.role
        self.title = semanticElement.title
        self.identifier = semanticElement.identifier
        self.frame = CertificationBounds(
            x: identity.frame.origin.x,
            y: identity.frame.origin.y,
            width: identity.frame.width,
            height: identity.frame.height
        )
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(String.self, forKey: .role)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        self.frame = try container.decode(CertificationBounds.self, forKey: .frame)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.role, forKey: .role)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.identifier, forKey: .identifier)
        try container.encode(self.frame, forKey: .frame)
    }
}

struct CertificationObserverRequestMarker: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case observe
        case restore
        case release
    }

    let version: Int
    let executionNonce: String
    let requestMarker: String
    let phase: Phase

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case requestMarker = "request_marker"
        case phase
    }
}

struct CertificationForegroundReadbackDocument: Codable, Equatable, Sendable {
    let version: Int
    let executionNonce: String
    let requestMarker: String
    let target: CertificationWindowReceipt
    let observer: CertificationProcessReceipt
    let observedValueSHA256: String
    let observedAtMilliseconds: Int64

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case requestMarker = "request_marker"
        case target
        case observer
        case observedValueSHA256 = "observed_value_sha256"
        case observedAtMilliseconds = "observed_at_milliseconds"
    }
}

struct CertificationForegroundPostconditionWitness: Codable, Equatable, Sendable {
    let version: Int
    let executionNonce: String
    let target: CertificationWindowReceipt
    let observer: CertificationProcessReceipt
    let focusedElement: CertificationFocusedElementReceipt
    let interval: CertificationIntervalReceipt
    let requestMarker: String
    let beforeValueSHA256: String
    let expectedValueSHA256: String
    let observedValueSHA256: String
    let restoredValueSHA256: String
    let observationPath: String
    let observationFileSHA256: String
    let restorationPath: String
    let restorationFileSHA256: String
    let passed: Bool
    let restored: Bool

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case target
        case observer
        case focusedElement = "focused_element"
        case interval
        case requestMarker = "request_marker"
        case beforeValueSHA256 = "before_value_sha256"
        case expectedValueSHA256 = "expected_value_sha256"
        case observedValueSHA256 = "observed_value_sha256"
        case restoredValueSHA256 = "restored_value_sha256"
        case observationPath = "observation_path"
        case observationFileSHA256 = "observation_file_sha256"
        case restorationPath = "restoration_path"
        case restorationFileSHA256 = "restoration_file_sha256"
        case passed
        case restored
    }
}

struct CertificationMutationSynchronizationMarker: Codable, Equatable, Sendable {
    let version: Int
    let phase: String
    let executionNonce: String
    let controllerID: String
    let targetID: String
    let target: CertificationWindowReceipt
    let timestampMilliseconds: Int64

    private enum CodingKeys: String, CodingKey {
        case version
        case phase
        case executionNonce = "execution_nonce"
        case controllerID = "controller_id"
        case targetID = "target_id"
        case target
        case timestampMilliseconds = "timestamp_milliseconds"
    }
}

struct CertificationControllerReleaseMarker: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case release
    }

    let version: Int
    let executionNonce: String
    let phase: Phase

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case phase
    }

    func validate(executionNonce: String) throws {
        guard self.version == 1,
              self.executionNonce == executionNonce,
              self.phase == .release
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller release marker is not bound to the exact run."
            )
        }
    }
}

struct CertificationControllerReadyReceipt: Codable, Equatable, Sendable {
    let version: Int
    let executionNonce: String
    let controllerID: String
    let targetID: String
    let controller: CertificationProcessReceipt
    let build: CertificationControllerBuildReceipt
    let readyAtMilliseconds: Int64

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case controllerID = "controller_id"
        case targetID = "target_id"
        case controller
        case build
        case readyAtMilliseconds = "ready_at_milliseconds"
    }
}

struct CertificationFinalBoundsReadyReceipt: Codable, Equatable, Sendable {
    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let controllerID: String
    let targetID: String
    let controller: CertificationProcessReceipt
    let completedSlotIDs: [String]
    let readyAtMilliseconds: Int64

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case controllerID = "controller_id"
        case targetID = "target_id"
        case controller
        case completedSlotIDs = "completed_slot_ids"
        case readyAtMilliseconds = "ready_at_milliseconds"
    }
}

struct CertificationFinalBoundsStartMarker: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case finalBounds = "final-bounds"
    }

    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let controllerID: String
    let phase: Phase

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case controllerID = "controller_id"
        case phase
    }

    func validate(executionNonce: String, monitorInstanceID: String, controllerID: String) throws {
        guard self.version == 1,
              self.executionNonce == executionNonce,
              self.monitorInstanceID == monitorInstanceID,
              self.controllerID == controllerID,
              self.phase == .finalBounds
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Final-bounds start marker is not bound to the exact run and controller."
            )
        }
    }
}

struct CertificationControllerStartMarker: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case start
    }

    let version: Int
    let executionNonce: String
    let controllerID: String
    let phase: Phase

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case controllerID = "controller_id"
        case phase
    }

    func validate(executionNonce: String, controllerID: String) throws {
        guard self.version == 1,
              self.executionNonce == executionNonce,
              self.controllerID == controllerID,
              self.phase == .start
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller start marker is not bound to the exact run and controller."
            )
        }
    }
}

struct VerifiedCertificationSlot: Equatable, Sendable {
    let template: CertificationSlot
    let marker: String
    let requestID: UUID
    let sessionID: UUID
    let sessionSequence: UInt64
    let listenerInstanceID: UUID
    let target: CertificationWindowReceipt
    let interval: CertificationIntervalReceipt
    let controllerInterval: CertificationIntervalReceipt
    let outcome: DesktopActionOutcome.Projection?
    let result: CertificationSlotResult
    let bundle: CertificationBundleReceipt

    var receipt: CertificationSlotReceipt {
        CertificationSlotReceipt(
            slotID: self.template.id,
            kind: self.template.kind.rawValue,
            operation: self.template.operation.rawValue,
            checkpoint: self.template.checkpoint,
            marker: self.marker,
            requestID: self.requestID.uuidString.lowercased(),
            sessionID: self.sessionID.uuidString.lowercased(),
            sessionSequence: String(self.sessionSequence),
            listenerInstanceID: self.listenerInstanceID.uuidString.lowercased(),
            target: self.target,
            interval: self.interval,
            controllerInterval: self.controllerInterval,
            outcome: self.outcome,
            result: self.result,
            bundle: self.bundle
        )
    }
}

struct CertificationRunLedger: Sendable {
    let plan: CertificationControllerPlan
    let sessionID: UUID
    let listenerInstanceID: UUID
    private(set) var slots: [VerifiedCertificationSlot] = []

    mutating func append(_ evidence: VerifiedCertificationSlot) throws {
        let ordinal = self.slots.count
        guard ordinal < self.plan.slots.count else {
            throw CertificationControllerError.runtimeRefusal("Controller produced more than four slot results.")
        }
        let expected = self.plan.slots[ordinal]
        guard evidence.template == expected else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller slot order drifted at ordinal \(ordinal)."
            )
        }
        guard evidence.marker == self.plan.marker(for: expected) else {
            throw CertificationControllerError.runtimeRefusal("Controller slot marker does not match the run plan.")
        }
        guard evidence.sessionID == self.sessionID,
              evidence.listenerInstanceID == self.listenerInstanceID,
              evidence.sessionSequence == UInt64(ordinal)
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller receipt session or deterministic sequence changed at \(expected.id)."
            )
        }
        guard evidence.target == CertificationWindowReceipt(target: self.plan.target) else {
            throw CertificationControllerError.runtimeRefusal("Controller receipt target changed at \(expected.id).")
        }
        guard evidence.interval.startedAtMilliseconds > 0,
              evidence.interval.completedAtMilliseconds >= evidence.interval.startedAtMilliseconds,
              evidence.controllerInterval.startedAtMilliseconds > 0,
              evidence.controllerInterval.completedAtMilliseconds >= evidence.controllerInterval.startedAtMilliseconds,
              evidence.bundle.file == "bundles/\(evidence.requestID.uuidString.lowercased()).json"
        else {
            throw CertificationControllerError.runtimeRefusal("Controller slot evidence is not closed.")
        }
        guard !self.slots.contains(where: { $0.requestID == evidence.requestID }) else {
            throw CertificationControllerError.runtimeRefusal("Controller reused an operation request ID.")
        }
        self.slots.append(evidence)
    }

    func validatedReceipts() throws -> [CertificationSlotReceipt] {
        guard self.slots.count == self.plan.slots.count else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller completed \(self.slots.count) of four required slots."
            )
        }
        return self.slots.map(\.receipt)
    }

    func finalBoundsReadySlotIDs() throws -> [String] {
        let expected = self.plan.slots.dropLast().map(\.id)
        let completed = self.slots.map(\.template.id)
        guard completed == expected,
              self.plan.slots.last?.checkpoint == "final-bounds"
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller is not ready for its final-bounds barrier."
            )
        }
        return completed
    }
}
