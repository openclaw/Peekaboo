import Darwin
import Foundation
import Security

enum ScreenCaptureKitProcessCapabilityRegistry {
    typealias Lease = ScreenCaptureKitOwnerLease
    typealias LeaseError = ScreenCaptureKitOwnerLease.LeaseError

    static let directoryURL = Lease.canonicalUserTemporaryDirectoryURL()
        .appendingPathComponent("boo.peekaboo.sckit-aware", isDirectory: true)
        .standardizedFileURL

    private static let formatVersion = 1
    private static let filePrefix = "boo.peekaboo.sckit-aware"
    private static let maximumReceiptBytes = 4096
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var heldDescriptorsByPath: [String: Int32] = [:]
    private nonisolated(unsafe) static var processInspectionCache: [ProcessInspectionKey: ProcessInspection] = [:]

    private struct ProcessInspectionKey: Hashable {
        let processIdentifier: pid_t
        let processStartIdentity: UInt64
        let executablePath: String
    }

    private struct ProcessInspection {
        let signature: CodeSignatureIdentity?
        let isPotentialHost: Bool
    }

    struct ProcessCapabilityReceipt: Codable, Sendable {
        let formatVersion: Int
        let processIdentifier: pid_t
        let processStartIdentity: UInt64
        let buildIdentity: String?
        let codeSignatureHash: String?
        let signingIdentifier: String?
        let teamIdentifier: String?

        init(
            processIdentifier: pid_t,
            processStartIdentity: UInt64,
            buildIdentity: String?,
            codeSignatureHash: String?,
            signingIdentifier: String?,
            teamIdentifier: String?)
        {
            self.formatVersion = ScreenCaptureKitProcessCapabilityRegistry.formatVersion
            self.processIdentifier = processIdentifier
            self.processStartIdentity = processStartIdentity
            self.buildIdentity = buildIdentity
            self.codeSignatureHash = codeSignatureHash
            self.signingIdentifier = signingIdentifier
            self.teamIdentifier = teamIdentifier
        }
    }

    struct CodeSignatureIdentity: Sendable {
        let signingIdentifier: String?
        let teamIdentifier: String?
        let codeSignatureHash: String?
    }

    static func register(
        ownerIdentity: Lease.OwnerIdentity,
        directory: URL = directoryURL,
        signatureIdentity: CodeSignatureIdentity? = currentCodeSignatureIdentity()) throws
    {
        let receipt = ProcessCapabilityReceipt(
            processIdentifier: ownerIdentity.processIdentifier,
            processStartIdentity: ownerIdentity.processStartIdentity,
            buildIdentity: ownerIdentity.buildIdentity,
            codeSignatureHash: ownerIdentity.codeSignatureHash,
            signingIdentifier: signatureIdentity?.signingIdentifier,
            teamIdentifier: signatureIdentity?.teamIdentifier)
        let markerURL = self.markerURL(
            processIdentifier: receipt.processIdentifier,
            processStartIdentity: receipt.processStartIdentity,
            directory: directory)
        let markerPath = markerURL.path

        try self.registryLock.withLock {
            if let descriptor = self.heldDescriptorsByPath[markerPath] {
                try Lease.validateHeldDescriptor(descriptor, path: markerPath)
                return
            }

            try self.removeStaleMarkers(
                directory: markerURL.deletingLastPathComponent(),
                excludingPath: markerPath)
            try Lease.prepareLockDirectory(for: markerPath)
            let descriptor = open(
                markerPath,
                O_CREAT | O_RDWR | O_CLOEXEC | Lease.closeOnForkOpenFlag | O_NOFOLLOW,
                S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else {
                throw LeaseError.systemCall(operation: "open process capability", path: markerPath, code: errno)
            }
            var shouldClose = true
            defer {
                if shouldClose {
                    close(descriptor)
                }
            }

            try Lease.secureAndValidateLockFile(descriptor: descriptor, path: markerPath)
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                throw LeaseError.systemCall(
                    operation: "claim process capability",
                    path: markerPath,
                    code: errno)
            }
            do {
                try Lease.persist(receipt: receipt, descriptor: descriptor, path: markerPath)
                self.heldDescriptorsByPath[markerPath] = descriptor
                shouldClose = false
            } catch {
                _ = flock(descriptor, LOCK_UN)
                throw error
            }
        }
    }

    static func markerURL(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        directory: URL = directoryURL) -> URL
    {
        directory.appendingPathComponent(
            "\(self.filePrefix).\(processIdentifier).\(processStartIdentity)",
            isDirectory: false).standardizedFileURL
    }

    static func liveUncoordinatedProcesses(
        excluding currentIdentity: Lease.OwnerIdentity) throws -> [Lease.UncoordinatedProcess]
    {
        let processIdentifiers = try self.allProcessIdentifiers()
        var conflicts: [Lease.UncoordinatedProcess] = []
        var seen = Set<pid_t>()
        var activeInspectionKeys = Set<ProcessInspectionKey>()

        for processIdentifier in processIdentifiers where processIdentifier > 0 {
            guard processIdentifier != currentIdentity.processIdentifier,
                  seen.insert(processIdentifier).inserted,
                  self.userIdentifier(for: processIdentifier) == geteuid(),
                  let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier),
                  let executablePath = self.executablePath(for: processIdentifier)
            else {
                continue
            }

            let (inspectionKey, inspection) = self.processInspection(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                executablePath: executablePath)
            activeInspectionKeys.insert(inspectionKey)
            guard inspection.isPotentialHost
            else {
                continue
            }

            guard SystemIdentityResolver.processStartIdentity(processIdentifier) == processStartIdentity,
                  self.executablePath(for: processIdentifier) == executablePath
            else {
                continue
            }
            var hasValidCapability = self.hasValidCapability(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                executablePath: executablePath,
                signature: inspection.signature)
            if !hasValidCapability {
                // A current binary can become visible between exec and entrypoint registration.
                for _ in 0..<3 {
                    usleep(10000)
                    hasValidCapability = self.hasValidCapability(
                        processIdentifier: processIdentifier,
                        processStartIdentity: processStartIdentity,
                        executablePath: executablePath,
                        signature: inspection.signature)
                    if hasValidCapability {
                        break
                    }
                }
            }
            if hasValidCapability {
                continue
            }
            conflicts.append(Lease.UncoordinatedProcess(
                processIdentifier: processIdentifier,
                processStartIdentity: processStartIdentity,
                executablePath: executablePath))
        }
        self.registryLock.withLock {
            self.processInspectionCache = self.processInspectionCache.filter { activeInspectionKeys.contains($0.key) }
        }
        return conflicts.sorted { $0.processIdentifier < $1.processIdentifier }
    }

    private static func processInspection(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        executablePath: String) -> (ProcessInspectionKey, ProcessInspection)
    {
        let key = ProcessInspectionKey(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            executablePath: executablePath)
        if let cached = self.registryLock.withLock({ self.processInspectionCache[key] }) {
            return (key, cached)
        }

        let signature = self.codeSignatureIdentity(for: processIdentifier) ??
            self.codeSignatureIdentity(at: URL(fileURLWithPath: executablePath))
        let inspection = ProcessInspection(
            signature: signature,
            isPotentialHost: self.isPotentialPeekabooProcess(
                executablePath: executablePath,
                signingIdentifier: signature?.signingIdentifier))
        // Do not cache an unidentifiable unrelated process: a transient Security failure must not
        // hide a renamed signed host on the next ownership boundary.
        if signature != nil || inspection.isPotentialHost {
            self.registryLock.withLock {
                self.processInspectionCache[key] = inspection
            }
        }
        return (key, inspection)
    }

    static func hasValidCapability(
        processIdentifier: pid_t,
        processStartIdentity: UInt64,
        executablePath: String,
        signature: CodeSignatureIdentity?,
        directory: URL = directoryURL) -> Bool
    {
        let markerPath = self.markerURL(
            processIdentifier: processIdentifier,
            processStartIdentity: processStartIdentity,
            directory: directory).path
        let descriptor = open(
            markerPath,
            O_RDONLY | O_CLOEXEC | Lease.closeOnForkOpenFlag | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        do {
            try Lease.validateHeldDescriptor(descriptor, path: markerPath)
            // Darwin F_GETLK reports whole-file flock locks with l_pid = -1 without mutating them.
            var lockQuery = Darwin.flock()
            lockQuery.l_start = 0
            lockQuery.l_len = 0
            lockQuery.l_pid = 0
            lockQuery.l_type = Int16(F_WRLCK)
            lockQuery.l_whence = Int16(SEEK_SET)
            guard fcntl(descriptor, F_GETLK, &lockQuery) == 0,
                  lockQuery.l_type != Int16(F_UNLCK),
                  let receipt = try self.readReceipt(descriptor: descriptor),
                  receipt.formatVersion == self.formatVersion,
                  receipt.processIdentifier == processIdentifier,
                  receipt.processStartIdentity == processStartIdentity,
                  SystemIdentityResolver.processStartIdentity(processIdentifier) == processStartIdentity,
                  try self.buildMatches(
                      receipt,
                      executablePath: executablePath,
                      signature: signature)
            else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    private static func buildMatches(
        _ receipt: ProcessCapabilityReceipt,
        executablePath: String,
        signature: CodeSignatureIdentity?) throws -> Bool
    {
        try Lease.validateExecutableIdentity(
            buildIdentity: receipt.buildIdentity,
            codeSignatureHash: receipt.codeSignatureHash)
        if let codeSignatureHash = receipt.codeSignatureHash {
            guard signature?.codeSignatureHash == codeSignatureHash else { return false }
        }
        if let buildIdentity = receipt.buildIdentity {
            guard try Lease.executableBuildIdentity(at: URL(fileURLWithPath: executablePath)) == buildIdentity else {
                return false
            }
        }
        if let signingIdentifier = receipt.signingIdentifier {
            guard signature?.signingIdentifier == signingIdentifier else { return false }
        }
        if let teamIdentifier = receipt.teamIdentifier {
            guard signature?.teamIdentifier == teamIdentifier else { return false }
        }
        return true
    }

    private static func readReceipt(descriptor: Int32) throws -> ProcessCapabilityReceipt? {
        var fileInfo = stat()
        guard fstat(descriptor, &fileInfo) == 0,
              fileInfo.st_size > 0,
              fileInfo.st_size <= off_t(self.maximumReceiptBytes)
        else {
            return nil
        }
        var data = Data(count: Int(fileInfo.st_size))
        let count = data.withUnsafeMutableBytes { buffer -> Int in
            guard let baseAddress = buffer.baseAddress else { return 0 }
            return pread(descriptor, baseAddress, buffer.count, 0)
        }
        guard count == data.count else { return nil }
        return try JSONDecoder().decode(ProcessCapabilityReceipt.self, from: data)
    }

    static func isPotentialPeekabooProcess(
        executablePath: String,
        signingIdentifier: String?) -> Bool
    {
        if let signingIdentifier {
            return self.screenCaptureKitHostIdentifiers.contains(signingIdentifier.lowercased())
        }
        if URL(fileURLWithPath: executablePath).lastPathComponent.lowercased() == "peekaboo" {
            return true
        }
        return self.unsignedMainBundleIsScreenCaptureKitHost(executablePath: executablePath)
    }

    private static let screenCaptureKitHostIdentifiers: Set<String> = [
        "peekaboo",
        "boo.peekaboo",
        "boo.peekaboo.peekaboo",
        "boo.peekaboo.mac",
        "boo.peekaboo.mac.debug",
        "com.anthropic.claudefordesktop",
        "com.clawdis.mac",
        "com.clawdis.mac.debug",
        "com.clawdbot.mac",
        "com.clawdbot.mac.debug",
        "bot.molt.mac",
        "bot.molt.mac.debug",
        "ai.openclaw.mac",
        "ai.openclaw.mac.debug",
    ]

    private static func unsignedMainBundleIsScreenCaptureKitHost(executablePath: String) -> Bool {
        let executableURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        let macOSDirectory = executableURL.deletingLastPathComponent()
        let contentsDirectory = macOSDirectory.deletingLastPathComponent()
        let bundleURL = contentsDirectory.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS",
              contentsDirectory.lastPathComponent == "Contents",
              bundleURL.pathExtension.lowercased() == "app",
              let bundle = Bundle(url: bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier?.lowercased(),
              self.screenCaptureKitHostIdentifiers.contains(bundleIdentifier),
              let bundleExecutableURL = bundle.executableURL?.standardizedFileURL,
              bundleExecutableURL.path == executableURL.path
        else {
            return false
        }
        return true
    }

    static func removeStaleMarkers(
        directory: URL = directoryURL,
        excludingPath: String? = nil) throws
    {
        let directoryPath = directory.standardizedFileURL.path
        var directoryInfo = stat()
        guard lstat(directoryPath, &directoryInfo) == 0 else {
            if errno == ENOENT {
                return
            }
            throw LeaseError.systemCall(operation: "inspect marker directory", path: directoryPath, code: errno)
        }
        guard directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & mode_t(S_IRWXG | S_IRWXO) == 0
        else {
            throw LeaseError.unsafeDirectory(path: directoryPath)
        }

        let names = try FileManager.default.contentsOfDirectory(atPath: directoryPath)
        let prefix = self.filePrefix + "."
        for name in names where name.hasPrefix(prefix) {
            let components = name.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
            guard components.count == 2,
                  let processIdentifier = pid_t(components[0]),
                  let processStartIdentity = UInt64(components[1])
            else {
                continue
            }
            let path = directory.appendingPathComponent(name, isDirectory: false).standardizedFileURL.path
            guard path != excludingPath,
                  SystemIdentityResolver.processStartIdentity(processIdentifier) != processStartIdentity
            else {
                continue
            }

            let descriptor = open(
                path,
                O_RDONLY | O_CLOEXEC | Lease.closeOnForkOpenFlag | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { continue }
            defer { close(descriptor) }
            do {
                try Lease.validateHeldDescriptor(descriptor, path: path)
                // Use Darwin's non-mutating flock visibility before attempting stale-file cleanup.
                var lockQuery = Darwin.flock()
                lockQuery.l_start = 0
                lockQuery.l_len = 0
                lockQuery.l_pid = 0
                lockQuery.l_type = Int16(F_WRLCK)
                lockQuery.l_whence = Int16(SEEK_SET)
                guard fcntl(descriptor, F_GETLK, &lockQuery) == 0,
                      lockQuery.l_type == Int16(F_UNLCK)
                else {
                    continue
                }
                guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
                defer { flock(descriptor, LOCK_UN) }
                try Lease.validateHeldDescriptor(descriptor, path: path)
                if unlink(path) != 0, errno != ENOENT {
                    throw LeaseError.systemCall(operation: "remove stale marker", path: path, code: errno)
                }
            } catch is LeaseError {
                continue
            }
        }
    }

    static func currentCodeSignatureIdentity() -> CodeSignatureIdentity? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        return self.codeSignatureIdentity(for: code)
    }

    private static func codeSignatureIdentity(for processIdentifier: pid_t) -> CodeSignatureIdentity? {
        let attributes: NSDictionary = [kSecGuestAttributePid: processIdentifier]
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &code) == errSecSuccess,
              let code
        else {
            return nil
        }
        return self.codeSignatureIdentity(for: code)
    }

    private static func codeSignatureIdentity(for code: SecCode) -> CodeSignatureIdentity? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        return self.codeSignatureIdentity(for: staticCode)
    }

    private static func codeSignatureIdentity(at executableURL: URL) -> CodeSignatureIdentity? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executableURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        return self.codeSignatureIdentity(for: staticCode)
    }

    private static func codeSignatureIdentity(for staticCode: SecStaticCode) -> CodeSignatureIdentity? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let values = information as? [String: Any]
        else {
            return nil
        }
        let hashData = values[kSecCodeInfoUnique as String] as? Data
        let hash = hashData.flatMap { data in
            data.isEmpty ? nil : data.map { String(format: "%02x", $0) }.joined()
        }
        return CodeSignatureIdentity(
            signingIdentifier: values[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: values[kSecCodeInfoTeamIdentifier as String] as? String,
            codeSignatureHash: hash)
    }

    private static func allProcessIdentifiers() throws -> [pid_t] {
        let estimatedCount = proc_listallpids(nil, 0)
        guard estimatedCount >= 0 else {
            throw LeaseError.systemCall(operation: "enumerate processes", path: "<process table>", code: errno)
        }
        var processIdentifiers = [pid_t](repeating: 0, count: Int(estimatedCount) + 64)
        let count = processIdentifiers.withUnsafeMutableBytes { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count >= 0 else {
            throw LeaseError.systemCall(operation: "enumerate processes", path: "<process table>", code: errno)
        }
        return Array(processIdentifiers.prefix(Int(count)))
    }

    private static func executablePath(for processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func userIdentifier(for processIdentifier: pid_t) -> uid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout.size(ofValue: info)
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        let succeeded = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, u_int(pointer.count), &info, &size, nil, 0) == 0
        }
        return succeeded ? info.kp_eproc.e_ucred.cr_uid : nil
    }
}
