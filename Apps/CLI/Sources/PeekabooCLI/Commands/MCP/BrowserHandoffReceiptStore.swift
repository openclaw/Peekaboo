import Commander
import Darwin
import Foundation
import PeekabooBridge
import PeekabooFoundation

/// Publishes and loads the signed Bridge receipt used to hand one exact browser target to a later MCP process.
///
/// The file is deliberately treated as private capability material: callers cannot overwrite it, follow a
/// symbolic link, accept a widened ACL, or decode bytes that changed while they were being read.
struct BrowserHandoffReceiptStore: Sendable {
    static let maximumReceiptBytes: off_t = 256 * 1024

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    init(resolvingAbsolutePath path: String) throws {
        guard !path.isEmpty, !path.utf8.contains(0), path.hasPrefix("/") else {
            throw BrowserHandoffReceiptStoreError.unsafePath("path must be absolute and nonempty")
        }
        let resolved = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
        guard resolved.path == path,
              !resolved.lastPathComponent.isEmpty,
              resolved.lastPathComponent != ".",
              resolved.lastPathComponent != ".."
        else {
            throw BrowserHandoffReceiptStoreError.unsafePath("path must already be in standardized absolute form")
        }
        self.fileURL = resolved
    }

    /// Proves before runtime construction that the private parent exists and the destination is unused.
    func validateCanSave() throws {
        let directory = try self.openPrivateDirectory()
        defer { Darwin.close(directory) }
        try self.requireDestinationAbsent(in: directory)
    }

    func save(_ canonicalReceipt: Data) throws {
        _ = try Self.validateCanonicalReceipt(canonicalReceipt)
        let directory = try self.openPrivateDirectory()
        defer { Darwin.close(directory) }
        try self.requireDestinationAbsent(in: directory)

        let destinationName = self.fileURL.lastPathComponent
        let temporaryName = ".pbh-\(UUID().uuidString.lowercased()).tmp"
        let descriptor = temporaryName.withCString { name in
            openat(
                directory,
                name,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                S_IRUSR | S_IWUSR
            )
        }
        guard descriptor >= 0 else {
            throw BrowserHandoffReceiptStoreError.writeFailed("temporary file could not be created")
        }
        var temporaryStillExists = true
        defer {
            Darwin.close(descriptor)
            if temporaryStillExists {
                _ = temporaryName.withCString { unlinkat(directory, $0, 0) }
            }
        }

        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw BrowserHandoffReceiptStoreError.writeFailed("temporary file permissions could not be restricted")
        }
        _ = try Self.validatedFileMetadata(descriptor, expectedSize: 0)
        try Self.writeExactly(canonicalReceipt, to: descriptor)
        guard fsync(descriptor) == 0 else {
            throw BrowserHandoffReceiptStoreError.writeFailed("temporary file could not be synchronized")
        }
        _ = try Self.validatedFileMetadata(descriptor, expectedSize: off_t(canonicalReceipt.count))

        let renameResult = temporaryName.withCString { source in
            destinationName.withCString { destination in
                renameatx_np(directory, source, directory, destination, UInt32(RENAME_EXCL))
            }
        }
        guard renameResult == 0 else {
            if errno == EEXIST {
                throw BrowserHandoffReceiptStoreError.alreadyExists
            }
            throw BrowserHandoffReceiptStoreError.writeFailed("file could not be published atomically")
        }
        temporaryStillExists = false
        _ = fsync(directory)
    }

    func load(afterValidation: () throws -> Void = {}) throws -> Data {
        let directory = try self.openPrivateDirectory()
        defer { Darwin.close(directory) }
        let descriptor = self.fileURL.lastPathComponent.withCString { name in
            openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            let reason = switch errno {
            case ENOENT: "file does not exist"
            case ELOOP: "symbolic links are not accepted"
            default: "file cannot be opened securely"
            }
            throw BrowserHandoffReceiptStoreError.unsafePath(reason)
        }
        defer { Darwin.close(descriptor) }

        let before = try Self.validatedFileMetadata(descriptor)
        try afterValidation()
        let data = try Self.readExactly(descriptor, expectedSize: Int(before.st_size))
        var after = stat()
        var pathAfter = stat()
        let pathStillNamesOpenedFile = self.fileURL.lastPathComponent.withCString { name in
            fstatat(directory, name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0 && Self.sameFile(before, pathAfter)
        }
        guard fstat(descriptor, &after) == 0,
              Self.sameFile(before, after),
              pathStillNamesOpenedFile,
              Int64(data.count) == before.st_size
        else {
            throw BrowserHandoffReceiptStoreError.unsafePath("file changed while it was being read")
        }
        _ = try Self.validateCanonicalReceipt(data)
        return data
    }

    @discardableResult
    static func validateCanonicalReceipt(_ data: Data) throws -> PeekabooBridgeOperationReceiptBundle {
        guard !data.isEmpty, data.count <= Int(self.maximumReceiptBytes) else {
            throw BrowserHandoffReceiptStoreError.invalidReceipt(
                "receipt must be nonempty and at most \(self.maximumReceiptBytes) bytes"
            )
        }
        let bundle: PeekabooBridgeOperationReceiptBundle
        do {
            bundle = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeOperationReceiptBundle.self,
                from: data
            )
            try bundle.validate()
        } catch {
            throw BrowserHandoffReceiptStoreError.invalidReceipt("receipt bundle is not internally valid")
        }

        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let canonical = try? encoder.encode(bundle), canonical == data else {
            throw BrowserHandoffReceiptStoreError.invalidReceipt("receipt bundle bytes are not canonical")
        }
        let request: PeekabooBridgeRequest
        let response: PeekabooBridgeResponse
        do {
            request = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeRequest.self,
                from: bundle.canonicalRequest
            )
            response = try JSONDecoder.peekabooBridgeDecoder().decode(
                PeekabooBridgeResponse.self,
                from: bundle.canonicalResponse
            )
        } catch {
            throw BrowserHandoffReceiptStoreError.invalidReceipt("receipt request or response is not decodable")
        }
        let unwrappedRequest: PeekabooBridgeRequest = if case let .projectedAction(projected) = request {
            projected.request
        } else {
            request
        }
        let unwrappedResponse: PeekabooBridgeResponse = if case let .projectedAction(projected) = response {
            projected.response
        } else {
            response
        }
        guard case let .browserConnect(connectRequest) = unwrappedRequest,
              connectRequest.requestsHandoff,
              case let .browserStatus(status) = unwrappedResponse,
              status.isConnected,
              status.connectionReceipt?.isCanonicalTarget == true
        else {
            throw BrowserHandoffReceiptStoreError.invalidReceipt(
                "receipt must attest a successful handoff-requesting browser connect"
            )
        }
        return bundle
    }

    private func openPrivateDirectory() throws -> Int32 {
        let directoryURL = self.fileURL.deletingLastPathComponent().standardizedFileURL
        let descriptor = directoryURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw BrowserHandoffReceiptStoreError.unsafePath("private parent directory cannot be opened securely")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o700
        else {
            Darwin.close(descriptor)
            throw BrowserHandoffReceiptStoreError.unsafePath(
                "parent directory must be owned by the current user with mode 0700"
            )
        }
        do {
            try Self.requireNoExtendedACL(descriptor)
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    private func requireDestinationAbsent(in directory: Int32) throws {
        let descriptor = self.fileURL.lastPathComponent.withCString { name in
            openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        if descriptor < 0 {
            guard errno == ENOENT else {
                throw BrowserHandoffReceiptStoreError.unsafePath(
                    errno == ELOOP ? "symbolic links are not accepted" : "destination cannot be inspected securely"
                )
            }
            return
        }
        defer { Darwin.close(descriptor) }
        _ = try Self.validatedFileMetadata(descriptor)
        throw BrowserHandoffReceiptStoreError.alreadyExists
    }

    private static func validatedFileMetadata(_ descriptor: Int32, expectedSize: off_t? = nil) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600,
              info.st_nlink == 1,
              info.st_size >= 0,
              info.st_size <= self.maximumReceiptBytes,
              expectedSize.map({ info.st_size == $0 }) ?? (info.st_size > 0)
        else {
            throw BrowserHandoffReceiptStoreError.unsafePath(
                "file must be one owner-only regular file with mode 0600 and a bounded size"
            )
        }
        try self.requireNoExtendedACL(descriptor)
        return info
    }

    private static func requireNoExtendedACL(_ descriptor: Int32) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return
            }
            throw BrowserHandoffReceiptStoreError.unsafePath("access controls could not be inspected")
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw BrowserHandoffReceiptStoreError.unsafePath("extended access-control entries are not accepted")
    }

    private static func readExactly(_ descriptor: Int32, expectedSize: Int) throws -> Data {
        var data = Data()
        data.reserveCapacity(expectedSize)
        var buffer = [UInt8](repeating: 0, count: min(expectedSize, 64 * 1024))
        while data.count < expectedSize {
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, min(bytes.count, expectedSize - data.count))
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw BrowserHandoffReceiptStoreError.unsafePath("file changed while it was being read")
            }
        }
        var trailingByte: UInt8 = 0
        while true {
            let count = withUnsafeMutablePointer(to: &trailingByte) { Darwin.read(descriptor, $0, 1) }
            if count == 0 {
                return data
            }
            if count == -1, errno == EINTR {
                continue
            }
            throw BrowserHandoffReceiptStoreError.unsafePath("file changed while it was being read")
        }
    }

    private static func writeExactly(_ data: Data, to descriptor: Int32) throws {
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
                    throw BrowserHandoffReceiptStoreError.writeFailed("temporary file could not be written")
                }
            }
        }
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_uid == rhs.st_uid &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

enum BrowserHandoffReceiptStoreError: LocalizedError, ResultEnvelopeError, Equatable {
    case alreadyExists
    case unsafePath(String)
    case invalidReceipt(String)
    case writeFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .alreadyExists:
            "A browser handoff receipt already exists at that path."
        case let .unsafePath(reason):
            "Browser handoff receipt path is unsafe: \(reason)."
        case let .invalidReceipt(reason):
            "Browser handoff receipt is invalid: \(reason)."
        case let .writeFailed(reason):
            "Browser handoff receipt could not be published: \(reason)."
        }
    }

    nonisolated var envelopeCode: ErrorCode? {
        switch self {
        case .alreadyExists, .invalidReceipt: .VALIDATION_ERROR
        case .unsafePath, .writeFailed: .FILE_IO_ERROR
        }
    }

    nonisolated var envelopeEffect: ActionEffect? {
        nil
    }

    nonisolated var envelopeRetrySafe: Bool? {
        true
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        false
    }

    nonisolated var envelopeHint: String? {
        switch self {
        case .alreadyExists:
            "Use a new path; Peekaboo never overwrites capability material."
        case .unsafePath:
            "Use a standardized absolute path in an existing owner-only directory with mode 0700."
        case .invalidReceipt:
            "Create a fresh handoff with an authenticated current Bridge host."
        case .writeFailed:
            "Check the private directory and use a new destination before connecting again."
        }
    }
}

enum BrowserHandoffCLIInput {
    static func configureRuntimeOptions(
        _ options: inout CommandRuntimeOptions,
        commandType: (any ParsableCommand.Type)?,
        values: CommanderBindableValues,
        environment: [String: String]
    ) throws {
        guard commandType == MCPCommand.Serve.self else { return }
        options.browserHandoffReceiptBundleData = try self.load(values: values, environment: environment)
        guard options.browserHandoffReceiptBundleData != nil else { return }
        options.requiresBrowserHandoffBridge = true
        options.preferRemote = true
        options.remoteIsolationRequested = false
        options.autoStartDaemon = false
    }

    static func load(
        values: CommanderBindableValues,
        environment: [String: String]
    ) throws -> Data? {
        let handoffValues = values.optionValues("browserHandoff")
        guard !handoffValues.isEmpty else { return nil }
        guard handoffValues.count == 1 else {
            throw BrowserHandoffCLIInputError.duplicateOption("--browser-handoff")
        }
        let socketValues = values.optionValues("bridge-socket")
        guard socketValues.count == 1 else {
            throw BrowserHandoffCLIInputError.exactBridgeSocketRequired
        }
        guard !values.flag("no-remote"), environment["PEEKABOO_NO_REMOTE"] == nil else {
            throw BrowserHandoffCLIInputError.localExecutionRefused
        }

        let socketPath = socketValues[0]
        guard socketPath.hasPrefix("/"),
              URL(fileURLWithPath: socketPath).standardizedFileURL.path == socketPath
        else {
            throw BrowserHandoffCLIInputError.exactBridgeSocketRequired
        }
        if let environmentSocket = environment["PEEKABOO_BRIDGE_SOCKET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !environmentSocket.isEmpty,
            environmentSocket != socketPath {
            throw BrowserHandoffCLIInputError.conflictingBridgeSocket
        }
        do {
            return try BrowserHandoffReceiptStore(
                resolvingAbsolutePath: handoffValues[0]
            ).load()
        } catch {
            throw BrowserHandoffCLIInputError.invalidReceipt(error.localizedDescription)
        }
    }
}

enum BrowserHandoffCLIInputError: LocalizedError, ResultEnvelopeError, Equatable {
    case duplicateOption(String)
    case exactBridgeSocketRequired
    case conflictingBridgeSocket
    case localExecutionRefused
    case invalidReceipt(String)

    nonisolated var errorDescription: String? {
        switch self {
        case let .duplicateOption(option):
            "\(option) may be specified only once."
        case .exactBridgeSocketRequired:
            "--browser-handoff requires exactly one standardized absolute --bridge-socket."
        case .conflictingBridgeSocket:
            "--bridge-socket conflicts with PEEKABOO_BRIDGE_SOCKET."
        case .localExecutionRefused:
            "--browser-handoff does not support --no-remote or PEEKABOO_NO_REMOTE."
        case let .invalidReceipt(cause):
            "Browser handoff receipt could not be loaded before runtime creation: \(cause)"
        }
    }

    nonisolated var envelopeCode: ErrorCode? {
        .VALIDATION_ERROR
    }

    nonisolated var envelopeEffect: ActionEffect? {
        nil
    }

    nonisolated var envelopeRetrySafe: Bool? {
        true
    }

    nonisolated var envelopeMutationDispatched: Bool? {
        false
    }

    nonisolated var envelopeHint: String? {
        "Use the exact current Bridge socket and untouched receipt; do not fall back to an ambient browser target."
    }
}
