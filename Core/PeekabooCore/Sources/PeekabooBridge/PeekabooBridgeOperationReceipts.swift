import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Security

/// Stable process-generation evidence used by protocol 1.29 operation receipts.
public struct PeekabooBridgeOperationProcessIdentity: Codable, Equatable, Sendable {
    public let processIdentifier: pid_t
    public let processStartIdentity: UInt64
    public let codeSignatureHash: String

    public init(processIdentifier: pid_t, processStartIdentity: UInt64, codeSignatureHash: String) {
        self.processIdentifier = processIdentifier
        self.processStartIdentity = processStartIdentity
        self.codeSignatureHash = codeSignatureHash
    }

    private enum CodingKeys: String, CodingKey {
        case processIdentifier
        case processStartIdentity
        case codeSignatureHash
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let processIdentifier = try container.decode(pid_t.self, forKey: .processIdentifier)
        let decimal = try container.decode(String.self, forKey: .processStartIdentity)
        let codeSignatureHash = try container.decode(String.self, forKey: .codeSignatureHash)
        guard processIdentifier > 0,
              let processStartIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal),
              !codeSignatureHash.isEmpty
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentity,
                in: container,
                debugDescription: "Bridge process identity fields are invalid")
        }
        self.init(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            codeSignatureHash: codeSignatureHash)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.processIdentifier, forKey: .processIdentifier)
        try container.encode(String(self.processStartIdentity), forKey: .processStartIdentity)
        try container.encode(self.codeSignatureHash, forKey: .codeSignatureHash)
    }
}

/// The strongest target the Bridge caller supplied for one operation.
///
/// The operation receipt never invents a more precise target than the request carried. Leaf
/// services remain responsible for validating their native target immediately before dispatch.
public enum PeekabooBridgeOperationTargetReceipt: Codable, Equatable, Sendable {
    case global
    case process(ApplicationProcessIdentity)
    case window(WindowMutationIdentity)

    private enum CodingKeys: String, CodingKey {
        case kind
        case processIdentifier
        case processStartIdentity
        case windowID
        case capturedBounds
        case isMinimized
    }

    private enum Kind: String, Codable {
        case global
        case process
        case window
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .global:
            self = .global
        case .process:
            self = try .process(Self.decodeProcessIdentity(from: container))
        case .window:
            let process = try Self.decodeProcessIdentity(from: container)
            let windowID = try container.decode(Int.self, forKey: .windowID)
            let capturedBounds = try container.decode(CGRect.self, forKey: .capturedBounds)
            let isMinimized = try container.decodeIfPresent(Bool.self, forKey: .isMinimized)
            guard windowID > 0,
                  UInt32(exactly: windowID) != nil,
                  capturedBounds.width > 0,
                  capturedBounds.height > 0
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .windowID,
                    in: container,
                    debugDescription: "Bridge operation window target fields are invalid")
            }
            self = .window(.init(
                windowID: windowID,
                ownerProcessIdentifier: process.processIdentifier,
                ownerProcessStartIdentity: process.processStartIdentity,
                capturedBounds: capturedBounds,
                isMinimized: isMinimized))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .global:
            try container.encode(Kind.global, forKey: .kind)
        case let .process(identity):
            try container.encode(Kind.process, forKey: .kind)
            try Self.encodeProcessIdentity(identity, to: &container)
        case let .window(identity):
            guard let capturedBounds = identity.capturedBounds else {
                throw EncodingError.invalidValue(
                    identity,
                    .init(
                        codingPath: container.codingPath,
                        debugDescription: "Exact Bridge operation target requires capture-time bounds"))
            }
            try container.encode(Kind.window, forKey: .kind)
            try Self.encodeProcessIdentity(identity.processIdentity, to: &container)
            try container.encode(identity.windowID, forKey: .windowID)
            try container.encode(capturedBounds, forKey: .capturedBounds)
            try container.encodeIfPresent(identity.isMinimized, forKey: .isMinimized)
        }
    }

    private static func decodeProcessIdentity(
        from container: KeyedDecodingContainer<CodingKeys>) throws -> ApplicationProcessIdentity
    {
        let processIdentifier = try container.decode(Int32.self, forKey: .processIdentifier)
        let decimal = try container.decode(String.self, forKey: .processStartIdentity)
        guard processIdentifier > 0,
              let processStartIdentity = PeekabooBridgeOperationReceiptCoding.uint64(decimal: decimal)
        else {
            throw DecodingError.dataCorruptedError(
                forKey: .processStartIdentity,
                in: container,
                debugDescription: "Bridge operation target process identity is invalid")
        }
        return .init(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity)
    }

    private static func encodeProcessIdentity(
        _ identity: ApplicationProcessIdentity,
        to container: inout KeyedEncodingContainer<CodingKeys>) throws
    {
        try container.encode(identity.processIdentifier, forKey: .processIdentifier)
        try container.encode(String(identity.processStartIdentity), forKey: .processStartIdentity)
    }
}

/// Self-signed, process-bound identity generated once for one listening socket lifetime.
public struct PeekabooBridgeListenerAttestation: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let listenerInstanceID: UUID
    public let publicKey: Data
    public let host: PeekabooBridgeOperationProcessIdentity
    public let createdAtUnixMilliseconds: Int64
    public let receiptArchiveDirectory: String
    public let signature: Data

    init(
        listenerInstanceID: UUID,
        publicKey: Data,
        host: PeekabooBridgeOperationProcessIdentity,
        createdAtUnixMilliseconds: Int64,
        receiptArchiveDirectory: String,
        signature: Data)
    {
        self.schemaVersion = 1
        self.listenerInstanceID = listenerInstanceID
        self.publicKey = publicKey
        self.host = host
        self.createdAtUnixMilliseconds = createdAtUnixMilliseconds
        self.receiptArchiveDirectory = receiptArchiveDirectory
        self.signature = signature
    }

    public func validateSignature() throws {
        guard self.schemaVersion == 1,
              self.host.processIdentifier > 0,
              self.host.processStartIdentity > 0,
              !self.host.codeSignatureHash.isEmpty,
              !self.receiptArchiveDirectory.isEmpty
        else {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: self.publicKey)
        } catch {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        guard try key.isValidSignature(
            self.signature,
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(self.unsignedPayload))
        else {
            throw PeekabooBridgeOperationReceiptError.invalidListenerSignature
        }
    }

    var unsignedPayload: UnsignedPayload {
        UnsignedPayload(
            schemaVersion: self.schemaVersion,
            listenerInstanceID: self.listenerInstanceID,
            publicKey: self.publicKey,
            host: self.host,
            createdAtUnixMilliseconds: self.createdAtUnixMilliseconds,
            receiptArchiveDirectory: self.receiptArchiveDirectory)
    }

    struct UnsignedPayload: Codable, Equatable, Sendable {
        let schemaVersion: Int
        let listenerInstanceID: UUID
        let publicKey: Data
        let host: PeekabooBridgeOperationProcessIdentity
        let createdAtUnixMilliseconds: Int64
        let receiptArchiveDirectory: String
    }
}

/// One unique, listener-bound operation request.
public struct PeekabooBridgeAttestedOperationRequest: Codable, Sendable {
    public let requestID: UUID
    public let expectedListenerInstanceID: UUID
    public let client: PeekabooBridgeOperationProcessIdentity
    public let request: PeekabooBridgeRequest

    public init(
        requestID: UUID,
        expectedListenerInstanceID: UUID,
        client: PeekabooBridgeOperationProcessIdentity,
        request: PeekabooBridgeRequest)
    {
        self.requestID = requestID
        self.expectedListenerInstanceID = expectedListenerInstanceID
        self.client = client
        self.request = request
    }

    func validatedRequest() throws -> PeekabooBridgeRequest {
        switch self.request {
        case .attestedOperation:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Attested Bridge operation requests cannot be nested")
        case .handshake:
            throw PeekabooBridgeErrorEnvelope(
                code: .invalidRequest,
                message: "Bridge handshakes cannot use operation receipt carriage")
        case let .projectedAction(payload):
            let nested = try payload.validatedRequest()
            if case .attestedOperation = nested {
                throw PeekabooBridgeErrorEnvelope(
                    code: .invalidRequest,
                    message: "Attested Bridge operation requests cannot be nested inside action carriage")
            }
        default:
            break
        }
        return self.request
    }
}

/// Canonical facts signed by the serving listener after one operation reaches a terminal response.
public struct PeekabooBridgeOperationReceiptPayload: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let requestID: UUID
    public let listenerInstanceID: UUID
    public let listenerPublicKeySHA256: String
    public let host: PeekabooBridgeOperationProcessIdentity
    public let client: PeekabooBridgeOperationProcessIdentity
    public let operation: PeekabooBridgeOperation
    public let requestSHA256: String
    public let responseSHA256: String
    public let target: PeekabooBridgeOperationTargetReceipt
    public let outcome: DesktopActionOutcome.Projection?
    public let startedAtUnixMilliseconds: Int64
    public let completedAtUnixMilliseconds: Int64

    public init(
        requestID: UUID,
        listenerInstanceID: UUID,
        listenerPublicKeySHA256: String,
        host: PeekabooBridgeOperationProcessIdentity,
        client: PeekabooBridgeOperationProcessIdentity,
        operation: PeekabooBridgeOperation,
        requestSHA256: String,
        responseSHA256: String,
        target: PeekabooBridgeOperationTargetReceipt,
        outcome: DesktopActionOutcome.Projection?,
        startedAtUnixMilliseconds: Int64,
        completedAtUnixMilliseconds: Int64)
    {
        self.schemaVersion = 1
        self.requestID = requestID
        self.listenerInstanceID = listenerInstanceID
        self.listenerPublicKeySHA256 = listenerPublicKeySHA256
        self.host = host
        self.client = client
        self.operation = operation
        self.requestSHA256 = requestSHA256
        self.responseSHA256 = responseSHA256
        self.target = target
        self.outcome = outcome
        self.startedAtUnixMilliseconds = startedAtUnixMilliseconds
        self.completedAtUnixMilliseconds = completedAtUnixMilliseconds
    }
}

/// Durable proof emitted by one listener. The signature covers every payload field.
public struct PeekabooBridgeOperationReceipt: Codable, Equatable, Sendable {
    public let payload: PeekabooBridgeOperationReceiptPayload
    public let signature: Data

    public init(payload: PeekabooBridgeOperationReceiptPayload, signature: Data) {
        self.payload = payload
        self.signature = signature
    }

    public func validateSignature(publicKey: Data) throws {
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        guard try key.isValidSignature(
            self.signature,
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(self.payload))
        else {
            throw PeekabooBridgeOperationReceiptError.invalidOperationSignature
        }
    }
}

/// Opt-in audit export that makes both signed digests independently reproducible.
///
/// Unlike the privacy-minimized host archive, this bundle contains the complete canonical request
/// and response bytes. Callers must treat it as sensitive command data.
public struct PeekabooBridgeOperationReceiptBundle: Codable, Equatable, Sendable {
    public let operationAttestation: PeekabooBridgeListenerAttestation
    public let receipt: PeekabooBridgeOperationReceipt
    public let canonicalListenerAttestationPayload: Data
    public let canonicalReceiptPayload: Data
    public let canonicalRequest: Data
    public let canonicalResponse: Data

    public init(
        operationAttestation: PeekabooBridgeListenerAttestation,
        receipt: PeekabooBridgeOperationReceipt,
        canonicalListenerAttestationPayload: Data,
        canonicalReceiptPayload: Data,
        canonicalRequest: Data,
        canonicalResponse: Data)
    {
        self.operationAttestation = operationAttestation
        self.receipt = receipt
        self.canonicalListenerAttestationPayload = canonicalListenerAttestationPayload
        self.canonicalReceiptPayload = canonicalReceiptPayload
        self.canonicalRequest = canonicalRequest
        self.canonicalResponse = canonicalResponse
    }

    public func validate() throws {
        guard try self.canonicalListenerAttestationPayload == (PeekabooBridgeOperationReceiptCoding.canonicalData(
            self.operationAttestation.unsignedPayload)),
            try self.canonicalReceiptPayload == (PeekabooBridgeOperationReceiptCoding.canonicalData(
                self.receipt.payload))
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the exported signature payload bytes")
        }
        try self.operationAttestation.validateSignature()
        try self.receipt.validateSignature(publicKey: self.operationAttestation.publicKey)
        guard self.receipt.payload.listenerInstanceID == self.operationAttestation.listenerInstanceID,
              self.receipt.payload.listenerPublicKeySHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.operationAttestation.publicKey),
              self.receipt.payload.requestSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.canonicalRequest),
              self.receipt.payload.responseSHA256 == PeekabooBridgeOperationReceiptCoding.sha256(
                  self.canonicalResponse)
        else {
            throw PeekabooBridgeOperationReceiptError.receiptMismatch("the exported verification bundle")
        }
    }
}

public struct PeekabooBridgeAttestedOperationResponse: Codable, Sendable {
    public let response: PeekabooBridgeResponse
    public let receipt: PeekabooBridgeOperationReceipt

    public init(response: PeekabooBridgeResponse, receipt: PeekabooBridgeOperationReceipt) {
        self.response = response
        self.receipt = receipt
    }
}

enum PeekabooBridgeOperationReceiptError: Error, LocalizedError, Equatable {
    case invalidListenerAttestation
    case invalidListenerSignature
    case listenerInstanceMismatch
    case peerIdentityMismatch
    case clientIdentityMismatch
    case replayedRequest
    case invalidOperationSignature
    case receiptMismatch(String)
    case unsafeArchive(String)
    case archiveWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidListenerAttestation:
            "Bridge listener attestation is incomplete or malformed"
        case .invalidListenerSignature:
            "Bridge listener attestation signature is invalid"
        case .listenerInstanceMismatch:
            "Bridge listener instance changed after handshake"
        case .peerIdentityMismatch:
            "Connected Bridge peer does not match the attested process generation"
        case .clientIdentityMismatch:
            "Bridge request client identity does not match the connected peer"
        case .replayedRequest:
            "Bridge operation request ID was already used by this listener"
        case .invalidOperationSignature:
            "Bridge operation receipt signature is invalid"
        case let .receiptMismatch(field):
            "Bridge operation receipt does not match \(field)"
        case let .unsafeArchive(path):
            "Bridge operation receipt archive is unsafe: \(path)"
        case let .archiveWriteFailed(message):
            "Bridge operation receipt archive write failed: \(message)"
        }
    }
}

enum PeekabooBridgeOperationReceiptCoding {
    static func canonicalData(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func sha256(_ value: some Encodable) throws -> String {
        try self.sha256(self.canonicalData(value))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func unixMilliseconds(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    }

    static func uint64(decimal: String) -> UInt64? {
        guard !decimal.isEmpty,
              decimal == "0" || decimal.first != "0",
              decimal.allSatisfy(\.isNumber),
              let value = UInt64(decimal),
              String(value) == decimal
        else { return nil }
        return value
    }
}

/// Ephemeral signer, replay fence, and private durable archive for one listening socket lifetime.
final class PeekabooBridgeOperationReceiptAuthority: @unchecked Sendable {
    let attestation: PeekabooBridgeListenerAttestation

    private let privateKey: Curve25519.Signing.PrivateKey
    private let archiveDirectory: URL
    private let lock = NSLock()
    private var claimedRequestIDs: Set<UUID> = []

    init(socketPath: String) throws {
        let processIdentifier = getpid()
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier),
              let codeSignatureHash = PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(
                  processIdentifier: processIdentifier)
        else {
            throw PeekabooBridgeOperationReceiptError.invalidListenerAttestation
        }
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let listenerInstanceID = UUID()
        let archiveRoot = URL(fileURLWithPath: socketPath + ".receipts", isDirectory: true)
        let archiveDirectory = archiveRoot.appendingPathComponent(
            listenerInstanceID.uuidString.lowercased(),
            isDirectory: true)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(archiveRoot)
        try PeekabooBridgePrivateReceiptArchive.prepareDirectory(archiveDirectory)

        let unsigned = PeekabooBridgeListenerAttestation.UnsignedPayload(
            schemaVersion: 1,
            listenerInstanceID: listenerInstanceID,
            publicKey: publicKey,
            host: .init(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                codeSignatureHash: codeSignatureHash),
            createdAtUnixMilliseconds: PeekabooBridgeOperationReceiptCoding.unixMilliseconds(),
            receiptArchiveDirectory: archiveDirectory.path)
        let signature = try privateKey.signature(
            for: PeekabooBridgeOperationReceiptCoding.canonicalData(unsigned))
        self.privateKey = privateKey
        self.archiveDirectory = archiveDirectory
        self.attestation = PeekabooBridgeListenerAttestation(
            listenerInstanceID: unsigned.listenerInstanceID,
            publicKey: unsigned.publicKey,
            host: unsigned.host,
            createdAtUnixMilliseconds: unsigned.createdAtUnixMilliseconds,
            receiptArchiveDirectory: unsigned.receiptArchiveDirectory,
            signature: signature)
    }

    func claim(
        _ payload: PeekabooBridgeAttestedOperationRequest,
        peer: PeekabooBridgePeer,
        currentProcessStartIdentity: (pid_t) -> UInt64? = SystemIdentityResolver.processStartIdentity) throws
    {
        guard payload.expectedListenerInstanceID == self.attestation.listenerInstanceID else {
            throw PeekabooBridgeOperationReceiptError.listenerInstanceMismatch
        }
        guard payload.client.processIdentifier == peer.processIdentifier,
              payload.client.processStartIdentity == peer.processStartIdentity,
              payload.client.codeSignatureHash == peer.codeSignatureHash,
              currentProcessStartIdentity(peer.processIdentifier) == payload.client.processStartIdentity
        else {
            throw PeekabooBridgeOperationReceiptError.clientIdentityMismatch
        }

        self.lock.lock()
        let inserted = self.claimedRequestIDs.insert(payload.requestID).inserted
        self.lock.unlock()
        guard inserted else {
            throw PeekabooBridgeOperationReceiptError.replayedRequest
        }
    }

    func signAndArchive(_ payload: PeekabooBridgeOperationReceiptPayload) throws
        -> PeekabooBridgeOperationReceipt
    {
        guard payload.listenerInstanceID == self.attestation.listenerInstanceID else {
            throw PeekabooBridgeOperationReceiptError.listenerInstanceMismatch
        }
        let signature: Data
        self.lock.lock()
        do {
            signature = try self.privateKey.signature(
                for: PeekabooBridgeOperationReceiptCoding.canonicalData(payload))
            self.lock.unlock()
        } catch {
            self.lock.unlock()
            throw error
        }
        let receipt = PeekabooBridgeOperationReceipt(payload: payload, signature: signature)
        let data = try PeekabooBridgeOperationReceiptCoding.canonicalData(receipt)
        let destination = self.archiveDirectory.appendingPathComponent(
            payload.requestID.uuidString.lowercased() + ".json",
            isDirectory: false)
        try PeekabooBridgePrivateReceiptArchive.writeAtomically(data, to: destination)
        return receipt
    }
}

enum PeekabooBridgeCodeSignatureIdentity {
    static func codeSignatureHash(processIdentifier: pid_t) -> String? {
        let attributes: NSDictionary = [kSecGuestAttributePid: processIdentifier]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code
        else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [String: Any],
              let hash = values[kSecCodeInfoUnique as String] as? Data,
              !hash.isEmpty
        else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

enum PeekabooBridgePrivateReceiptArchive {
    static func prepareDirectory(_ url: URL) throws {
        var existing = stat()
        if lstat(url.path, &existing) == 0 {
            guard (existing.st_mode & S_IFMT) == S_IFDIR,
                  existing.st_uid == geteuid(),
                  existing.st_mode & 0o077 == 0
            else {
                throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
            }
            return
        }
        guard errno == ENOENT else {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
        }

        let manager = FileManager.default
        do {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
        }

        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else {
            throw PeekabooBridgeOperationReceiptError.unsafeArchive(url.path)
        }
    }

    static func writeAtomically(_ data: Data, to destination: URL) throws {
        try self.prepareDirectory(destination.deletingLastPathComponent())
        let temporary = self.temporaryURL(for: destination)
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
        }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary {
                unlink(temporary.path)
            }
        }

        do {
            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
            }
            try data.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                    if count > 0 {
                        offset += count
                    } else if count == -1, errno == EINTR {
                        continue
                    } else {
                        throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(
                            String(cString: strerror(errno)))
                    }
                }
            }
            guard fsync(descriptor) == 0 else {
                throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
            }
            guard renameatx_np(
                AT_FDCWD,
                temporary.path,
                AT_FDCWD,
                destination.path,
                UInt32(RENAME_EXCL)) == 0
            else {
                throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
            }
            shouldRemoveTemporary = false
            let directoryDescriptor = open(
                destination.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard directoryDescriptor >= 0 else {
                throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
            }
            defer { close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else {
                throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(String(cString: strerror(errno)))
            }
        } catch let error as PeekabooBridgeOperationReceiptError {
            throw error
        } catch {
            throw PeekabooBridgeOperationReceiptError.archiveWriteFailed(error.localizedDescription)
        }
    }

    static func temporaryURL(for destination: URL, nonce: UUID = UUID()) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(nonce.uuidString.lowercased()).tmp")
    }
}

extension PeekabooBridgeRequest {
    func operationTargetReceipt(
        resolvedFrom response: PeekabooBridgeResponse) -> PeekabooBridgeOperationTargetReceipt
    {
        if self.operation != .detectElements,
           let resolved = response.resolvedOperationTargetReceipt
        {
            return resolved
        }
        // A mutating leaf revalidates any request-carried identity immediately around dispatch.
        // Read-only calls must instead prove their actual resolved target from the response.
        return self.mayMutateDesktop ? self.operationTargetReceipt : .global
    }

    var operationTargetReceipt: PeekabooBridgeOperationTargetReceipt {
        switch self {
        case let .projectedAction(payload):
            payload.request.operationTargetReceipt
        case let .attestedOperation(payload):
            payload.request.operationTargetReceipt
        case let .exactWindowTargetedTypeActions(payload):
            .window(payload.expectedWindowIdentity)
        case let .exactWindowTargetedHotkey(payload):
            .window(payload.expectedWindowIdentity)
        case let .targetedTypeActions(payload):
            payload.expectedProcessIdentity.map(PeekabooBridgeOperationTargetReceipt.process) ?? .global
        case let .targetedHotkey(payload):
            payload.expectedProcessIdentity.map(PeekabooBridgeOperationTargetReceipt.process) ?? .global
        case let .targetedClick(payload):
            if let identity = payload.expectedWindowIdentity {
                .window(identity)
            } else {
                payload.expectedProcessIdentity.map(PeekabooBridgeOperationTargetReceipt.process) ?? .global
            }
        case let .moveWindow(payload):
            payload.expectedIdentity.map(PeekabooBridgeOperationTargetReceipt.window) ?? .global
        case let .resizeWindow(payload):
            payload.expectedIdentity.map(PeekabooBridgeOperationTargetReceipt.window) ?? .global
        case let .setWindowBounds(payload):
            payload.expectedIdentity.map(PeekabooBridgeOperationTargetReceipt.window) ?? .global
        case let .closeWindow(payload),
             let .backgroundCloseWindow(payload),
             let .minimizeWindow(payload),
             let .restoreWindow(payload),
             let .maximizeWindow(payload):
            payload.expectedIdentity.map(PeekabooBridgeOperationTargetReceipt.window) ?? .global
        case let .quitApplication(payload):
            payload.expectedIdentity.map(PeekabooBridgeOperationTargetReceipt.process) ?? .global
        case let .exactDialogClickButton(receipt), let .exactDialogDismiss(receipt):
            .window(receipt.target.identity)
        default:
            .global
        }
    }
}

extension PeekabooBridgeResponse {
    var resolvedOperationTargetReceipt: PeekabooBridgeOperationTargetReceipt? {
        switch self {
        case let .attestedOperation(payload):
            payload.response.resolvedOperationTargetReceipt
        case let .projectedAction(payload):
            payload.response.resolvedOperationTargetReceipt
        case let .desktopObservation(result):
            Self.coalescedTargetReceipt([
                Self.exactWindowReceipt(result.target.detectionContext),
                Self.captureTargetReceipt(result.capture.metadata),
                Self.processReceipt(result.target.app),
            ])
        case let .capture(result):
            Self.captureTargetReceipt(result.metadata)
        case let .elementDetection(result):
            Self.exactWindowReceipt(result.metadata.windowContext)
        case let .window(window):
            window?.mutationIdentity.flatMap(Self.exactWindowReceipt)
        case let .application(application):
            Self.processReceipt(application)
        case let .preparedDialogAction(receipt):
            Self.exactWindowReceipt(receipt.target.identity)
        default:
            nil
        }
    }

    private static func captureTargetReceipt(
        _ metadata: CaptureMetadata) -> PeekabooBridgeOperationTargetReceipt?
    {
        let windowReceipt: PeekabooBridgeOperationTargetReceipt? = if let window = metadata.windowInfo,
                                                                      let identity = window.mutationIdentity,
                                                                      identity.windowID == window.windowID,
                                                                      identity.capturedBounds == window.bounds
        {
            self.exactWindowReceipt(identity)
        } else {
            nil
        }
        return self.coalescedTargetReceipt([
            windowReceipt,
            metadata.applicationInfo.flatMap(self.processReceipt),
        ])
    }

    private static func exactWindowReceipt(
        _ context: WindowContext?) -> PeekabooBridgeOperationTargetReceipt?
    {
        guard let context,
              let identity = context.windowMutationIdentity,
              context.applicationProcessId == identity.ownerProcessIdentifier,
              context.windowID == identity.windowID,
              context.windowBounds == identity.capturedBounds
        else { return nil }
        return self.exactWindowReceipt(identity)
    }

    private static func exactWindowReceipt(
        _ identity: WindowMutationIdentity) -> PeekabooBridgeOperationTargetReceipt?
    {
        guard identity.windowID > 0,
              UInt32(exactly: identity.windowID) != nil,
              identity.ownerProcessIdentifier > 0,
              identity.ownerProcessStartIdentity > 0,
              let bounds = identity.capturedBounds,
              bounds.width > 0,
              bounds.height > 0
        else { return nil }
        return .window(identity)
    }

    private static func processReceipt(
        _ application: ApplicationIdentity?) -> PeekabooBridgeOperationTargetReceipt?
    {
        guard let application,
              application.processIdentifier > 0,
              let generation = application.processStartIdentity,
              generation > 0
        else { return nil }
        return .process(.init(
            processIdentifier: application.processIdentifier,
            processStartIdentity: generation))
    }

    private static func processReceipt(
        _ application: ServiceApplicationInfo) -> PeekabooBridgeOperationTargetReceipt?
    {
        guard application.processIdentifier > 0,
              let generation = application.processStartIdentity,
              generation > 0
        else { return nil }
        return .process(.init(
            processIdentifier: application.processIdentifier,
            processStartIdentity: generation))
    }

    private static func coalescedTargetReceipt(
        _ candidates: [PeekabooBridgeOperationTargetReceipt?]) -> PeekabooBridgeOperationTargetReceipt?
    {
        var resolved: PeekabooBridgeOperationTargetReceipt?
        for candidate in candidates.compactMap(\.self) {
            guard let current = resolved else {
                resolved = candidate
                continue
            }
            switch (current, candidate) {
            case (.global, _), (_, .global):
                return nil
            case let (.process(lhs), .process(rhs)):
                guard lhs == rhs else { return nil }
            case let (.window(lhs), .window(rhs)):
                guard lhs.hasSameStableReceipt(as: rhs) else { return nil }
            case let (.window(window), .process(process)), let (.process(process), .window(window)):
                guard window.processIdentity == process else { return nil }
                resolved = .window(window)
            }
        }
        return resolved
    }
}
