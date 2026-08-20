import Darwin
import Foundation
import Security

enum PeekabooBridgeCertificationProducerTransport {
    struct SocketIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    struct ExecutableIdentity: Equatable {
        let path: String
        let sha256: String
        let sourceCommit: String
        let signingIdentifier: String
        let teamIdentifier: String
    }

    static func perform(
        request: PeekabooBridgeCertificationProducerAttestationRequest,
        listenerAttestation: PeekabooBridgeListenerAttestation) throws
        -> PeekabooBridgeCertificationProducerAttestationResponse
    {
        try request.validate()
        try listenerAttestation.validateSignature()
        let socketIdentity = try self.requireOwnerPrivateSocket(request.producerSocketPath)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw self.transportFailure("create producer socket") }
        defer { close(descriptor) }

        do {
            try PeekabooBridgeSocketIO.configureConnectedSocket(descriptor)
            try self.disableSIGPIPE(descriptor)
            let deadline = Date().addingTimeInterval(Double(request.timeoutMilliseconds) / 1000)
            var address = try self.socketAddress(request.producerSocketPath)
            let addressLength = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, addressLength)
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS || errno == EAGAIN || errno == EALREADY else {
                    throw self.transportFailure("connect producer socket")
                }
                try PeekabooBridgeSocketIO.finishConnect(fd: descriptor, deadline: deadline)
            }
            guard try self.requireOwnerPrivateSocket(request.producerSocketPath) == socketIdentity else {
                throw self.invalidEvidence("Certification producer socket changed during connection")
            }

            let liveIdentity = try PeekabooBridgeSocketIO.livePeerIdentity(fd: descriptor)
            let executable = try self.authenticateProducer(
                liveIdentity,
                expected: request.expectedProducer,
                kind: request.kind)
            let producer = PeekabooBridgeCertificationProducerAuthorization(
                processIdentifier: liveIdentity.processIdentifier,
                processIdentifierVersion: liveIdentity.processIdentifierVersion,
                processStartIdentity: liveIdentity.processStartIdentity,
                codeSignatureHash: liveIdentity.codeSignatureHash ?? "",
                signingIdentifier: executable.signingIdentifier,
                teamIdentifier: executable.teamIdentifier,
                sourceCommit: executable.sourceCommit,
                executableSHA256: executable.sha256)
            let challenge = try PeekabooBridgeCertificationProducerChallenge(
                kind: request.kind,
                executionNonce: request.executionNonce,
                monitorInstanceID: request.monitorInstanceID,
                challenge: self.randomChallenge(),
                listenerInstanceID: listenerAttestation.listenerInstanceID,
                listenerPublicKeySHA256: PeekabooBridgeOperationReceiptCoding.sha256(
                    listenerAttestation.publicKey))
            let requestData = try self.record(challenge)
            try PeekabooBridgeSocketIO.writeAll(fd: descriptor, data: requestData, deadline: deadline)
            guard shutdown(descriptor, SHUT_WR) == 0 else {
                throw self.transportFailure("finish producer challenge")
            }
            let responseData = try PeekabooBridgeSocketIO.readAll(
                fd: descriptor,
                maxBytes: request.maximumResponseBytes + 1,
                deadline: deadline)
            let wireResponse = try self.decodeOneRecord(
                responseData,
                maximumBytes: request.maximumResponseBytes)

            try self.validateWireEnvelope(
                wireResponse,
                request: request,
                challenge: challenge,
                listenerAttestation: listenerAttestation)
            guard try self.requireOwnerPrivateSocket(request.producerSocketPath) == socketIdentity else {
                throw self.invalidEvidence("Certification producer socket changed while evidence was read")
            }
            try self.revalidateProducer(
                liveIdentity,
                expected: request.expectedProducer,
                executable: executable,
                kind: request.kind)

            let context = PeekabooBridgeCertificationPayloadValidationContext(
                request: request,
                producer: producer,
                listenerAttestation: listenerAttestation)
            try wireResponse.payload.validate(context: context)
            return PeekabooBridgeCertificationProducerAttestationResponse(
                kind: request.kind,
                executionNonce: request.executionNonce,
                monitorInstanceID: request.monitorInstanceID,
                challenge: challenge.challenge,
                listenerInstanceID: listenerAttestation.listenerInstanceID,
                listenerPublicKeySHA256: challenge.listenerPublicKeySHA256,
                producer: producer,
                payload: wireResponse.payload,
                observedAtUnixMilliseconds: PeekabooBridgeOperationReceiptCoding.unixMilliseconds())
        } catch let error as PeekabooBridgeErrorEnvelope {
            throw error
        } catch {
            throw PeekabooBridgeErrorEnvelope(
                code: .internalError,
                message: "Certification producer attestation failed closed",
                details: String(describing: error))
        }
    }

    static func authenticateProducer(
        _ liveIdentity: PeekabooBridgeLivePeerIdentity,
        expected: PeekabooBridgeCertificationProducerExpectation,
        kind: PeekabooBridgeCertificationProducerAttestationKind,
        signingInformationProvider: (PeekabooBridgePeerAuditIdentity) -> [String: Any]? = {
            PeekabooBridgeCodeSignatureIdentity.signingInformation(auditIdentity: $0)
        },
        processPathProvider: (pid_t) -> String? = {
            PeekabooBridgeAgentExecutionExecutable.canonicalProcessPath($0)
        },
        canonicalPathProvider: (String) -> String? = {
            PeekabooBridgeAgentExecutionExecutable.canonicalPath($0)
        },
        executableSHA256Provider: (String) throws -> String = {
            try PeekabooBridgeAgentExecutionExecutable.stableExecutableSHA256($0)
        },
        staticCodeSignatureHashProvider: (String) -> String? = {
            PeekabooBridgeCodeSignatureIdentity.codeSignatureHash(executablePath: $0)
        }) throws -> ExecutableIdentity
    {
        guard liveIdentity.effectiveUserIdentifier == geteuid(),
              liveIdentity.processIdentifier == expected.processIdentifier,
              liveIdentity.processStartIdentity == expected.processStartIdentity,
              liveIdentity.codeSignatureHash == expected.codeSignatureHash,
              let auditIdentity = liveIdentity.auditIdentity,
              let information = signingInformationProvider(auditIdentity),
              let signingIdentifier = information[kSecCodeInfoIdentifier as String] as? String,
              signingIdentifier == kind.expectedSigningIdentifier,
              let teamIdentifier = information[kSecCodeInfoTeamIdentifier as String] as? String,
              teamIdentifier == PeekabooBridgeCertificationValidation.foundationTeamIdentifier,
              let plist = information[kSecCodeInfoPList as String] as? [String: Any],
              let sourceCommit = plist["PeekabooSourceCommit"] as? String,
              PeekabooBridgeCertificationValidation.isLowerHex(sourceCommit, count: 40),
              let executableURL = url(information[kSecCodeInfoMainExecutable as String]),
              let canonicalPath = canonicalPathProvider(executableURL.path),
              processPathProvider(liveIdentity.processIdentifier) == canonicalPath,
              let executableSHA256 = try? executableSHA256Provider(canonicalPath),
              staticCodeSignatureHashProvider(canonicalPath) == expected.codeSignatureHash
        else {
            throw self.invalidEvidence("Certification producer identity is not authorized")
        }
        return ExecutableIdentity(
            path: canonicalPath,
            sha256: executableSHA256,
            sourceCommit: sourceCommit,
            signingIdentifier: signingIdentifier,
            teamIdentifier: teamIdentifier)
    }

    private static func revalidateProducer(
        _ original: PeekabooBridgeLivePeerIdentity,
        expected: PeekabooBridgeCertificationProducerExpectation,
        executable: ExecutableIdentity,
        kind: PeekabooBridgeCertificationProducerAttestationKind) throws
    {
        let current = try self.authenticateProducer(original, expected: expected, kind: kind)
        guard current.path == executable.path,
              current.sha256 == executable.sha256,
              current.sourceCommit == executable.sourceCommit,
              current.signingIdentifier == executable.signingIdentifier,
              current.teamIdentifier == executable.teamIdentifier
        else {
            throw self.invalidEvidence("Certification producer identity changed during attestation")
        }
    }

    static func requireOwnerPrivateSocket(_ path: String) throws -> SocketIdentity {
        let pathString = NSString(string: path)
        let parent = pathString.deletingLastPathComponent
        let basename = pathString.lastPathComponent
        guard !basename.isEmpty,
              PeekabooBridgeAgentExecutionExecutable.canonicalPath(parent) == parent,
              NSString(string: parent).appendingPathComponent(basename) == path
        else {
            throw self.invalidEvidence("Certification producer socket path is not canonical")
        }
        var socketInfo = stat()
        var parentInfo = stat()
        guard lstat(path, &socketInfo) == 0,
              (socketInfo.st_mode & S_IFMT) == S_IFSOCK,
              socketInfo.st_uid == geteuid(),
              socketInfo.st_mode & 0o077 == 0,
              lstat(parent, &parentInfo) == 0,
              (parentInfo.st_mode & S_IFMT) == S_IFDIR,
              parentInfo.st_uid == geteuid(),
              parentInfo.st_mode & 0o077 == 0
        else {
            throw self.invalidEvidence("Certification producer endpoint is not owner-private")
        }
        return SocketIdentity(device: socketInfo.st_dev, inode: socketInfo.st_ino)
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8) + [0]
        var address = sockaddr_un()
        let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path),
              offset + bytes.count <= Int(UInt8.max)
        else { throw POSIXError(.ENAMETOOLONG) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(offset + bytes.count)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func disableSIGPIPE(_ descriptor: Int32) throws {
        var value: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)) == 0
        else { throw self.transportFailure("disable producer SIGPIPE") }
    }

    private static func record(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    static func decodeOneRecord(
        _ data: Data,
        maximumBytes: Int) throws -> PeekabooBridgeCertificationProducerWireResponse
    {
        guard data.count >= 2,
              data.count <= maximumBytes,
              data.last == 0x0A,
              data.dropLast().allSatisfy({ $0 != 0x0A && $0 != 0x0D })
        else {
            throw self.invalidEvidence("Certification producer returned an invalid response record")
        }
        return try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeCertificationProducerWireResponse.self,
            from: data.dropLast())
    }

    static func validateWireEnvelope(
        _ response: PeekabooBridgeCertificationProducerWireResponse,
        request: PeekabooBridgeCertificationProducerAttestationRequest,
        challenge: PeekabooBridgeCertificationProducerChallenge,
        listenerAttestation: PeekabooBridgeListenerAttestation) throws
    {
        guard response.schemaVersion == 1,
              response.kind == request.kind,
              response.kind == response.payload.kind,
              response.executionNonce == request.executionNonce,
              response.monitorInstanceID == request.monitorInstanceID,
              response.challenge == challenge.challenge,
              response.listenerInstanceID == listenerAttestation.listenerInstanceID,
              response.listenerPublicKeySHA256 == challenge.listenerPublicKeySHA256
        else {
            throw self.invalidEvidence("Certification producer response did not echo the exact challenge")
        }
    }

    private static func randomChallenge() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw self.invalidEvidence("Bridge could not create a certification challenge")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func url(_ value: Any?) -> URL? {
        (value as? URL) ?? (value as? NSURL).map { $0 as URL }
    }

    private static func invalidEvidence(_ message: String) -> PeekabooBridgeErrorEnvelope {
        PeekabooBridgeErrorEnvelope(code: .invalidRequest, message: message)
    }

    private static func transportFailure(_ operation: String) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? (operation.isEmpty ? .EPROTO : .EIO))
    }
}

extension PeekabooBridgeCertificationProducerPayload {
    func validate(context: PeekabooBridgeCertificationPayloadValidationContext) throws {
        switch self {
        case let .crashInventoryPair(payload):
            try payload.validate(context: context)
        case let .monitorSeal(payload):
            try payload.validate(context: context)
        case let .observerSemantic(payload):
            try payload.validate(context: context)
        }
    }
}
