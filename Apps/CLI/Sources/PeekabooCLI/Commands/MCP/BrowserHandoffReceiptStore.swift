import Commander
import Darwin
import Foundation
import PeekabooBridge
import PeekabooFoundation

/// Publishes and loads the signed Bridge receipt used to hand one exact browser target to a later MCP process.
///
/// The file is deliberately treated as private capability material: callers cannot overwrite it, follow a
/// symbolic link, accept a widened ACL, or decode bytes that changed while they were being read.
final class BrowserHandoffReceiptStore: @unchecked Sendable {
    static let maximumReceiptBytes: off_t = 256 * 1024

    let fileURL: URL
    private let directoryBinding: BrowserHandoffReceiptDirectoryBinding

    convenience init(fileURL: URL) throws {
        try self.init(resolvingAbsolutePath: fileURL.path)
    }

    init(resolvingAbsolutePath path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.utf8.contains(0),
              path.hasPrefix("/"),
              !path.hasSuffix("/"),
              components.count >= 2,
              components.first?.isEmpty == true,
              components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw BrowserHandoffReceiptStoreError.unsafePath(
                "path must be absolute, nonempty, and already in standardized component form"
            )
        }
        let resolved = URL(fileURLWithPath: path, isDirectory: false)
        self.fileURL = resolved
        self.directoryBinding = BrowserHandoffReceiptDirectoryBinding(
            directoryPath: resolved.deletingLastPathComponent().path
        )
    }

    /// Proves before runtime construction that the private parent exists and the destination is unused.
    func validateCanSave() throws {
        try self.directoryBinding.withVerifiedDescriptor { directory, revalidate in
            try self.requireDestinationAbsent(in: directory)
            try revalidate()
        }
    }

    func save(
        _ canonicalReceipt: Data,
        beforePublication: () throws -> Void = {},
        afterPublication: () throws -> Void = {}
    ) throws {
        _ = try Self.validateCanonicalReceipt(canonicalReceipt)
        try self.directoryBinding.withVerifiedDescriptor { directory, revalidate in
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
            var publishedIdentity: BrowserHandoffReceiptFileIdentity?
            var publicationCommitted = false
            defer {
                Darwin.close(descriptor)
                if temporaryStillExists {
                    _ = temporaryName.withCString { unlinkat(directory, $0, 0) }
                }
                if !publicationCommitted, let publishedIdentity {
                    Self.unlinkNamedFile(
                        destinationName,
                        ifIdentityMatches: publishedIdentity,
                        in: directory
                    )
                    _ = fsync(directory)
                }
            }

            guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
                throw BrowserHandoffReceiptStoreError.writeFailed(
                    "temporary file permissions could not be restricted"
                )
            }
            _ = try Self.validatedFileMetadata(descriptor, expectedSize: 0)
            try Self.writeExactly(canonicalReceipt, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw BrowserHandoffReceiptStoreError.writeFailed("temporary file could not be synchronized")
            }
            let writtenInfo = try Self.validatedFileMetadata(
                descriptor,
                expectedSize: off_t(canonicalReceipt.count)
            )
            try beforePublication()
            try Self.requireNamedFile(
                temporaryName,
                matches: BrowserHandoffReceiptFileIdentity(writtenInfo),
                in: directory
            )

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
            publishedIdentity = BrowserHandoffReceiptFileIdentity(writtenInfo)
            try afterPublication()
            _ = try Self.validatedFileMetadata(
                descriptor,
                expectedSize: off_t(canonicalReceipt.count)
            )
            try revalidate()
            try Self.requireNamedFile(
                destinationName,
                matches: BrowserHandoffReceiptFileIdentity(writtenInfo),
                in: directory
            )
            _ = fsync(directory)
            publicationCommitted = true
        }
    }

    func load(afterValidation: () throws -> Void = {}) throws -> Data {
        try self.directoryBinding.withVerifiedDescriptor { directory, revalidate in
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
            var pathAfter = stat()
            let pathStillNamesOpenedFile = self.fileURL.lastPathComponent.withCString { name in
                fstatat(directory, name, &pathAfter, AT_SYMLINK_NOFOLLOW) == 0 && Self.sameFile(before, pathAfter)
            }
            let after = try Self.validatedFileMetadata(descriptor, expectedSize: before.st_size)
            guard Self.sameFile(before, after),
                  pathStillNamesOpenedFile,
                  Int64(data.count) == before.st_size
            else {
                throw BrowserHandoffReceiptStoreError.unsafePath("file changed while it was being read")
            }
            try revalidate()
            _ = try Self.validateCanonicalReceipt(data)
            return data
        }
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

    private func requireDestinationAbsent(in directory: Int32) throws {
        while true {
            var info = stat()
            let result = self.fileURL.lastPathComponent.withCString { name in
                fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW)
            }
            if result == 0 {
                throw BrowserHandoffReceiptStoreError.alreadyExists
            }
            let failure = errno
            if failure == EINTR {
                continue
            }
            guard failure == ENOENT else {
                throw BrowserHandoffReceiptStoreError.unsafePath("destination cannot be inspected securely")
            }
            return
        }
    }

    fileprivate static func validatedFileMetadata(_ descriptor: Int32, expectedSize: off_t? = nil) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw BrowserHandoffReceiptStoreError.inspectionFailed(.receipt, .fileStatus)
        }
        guard info.st_mode & S_IFMT == S_IFREG,
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
        try self.requireNoExtendedACL(descriptor, subject: .receipt)
        try self.requireNoExtendedAttributes(descriptor, subject: .receipt)
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw BrowserHandoffReceiptStoreError.inspectionFailed(.receipt, .fileStatus)
        }
        guard self.sameFile(info, after) else {
            throw BrowserHandoffReceiptStoreError.unsafePath("file metadata changed during validation")
        }
        return after
    }

    static func requireNoExtendedACL(_ descriptor: Int32, subject: BrowserHandoffPathSubject) throws {
        errno = 0
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT {
                return
            }
            throw BrowserHandoffReceiptStoreError.inspectionFailed(subject, .extendedACL)
        }
        acl_free(UnsafeMutableRawPointer(acl))
        throw BrowserHandoffReceiptStoreError.extendedACL(subject)
    }

    static func requireNoExtendedAttributes(_ descriptor: Int32, subject: BrowserHandoffPathSubject) throws {
        while true {
            errno = 0
            let count = flistxattr(descriptor, nil, 0, XATTR_SHOWCOMPRESSION)
            if count == 0 {
                return
            }
            if count == -1, errno == EINTR {
                continue
            }
            if count > 0 {
                throw BrowserHandoffReceiptStoreError.extendedAttributes(subject)
            }
            throw BrowserHandoffReceiptStoreError.inspectionFailed(subject, .extendedAttributes)
        }
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

    private static func requireNamedFile(
        _ name: String,
        matches identity: BrowserHandoffReceiptFileIdentity,
        in directory: Int32
    ) throws {
        var info = stat()
        let matches = name.withCString {
            fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
                BrowserHandoffReceiptFileIdentity(info) == identity
        }
        guard matches else {
            throw BrowserHandoffReceiptStoreError.unsafePath("published file identity changed")
        }
    }

    private static func unlinkNamedFile(
        _ name: String,
        ifIdentityMatches identity: BrowserHandoffReceiptFileIdentity,
        in directory: Int32
    ) {
        var info = stat()
        let matches = name.withCString {
            fstatat(directory, $0, &info, AT_SYMLINK_NOFOLLOW) == 0 &&
                BrowserHandoffReceiptFileIdentity(info) == identity
        }
        guard matches else { return }
        _ = name.withCString { unlinkat(directory, $0, 0) }
    }
}

private struct BrowserHandoffReceiptFileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        self.device = info.st_dev
        self.inode = info.st_ino
    }
}

private final class BrowserHandoffReceiptDirectoryBinding: @unchecked Sendable {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct OpenedPath {
        let descriptor: Int32
        let identities: [Identity]
    }

    private let directoryPath: String
    private let lock = NSLock()
    private var descriptor: Int32?
    private var identities: [Identity]?

    init(directoryPath: String) {
        self.directoryPath = directoryPath
    }

    deinit {
        if let descriptor {
            Darwin.close(descriptor)
        }
    }

    func withVerifiedDescriptor<T>(
        _ operation: (Int32, () throws -> Void) throws -> T
    ) throws -> T {
        self.lock.lock()
        defer { self.lock.unlock() }
        let descriptor = try self.boundDescriptorLocked()
        try self.revalidateLocked(descriptor: descriptor)
        return try operation(descriptor) {
            try self.revalidateLocked(descriptor: descriptor)
        }
    }

    private func boundDescriptorLocked() throws -> Int32 {
        if let descriptor {
            try self.validatePrivateDirectory(descriptor)
            return descriptor
        }
        let opened = try Self.openDirectoryPath(self.directoryPath)
        do {
            try self.validatePrivateDirectory(opened.descriptor)
        } catch {
            Darwin.close(opened.descriptor)
            throw error
        }
        self.descriptor = opened.descriptor
        self.identities = opened.identities
        return opened.descriptor
    }

    private func revalidateLocked(descriptor: Int32) throws {
        try self.validatePrivateDirectory(descriptor)
        guard let identities else {
            throw BrowserHandoffReceiptStoreError.unsafePath("parent directory identity is unavailable")
        }
        let current = try Self.openDirectoryPath(self.directoryPath)
        defer { Darwin.close(current.descriptor) }
        try self.validatePrivateDirectory(current.descriptor)
        guard current.identities == identities else {
            throw BrowserHandoffReceiptStoreError.unsafePath(
                "parent directory or one of its ancestors changed after validation"
            )
        }
    }

    private func validatePrivateDirectory(_ descriptor: Int32) throws {
        var before = stat()
        guard fstat(descriptor, &before) == 0 else {
            throw BrowserHandoffReceiptStoreError.inspectionFailed(.parent, .fileStatus)
        }
        guard before.st_mode & S_IFMT == S_IFDIR,
              before.st_uid == geteuid(),
              before.st_mode & 0o777 == 0o700,
              before.st_nlink >= 1
        else {
            throw BrowserHandoffReceiptStoreError.unsafePath(
                "parent directory must be owned by the current user with mode 0700"
            )
        }
        try BrowserHandoffReceiptStore.requireNoExtendedACL(descriptor, subject: .parent)
        try BrowserHandoffReceiptStore.requireNoExtendedAttributes(descriptor, subject: .parent)
        var after = stat()
        guard fstat(descriptor, &after) == 0 else {
            throw BrowserHandoffReceiptStoreError.inspectionFailed(.parent, .fileStatus)
        }
        guard Self.sameDirectoryMetadata(before, after) else {
            throw BrowserHandoffReceiptStoreError.unsafePath(
                "parent directory metadata changed during validation"
            )
        }
    }

    private static func openDirectoryPath(_ path: String) throws -> OpenedPath {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw BrowserHandoffReceiptStoreError.unsafePath("parent directory path must be absolute")
        }
        let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var descriptor = Darwin.open("/", flags)
        guard descriptor >= 0 else {
            throw BrowserHandoffReceiptStoreError.unsafePath("filesystem root cannot be opened securely")
        }
        var identities: [Identity] = []
        guard let rootIdentity = self.directoryIdentity(descriptor) else {
            Darwin.close(descriptor)
            throw BrowserHandoffReceiptStoreError.unsafePath("filesystem root identity is unavailable")
        }
        identities.append(rootIdentity)

        for substring in path.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(substring)
            guard component != ".", component != "..", !component.utf8.contains(0) else {
                Darwin.close(descriptor)
                throw BrowserHandoffReceiptStoreError.unsafePath("parent path contains an unsafe component")
            }
            let next = component.withCString { openat(descriptor, $0, flags) }
            guard next >= 0 else {
                Darwin.close(descriptor)
                throw BrowserHandoffReceiptStoreError.unsafePath(
                    "parent path components must be existing non-symbolic-link directories"
                )
            }
            guard let identity = self.directoryIdentity(next) else {
                Darwin.close(next)
                Darwin.close(descriptor)
                throw BrowserHandoffReceiptStoreError.unsafePath(
                    "parent path component identity is unavailable"
                )
            }
            Darwin.close(descriptor)
            descriptor = next
            identities.append(identity)
        }
        return OpenedPath(descriptor: descriptor, identities: identities)
    }

    private static func directoryIdentity(_ descriptor: Int32) -> Identity? {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_nlink >= 1
        else { return nil }
        return Identity(device: info.st_dev, inode: info.st_ino)
    }

    private static func sameDirectoryMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_uid == rhs.st_uid &&
            lhs.st_mode == rhs.st_mode &&
            lhs.st_nlink == rhs.st_nlink &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

final class BrowserHandoffReceiptStoreCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cachedStore: BrowserHandoffReceiptStore?

    func store(resolvingAbsolutePath path: String) throws -> BrowserHandoffReceiptStore {
        let candidate = try BrowserHandoffReceiptStore(resolvingAbsolutePath: path)
        self.lock.lock()
        defer { self.lock.unlock() }
        if let cachedStore = self.cachedStore {
            guard cachedStore.fileURL == candidate.fileURL else {
                throw BrowserHandoffReceiptStoreError.unsafePath(
                    "handoff destination changed after command validation"
                )
            }
            return cachedStore
        }
        self.cachedStore = candidate
        return candidate
    }
}

enum BrowserHandoffPathSubject: String, CaseIterable {
    case parent = "parent directory"
    case receipt = "receipt file"
}

enum BrowserHandoffPathInspection: String, CaseIterable {
    case fileStatus = "file status"
    case extendedACL = "extended access controls"
    case extendedAttributes = "extended attributes"
}

enum BrowserHandoffReceiptStoreError: LocalizedError, ResultEnvelopeError, Equatable {
    case alreadyExists
    case unsafePath(String)
    case extendedACL(BrowserHandoffPathSubject)
    case extendedAttributes(BrowserHandoffPathSubject)
    case inspectionFailed(BrowserHandoffPathSubject, BrowserHandoffPathInspection)
    case invalidReceipt(String)
    case writeFailed(String)

    nonisolated var errorDescription: String? {
        switch self {
        case .alreadyExists:
            "A browser handoff receipt already exists at that path."
        case let .unsafePath(reason):
            "Browser handoff receipt path is unsafe: \(reason)."
        case let .extendedACL(subject):
            "Browser handoff \(subject.rawValue) is unsafe: extended access controls are not accepted."
        case let .extendedAttributes(subject):
            "Browser handoff \(subject.rawValue) is unsafe: extended attributes are not accepted."
        case let .inspectionFailed(subject, inspection):
            "Browser handoff \(subject.rawValue) could not be verified: \(inspection.rawValue) could not be inspected."
        case let .invalidReceipt(reason):
            "Browser handoff receipt is invalid: \(reason)."
        case let .writeFailed(reason):
            "Browser handoff receipt could not be published: \(reason)."
        }
    }

    nonisolated var envelopeCode: ErrorCode? {
        switch self {
        case .alreadyExists, .invalidReceipt: .VALIDATION_ERROR
        case .unsafePath, .extendedACL, .extendedAttributes, .inspectionFailed, .writeFailed: .FILE_IO_ERROR
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
        case .extendedACL:
            "Both the parent directory and receipt must have zero extended ACLs; " +
                "owner-only modes alone are insufficient. " +
                "Handoff remains refused without fallback."
        case .extendedAttributes:
            "Both the parent directory and receipt must have zero extended attributes, including OS provenance. " +
                "Modes 0700/0600 alone are insufficient; environments that attach metadata are not compatible. " +
                "Handoff remains refused without fallback."
        case .inspectionFailed:
            "Inspection failure does not establish whether extended ACLs or attributes are present. " +
                "Handoff remains refused without fallback because path safety could not be verified."
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
