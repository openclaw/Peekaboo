import Darwin
import Foundation

/// The stable identity scope guarded while Peekaboo reads or mutates desktop state.
///
/// A process generation is part of every scoped key because both PIDs and WindowServer IDs are reusable.
/// Mutable window hints such as bounds and minimized state are intentionally excluded from the lane key.
public enum DesktopOperationScope: Sendable, Codable, Equatable {
    case global
    case process(ApplicationProcessIdentity)
    case window(WindowMutationIdentity)

    public var processIdentity: ApplicationProcessIdentity? {
        switch self {
        case .global:
            nil
        case let .process(identity):
            identity
        case let .window(identity):
            ApplicationProcessIdentity(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity)
        }
    }
}

public enum DesktopOperationAccess: Sendable, Equatable {
    case read
    case write
}

public enum DesktopOperationLaneError: LocalizedError, Sendable {
    case fileSystem(operation: String, path: String, message: String)
    case systemCall(operation: String, path: String, code: Int32)
    case unsafeDirectory(path: String)
    case unsafeLockFile(path: String)

    public var errorDescription: String? {
        switch self {
        case let .fileSystem(operation, path, message):
            "Desktop operation coordination failed during \(operation) at \(path): \(message)"
        case let .systemCall(operation, path, code):
            "Desktop operation coordination failed during \(operation) at \(path): " +
                String(cString: strerror(code))
        case let .unsafeDirectory(path):
            "Desktop operation coordination directory is unsafe: \(path)"
        case let .unsafeLockFile(path):
            "Desktop operation coordination lock is not a regular file owned by the current user: \(path)"
        }
    }
}

/// Cross-process reader/writer lanes for native desktop operations.
///
/// Claims are always acquired in the order global -> process -> window. Scoped work shares the global lane;
/// foreground or otherwise unresolved work uses an exclusive global claim. The coordinator retains every claim until
/// the operation body actually returns, including when caller cancellation is ignored by an in-flight native call.
public actor DesktopOperationLaneCoordinator {
    public static let shared = DesktopOperationLaneCoordinator()

    private struct Claim: Sendable {
        let fileName: String
        let access: DesktopOperationAccess
    }

    private struct HeldClaim: Sendable {
        let descriptor: Int32
    }

    private let coordinationRootURL: URL

    public init() {
        self.coordinationRootURL = DesktopCoordinationRuntimeRoot.defaultURL
    }

    init(coordinationRootURL: URL) {
        self.coordinationRootURL = coordinationRootURL.standardizedFileURL
    }

    public nonisolated func run<T: Sendable>(
        scope: DesktopOperationScope,
        access: DesktopOperationAccess,
        operation: () async throws -> T) async throws -> T
    {
        let claims = await self.claims(scope: scope, access: access)
        let heldClaims = try await self.acquire(claims)
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await self.release(heldClaims)
            return result
        } catch {
            await self.release(heldClaims)
            throw error
        }
    }

    private func claims(
        scope: DesktopOperationScope,
        access: DesktopOperationAccess) -> [Claim]
    {
        switch scope {
        case .global:
            return [Claim(fileName: "global.lock", access: access)]
        case let .process(identity):
            return [
                Claim(fileName: "global.lock", access: .read),
                Claim(fileName: Self.processFileName(identity), access: access),
            ]
        case let .window(identity):
            let process = ApplicationProcessIdentity(
                processIdentifier: identity.ownerProcessIdentifier,
                processStartIdentity: identity.ownerProcessStartIdentity)
            return [
                Claim(fileName: "global.lock", access: .read),
                Claim(fileName: Self.processFileName(process), access: .read),
                Claim(fileName: Self.windowFileName(identity), access: access),
            ]
        }
    }

    private func acquire(_ claims: [Claim]) async throws -> [HeldClaim] {
        try self.prepareCoordinationRoot()
        var heldClaims: [HeldClaim] = []
        do {
            for claim in claims {
                try Task.checkCancellation()
                let url = self.coordinationRootURL.appendingPathComponent(claim.fileName, isDirectory: false)
                let descriptor = try self.openLockDescriptor(at: url)
                do {
                    try await self.acquireFileLock(
                        descriptor: descriptor,
                        path: url.path,
                        access: claim.access)
                    heldClaims.append(HeldClaim(descriptor: descriptor))
                } catch {
                    close(descriptor)
                    throw error
                }
            }
            try Task.checkCancellation()
            return heldClaims
        } catch {
            self.release(heldClaims)
            throw error
        }
    }

    private func acquireFileLock(
        descriptor: Int32,
        path: String,
        access: DesktopOperationAccess) async throws
    {
        let operation = (access == .read ? LOCK_SH : LOCK_EX) | LOCK_NB
        while flock(descriptor, operation) != 0 {
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN || code == EINTR else {
                throw DesktopOperationLaneError.systemCall(operation: "flock", path: path, code: code)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func release(_ heldClaims: [HeldClaim]) {
        for claim in heldClaims.reversed() {
            _ = flock(claim.descriptor, LOCK_UN)
            close(claim.descriptor)
        }
    }

    private func prepareCoordinationRoot() throws {
        do {
            try FileManager.default.createDirectory(
                at: self.coordinationRootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: S_IRWXU)])
        } catch {
            throw DesktopOperationLaneError.fileSystem(
                operation: "prepare",
                path: self.coordinationRootURL.path,
                message: error.localizedDescription)
        }

        var info = stat()
        guard lstat(self.coordinationRootURL.path, &info) == 0 else {
            throw DesktopOperationLaneError.systemCall(
                operation: "inspect",
                path: self.coordinationRootURL.path,
                code: errno)
        }
        let writableByAnotherUser = info.st_mode & mode_t(S_IWGRP | S_IWOTH) != 0
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              info.st_uid == geteuid(),
              !writableByAnotherUser
        else {
            throw DesktopOperationLaneError.unsafeDirectory(path: self.coordinationRootURL.path)
        }
        guard chmod(self.coordinationRootURL.path, S_IRWXU) == 0 else {
            throw DesktopOperationLaneError.systemCall(
                operation: "secure",
                path: self.coordinationRootURL.path,
                code: errno)
        }
    }

    private func openLockDescriptor(at url: URL) throws -> Int32 {
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw DesktopOperationLaneError.systemCall(operation: "open", path: url.path, code: errno)
        }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw DesktopOperationLaneError.systemCall(operation: "inspect", path: url.path, code: code)
        }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(),
              info.st_nlink == 1
        else {
            close(descriptor)
            throw DesktopOperationLaneError.unsafeLockFile(path: url.path)
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let code = errno
            close(descriptor)
            throw DesktopOperationLaneError.systemCall(operation: "secure", path: url.path, code: code)
        }
        return descriptor
    }

    private static func processFileName(_ identity: ApplicationProcessIdentity) -> String {
        "process-\(identity.processIdentifier)-\(identity.processStartIdentity).lock"
    }

    private static func windowFileName(_ identity: WindowMutationIdentity) -> String {
        "window-\(identity.ownerProcessIdentifier)-\(identity.ownerProcessStartIdentity)-\(identity.windowID).lock"
    }
}

enum DesktopCoordinationRuntimeRoot {
    static var defaultURL: URL {
        self.physicalHomeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Peekaboo", isDirectory: true)
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent("Coordination", isDirectory: true)
            .standardizedFileURL
    }

    /// Foundation's home URL honors `CFFIXED_USER_HOME`, which may differ between otherwise
    /// cooperating processes. The account database is the single per-UID source of truth.
    private static var physicalHomeDirectoryURL: URL {
        let suggestedSize = sysconf(_SC_GETPW_R_SIZE_MAX)
        let bufferSize = max(suggestedSize > 0 ? Int(suggestedSize) : 4096, 1024)
        var passwordEntry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: bufferSize)
        let code = getpwuid_r(geteuid(), &passwordEntry, &buffer, buffer.count, &result)
        if code == 0, result != nil, let home = passwordEntry.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        // Fail closed at one fixed system location rather than splitting coordination authority
        // across environment-dependent container homes. Normal macOS accounts always resolve above.
        return URL(fileURLWithPath: "/var/empty", isDirectory: true)
    }
}
