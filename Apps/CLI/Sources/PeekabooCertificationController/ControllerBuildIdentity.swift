import CryptoKit
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooFoundation
import Security

@_silgen_name("csops")
private func certification_csops(
    _ processIdentifier: pid_t,
    _ operation: UInt32,
    _ userAddress: UnsafeMutableRawPointer?,
    _ userSize: Int
) -> Int32

struct CertificationAuthenticatedControllerBuild: Sendable {
    let process: CertificationProcessReceipt
    let build: CertificationControllerBuildReceipt
}

struct CertificationCodeValidityChecking {
    let checkDynamic: (SecCode, SecCSFlags, SecRequirement) -> OSStatus
    let checkStatic: (SecStaticCode, SecCSFlags, SecRequirement) -> OSStatus

    static var securityFramework: Self {
        Self(
            checkDynamic: { code, flags, requirement in
                SecCodeCheckValidity(code, flags, requirement)
            },
            checkStatic: { code, flags, requirement in
                SecStaticCodeCheckValidity(code, flags, requirement)
            }
        )
    }
}

enum CertificationControllerBuildIdentityResolver {
    static func current(expectedTeamID: String) throws -> CertificationAuthenticatedControllerBuild {
        let processIdentifier = getpid()
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(processIdentifier),
              let kernelPath = self.executablePath(processIdentifier: processIdentifier),
              let executablePath = self.canonicalPath(kernelPath)
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller cannot resolve its kernel process generation and executable path."
            )
        }
        let executableURL = URL(fileURLWithPath: executablePath, isDirectory: false)
        let descriptor = open(executablePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller cannot open its kernel-bound executable."
            )
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller executable descriptor is not one regular file."
            )
        }
        let executableSHA256 = try self.sha256(descriptor: descriptor)

        var dynamicCode: SecCode?
        guard let liveCDHashBefore = self.liveCodeSignatureHash(processIdentifier: processIdentifier),
              SecCodeCopySelf([], &dynamicCode) == errSecSuccess,
              let dynamicCode,
              let dynamicStaticCode = self.staticCode(for: dynamicCode),
              let pathStaticCode = self.staticCode(at: executableURL),
              self.validateAppleAnchoredCode(
                  dynamicCode: dynamicCode,
                  pathStaticCode: pathStaticCode,
                  expectedTeamID: expectedTeamID
              ),
              let dynamicInformation = self.signingInformation(dynamicStaticCode),
              let pathInformation = self.signingInformation(pathStaticCode),
              let dynamicCDHash = self.codeSignatureData(dynamicInformation),
              let pathCDHash = self.codeSignatureData(pathInformation),
              liveCDHashBefore == dynamicCDHash,
              dynamicCDHash == pathCDHash,
              let dynamicTeamID = dynamicInformation[kSecCodeInfoTeamIdentifier as String] as? String,
              let pathTeamID = pathInformation[kSecCodeInfoTeamIdentifier as String] as? String,
              dynamicTeamID == expectedTeamID,
              pathTeamID == expectedTeamID,
              let sourceCommit = self.sourceCommit(pathInformation),
              self.mainExecutablePath(dynamicInformation) == executablePath,
              self.liveCodeSignatureHash(processIdentifier: processIdentifier) == dynamicCDHash
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller cannot bind its live code signature, signed source stamp, and executable file."
            )
        }
        var after = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(executablePath, &pathInfo) == 0,
              self.sameFile(before, after),
              self.sameFile(after, pathInfo)
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller executable changed while its build identity was authenticated."
            )
        }
        return CertificationAuthenticatedControllerBuild(
            process: CertificationProcessReceipt(
                pid: processIdentifier,
                startIdentity: String(processStartIdentity),
                codeSignatureHash: self.hexString(dynamicCDHash)
            ),
            build: CertificationControllerBuildReceipt(
                sourceCommit: sourceCommit,
                executablePath: executablePath,
                executableSHA256: executableSHA256,
                teamID: dynamicTeamID
            )
        )
    }

    static func appleAnchoredRequirementText(expectedTeamID: String) -> String? {
        guard expectedTeamID.utf8.count == 10,
              expectedTeamID.utf8.allSatisfy({
                  (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
              })
        else { return nil }
        return "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamID)\""
    }

    static func validateAppleAnchoredCode(
        dynamicCode: SecCode,
        pathStaticCode: SecStaticCode,
        expectedTeamID: String,
        checker: CertificationCodeValidityChecking = .securityFramework
    ) -> Bool {
        guard let requirement = self.appleAnchoredRequirement(expectedTeamID: expectedTeamID) else { return false }
        let staticFlags = SecCSFlags(
            rawValue: UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures)
        )
        return checker.checkDynamic(dynamicCode, [], requirement) == errSecSuccess &&
            checker.checkStatic(pathStaticCode, staticFlags, requirement) == errSecSuccess
    }

    static func validateAppleAnchoredStaticCode(
        _ staticCode: SecStaticCode,
        expectedTeamID: String,
        checker: CertificationCodeValidityChecking = .securityFramework
    ) -> Bool {
        guard let requirement = self.appleAnchoredRequirement(expectedTeamID: expectedTeamID) else { return false }
        let flags = SecCSFlags(
            rawValue: UInt32(kSecCSStrictValidate) | UInt32(kSecCSCheckAllArchitectures)
        )
        return checker.checkStatic(staticCode, flags, requirement) == errSecSuccess
    }

    private static func appleAnchoredRequirement(expectedTeamID: String) -> SecRequirement? {
        guard let text = self.appleAnchoredRequirementText(expectedTeamID: expectedTeamID) else { return nil }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    static func executablePath(processIdentifier: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(processIdentifier, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func canonicalPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = path.withCString { input in
            buffer.withUnsafeMutableBufferPointer { output in
                realpath(input, output.baseAddress)
            }
        }
        guard resolved != nil else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(bytes: bytes, encoding: .utf8)
    }

    static func staticCode(for code: SecCode) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    static func staticCode(at url: URL) -> SecStaticCode? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess else { return nil }
        return staticCode
    }

    static func signingInformation(_ code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: UInt32(kSecCSSigningInformation))
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }

    static func codeSignatureHash(_ information: [String: Any]) -> String? {
        self.codeSignatureData(information).map(self.hexString(_:))
    }

    static func codeSignatureData(_ information: [String: Any]) -> Data? {
        guard let data = information[kSecCodeInfoUnique as String] as? Data, data.count == 20 else { return nil }
        return data
    }

    static func liveCodeSignatureHash(
        processIdentifier: pid_t,
        systemCall: (pid_t, UInt32, UnsafeMutableRawPointer?, Int) -> Int32 = certification_csops
    ) -> Data? {
        var hash = [UInt8](repeating: 0, count: 20)
        let result = hash.withUnsafeMutableBytes { bytes in
            systemCall(processIdentifier, 5, bytes.baseAddress, bytes.count)
        }
        guard result == 0, hash.contains(where: { $0 != 0 }) else { return nil }
        return Data(hash)
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func sourceCommit(_ information: [String: Any]) -> String? {
        let plist = information[kSecCodeInfoPList as String] as? [String: Any]
        return SourceProvenance.exactCommit(plist?["PeekabooSourceCommit"] as? String)
    }

    static func mainExecutablePath(_ information: [String: Any]) -> String? {
        let value = information[kSecCodeInfoMainExecutable as String]
        let url = (value as? URL) ?? (value as? NSURL).map { $0 as URL }
        guard let path = url?.path else { return nil }
        return self.canonicalPath(path)
    }

    static func sha256(descriptor: Int32) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw CertificationControllerError.runtimeRefusal(
                "Controller cannot seek its executable for hashing."
            )
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev &&
            lhs.st_ino == rhs.st_ino &&
            lhs.st_size == rhs.st_size &&
            lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec &&
            lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec &&
            lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec &&
            lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
