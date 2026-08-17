import Foundation
import PeekabooAutomationKit
import Security
import Testing
@testable import PeekabooCertificationController

@Suite("Certification retained code identity")
struct CodeIdentityRunnerTests {
    private static let teamID = "FWJYW4S8P8"
    private static let sourceCommit = String(repeating: "a", count: 40)
    private static let codeSignatureHash = String(repeating: "b", count: 40)

    @Test
    func `private identity plan has one closed subject shape`() throws {
        let executable = Self.planObject(subject: [
            "kind": "executable",
            "executable_path": "/private/tmp/subject",
            "expected_team_id": Self.teamID,
        ])
        let plan = try CertificationCodeIdentityPlan.decode(JSONSerialization.data(withJSONObject: executable))
        #expect(plan.subject.kind == .executable)
        #expect(plan.subject.executablePath == "/private/tmp/subject")

        var unknown = executable
        unknown["success"] = true
        #expect(throws: CertificationControllerError.self) {
            try CertificationCodeIdentityPlan.decode(JSONSerialization.data(withJSONObject: unknown))
        }
        var mixed = executable
        var subject = try #require(mixed["subject"] as? [String: Any])
        subject["process_identifier"] = 42
        mixed["subject"] = subject
        #expect(throws: CertificationControllerError.self) {
            try CertificationCodeIdentityPlan.decode(JSONSerialization.data(withJSONObject: mixed))
        }
    }

    @Test
    func `disk authentication reads identity from the validated retained handle and rejects path replacement`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try URL(fileURLWithPath: #require(
            CertificationControllerBuildIdentityResolver.canonicalPath(CommandLine.arguments[0])
        ))
        let target = directory.appendingPathComponent("subject")
        let replacement = directory.appendingPathComponent("replacement")
        try FileManager.default.copyItem(at: source, to: target)
        try FileManager.default.copyItem(at: source, to: replacement)
        var validatedHandle: UnsafeMutableRawPointer?
        var informationHandle: UnsafeMutableRawPointer?
        let checking = CertificationRetainedCodeChecking(
            validateDynamic: { _, _, _ in false },
            validateStatic: { code, _ in
                validatedHandle = Unmanaged.passUnretained(code).toOpaque()
                return true
            },
            signingInformation: { code in
                informationHandle = Unmanaged.passUnretained(code).toOpaque()
                return Self.information(executablePath: target.path)
            }
        )

        #expect(throws: CertificationControllerError.self) {
            try CertificationCodeIdentityRunner.inspectExecutable(
                path: target.path,
                expectedTeamID: Self.teamID,
                checking: checking,
                afterAuthentication: {
                    try? FileManager.default.removeItem(at: target)
                    try? FileManager.default.moveItem(at: replacement, to: target)
                }
            )
        }
        #expect(validatedHandle != nil)
        #expect(validatedHandle == informationHandle)
    }

    @Test
    func `process authentication reads identity from one retained handle and rejects generation drift`() throws {
        var dynamicCode: SecCode?
        try #require(SecCodeCopySelf([], &dynamicCode) == errSecSuccess)
        let retainedDynamicCode = try #require(dynamicCode)
        let pid = ProcessInfo.processInfo.processIdentifier
        let startIdentity = try #require(SystemIdentityResolver.processStartIdentity(pid))
        let executablePath = try #require(
            CertificationControllerBuildIdentityResolver.canonicalPath(CommandLine.arguments[0])
        )
        var startIdentities = [startIdentity, startIdentity + 1]
        var validatedDynamicHandle: UnsafeMutableRawPointer?
        var validatedStaticHandle: UnsafeMutableRawPointer?
        var informationHandle: UnsafeMutableRawPointer?
        let checking = CertificationRetainedCodeChecking(
            validateDynamic: { dynamic, code, _ in
                validatedDynamicHandle = Unmanaged.passUnretained(dynamic).toOpaque()
                validatedStaticHandle = Unmanaged.passUnretained(code).toOpaque()
                return true
            },
            validateStatic: { _, _ in false },
            signingInformation: { code in
                informationHandle = Unmanaged.passUnretained(code).toOpaque()
                return Self.information(executablePath: executablePath)
            }
        )

        #expect(throws: CertificationControllerError.self) {
            try CertificationCodeIdentityRunner.inspectProcess(
                processIdentifier: pid,
                expectedStartIdentity: String(startIdentity),
                expectedTeamID: Self.teamID,
                processStartIdentity: { _ in startIdentities.removeFirst() },
                dynamicCode: { _ in retainedDynamicCode },
                liveCodeSignatureHash: { _ in Data(repeating: 0xBB, count: 20) },
                checking: checking
            )
        }
        #expect(validatedDynamicHandle == Unmanaged.passUnretained(retainedDynamicCode).toOpaque())
        #expect(validatedStaticHandle != nil)
        #expect(validatedStaticHandle == informationHandle)
    }

    @Test
    func `process authentication rejects same PID exec CDHash drift`() throws {
        var dynamicCode: SecCode?
        try #require(SecCodeCopySelf([], &dynamicCode) == errSecSuccess)
        let retainedDynamicCode = try #require(dynamicCode)
        let pid = ProcessInfo.processInfo.processIdentifier
        let startIdentity = try #require(SystemIdentityResolver.processStartIdentity(pid))
        let executablePath = try #require(
            CertificationControllerBuildIdentityResolver.canonicalPath(CommandLine.arguments[0])
        )
        var liveHashes = [Data(repeating: 0xBB, count: 20), Data(repeating: 0xCC, count: 20)]
        let checking = CertificationRetainedCodeChecking(
            validateDynamic: { _, _, _ in true },
            validateStatic: { _, _ in false },
            signingInformation: { _ in Self.information(executablePath: executablePath) }
        )

        #expect(throws: CertificationControllerError.self) {
            try CertificationCodeIdentityRunner.inspectProcess(
                processIdentifier: pid,
                expectedStartIdentity: String(startIdentity),
                expectedTeamID: Self.teamID,
                processStartIdentity: { _ in startIdentity },
                dynamicCode: { _ in retainedDynamicCode },
                liveCodeSignatureHash: { _ in liveHashes.removeFirst() },
                checking: checking
            )
        }
        #expect(liveHashes.isEmpty)
    }

    @Test
    func `identity receipt encodes canonical nulls for unavailable fields`() throws {
        let receipt = CertificationCodeIdentityReceipt(
            version: 1,
            inspectorProcess: .init(
                pid: 1,
                startIdentity: "1",
                codeSignatureHash: Self.codeSignatureHash
            ),
            inspectorBuild: .init(
                sourceCommit: Self.sourceCommit,
                executablePath: "/private/tmp/inspector",
                executableSHA256: String(repeating: "c", count: 64),
                teamID: Self.teamID
            ),
            subject: .init(
                kind: .executable,
                process: nil,
                executablePath: "/private/tmp/subject",
                executableSHA256: String(repeating: "d", count: 64),
                codeSignatureHash: Self.codeSignatureHash,
                teamID: Self.teamID,
                sourceCommit: Self.sourceCommit
            )
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any]
        )
        #expect(Set(object.keys) == ["version", "inspector_process", "inspector_build", "subject"])
        let subject = try #require(object["subject"] as? [String: Any])
        #expect(Set(subject.keys) == [
            "kind", "process", "executable_path", "executable_sha256", "code_signature_hash", "team_id",
            "source_commit",
        ])
        #expect(subject["process"] is NSNull)
    }

    private static func planObject(subject: [String: Any]) -> [String: Any] {
        [
            "version": 1,
            "execution_nonce": String(repeating: "e", count: 64),
            "expected_inspector_build": [
                "source_commit": self.sourceCommit,
                "executable_path": "/private/tmp/inspector",
                "executable_sha256": String(repeating: "c", count: 64),
                "team_id": self.teamID,
            ],
            "subject": subject,
            "output_path": "/private/tmp/identity.json",
            "release_path": "/private/tmp/identity-release.json",
        ]
    }

    private static func information(executablePath: String) -> [String: Any] {
        [
            kSecCodeInfoMainExecutable as String: URL(fileURLWithPath: executablePath),
            kSecCodeInfoUnique as String: Data(repeating: 0xBB, count: 20),
            kSecCodeInfoTeamIdentifier as String: self.teamID,
            kSecCodeInfoPList as String: ["PeekabooSourceCommit": self.sourceCommit],
        ]
    }
}
