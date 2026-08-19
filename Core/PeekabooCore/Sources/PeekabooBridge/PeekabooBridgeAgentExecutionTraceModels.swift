import Foundation

// MARK: - Protocol 1.31 wire contract

public enum PeekabooBridgeAgentExecutionPolicy {
    /// The task is transported in `argv`. Keep it to one quarter of macOS's 1 MiB `ARG_MAX` so
    /// fixed arguments, the closed environment, pointer tables, and kernel bookkeeping retain
    /// substantial headroom.
    public static let maximumTaskBytes = 256 * 1024

    /// A second aggregate gate protects against unexpectedly large allowlisted environment values.
    static let maximumArgumentEnvironmentBytes = 512 * 1024
}

/// One long-running, background-only Agent execution owned by the Bridge host.
public struct PeekabooBridgeAgentExecutionTraceRequest: Codable, Equatable, Sendable {
    public let task: String
    public let maxSteps: Int
    public let runRootPath: String
    public let coordinationReceiptPath: String
    public let acknowledgementPath: String
    public let startTimeoutMilliseconds: Int
    public let runTimeoutMilliseconds: Int

    public init(
        task: String,
        maxSteps: Int,
        runRootPath: String,
        coordinationReceiptPath: String,
        acknowledgementPath: String,
        startTimeoutMilliseconds: Int,
        runTimeoutMilliseconds: Int)
    {
        self.task = task
        self.maxSteps = maxSteps
        self.runRootPath = runRootPath
        self.coordinationReceiptPath = coordinationReceiptPath
        self.acknowledgementPath = acknowledgementPath
        self.startTimeoutMilliseconds = startTimeoutMilliseconds
        self.runTimeoutMilliseconds = runTimeoutMilliseconds
    }
}

/// The exact child generation and executable committed by the terminal response.
public struct PeekabooBridgeAgentExecutionProcessIdentity: Codable, Equatable, Sendable {
    public let processIdentity: PeekabooBridgeOperationProcessIdentity
    public let executablePath: String
    public let executableSHA256: String

    public init(
        processIdentity: PeekabooBridgeOperationProcessIdentity,
        executablePath: String,
        executableSHA256: String)
    {
        self.processIdentity = processIdentity
        self.executablePath = executablePath
        self.executableSHA256 = executableSHA256
    }
}

/// Host-published launch authority. The connected CLI must acknowledge these exact bytes before release.
public struct PeekabooBridgeAgentExecutionCoordinationReceipt: Codable, Equatable, Sendable {
    public let version: Int
    public let challenge: String
    public let requestingPeer: PeekabooBridgeOperationProcessIdentity
    public let process: PeekabooBridgeAgentExecutionProcessIdentity
    public let bridgeSocketPath: String
    public let runRootPath: String
    public let coordinationReceiptPath: String
    public let acknowledgementPath: String
    public let operationReceiptDirectoryPath: String
    public let taskSHA256: String
    public let maxSteps: Int
    public let startTimeoutMilliseconds: Int
    public let runTimeoutMilliseconds: Int
    public let arguments: [String]
    public let argumentsSHA256: String
    public let backgroundOnly: Bool
    public let allowForeground: Bool
    public let shellAvailable: Bool
    /// Both soft and hard Darwin `RLIMIT_NPROC`; readiness is required before `publishedAt`.
    public let processCreationLimit: Int
    public let environmentPolicyVersion: Int
    public let environmentKeys: [String]
    public let environmentSHA256: String
    public let spawnedAt: Int64
    public let lockdownAcknowledgedAt: Int64
    public let publishedAt: Int64

    public init(
        version: Int = 1,
        challenge: String,
        requestingPeer: PeekabooBridgeOperationProcessIdentity,
        process: PeekabooBridgeAgentExecutionProcessIdentity,
        bridgeSocketPath: String,
        runRootPath: String,
        coordinationReceiptPath: String,
        acknowledgementPath: String,
        operationReceiptDirectoryPath: String,
        taskSHA256: String,
        maxSteps: Int,
        startTimeoutMilliseconds: Int,
        runTimeoutMilliseconds: Int,
        arguments: [String],
        argumentsSHA256: String,
        backgroundOnly: Bool,
        allowForeground: Bool,
        shellAvailable: Bool,
        processCreationLimit: Int,
        environmentPolicyVersion: Int,
        environmentKeys: [String],
        environmentSHA256: String,
        spawnedAt: Int64,
        lockdownAcknowledgedAt: Int64,
        publishedAt: Int64)
    {
        self.version = version
        self.challenge = challenge
        self.requestingPeer = requestingPeer
        self.process = process
        self.bridgeSocketPath = bridgeSocketPath
        self.runRootPath = runRootPath
        self.coordinationReceiptPath = coordinationReceiptPath
        self.acknowledgementPath = acknowledgementPath
        self.operationReceiptDirectoryPath = operationReceiptDirectoryPath
        self.taskSHA256 = taskSHA256
        self.maxSteps = maxSteps
        self.startTimeoutMilliseconds = startTimeoutMilliseconds
        self.runTimeoutMilliseconds = runTimeoutMilliseconds
        self.arguments = arguments
        self.argumentsSHA256 = argumentsSHA256
        self.backgroundOnly = backgroundOnly
        self.allowForeground = allowForeground
        self.shellAvailable = shellAvailable
        self.processCreationLimit = processCreationLimit
        self.environmentPolicyVersion = environmentPolicyVersion
        self.environmentKeys = environmentKeys
        self.environmentSHA256 = environmentSHA256
        self.spawnedAt = spawnedAt
        self.lockdownAcknowledgedAt = lockdownAcknowledgedAt
        self.publishedAt = publishedAt
    }
}

/// Exact acknowledgement written atomically by the still-connected authenticated CLI.
public struct PeekabooBridgeAgentExecutionAcknowledgement: Codable, Equatable, Sendable {
    public let version: Int
    public let challenge: String
    public let coordinationReceiptSHA256: String
    public let requestingPeer: PeekabooBridgeOperationProcessIdentity
    public let process: PeekabooBridgeAgentExecutionProcessIdentity
    public let taskSHA256: String
    public let argumentsSHA256: String
    public let environmentSHA256: String
    public let acknowledgedAt: Int64

    public init(
        version: Int = 1,
        challenge: String,
        coordinationReceiptSHA256: String,
        requestingPeer: PeekabooBridgeOperationProcessIdentity,
        process: PeekabooBridgeAgentExecutionProcessIdentity,
        taskSHA256: String,
        argumentsSHA256: String,
        environmentSHA256: String,
        acknowledgedAt: Int64)
    {
        self.version = version
        self.challenge = challenge
        self.coordinationReceiptSHA256 = coordinationReceiptSHA256
        self.requestingPeer = requestingPeer
        self.process = process
        self.taskSHA256 = taskSHA256
        self.argumentsSHA256 = argumentsSHA256
        self.environmentSHA256 = environmentSHA256
        self.acknowledgedAt = acknowledgedAt
    }
}

/// Exact retained bytes and their independently checkable commitment.
public struct PeekabooBridgeAgentExecutionByteEvidence: Codable, Equatable, Sendable {
    public let bytes: Data
    public let sha256: String
    public let byteCount: Int
    public let truncated: Bool
    public let readErrorCode: Int32?

    public init(bytes: Data, truncated: Bool = false, readErrorCode: Int32? = nil) {
        self.bytes = bytes
        self.sha256 = PeekabooBridgeAgentExecutionCoding.sha256(bytes)
        self.byteCount = bytes.count
        self.truncated = truncated
        self.readErrorCode = readErrorCode
    }
}

public enum PeekabooBridgeAgentExecutionProcessDisposition: String, Codable, Equatable, Sendable {
    case exited
    case signaled
    case timedOut = "timed_out"
    case cancelled
    case outputOverflow = "output_overflow"
    case waitFailed = "wait_failed"
}

/// Whether stdout contained the one trusted Agent JSON result required by protocol 1.31.
public enum PeekabooBridgeAgentExecutionOutputDisposition: String, Codable, Equatable, Sendable {
    case validatedExecutionTrace = "validated_execution_trace"
    case emptyOutput = "empty_output"
    case malformedOrMultipleJSON = "malformed_or_multiple_json"
    case nonObjectJSON = "non_object_json"
    case reportedFailure = "reported_failure"
    case missingResult = "missing_result"
    case missingExecutionTrace = "missing_execution_trace"
    case invalidExecutionTrace = "invalid_execution_trace"
    case executionTraceTooLarge = "execution_trace_too_large"
    case outputOverflow = "output_overflow"
    case streamCaptureFailed = "stream_capture_failed"
}

/// Listener-signed terminal evidence. Post-release failures are results, never transport errors.
public struct PeekabooBridgeAgentExecutionTraceResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let process: PeekabooBridgeAgentExecutionProcessIdentity
    public let requestingPeer: PeekabooBridgeOperationProcessIdentity
    public let bridgeSocketPath: String
    public let runRootPath: String
    public let coordinationReceiptPath: String
    public let acknowledgementPath: String
    public let operationReceiptDirectoryPath: String
    public let taskSHA256: String
    public let maxSteps: Int
    public let startTimeoutMilliseconds: Int
    public let runTimeoutMilliseconds: Int
    public let arguments: [String]
    public let argumentsSHA256: String
    public let backgroundOnly: Bool
    public let allowForeground: Bool
    public let shellAvailable: Bool
    /// Both soft and hard Darwin `RLIMIT_NPROC`, attested before coordination publication.
    public let processCreationLimit: Int
    public let environmentPolicyVersion: Int
    public let environmentKeys: [String]
    public let environmentSHA256: String
    public let stdout: PeekabooBridgeAgentExecutionByteEvidence
    public let stderr: PeekabooBridgeAgentExecutionByteEvidence
    public let coordinationReceipt: PeekabooBridgeAgentExecutionByteEvidence
    public let acknowledgement: PeekabooBridgeAgentExecutionByteEvidence
    public let processDisposition: PeekabooBridgeAgentExecutionProcessDisposition
    public let outputDisposition: PeekabooBridgeAgentExecutionOutputDisposition
    public let executionTrace: PeekabooBridgeJSONValue?
    public let exitCode: Int32?
    public let terminationSignal: Int32?
    public let spawnedAt: Int64
    public let lockdownAcknowledgedAt: Int64
    public let coordinationReceiptPublishedAt: Int64
    public let acknowledgedAt: Int64
    public let releasedAt: Int64
    /// End of bounded terminal observation; `waitFailed` does not claim process termination.
    public let terminalObservationEndedAt: Int64

    public init(
        version: Int = 1,
        process: PeekabooBridgeAgentExecutionProcessIdentity,
        requestingPeer: PeekabooBridgeOperationProcessIdentity,
        bridgeSocketPath: String,
        runRootPath: String,
        coordinationReceiptPath: String,
        acknowledgementPath: String,
        operationReceiptDirectoryPath: String,
        taskSHA256: String,
        maxSteps: Int,
        startTimeoutMilliseconds: Int,
        runTimeoutMilliseconds: Int,
        arguments: [String],
        argumentsSHA256: String,
        backgroundOnly: Bool,
        allowForeground: Bool,
        shellAvailable: Bool,
        processCreationLimit: Int,
        environmentPolicyVersion: Int,
        environmentKeys: [String],
        environmentSHA256: String,
        stdout: PeekabooBridgeAgentExecutionByteEvidence,
        stderr: PeekabooBridgeAgentExecutionByteEvidence,
        coordinationReceipt: PeekabooBridgeAgentExecutionByteEvidence,
        acknowledgement: PeekabooBridgeAgentExecutionByteEvidence,
        processDisposition: PeekabooBridgeAgentExecutionProcessDisposition,
        outputDisposition: PeekabooBridgeAgentExecutionOutputDisposition,
        executionTrace: PeekabooBridgeJSONValue?,
        exitCode: Int32?,
        terminationSignal: Int32?,
        spawnedAt: Int64,
        lockdownAcknowledgedAt: Int64,
        coordinationReceiptPublishedAt: Int64,
        acknowledgedAt: Int64,
        releasedAt: Int64,
        terminalObservationEndedAt: Int64)
    {
        self.version = version
        self.process = process
        self.requestingPeer = requestingPeer
        self.bridgeSocketPath = bridgeSocketPath
        self.runRootPath = runRootPath
        self.coordinationReceiptPath = coordinationReceiptPath
        self.acknowledgementPath = acknowledgementPath
        self.operationReceiptDirectoryPath = operationReceiptDirectoryPath
        self.taskSHA256 = taskSHA256
        self.maxSteps = maxSteps
        self.startTimeoutMilliseconds = startTimeoutMilliseconds
        self.runTimeoutMilliseconds = runTimeoutMilliseconds
        self.arguments = arguments
        self.argumentsSHA256 = argumentsSHA256
        self.backgroundOnly = backgroundOnly
        self.allowForeground = allowForeground
        self.shellAvailable = shellAvailable
        self.processCreationLimit = processCreationLimit
        self.environmentPolicyVersion = environmentPolicyVersion
        self.environmentKeys = environmentKeys
        self.environmentSHA256 = environmentSHA256
        self.stdout = stdout
        self.stderr = stderr
        self.coordinationReceipt = coordinationReceipt
        self.acknowledgement = acknowledgement
        self.processDisposition = processDisposition
        self.outputDisposition = outputDisposition
        self.executionTrace = executionTrace
        self.exitCode = exitCode
        self.terminationSignal = terminationSignal
        self.spawnedAt = spawnedAt
        self.lockdownAcknowledgedAt = lockdownAcknowledgedAt
        self.coordinationReceiptPublishedAt = coordinationReceiptPublishedAt
        self.acknowledgedAt = acknowledgedAt
        self.releasedAt = releasedAt
        self.terminalObservationEndedAt = terminalObservationEndedAt
    }

    /// Re-derives every caller-visible commitment from the request and retained bytes.
    public func validate(request: PeekabooBridgeAgentExecutionTraceRequest) throws {
        guard self.version == 1,
              !request.task.isEmpty,
              request.task.first != "-",
              request.task.utf8.count <= PeekabooBridgeAgentExecutionPolicy.maximumTaskBytes,
              !request.task.utf8.contains(0),
              (1...120_000).contains(request.startTimeoutMilliseconds),
              (1...7_200_000).contains(request.runTimeoutMilliseconds),
              request.runRootPath.first == "/",
              request.coordinationReceiptPath.first == "/",
              request.acknowledgementPath.first == "/",
              self.runRootPath == request.runRootPath,
              self.coordinationReceiptPath == request.coordinationReceiptPath,
              self.acknowledgementPath == request.acknowledgementPath,
              self.operationReceiptDirectoryPath == URL(fileURLWithPath: request.runRootPath, isDirectory: true)
                  .appendingPathComponent(PeekabooBridgeAgentExecutionCoding.operationReceiptDirectoryBasename)
                  .path,
                  self.taskSHA256 == PeekabooBridgeAgentExecutionCoding.sha256(Data(request.task.utf8)),
                  self.maxSteps == request.maxSteps,
                  (1...100).contains(self.maxSteps),
                  self.startTimeoutMilliseconds == request.startTimeoutMilliseconds,
                  self.runTimeoutMilliseconds == request.runTimeoutMilliseconds,
                  self.arguments == PeekabooBridgeAgentExecutionCoding.arguments(
                      task: request.task,
                      maxSteps: request.maxSteps,
                      socketPath: self.bridgeSocketPath),
                  self.argumentsSHA256 == PeekabooBridgeAgentExecutionCoding.argumentsSHA256(
                      task: request.task,
                      maxSteps: request.maxSteps,
                      socketPath: self.bridgeSocketPath),
                  self.backgroundOnly,
                  !self.allowForeground,
                  !self.shellAvailable,
                  self.processCreationLimit == 0,
                  self.environmentPolicyVersion == 3,
                  self.environmentKeys == self.environmentKeys.sorted(),
                  Set(self.environmentKeys).count == self.environmentKeys.count,
                  Set(self.environmentKeys).isSubset(of: Self.allowedEnvironmentKeys),
                  self.environmentKeys.contains("PATH"),
                  self.environmentKeys.contains("PEEKABOO_OPERATION_RECEIPT_DIRECTORY"),
                  self.environmentKeys.contains("PEEKABOO_AGENT_EXECUTION_GATE_FD"),
                  self.environmentKeys.contains("PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE"),
                  self.environmentKeys.contains("PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD"),
                  self.environmentKeys.contains("PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT"),
                  self.process.processIdentity.processIdentifier > 0,
                  self.process.processIdentity.processStartIdentity > 0,
                  self.requestingPeer.processIdentifier > 0,
                  self.requestingPeer.processStartIdentity > 0,
                  self.process.processIdentity.processIdentifier != self.requestingPeer.processIdentifier,
                  Self.isCDHash(self.process.processIdentity.codeSignatureHash),
                  Self.isCDHash(self.requestingPeer.codeSignatureHash),
                  self.process.processIdentity.codeSignatureHash == self.requestingPeer.codeSignatureHash,
                  self.bridgeSocketPath.first == "/",
                  self.process.executablePath.first == "/",
                  Self.isSHA256(self.process.executableSHA256),
                  Self.isSHA256(self.taskSHA256),
                  Self.isSHA256(self.argumentsSHA256),
                  Self.isSHA256(self.environmentSHA256),
                  self.validateEvidence(self.stdout),
                  self.validateEvidence(self.stderr),
                  self.validateEvidence(self.coordinationReceipt),
                  self.validateEvidence(self.acknowledgement),
                  !self.coordinationReceipt.truncated,
                  self.coordinationReceipt.readErrorCode == nil,
                  !self.acknowledgement.truncated,
                  self.acknowledgement.readErrorCode == nil,
                  self.stdout.byteCount + self.stderr.byteCount <= 16 * 1024 * 1024,
                  self.spawnedAt > 0,
                  self.spawnedAt <= self.lockdownAcknowledgedAt,
                  self.lockdownAcknowledgedAt <= self.coordinationReceiptPublishedAt,
                  self.coordinationReceiptPublishedAt <= self.acknowledgedAt,
                  self.acknowledgedAt <= self.releasedAt,
                  self.releasedAt <= self.terminalObservationEndedAt
        else {
            throw PeekabooBridgeAgentExecutionResponseValidationError.inconsistentTerminalEvidence
        }

        do {
            try PeekabooBridgeAgentExecutionAcknowledgementReader.validateExactKeys(self.acknowledgement.bytes)
        } catch {
            throw PeekabooBridgeAgentExecutionResponseValidationError.inconsistentTerminalEvidence
        }
        let decoder = JSONDecoder.peekabooBridgeDecoder()
        let receipt = try decoder.decode(
            PeekabooBridgeAgentExecutionCoordinationReceipt.self,
            from: self.coordinationReceipt.bytes)
        let acknowledgement = try decoder.decode(
            PeekabooBridgeAgentExecutionAcknowledgement.self,
            from: self.acknowledgement.bytes)
        guard receipt.version == 1,
              receipt.requestingPeer == self.requestingPeer,
              receipt.process == self.process,
              receipt.bridgeSocketPath == self.bridgeSocketPath,
              receipt.runRootPath == self.runRootPath,
              receipt.coordinationReceiptPath == self.coordinationReceiptPath,
              receipt.acknowledgementPath == self.acknowledgementPath,
              receipt.operationReceiptDirectoryPath == self.operationReceiptDirectoryPath,
              receipt.taskSHA256 == self.taskSHA256,
              receipt.maxSteps == self.maxSteps,
              receipt.startTimeoutMilliseconds == self.startTimeoutMilliseconds,
              receipt.runTimeoutMilliseconds == self.runTimeoutMilliseconds,
              receipt.arguments == self.arguments,
              receipt.argumentsSHA256 == self.argumentsSHA256,
              receipt.backgroundOnly == self.backgroundOnly,
              receipt.allowForeground == self.allowForeground,
              receipt.shellAvailable == self.shellAvailable,
              receipt.processCreationLimit == self.processCreationLimit,
              receipt.environmentPolicyVersion == self.environmentPolicyVersion,
              receipt.environmentKeys == self.environmentKeys,
              receipt.environmentSHA256 == self.environmentSHA256,
              receipt.spawnedAt == self.spawnedAt,
              receipt.lockdownAcknowledgedAt == self.lockdownAcknowledgedAt,
              receipt.publishedAt == self.coordinationReceiptPublishedAt,
              acknowledgement.version == 1,
              acknowledgement.challenge == receipt.challenge,
              acknowledgement.coordinationReceiptSHA256 == self.coordinationReceipt.sha256,
              acknowledgement.requestingPeer == self.requestingPeer,
              acknowledgement.process == self.process,
              acknowledgement.taskSHA256 == self.taskSHA256,
              acknowledgement.argumentsSHA256 == self.argumentsSHA256,
              acknowledgement.environmentSHA256 == self.environmentSHA256,
              acknowledgement.acknowledgedAt >= receipt.publishedAt,
              acknowledgement.acknowledgedAt <= self.acknowledgedAt,
              Self.isChallenge(receipt.challenge),
              self.validateTerminalStatus()
        else {
            throw PeekabooBridgeAgentExecutionResponseValidationError.inconsistentTerminalEvidence
        }

        let extracted = PeekabooBridgeAgentExecutionOutputExtractor.extract(
            self.stdout.bytes,
            outputOverflow: self.processDisposition == .outputOverflow,
            streamFailed: self.stdout.readErrorCode != nil || self.stdout.truncated || self.stderr
                .readErrorCode != nil ||
                self.stderr.truncated)
        guard extracted.disposition == self.outputDisposition,
              extracted.trace == self.executionTrace
        else {
            throw PeekabooBridgeAgentExecutionResponseValidationError.invalidExecutionTraceEvidence
        }
    }

    private func validateEvidence(_ evidence: PeekabooBridgeAgentExecutionByteEvidence) -> Bool {
        evidence.byteCount == evidence.bytes.count &&
            evidence.sha256 == PeekabooBridgeAgentExecutionCoding.sha256(evidence.bytes) &&
            Self.isSHA256(evidence.sha256)
    }

    private func validateTerminalStatus() -> Bool {
        let processStateIsValid = switch self.processDisposition {
        case .exited:
            self.exitCode != nil && self.terminationSignal == nil
        case .signaled:
            self.exitCode == nil && self.terminationSignal != nil
        case .timedOut, .cancelled, .outputOverflow:
            (self.exitCode != nil) != (self.terminationSignal != nil)
        case .waitFailed:
            self.exitCode == nil && self.terminationSignal == nil
        }
        guard processStateIsValid else { return false }
        if self.processDisposition == .outputOverflow {
            return self.stdout.truncated || self.stderr.truncated
        }
        return true
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isChallenge(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static func isCDHash(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private static let allowedEnvironmentKeys: Set<String> = [
        "PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "LOGNAME", "SSL_CERT_DIR", "SSL_CERT_FILE",
        "TMPDIR", "TZ", "USER", "ANTHROPIC_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY",
        "GROK_API_KEY", "MINIMAX_API_KEY", "MOONSHOT_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY",
        "X_AI_API_KEY", "XAI_API_KEY", "PEEKABOO_OPERATION_RECEIPT_DIRECTORY",
        "PEEKABOO_AGENT_EXECUTION_GATE_FD",
        "PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE", "PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD",
        "PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT",
    ]
}

public enum PeekabooBridgeAgentExecutionResponseValidationError: Error, LocalizedError, Sendable {
    case inconsistentTerminalEvidence
    case invalidExecutionTraceEvidence

    public var errorDescription: String? {
        switch self {
        case .inconsistentTerminalEvidence:
            "Bridge Agent terminal evidence is incomplete or contradictory"
        case .invalidExecutionTraceEvidence:
            "Bridge Agent execution trace is not derived from the exact retained stdout"
        }
    }
}

/// Errors before the release challenge and Agent command routing are distinguishable from terminal child results.
public enum PeekabooBridgeAgentExecutionPreReleaseError: Error, LocalizedError, Sendable {
    case invalidRequest(String)
    case unauthenticatedPeer
    case unsafeRunRoot(String)
    case executableIdentityChanged
    case spawnFailed(String)
    case receiptPublicationFailed(String)
    case acknowledgementTimedOut
    case invalidAcknowledgement(String)
    case cancelledBeforeRelease
    case releaseFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message): "Invalid Bridge Agent request: \(message)"
        case .unauthenticatedPeer: "Bridge Agent launch peer is not the exact authenticated CLI generation"
        case let .unsafeRunRoot(path): "Bridge Agent run root or output path is unsafe: \(path)"
        case .executableIdentityChanged: "Authenticated CLI executable identity changed before release"
        case let .spawnFailed(message): "Suspended Bridge Agent spawn failed: \(message)"
        case let .receiptPublicationFailed(message): "Bridge Agent coordination receipt failed: \(message)"
        case .acknowledgementTimedOut: "Bridge Agent acknowledgement timed out before release"
        case let .invalidAcknowledgement(message): "Bridge Agent acknowledgement is invalid: \(message)"
        case .cancelledBeforeRelease: "Bridge Agent execution was cancelled before release"
        case let .releaseFailed(code): "Bridge Agent SIGCONT failed: \(String(cString: strerror(code)))"
        }
    }
}
