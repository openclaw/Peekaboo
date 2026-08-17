import CryptoKit
import Darwin
import Foundation
import Security

enum CertificationAttestationResponseKind: String, Codable, Sendable {
    case monitor
    case observer
}

struct CertificationMonitorAttestationClientPlan: Codable, Equatable, Sendable {
    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let socketPath: String
    let expectedPeerPID: Int32
    let responseKind: CertificationAttestationResponseKind
    let artifactsDirectory: String
    let outputPath: String
    let releasePath: String
    let timeoutMilliseconds: Int
    let maximumResponseBytes: Int

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case socketPath = "socket_path"
        case expectedPeerPID = "expected_peer_pid"
        case responseKind = "response_kind"
        case artifactsDirectory = "artifacts_directory"
        case outputPath = "output_path"
        case releasePath = "release_path"
        case timeoutMilliseconds = "timeout_milliseconds"
        case maximumResponseBytes = "maximum_response_bytes"
    }

    var artifactsURL: URL {
        URL(fileURLWithPath: self.artifactsDirectory, isDirectory: true)
    }

    var outputURL: URL {
        URL(fileURLWithPath: self.outputPath)
    }

    var releaseURL: URL {
        URL(fileURLWithPath: self.releasePath)
    }

    static func decode(_ data: Data) throws -> Self {
        let root: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CertificationControllerError.invalidPlan("Monitor attestation plan must be one object.")
            }
            root = object
        } catch let error as CertificationControllerError {
            throw error
        } catch {
            throw CertificationControllerError.invalidPlan("Monitor attestation plan is invalid JSON: \(error)")
        }
        let keys: Set = [
            "version", "execution_nonce", "monitor_instance_id", "socket_path", "expected_peer_pid",
            "response_kind", "artifacts_directory", "output_path", "timeout_milliseconds",
            "maximum_response_bytes", "release_path",
        ]
        guard Set(root.keys) == keys else {
            throw CertificationControllerError.invalidPlan("Monitor attestation plan keys are not closed.")
        }
        let plan = try JSONDecoder().decode(Self.self, from: data)
        try plan.validate()
        return plan
    }

    func validate() throws {
        let root = self.artifactsURL.standardizedFileURL.path
        guard self.version == 1,
              Self.isLowerHex(self.executionNonce, count: 64),
              Self.isCanonicalV4UUID(self.monitorInstanceID),
              Self.isAbsolutePath(self.socketPath),
              self.socketPath.utf8.count < 104,
              self.expectedPeerPID > 0,
              Self.isAbsolutePath(self.artifactsDirectory),
              self.outputURL.standardizedFileURL.deletingLastPathComponent().path == root,
              self.releaseURL.standardizedFileURL.deletingLastPathComponent().path == root,
              self.releaseURL.standardizedFileURL != self.outputURL.standardizedFileURL,
              (100...30000).contains(self.timeoutMilliseconds),
              (1024...1024 * 1024).contains(self.maximumResponseBytes)
        else {
            throw CertificationControllerError.invalidPlan(
                "Monitor attestation run, peer, paths, or transport bounds are invalid."
            )
        }
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isCanonicalV4UUID(_ value: String) -> Bool {
        guard value == value.lowercased(), value.count == 36,
              value[value.index(value.startIndex, offsetBy: 14)] == "4",
              "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)]),
              let uuid = UUID(uuidString: value)
        else { return false }
        return uuid.uuidString.lowercased() == value
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") &&
            !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

struct CertificationAttestationRequest: Codable, Equatable, Sendable {
    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let challenge: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case challenge
    }
}

struct CertificationMonitorAttestationResponse: Codable, Equatable, Sendable {
    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let challenge: String
    let monitor: CertificationProcessReceipt
    let monitorEvidenceSHA256: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case challenge
        case monitor
        case monitorEvidenceSHA256 = "monitor_evidence_sha256"
    }
}

struct CertificationObserverAttestationResponse: Codable, Equatable, Sendable {
    let version: Int
    let executionNonce: String
    let monitorInstanceID: String
    let challenge: String
    let observer: CertificationProcessReceipt
    let witnessSHA256: String
    let observationFileSHA256: String
    let restorationFileSHA256: String
    let beforeValueSHA256: String
    let expectedValueSHA256: String
    let observedValueSHA256: String
    let restoredValueSHA256: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case monitorInstanceID = "monitor_instance_id"
        case challenge
        case observer
        case witnessSHA256 = "witness_sha256"
        case observationFileSHA256 = "observation_file_sha256"
        case restorationFileSHA256 = "restoration_file_sha256"
        case beforeValueSHA256 = "before_value_sha256"
        case expectedValueSHA256 = "expected_value_sha256"
        case observedValueSHA256 = "observed_value_sha256"
        case restoredValueSHA256 = "restored_value_sha256"
    }
}

enum CertificationLocalPeerPolicy {
    static func requirePeerPID(_ observed: pid_t, expected: pid_t) throws {
        guard observed == expected, observed > 0 else {
            throw CertificationControllerError.runtimeRefusal(
                "Unix attestation peer PID does not match the owner plan."
            )
        }
    }
}

enum CertificationAttestationChallenge {
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CertificationControllerError.runtimeRefusal("Cannot create an attestation challenge.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum CertificationUnixSocket {
    static func connect(path: String, timeoutMilliseconds: Int) throws -> Int32 {
        try self.requireSocket(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw self.transportError("create Unix socket") }
        do {
            try self.setTimeout(descriptor, milliseconds: timeoutMilliseconds)
            var address = try self.address(path: path)
            let addressLength = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, addressLength)
                }
            }
            guard result == 0 else { throw self.transportError("connect Unix socket") }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func peerPID(_ descriptor: Int32) throws -> pid_t {
        var peer = pid_t()
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &peer, &length) == 0,
              length == MemoryLayout<pid_t>.size,
              peer > 0
        else { throw self.transportError("read Unix peer PID") }
        return peer
    }

    static func writeJSON(_ value: some Encodable, descriptor: Int32) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        try self.writeAll(data, descriptor: descriptor)
    }

    static func readJSONLine(
        descriptor: Int32,
        maximumBytes: Int,
        timeoutMilliseconds: Int
    ) throws -> Data {
        var data = Data()
        var byte = UInt8.zero
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeoutMilliseconds) * 1_000_000
        while data.count < maximumBytes {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else {
                throw CertificationControllerError.runtimeRefusal(
                    "Unix attestation message exceeded its whole-message deadline."
                )
            }
            let remainingMilliseconds = max(1, Int((deadline - now) / 1_000_000))
            var descriptorEvent = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptorEvent, 1, Int32(clamping: remainingMilliseconds))
            if ready == 0 {
                throw CertificationControllerError.runtimeRefusal(
                    "Unix attestation message exceeded its whole-message deadline."
                )
            }
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                throw self.transportError("poll Unix attestation message")
            }
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 1 {
                if byte == 0x0A {
                    return data
                }
                data.append(byte)
            } else if count == 0 {
                throw CertificationControllerError.runtimeRefusal(
                    "Unix attestation message ended before its newline delimiter."
                )
            } else if errno == EINTR {
                continue
            } else {
                throw self.transportError("read Unix attestation response")
            }
        }
        throw CertificationControllerError.runtimeRefusal(
            "Unix attestation message is empty, unterminated, or too large."
        )
    }

    static func makeServer(path: String) throws -> Int32 {
        var existing = stat()
        guard lstat(path, &existing) != 0, errno == ENOENT else {
            throw CertificationControllerError.unsafePrivatePath(
                "Unix attestation socket path already exists."
            )
        }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw self.transportError("create Unix listener") }
        do {
            var address = try self.address(path: path)
            let addressLength = socklen_t(address.sun_len)
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, addressLength)
                }
            }
            guard result == 0,
                  chmod(path, S_IRUSR | S_IWUSR) == 0,
                  listen(descriptor, 8) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
            else { throw self.transportError("bind Unix listener") }
            return descriptor
        } catch {
            close(descriptor)
            unlink(path)
            throw error
        }
    }

    private static func address(path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8) + [0]
        var address = sockaddr_un()
        let offset = MemoryLayout.offset(of: \sockaddr_un.sun_path) ?? 0
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path),
              offset + pathBytes.count <= Int(UInt8.max)
        else {
            throw CertificationControllerError.invalidPlan("Unix attestation socket path is too long.")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(offset + pathBytes.count)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
        }
        return address
    }

    private static func requireSocket(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFSOCK,
              info.st_uid == geteuid()
        else {
            throw CertificationControllerError.unsafePrivatePath(
                "Attestation endpoint is not an owner-controlled Unix socket."
            )
        }
    }

    static func setTimeout(_ descriptor: Int32, milliseconds: Int) throws {
        var timeout = timeval(
            tv_sec: milliseconds / 1000,
            tv_usec: Int32((milliseconds % 1000) * 1000)
        )
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0
        else { throw self.transportError("configure Unix socket timeout") }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count == -1, errno == EINTR {
                    continue
                } else {
                    throw self.transportError("write Unix attestation request")
                }
            }
        }
    }

    private static func transportError(_ operation: String) -> CertificationControllerError {
        .runtimeRefusal("Cannot \(operation): \(String(cString: strerror(errno))).")
    }
}

final class CertificationObserverAttestationServer: @unchecked Sendable {
    private let socketPath: String
    private let executionNonce: String
    private let monitorInstanceID: String
    private let observer: CertificationProcessReceipt
    private let witnessSHA256: String
    private let observationFileSHA256: String
    private let restorationFileSHA256: String
    private let beforeValueSHA256: String
    private let expectedValueSHA256: String
    private let observedValueSHA256: String
    private let restoredValueSHA256: String
    private let lock = NSLock()
    private var descriptor: Int32
    private var activeClient: Int32 = -1

    init(
        socketPath: String,
        executionNonce: String,
        monitorInstanceID: String,
        observer: CertificationProcessReceipt,
        witnessSHA256: String,
        observationFileSHA256: String,
        restorationFileSHA256: String,
        beforeValueSHA256: String,
        expectedValueSHA256: String,
        observedValueSHA256: String,
        restoredValueSHA256: String
    ) throws {
        self.socketPath = socketPath
        self.executionNonce = executionNonce
        self.monitorInstanceID = monitorInstanceID
        self.observer = observer
        self.witnessSHA256 = witnessSHA256
        self.observationFileSHA256 = observationFileSHA256
        self.restorationFileSHA256 = restorationFileSHA256
        self.beforeValueSHA256 = beforeValueSHA256
        self.expectedValueSHA256 = expectedValueSHA256
        self.observedValueSHA256 = observedValueSHA256
        self.restoredValueSHA256 = restoredValueSHA256
        self.descriptor = try CertificationUnixSocket.makeServer(path: socketPath)
    }

    func serve() async {
        defer { self.stop() }
        while !Task.isCancelled {
            let listener = self.lock.withLock { self.descriptor }
            guard listener >= 0 else { return }
            let client = accept(listener, nil, nil)
            if client >= 0 {
                self.lock.withLock { self.activeClient = client }
                do {
                    try CertificationUnixSocket.setTimeout(client, milliseconds: 2000)
                    try self.handle(client)
                } catch {
                    // Invalid or stalled challenges are refused by closing only that connection.
                }
                self.lock.withLock {
                    if self.activeClient == client {
                        self.activeClient = -1
                    }
                }
                close(client)
            } else if errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    func stop() {
        let listener = self.lock.withLock { () -> Int32 in
            let current = self.descriptor
            self.descriptor = -1
            if self.activeClient >= 0 {
                shutdown(self.activeClient, SHUT_RDWR)
            }
            return current
        }
        if listener >= 0 {
            close(listener)
            unlink(self.socketPath)
        }
    }

    private func handle(_ client: Int32) throws {
        let data = try CertificationUnixSocket.readJSONLine(
            descriptor: client,
            maximumBytes: 64 * 1024,
            timeoutMilliseconds: 2000
        )
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == ["version", "execution_nonce", "monitor_instance_id", "challenge"]
        else {
            throw CertificationControllerError.runtimeRefusal("Observer attestation request keys are not closed.")
        }
        let request = try JSONDecoder().decode(CertificationAttestationRequest.self, from: data)
        guard request.version == 1,
              request.executionNonce == self.executionNonce,
              request.monitorInstanceID == self.monitorInstanceID,
              request.challenge.utf8.count == 64,
              request.challenge.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              })
        else {
            throw CertificationControllerError.runtimeRefusal("Observer attestation request is not run bound.")
        }
        try CertificationUnixSocket.writeJSON(
            CertificationObserverAttestationResponse(
                version: 1,
                executionNonce: self.executionNonce,
                monitorInstanceID: self.monitorInstanceID,
                challenge: request.challenge,
                observer: self.observer,
                witnessSHA256: self.witnessSHA256,
                observationFileSHA256: self.observationFileSHA256,
                restorationFileSHA256: self.restorationFileSHA256,
                beforeValueSHA256: self.beforeValueSHA256,
                expectedValueSHA256: self.expectedValueSHA256,
                observedValueSHA256: self.observedValueSHA256,
                restoredValueSHA256: self.restoredValueSHA256
            ),
            descriptor: client
        )
    }
}
