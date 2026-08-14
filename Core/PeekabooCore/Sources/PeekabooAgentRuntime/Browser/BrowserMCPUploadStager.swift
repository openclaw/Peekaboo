import Darwin
import Foundation

enum BrowserMCPUploadStagingError: LocalizedError, Equatable {
    case invalidPath(String)
    case sourceUnavailable(String)
    case sourceChanged
    case unsupportedSource(String)
    case sourceTooLarge(maximumBytes: Int64)
    case stagingFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPath(reason):
            "Browser upload path is invalid: \(reason)"
        case let .sourceUnavailable(reason):
            "Browser upload source is unavailable: \(reason)"
        case .sourceChanged:
            "Browser upload source changed while it was being opened; no file was uploaded."
        case let .unsupportedSource(reason):
            "Browser upload source is not allowed: \(reason)"
        case let .sourceTooLarge(maximumBytes):
            "Browser upload source exceeds the \(maximumBytes)-byte safety limit."
        case let .stagingFailed(reason):
            "Browser upload staging failed: \(reason)"
        }
    }
}

final class BrowserMCPUploadWorkspace: @unchecked Sendable {
    let rootPath: String

    private let cleanupLock = NSLock()
    private var cleanedUp = false
    private var retainedUploads: [BrowserMCPStagedUpload] = []
    private let cleanupOperation: @Sendable () -> Void

    init(rootPath: String, cleanupOperation: @escaping @Sendable () -> Void) {
        self.rootPath = rootPath
        self.cleanupOperation = cleanupOperation
    }

    func cleanup() {
        let retainedUploads: [BrowserMCPStagedUpload]? = self.cleanupLock.withLock {
            guard !self.cleanedUp else { return nil }
            self.cleanedUp = true
            defer { self.retainedUploads.removeAll() }
            return self.retainedUploads
        }
        guard let retainedUploads else { return }
        self.cleanupOperation()
        retainedUploads.forEach { $0.cleanup() }
    }

    func retain(_ upload: BrowserMCPStagedUpload) {
        let retained = self.cleanupLock.withLock {
            guard !self.cleanedUp else { return false }
            self.retainedUploads.append(upload)
            return true
        }
        if !retained {
            upload.cleanup()
        }
    }

    deinit {
        self.cleanup()
    }
}

final class BrowserMCPStagedUpload: @unchecked Sendable {
    let filePath: String
    let rootPath: String

    private let cleanupLock = NSLock()
    private var cleanedUp = false
    private let cleanupOperation: @Sendable () -> Void

    init(filePath: String, rootPath: String, cleanupOperation: @escaping @Sendable () -> Void) {
        self.filePath = filePath
        self.rootPath = rootPath
        self.cleanupOperation = cleanupOperation
    }

    func cleanup() {
        let shouldClean = self.cleanupLock.withLock {
            guard !self.cleanedUp else { return false }
            self.cleanedUp = true
            return true
        }
        if shouldClean {
            self.cleanupOperation()
        }
    }

    deinit {
        self.cleanup()
    }
}

struct BrowserMCPUploadStager: Sendable {
    static let maximumFileSize: Int64 = 100 * 1024 * 1024

    typealias SourceInspectionHook = @Sendable (String) throws -> Void
    typealias CopyProgressHook = @Sendable (Int64) throws -> Void

    private let temporaryDirectory: String
    private let maximumBytes: Int64
    private let expectedUserID: uid_t
    private let sourceInspectionHook: SourceInspectionHook
    private let copyProgressHook: CopyProgressHook

    static let live = BrowserMCPUploadStager()

    init(
        temporaryDirectory: String = NSTemporaryDirectory(),
        maximumBytes: Int64 = Self.maximumFileSize,
        expectedUserID: uid_t = geteuid(),
        sourceInspectionHook: @escaping SourceInspectionHook = { _ in },
        copyProgressHook: @escaping CopyProgressHook = { _ in })
    {
        self.temporaryDirectory = temporaryDirectory
        self.maximumBytes = maximumBytes
        self.expectedUserID = expectedUserID
        self.sourceInspectionHook = sourceInspectionHook
        self.copyProgressHook = copyProgressHook
    }

    func createWorkspace() async throws -> BrowserMCPUploadWorkspace {
        let worker = Task.detached {
            let rootPath = try self.makePrivateDirectory(
                parentPath: self.temporaryDirectory,
                nameTemplate: "peekaboo-browser-session.XXXXXX")
            return BrowserMCPUploadWorkspace(rootPath: rootPath) {
                Self.removeStagingRoot(rootPath)
            }
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    func stage(path: String, in workspace: BrowserMCPUploadWorkspace) async throws -> BrowserMCPStagedUpload {
        let worker = Task.detached {
            try self.stageSynchronously(path: path, workspace: workspace)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func stageSynchronously(
        path: String,
        workspace: BrowserMCPUploadWorkspace) throws -> BrowserMCPStagedUpload
    {
        try Task.checkCancellation()
        let fileName = try Self.validatePath(path)

        var inspected = Darwin.stat()
        guard lstat(path, &inspected) == 0 else {
            throw BrowserMCPUploadStagingError.sourceUnavailable(Self.errorText(errno))
        }
        guard (inspected.st_mode & S_IFMT) != S_IFLNK else {
            throw BrowserMCPUploadStagingError.unsupportedSource("symbolic links are refused")
        }
        guard (inspected.st_mode & S_IFMT) == S_IFREG else {
            throw BrowserMCPUploadStagingError.unsupportedSource("only regular files can be uploaded")
        }

        try self.sourceInspectionHook(path)
        try Task.checkCancellation()

        let sourceDescriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard sourceDescriptor >= 0 else {
            if errno == ELOOP {
                throw BrowserMCPUploadStagingError.sourceChanged
            }
            throw BrowserMCPUploadStagingError.sourceUnavailable(Self.errorText(errno))
        }
        defer { close(sourceDescriptor) }

        var opened = Darwin.stat()
        guard fstat(sourceDescriptor, &opened) == 0 else {
            throw BrowserMCPUploadStagingError.sourceUnavailable(Self.errorText(errno))
        }
        guard inspected.st_dev == opened.st_dev, inspected.st_ino == opened.st_ino else {
            throw BrowserMCPUploadStagingError.sourceChanged
        }
        guard (opened.st_mode & S_IFMT) == S_IFREG else {
            throw BrowserMCPUploadStagingError.unsupportedSource("only regular files can be uploaded")
        }
        guard opened.st_uid == self.expectedUserID else {
            throw BrowserMCPUploadStagingError.unsupportedSource("the file is not owned by the current user")
        }
        guard opened.st_size >= 0 else {
            throw BrowserMCPUploadStagingError.unsupportedSource("the file has an invalid size")
        }
        guard opened.st_size <= self.maximumBytes else {
            throw BrowserMCPUploadStagingError.sourceTooLarge(maximumBytes: self.maximumBytes)
        }

        let rootPath = try self.makePrivateDirectory(
            parentPath: workspace.rootPath,
            nameTemplate: "upload.XXXXXX")
        var stagedSuccessfully = false
        defer {
            if !stagedSuccessfully {
                Self.removeStagingRoot(rootPath)
            }
        }

        let rootDescriptor = open(rootPath, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard rootDescriptor >= 0 else {
            throw BrowserMCPUploadStagingError.stagingFailed(Self.errorText(errno))
        }
        defer { close(rootDescriptor) }

        let destinationDescriptor = openat(
            rootDescriptor,
            fileName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR))
        guard destinationDescriptor >= 0 else {
            throw BrowserMCPUploadStagingError.stagingFailed(Self.errorText(errno))
        }
        defer { close(destinationDescriptor) }

        try self.copy(
            sourceDescriptor: sourceDescriptor,
            destinationDescriptor: destinationDescriptor,
            expectedSize: opened.st_size)
        guard fchmod(destinationDescriptor, mode_t(S_IRUSR)) == 0 else {
            throw BrowserMCPUploadStagingError.stagingFailed(Self.errorText(errno))
        }
        guard fsync(destinationDescriptor) == 0 else {
            throw BrowserMCPUploadStagingError.stagingFailed(Self.errorText(errno))
        }

        let stagedPath = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
            .path
        stagedSuccessfully = true
        return BrowserMCPStagedUpload(filePath: stagedPath, rootPath: rootPath) {
            Self.removeStagingRoot(rootPath)
        }
    }

    private func makePrivateDirectory(parentPath: String, nameTemplate: String) throws -> String {
        try Task.checkCancellation()
        var directory = Array(URL(fileURLWithPath: parentPath, isDirectory: true)
            .appendingPathComponent(nameTemplate, isDirectory: true)
            .path
            .utf8CString)
        let created = directory.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!)
        }
        guard created != nil else {
            throw BrowserMCPUploadStagingError.stagingFailed(Self.errorText(errno))
        }
        let rootPath = directory.withUnsafeBufferPointer { buffer in
            String(cString: buffer.baseAddress!)
        }
        var keepDirectory = false
        defer {
            if !keepDirectory {
                Self.removeStagingRoot(rootPath)
            }
        }
        guard chmod(rootPath, mode_t(S_IRWXU)) == 0 else {
            throw BrowserMCPUploadStagingError.stagingFailed(Self.errorText(errno))
        }
        let canonicalParent = try Self.canonicalPath(parentPath)
        let canonicalRoot = try Self.canonicalPath(rootPath)
        guard URL(fileURLWithPath: canonicalRoot).deletingLastPathComponent().path == canonicalParent else {
            throw BrowserMCPUploadStagingError.stagingFailed("the private directory escaped its parent")
        }

        var rootInfo = Darwin.stat()
        guard lstat(canonicalRoot, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR,
              rootInfo.st_uid == self.expectedUserID,
              (rootInfo.st_mode & mode_t(0o777)) == mode_t(0o700)
        else {
            throw BrowserMCPUploadStagingError.stagingFailed("the private directory ownership or mode is unsafe")
        }
        try Task.checkCancellation()
        keepDirectory = true
        return canonicalRoot
    }

    private func copy(
        sourceDescriptor: Int32,
        destinationDescriptor: Int32,
        expectedSize: off_t) throws
    {
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var copied: Int64 = 0
        while true {
            try Task.checkCancellation()
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                read(sourceDescriptor, bytes.baseAddress, bytes.count)
            }
            if readCount == 0 {
                break
            }
            guard readCount > 0 else {
                if errno == EINTR {
                    continue
                }
                throw BrowserMCPUploadStagingError.stagingFailed(Self.errorText(errno))
            }

            var written = 0
            while written < readCount {
                try Task.checkCancellation()
                let writeCount = buffer.withUnsafeBytes { bytes in
                    write(
                        destinationDescriptor,
                        bytes.baseAddress?.advanced(by: written),
                        readCount - written)
                }
                guard writeCount > 0 else {
                    if writeCount < 0, errno == EINTR {
                        continue
                    }
                    throw BrowserMCPUploadStagingError.stagingFailed(Self.errorText(errno))
                }
                written += writeCount
            }

            copied += Int64(readCount)
            guard copied <= Int64(expectedSize) else {
                throw BrowserMCPUploadStagingError.sourceChanged
            }
            guard copied <= self.maximumBytes else {
                throw BrowserMCPUploadStagingError.sourceTooLarge(maximumBytes: self.maximumBytes)
            }
            try self.copyProgressHook(copied)
        }
        guard copied == Int64(expectedSize) else {
            throw BrowserMCPUploadStagingError.sourceChanged
        }
    }

    private static func validatePath(_ path: String) throws -> String {
        guard !path.isEmpty else {
            throw BrowserMCPUploadStagingError.invalidPath("the path is empty")
        }
        guard path.utf8.count < Int(PATH_MAX) else {
            throw BrowserMCPUploadStagingError.invalidPath("the path is too long")
        }
        guard path.utf8.allSatisfy({ $0 != 0 }) else {
            throw BrowserMCPUploadStagingError.invalidPath("the path contains a null byte")
        }
        guard path.hasPrefix("/") else {
            throw BrowserMCPUploadStagingError.invalidPath("an absolute path is required")
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw BrowserMCPUploadStagingError.invalidPath("relative traversal components are refused")
        }
        let fileName = URL(fileURLWithPath: path, isDirectory: false).lastPathComponent
        guard !fileName.isEmpty, fileName != ".", fileName != ".." else {
            throw BrowserMCPUploadStagingError.invalidPath("the path has no safe file name")
        }
        guard fileName.utf8.count <= Int(NAME_MAX) else {
            throw BrowserMCPUploadStagingError.invalidPath("the file name is too long")
        }
        return fileName
    }

    private static func errorText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }

    private static func canonicalPath(_ path: String) throws -> String {
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &resolved) != nil else {
            throw BrowserMCPUploadStagingError.stagingFailed(Self.errorText(errno))
        }
        let bytes = resolved.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard let canonicalPath = String(bytes: bytes, encoding: .utf8) else {
            throw BrowserMCPUploadStagingError.stagingFailed("the canonical path is not valid UTF-8")
        }
        return canonicalPath
    }

    private static func removeStagingRoot(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }
}
