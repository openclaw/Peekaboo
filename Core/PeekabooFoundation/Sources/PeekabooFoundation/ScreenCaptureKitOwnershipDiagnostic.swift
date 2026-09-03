import Foundation

/// Evidence from an ownership check, not a claim that an uncoordinated process used ScreenCaptureKit.
public struct ScreenCaptureKitOwnershipDiagnostic: Codable, Equatable, StandardizedError {
    public enum Kind: String, Codable, Sendable {
        case fileSystem, systemCall, unsafeDirectory, unsafeLockFile, invalidOwnerIdentity, invalidOwnerReceipt
        case ownedByAnotherProcess, uncoordinatedProcesses, uncoordinatedHosts, timedOut, cancelled, unavailable,
             unknown

        public init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public enum Stage: String, Codable, Sendable {
        case registration, preparation, entry, admission, unknown

        public init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public struct ProcessEvidence: Codable, Equatable, Sendable {
        public let processIdentifier: Int32?
        public let processStartIdentity: UInt64?
        public let executablePath: String?
        public let socketPath: String?
        public let buildIdentity: String?
        public let codeSignatureHash: String?

        public init(
            processIdentifier: Int32? = nil,
            processStartIdentity: UInt64? = nil,
            executablePath: String? = nil,
            socketPath: String? = nil,
            buildIdentity: String? = nil,
            codeSignatureHash: String? = nil)
        {
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.executablePath = executablePath
            self.socketPath = socketPath
            self.buildIdentity = buildIdentity
            self.codeSignatureHash = codeSignatureHash
        }

        public var description: String {
            var parts: [String] = []
            if let processIdentifier {
                parts.append("PID \(processIdentifier)")
            }
            if let processStartIdentity {
                parts.append("generation \(processStartIdentity)")
            }
            if let executablePath {
                parts.append(executablePath)
            }
            if let socketPath {
                parts.append("socket \(socketPath)")
            }
            if let buildIdentity {
                parts.append("build \(buildIdentity)")
            }
            if let codeSignatureHash {
                parts.append("CDHash \(codeSignatureHash)")
            }
            return parts.isEmpty ? "unknown process identity" : parts.joined(separator: ", ")
        }
    }

    public let kind: Kind
    public let stage: Stage
    public let message: String
    public let operation: String?
    public let path: String?
    public let systemCode: Int32?
    public let timeoutSeconds: TimeInterval?
    public let blockers: [ProcessEvidence]
    public let selectedHost: ProcessEvidence?

    public init(
        kind: Kind,
        stage: Stage,
        message: String,
        operation: String? = nil,
        path: String? = nil,
        systemCode: Int32? = nil,
        timeoutSeconds: TimeInterval? = nil,
        blockers: [ProcessEvidence] = [],
        selectedHost: ProcessEvidence? = nil)
    {
        self.kind = kind
        self.stage = stage
        self.message = message
        self.operation = operation
        self.path = path
        self.systemCode = systemCode
        self.timeoutSeconds = timeoutSeconds
        self.blockers = blockers
        self.selectedHost = selectedHost
    }

    public var code: StandardErrorCode {
        .captureFailed
    }

    public var context: [String: String] {
        [:]
    }

    public var userMessage: String {
        let host = self.selectedHost.map { "Selected host: \($0.description). " } ?? ""
        let blockers = self.blockers.isEmpty ? "" :
            " Blockers: " + self.blockers.map(\.description).joined(separator: "; ") + "."
        return host + self.message + blockers + " The ownership check did not dispatch ScreenCaptureKit."
    }

    public func selectingHost(_ host: ProcessEvidence) -> Self {
        Self(
            kind: self.kind,
            stage: self.stage,
            message: self.message,
            operation: self.operation,
            path: self.path,
            systemCode: self.systemCode,
            timeoutSeconds: self.timeoutSeconds,
            blockers: self.blockers,
            selectedHost: host)
    }
}

/// A preparation observation permits an attempt; actual ownership is checked again at every SCK entry.
public struct ScreenCaptureKitReadiness: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case ready, blocked, unavailable, unknown

        public init(from decoder: any Decoder) throws {
            self = try Self(rawValue: decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    public let state: State
    public let observedAt: Date?
    public let failure: ScreenCaptureKitOwnershipDiagnostic?

    public init(state: State, observedAt: Date = Date(), failure: ScreenCaptureKitOwnershipDiagnostic? = nil) {
        self.state = state
        self.observedAt = observedAt
        self.failure = failure
    }

    public var permitsAttempt: Bool {
        self.state == .ready && self.observedAt != nil && self.failure == nil
    }

    private enum CodingKeys: String, CodingKey { case state, observedAt, failure }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.state = try container.decodeIfPresent(State.self, forKey: .state) ?? .unknown
        self.observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        self.failure = try container.decodeIfPresent(ScreenCaptureKitOwnershipDiagnostic.self, forKey: .failure)
    }

    public var refusal: ScreenCaptureKitOwnershipDiagnostic {
        self.failure ?? .init(
            kind: .unavailable,
            stage: .admission,
            message: "ScreenCaptureKit preparation readiness is unavailable.")
    }
}
