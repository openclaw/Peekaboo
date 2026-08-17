import Darwin
import Foundation
import PeekabooAutomationKit
import Security

enum CertificationCodeIdentitySubjectKind: String, Codable {
    case executable
    case process
}

struct CertificationCodeIdentitySubject: Codable {
    let kind: CertificationCodeIdentitySubjectKind
    let executablePath: String?
    let processIdentifier: Int32?
    let processStartIdentity: String?
    let expectedTeamID: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case executablePath = "executable_path"
        case processIdentifier = "process_identifier"
        case processStartIdentity = "process_start_identity"
        case expectedTeamID = "expected_team_id"
    }
}

struct CertificationCodeIdentityPlan: Codable {
    let version: Int
    let executionNonce: String
    let expectedInspectorBuild: CertificationExpectedControllerBuild
    let subject: CertificationCodeIdentitySubject
    let outputPath: String
    let releasePath: String

    private enum CodingKeys: String, CodingKey {
        case version
        case executionNonce = "execution_nonce"
        case expectedInspectorBuild = "expected_inspector_build"
        case subject
        case outputPath = "output_path"
        case releasePath = "release_path"
    }

    static func decode(_ data: Data) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == [
                  "version", "execution_nonce", "expected_inspector_build", "subject", "output_path", "release_path",
              ],
              let build = root["expected_inspector_build"] as? [String: Any],
              Set(build.keys) == ["source_commit", "executable_path", "executable_sha256", "team_id"],
              let subject = root["subject"] as? [String: Any],
              let kind = subject["kind"] as? String
        else {
            throw CertificationControllerError.invalidPlan("Code-identity plan schema is not closed.")
        }
        let expectedSubjectKeys: Set<String> = if kind == CertificationCodeIdentitySubjectKind.executable.rawValue {
            ["kind", "executable_path", "expected_team_id"]
        } else if kind == CertificationCodeIdentitySubjectKind.process.rawValue {
            ["kind", "process_identifier", "process_start_identity", "expected_team_id"]
        } else {
            []
        }
        guard !expectedSubjectKeys.isEmpty, Set(subject.keys) == expectedSubjectKeys else {
            throw CertificationControllerError.invalidPlan("Code-identity subject schema is not closed.")
        }
        let plan = try JSONDecoder().decode(Self.self, from: data)
        try plan.validate()
        return plan
    }

    private func validate() throws {
        guard self.version == 1,
              Self.isLowerHex(self.executionNonce, count: 64),
              Self.isAbsolutePath(self.expectedInspectorBuild.executablePath),
              Self.isLowerHex(self.expectedInspectorBuild.sourceCommit, count: 40),
              Self.isLowerHex(self.expectedInspectorBuild.executableSHA256, count: 64),
              Self.isTeamID(self.expectedInspectorBuild.teamID),
              Self.isTeamID(self.subject.expectedTeamID),
              Self.isAbsolutePath(self.outputPath),
              Self.isAbsolutePath(self.releasePath),
              self.outputPath != self.releasePath
        else {
            throw CertificationControllerError.invalidPlan("Code-identity plan values are invalid.")
        }
        switch self.subject.kind {
        case .executable:
            guard let path = self.subject.executablePath,
                  Self.isAbsolutePath(path),
                  self.subject.processIdentifier == nil,
                  self.subject.processStartIdentity == nil
            else {
                throw CertificationControllerError.invalidPlan("Executable identity subject is invalid.")
            }
        case .process:
            guard self.subject.executablePath == nil,
                  let processIdentifier = self.subject.processIdentifier,
                  processIdentifier > 0,
                  let startIdentity = self.subject.processStartIdentity,
                  Self.isPositiveDecimal(startIdentity)
            else {
                throw CertificationControllerError.invalidPlan("Process identity subject is invalid.")
            }
        }
    }

    private static func isAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/") && !value.contains("\0") &&
            !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isTeamID(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy {
            (0x41...0x5A).contains($0) || (0x30...0x39).contains($0)
        }
    }

    private static func isPositiveDecimal(_ value: String) -> Bool {
        guard !value.isEmpty, value.first != "0", value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else {
            return false
        }
        return UInt64(value) != nil
    }
}

struct CertificationInspectedCodeIdentity: Codable {
    let kind: CertificationCodeIdentitySubjectKind
    let process: CertificationProcessReceipt?
    let executablePath: String
    let executableSHA256: String?
    let codeSignatureHash: String
    let teamID: String
    let sourceCommit: String

    private enum CodingKeys: String, CodingKey {
        case kind
        case process
        case executablePath = "executable_path"
        case executableSHA256 = "executable_sha256"
        case codeSignatureHash = "code_signature_hash"
        case teamID = "team_id"
        case sourceCommit = "source_commit"
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        if let process = self.process {
            try container.encode(process, forKey: .process)
        } else {
            try container.encodeNil(forKey: .process)
        }
        try container.encode(self.executablePath, forKey: .executablePath)
        if let executableSHA256 = self.executableSHA256 {
            try container.encode(executableSHA256, forKey: .executableSHA256)
        } else {
            try container.encodeNil(forKey: .executableSHA256)
        }
        try container.encode(self.codeSignatureHash, forKey: .codeSignatureHash)
        try container.encode(self.teamID, forKey: .teamID)
        try container.encode(self.sourceCommit, forKey: .sourceCommit)
    }
}

struct CertificationCodeIdentityReceipt: Codable {
    let version: Int
    let inspectorProcess: CertificationProcessReceipt
    let inspectorBuild: CertificationControllerBuildReceipt
    let subject: CertificationInspectedCodeIdentity

    private enum CodingKeys: String, CodingKey {
        case version
        case inspectorProcess = "inspector_process"
        case inspectorBuild = "inspector_build"
        case subject
    }
}

struct CertificationRetainedCodeChecking {
    let validateDynamic: (SecCode, SecStaticCode, String) -> Bool
    let validateStatic: (SecStaticCode, String) -> Bool
    let signingInformation: (SecStaticCode) -> [String: Any]?

    static var securityFramework: Self {
        Self(
            validateDynamic: { dynamicCode, staticCode, teamID in
                CertificationControllerBuildIdentityResolver.validateAppleAnchoredCode(
                    dynamicCode: dynamicCode,
                    pathStaticCode: staticCode,
                    expectedTeamID: teamID
                )
            },
            validateStatic: { staticCode, teamID in
                CertificationControllerBuildIdentityResolver.validateAppleAnchoredStaticCode(
                    staticCode,
                    expectedTeamID: teamID
                )
            },
            signingInformation: { staticCode in
                CertificationControllerBuildIdentityResolver.signingInformation(staticCode)
            }
        )
    }
}

enum CertificationCodeIdentityRunner {
    static func run(planURL: URL) async throws -> URL {
        let plan = try CertificationCodeIdentityPlan.decode(CertificationPrivateArtifacts.readPlan(at: planURL))
        let inspector = try CertificationControllerBuildIdentityResolver.current(
            expectedTeamID: plan.expectedInspectorBuild.teamID
        )
        try plan.expectedInspectorBuild.requireMatches(inspector.build)
        let identity = switch plan.subject.kind {
        case .executable:
            try self.inspectExecutable(
                path: plan.subject.executablePath!,
                expectedTeamID: plan.subject.expectedTeamID
            )
        case .process:
            try self.inspectProcess(
                processIdentifier: plan.subject.processIdentifier!,
                expectedStartIdentity: plan.subject.processStartIdentity!,
                expectedTeamID: plan.subject.expectedTeamID
            )
        }
        let receipt = CertificationCodeIdentityReceipt(
            version: 1,
            inspectorProcess: inspector.process,
            inspectorBuild: inspector.build,
            subject: identity
        )
        let outputURL = URL(fileURLWithPath: plan.outputPath, isDirectory: false)
        try CertificationPrivateArtifacts.preparePrivateDirectory(outputURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(receipt)
        data.append(0x0A)
        try CertificationPrivateArtifacts.writeReceipt(data, to: outputURL)
        try await CertificationControllerLifecycleGate.waitForRelease(
            at: URL(fileURLWithPath: plan.releasePath, isDirectory: false),
            executionNonce: plan.executionNonce
        )
        return outputURL
    }

    static func inspectExecutable(
        path: String,
        expectedTeamID: String,
        checking: CertificationRetainedCodeChecking = .securityFramework,
        afterAuthentication: () -> Void = {}
    ) throws -> CertificationInspectedCodeIdentity {
        guard let executablePath = CertificationControllerBuildIdentityResolver.canonicalPath(path) else {
            throw CertificationControllerError.runtimeRefusal("Cannot resolve inspected executable path.")
        }
        let descriptor = open(executablePath, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw CertificationControllerError.runtimeRefusal("Cannot open inspected executable.")
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG else {
            throw CertificationControllerError.runtimeRefusal("Inspected executable is not one regular file.")
        }
        let executableData = try self.readExecutable(descriptor: descriptor)
        let executableSHA256 = CertificationPrivateArtifacts.sha256(executableData)
        let immutableCopy = try self.immutableCopy(executableData)
        defer { self.removeImmutableCopy(immutableCopy) }
        try self.validateImmutableCopy(immutableCopy)
        guard let staticCode = CertificationControllerBuildIdentityResolver.staticCode(at: immutableCopy.executable),
              checking.validateStatic(staticCode, expectedTeamID),
              let information = checking.signingInformation(staticCode),
              let identity = self.identity(
                  information: information,
                  kind: .executable,
                  process: nil,
                  executableSHA256: executableSHA256,
                  expectedTeamID: expectedTeamID,
                  executablePath: executablePath
              )
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Inspected executable does not satisfy its Apple-anchored identity."
            )
        }
        try self.validateImmutableCopy(immutableCopy)
        afterAuthentication()
        var after = stat()
        var pathInfo = stat()
        guard fstat(descriptor, &after) == 0,
              lstat(executablePath, &pathInfo) == 0,
              CertificationControllerBuildIdentityResolver.sameFile(before, after),
              CertificationControllerBuildIdentityResolver.sameFile(after, pathInfo)
        else {
            throw CertificationControllerError.runtimeRefusal("Inspected executable changed during authentication.")
        }
        return identity
    }

    static func inspectProcess(
        processIdentifier: Int32,
        expectedStartIdentity: String,
        expectedTeamID: String,
        processStartIdentity: (Int32) -> UInt64? = { SystemIdentityResolver.processStartIdentity($0) },
        dynamicCode: (Int32) -> SecCode? = { processIdentifier in
            let attributes: NSDictionary = [kSecGuestAttributePid: processIdentifier]
            var code: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess else { return nil }
            return code
        },
        liveCodeSignatureHash: (Int32) -> Data? = {
            CertificationControllerBuildIdentityResolver.liveCodeSignatureHash(processIdentifier: $0)
        },
        checking: CertificationRetainedCodeChecking = .securityFramework
    ) throws -> CertificationInspectedCodeIdentity {
        guard processStartIdentity(processIdentifier).map(String.init) == expectedStartIdentity
        else {
            throw CertificationControllerError.runtimeRefusal("Inspected process generation is not running.")
        }
        guard let liveCDHashBefore = liveCodeSignatureHash(processIdentifier),
              let retainedDynamicCode = dynamicCode(processIdentifier),
              let staticCode = CertificationControllerBuildIdentityResolver.staticCode(for: retainedDynamicCode),
              checking.validateDynamic(retainedDynamicCode, staticCode, expectedTeamID),
              let information = checking.signingInformation(staticCode),
              let staticCDHash = CertificationControllerBuildIdentityResolver.codeSignatureData(information),
              liveCDHashBefore == staticCDHash,
              let liveCDHashAfter = liveCodeSignatureHash(processIdentifier),
              liveCDHashAfter == staticCDHash,
              let identity = self.identity(
                  information: information,
                  kind: .process,
                  process: CertificationProcessReceipt(
                      pid: processIdentifier,
                      startIdentity: expectedStartIdentity,
                      codeSignatureHash: CertificationControllerBuildIdentityResolver.hexString(staticCDHash)
                  ),
                  executableSHA256: nil,
                  expectedTeamID: expectedTeamID
              ),
              processStartIdentity(processIdentifier).map(String.init) == expectedStartIdentity
        else {
            throw CertificationControllerError.runtimeRefusal(
                "Inspected process does not satisfy one retained Apple-anchored identity."
            )
        }
        return identity
    }

    static func identity(
        information: [String: Any],
        kind: CertificationCodeIdentitySubjectKind,
        process: CertificationProcessReceipt?,
        executableSHA256: String?,
        expectedTeamID: String,
        executablePath: String? = nil
    ) -> CertificationInspectedCodeIdentity? {
        guard let retainedExecutablePath = CertificationControllerBuildIdentityResolver.mainExecutablePath(information),
              let codeSignatureHash = CertificationControllerBuildIdentityResolver.codeSignatureHash(information),
              let teamID = information[kSecCodeInfoTeamIdentifier as String] as? String,
              teamID == expectedTeamID,
              let sourceCommit = CertificationControllerBuildIdentityResolver.sourceCommit(information)
        else { return nil }
        return CertificationInspectedCodeIdentity(
            kind: kind,
            process: process,
            executablePath: executablePath ?? retainedExecutablePath,
            executableSHA256: executableSHA256,
            codeSignatureHash: codeSignatureHash,
            teamID: teamID,
            sourceCommit: sourceCommit
        )
    }

    private struct ImmutableCopy {
        let directory: URL
        let executable: URL
        let directoryInfo: stat
        let executableInfo: stat
    }

    private static func readExecutable(descriptor: Int32) throws -> Data {
        guard lseek(descriptor, 0, SEEK_SET) == 0 else {
            throw CertificationControllerError.runtimeRefusal("Cannot seek inspected executable.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard !data.isEmpty, data.count <= 512 * 1024 * 1024 else {
            throw CertificationControllerError.runtimeRefusal("Inspected executable bytes are empty or unbounded.")
        }
        return data
    }

    private static func immutableCopy(_ data: Data) throws -> ImmutableCopy {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-code-subject-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        guard chmod(directory.path, S_IRWXU) == 0 else {
            throw CertificationControllerError.unsafePrivatePath("Cannot restrict code-subject directory.")
        }
        let executable = directory.appendingPathComponent("subject", isDirectory: false)
        do {
            try data.write(to: executable, options: .withoutOverwriting)
            guard chmod(executable.path, S_IRUSR) == 0,
                  chmod(directory.path, S_IRUSR | S_IXUSR) == 0
            else {
                throw CertificationControllerError.unsafePrivatePath("Cannot freeze code-subject copy.")
            }
            var directoryInfo = stat()
            var executableInfo = stat()
            guard lstat(directory.path, &directoryInfo) == 0,
                  lstat(executable.path, &executableInfo) == 0
            else {
                throw CertificationControllerError.unsafePrivatePath("Cannot inspect frozen code-subject copy.")
            }
            return ImmutableCopy(
                directory: directory,
                executable: executable,
                directoryInfo: directoryInfo,
                executableInfo: executableInfo
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func validateImmutableCopy(_ copy: ImmutableCopy) throws {
        var directoryInfo = stat()
        var executableInfo = stat()
        guard lstat(copy.directory.path, &directoryInfo) == 0,
              lstat(copy.executable.path, &executableInfo) == 0,
              (directoryInfo.st_mode & S_IFMT) == S_IFDIR,
              directoryInfo.st_uid == geteuid(),
              directoryInfo.st_mode & 0o077 == 0,
              directoryInfo.st_dev == copy.directoryInfo.st_dev,
              directoryInfo.st_ino == copy.directoryInfo.st_ino,
              directoryInfo.st_mtimespec.tv_sec == copy.directoryInfo.st_mtimespec.tv_sec,
              directoryInfo.st_mtimespec.tv_nsec == copy.directoryInfo.st_mtimespec.tv_nsec,
              directoryInfo.st_ctimespec.tv_sec == copy.directoryInfo.st_ctimespec.tv_sec,
              directoryInfo.st_ctimespec.tv_nsec == copy.directoryInfo.st_ctimespec.tv_nsec,
              (executableInfo.st_mode & S_IFMT) == S_IFREG,
              executableInfo.st_uid == geteuid(),
              executableInfo.st_nlink == 1,
              executableInfo.st_mode & 0o077 == 0,
              CertificationControllerBuildIdentityResolver.sameFile(executableInfo, copy.executableInfo),
              try FileManager.default.contentsOfDirectory(atPath: copy.directory.path) == ["subject"]
        else {
            throw CertificationControllerError.runtimeRefusal("Immutable code-subject copy changed during validation.")
        }
    }

    private static func removeImmutableCopy(_ copy: ImmutableCopy) {
        chmod(copy.directory.path, S_IRWXU)
        chmod(copy.executable.path, S_IRUSR | S_IWUSR)
        try? FileManager.default.removeItem(at: copy.directory)
    }
}
