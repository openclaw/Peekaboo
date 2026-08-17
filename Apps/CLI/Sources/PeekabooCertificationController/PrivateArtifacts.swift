import CryptoKit
import Darwin
import Foundation

enum CertificationPrivateArtifacts {
    static let maximumPlanBytes = 1024 * 1024

    static func readPlan(at url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CertificationControllerError.unsafePrivatePath(
                "Cannot open owner-private controller plan: \(Self.posixMessage())."
            )
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o077 == 0,
              info.st_size >= 0,
              info.st_size <= Self.maximumPlanBytes
        else {
            throw CertificationControllerError.unsafePrivatePath(
                "Controller plan must be an owner-private regular file no larger than 1 MiB."
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw CertificationControllerError.unsafePrivatePath("Cannot read controller plan: \(error).")
        }
    }

    static func prepare(for plan: CertificationControllerPlan) throws {
        try self.preparePrivateDirectory(plan.artifactsURL)
        try self.preparePrivateDirectory(plan.bundleDirectoryURL)
        try self.preparePrivateDirectory(plan.observationDirectoryURL)
        guard try self.inventory(plan.bundleDirectoryURL).isEmpty else {
            throw CertificationControllerError.unsafePrivatePath(
                "Controller bundle directory must be empty before execution."
            )
        }
        guard try self.inventory(plan.observationDirectoryURL).isEmpty else {
            throw CertificationControllerError.unsafePrivatePath(
                "Controller observation directory must be empty before execution."
            )
        }
        for destination in [
            plan.receiptURL,
            plan.mutationStartedURL,
            plan.mutationCompletedURL,
            plan.readyURL,
            plan.startURL,
            plan.finalBoundsReadyURL,
            plan.finalBoundsStartURL,
            plan.releaseURL,
        ] {
            var existing = stat()
            guard lstat(destination.path, &existing) != 0, errno == ENOENT else {
                throw CertificationControllerError.unsafePrivatePath(
                    "Controller evidence destination already exists: \(destination.lastPathComponent)."
                )
            }
        }
    }

    static func prepareObserver(for plan: CertificationObserveOnlyPlan) throws {
        try self.preparePrivateDirectory(plan.artifactsURL)
        let paths = [
            plan.readyURL,
            plan.observationRequestURL,
            plan.restorationRequestURL,
            plan.releaseURL,
            plan.observationURL,
            plan.restorationURL,
            plan.witnessURL,
            URL(fileURLWithPath: plan.attestationSocketPath),
        ]
        for destination in paths {
            var existing = stat()
            guard lstat(destination.path, &existing) != 0, errno == ENOENT else {
                throw CertificationControllerError.unsafePrivatePath(
                    "Observe-only evidence destination already exists: \(destination.lastPathComponent)."
                )
            }
        }
    }

    static func prepareHeldPointer(for plan: HeldPointerCertificationPlan) throws {
        try self.preparePrivateDirectory(plan.artifactsURL)
        guard try self.inventory(plan.artifactsURL).isEmpty else {
            throw CertificationControllerError.unsafePrivatePath(
                "Held-pointer artifact directory must be empty before execution."
            )
        }
        try self.preparePrivateDirectory(plan.bundleDirectoryURL)
        guard try self.inventory(plan.bundleDirectoryURL).isEmpty else {
            throw CertificationControllerError.unsafePrivatePath(
                "Held-pointer bundle directory must be empty before execution."
            )
        }
        var existing = stat()
        guard lstat(plan.receiptURL.path, &existing) != 0, errno == ENOENT else {
            throw CertificationControllerError.unsafePrivatePath(
                "Held-pointer evidence destination already exists."
            )
        }
    }

    static func preparePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT, mkdir(url.path, S_IRWXU) == 0 else {
                throw CertificationControllerError.unsafePrivatePath(
                    "Cannot create private directory \(url.path): \(Self.posixMessage())."
                )
            }
            guard chmod(url.path, S_IRWXU) == 0 else {
                throw CertificationControllerError.unsafePrivatePath(
                    "Cannot restrict private directory \(url.path): \(Self.posixMessage())."
                )
            }
            guard lstat(url.path, &info) == 0 else {
                throw CertificationControllerError.unsafePrivatePath(
                    "Cannot inspect private directory \(url.path): \(Self.posixMessage())."
                )
            }
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else {
            throw CertificationControllerError.unsafePrivatePath(
                "Directory is not owner-private: \(url.path)."
            )
        }
    }

    static func inventory(_ directory: URL) throws -> [String] {
        do {
            return try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        } catch {
            throw CertificationControllerError.unsafePrivatePath(
                "Cannot inventory private directory \(directory.path): \(error)."
            )
        }
    }

    static func requireExactBundleInventory(
        _ directory: URL,
        requestIDs: [UUID]
    ) throws {
        let expected = requestIDs.map { $0.uuidString.lowercased() + ".json" }.sorted()
        let actual = try self.inventory(directory)
        guard actual == expected else {
            throw CertificationControllerError.runtimeRefusal(
                "Bundle export inventory is not exact (expected \(expected), observed \(actual))."
            )
        }
    }

    static func requireOwnerPrivateRegularFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(),
              info.st_nlink == 1,
              info.st_mode & 0o077 == 0
        else {
            throw CertificationControllerError.unsafePrivatePath(
                "Expected one owner-private regular file at \(url.path)."
            )
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(file url: URL) throws -> String {
        try self.sha256(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    static func writeReceipt(_ data: Data, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString.lowercased()).tmp"
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw CertificationControllerError.unsafePrivatePath(
                "Cannot create controller receipt: \(Self.posixMessage())."
            )
        }
        var removeTemporary = true
        defer {
            close(descriptor)
            if removeTemporary {
                unlink(temporary.path)
            }
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            throw CertificationControllerError.unsafePrivatePath(
                "Cannot restrict controller receipt: \(Self.posixMessage())."
            )
        }
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, baseAddress.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written == -1, errno == EINTR {
                    continue
                } else {
                    throw CertificationControllerError.unsafePrivatePath(
                        "Cannot write controller receipt: \(Self.posixMessage())."
                    )
                }
            }
        }
        guard fsync(descriptor) == 0,
              renameatx_np(
                  AT_FDCWD,
                  temporary.path,
                  AT_FDCWD,
                  destination.path,
                  UInt32(RENAME_EXCL)
              ) == 0
        else {
            throw CertificationControllerError.unsafePrivatePath(
                "Cannot publish controller receipt exclusively: \(Self.posixMessage())."
            )
        }
        removeTemporary = false
        try self.requireOwnerPrivateRegularFile(destination)
    }

    private static func posixMessage() -> String {
        String(cString: strerror(errno))
    }
}
