import Foundation
import Security
import Testing
@testable import PeekabooCertificationController

@Suite("Certification controller build identity")
struct ControllerBuildIdentityTests {
    private let observed = CertificationControllerBuildReceipt(
        sourceCommit: String(repeating: "c", count: 40),
        executablePath: "/private/tmp/peekaboo-certification-controller",
        executableSHA256: String(repeating: "d", count: 64),
        teamID: "FWJYW4S8P8"
    )

    @Test
    func `expected team builds an Apple anchored requirement`() {
        #expect(
            CertificationControllerBuildIdentityResolver.appleAnchoredRequirementText(
                expectedTeamID: "FWJYW4S8P8"
            ) == #"anchor apple generic and certificate leaf[subject.OU] = "FWJYW4S8P8""#
        )
        for invalid in ["FWJYW4S8P", "fwjyw4s8p8", "FWJYW4S8P\"", "FWJYW4S8P-"] {
            #expect(
                CertificationControllerBuildIdentityResolver.appleAnchoredRequirementText(
                    expectedTeamID: invalid
                ) == nil
            )
        }
    }

    @Test
    func `dynamic and disk checks share one strict anchored requirement`() throws {
        var dynamicCode: SecCode?
        try #require(SecCodeCopySelf([], &dynamicCode) == errSecSuccess)
        let unwrappedDynamicCode = try #require(dynamicCode)
        var staticCode: SecStaticCode?
        try #require(SecCodeCopyStaticCode(unwrappedDynamicCode, [], &staticCode) == errSecSuccess)
        let unwrappedStaticCode = try #require(staticCode)
        var requirementTexts: [String] = []
        var dynamicFlags: SecCSFlags?
        var staticFlags: SecCSFlags?
        let checker = CertificationCodeValidityChecking(
            checkDynamic: { _, flags, requirement in
                dynamicFlags = flags
                requirementTexts.append(Self.requirementText(requirement))
                return errSecSuccess
            },
            checkStatic: { _, flags, requirement in
                staticFlags = flags
                requirementTexts.append(Self.requirementText(requirement))
                return errSecSuccess
            }
        )

        #expect(CertificationControllerBuildIdentityResolver.validateAppleAnchoredCode(
            dynamicCode: unwrappedDynamicCode,
            pathStaticCode: unwrappedStaticCode,
            expectedTeamID: "FWJYW4S8P8",
            checker: checker
        ))
        #expect(dynamicFlags?.rawValue == 0)
        #expect(staticFlags?.contains(SecCSFlags(rawValue: UInt32(kSecCSStrictValidate))) == true)
        #expect(staticFlags?.contains(SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures))) == true)
        #expect(requirementTexts == [
            "anchor apple generic and certificate leaf[subject.OU] = FWJYW4S8P8",
            "anchor apple generic and certificate leaf[subject.OU] = FWJYW4S8P8",
        ])

        let refusingChecker = CertificationCodeValidityChecking(
            checkDynamic: { _, _, _ in errSecSuccess },
            checkStatic: { _, _, _ in errSecCSReqFailed }
        )
        #expect(!CertificationControllerBuildIdentityResolver.validateAppleAnchoredCode(
            dynamicCode: unwrappedDynamicCode,
            pathStaticCode: unwrappedStaticCode,
            expectedTeamID: "FWJYW4S8P8",
            checker: refusingChecker
        ))
    }

    @Test
    func `expected build rejects wrong path hash team and source independently`() throws {
        try Self.expected().requireMatches(self.observed)
        let mismatches = [
            CertificationExpectedControllerBuild(
                sourceCommit: String(repeating: "e", count: 40),
                executablePath: self.observed.executablePath,
                executableSHA256: self.observed.executableSHA256,
                teamID: self.observed.teamID
            ),
            CertificationExpectedControllerBuild(
                sourceCommit: self.observed.sourceCommit,
                executablePath: "/private/tmp/replaced-controller",
                executableSHA256: self.observed.executableSHA256,
                teamID: self.observed.teamID
            ),
            CertificationExpectedControllerBuild(
                sourceCommit: self.observed.sourceCommit,
                executablePath: self.observed.executablePath,
                executableSHA256: String(repeating: "f", count: 64),
                teamID: self.observed.teamID
            ),
            CertificationExpectedControllerBuild(
                sourceCommit: self.observed.sourceCommit,
                executablePath: self.observed.executablePath,
                executableSHA256: self.observed.executableSHA256,
                teamID: "AAAAAAAAAA"
            ),
        ]

        for mismatch in mismatches {
            #expect(throws: CertificationControllerError.self) {
                try mismatch.requireMatches(self.observed)
            }
        }
    }

    @Test
    func `controller and build receipts have closed schemas`() throws {
        let build = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(self.observed)) as? [String: Any]
        )
        #expect(Set(build.keys) == [
            "source_commit", "executable_path", "executable_sha256", "team_id",
        ])

        let process = CertificationProcessReceipt(
            pid: 123,
            startIdentity: "12300",
            codeSignatureHash: String(repeating: "a", count: 40)
        )
        let interval = CertificationIntervalReceipt(startedAtMilliseconds: 100, completedAtMilliseconds: 200)

        let controller = try CertificationControllerReceipt(
            version: 1,
            result: "passed",
            executionNonce: String(repeating: "9", count: 64),
            monitorInstanceID: "019c0000-0000-4000-8000-000000000001",
            controllerID: "controller-a",
            targetID: "target-a",
            controller: process,
            build: self.observed,
            handshake: CertificationHandshakeReceipt(
                socketPath: "/private/tmp/bridge.sock",
                negotiatedVersion: .init(major: 1, minor: 30),
                hostKind: "gui",
                build: "fixture",
                listenerInstanceID: "019c0000-0000-4000-8000-000000000002",
                host: CertificationHostReceipt(
                    process: process,
                    bundleIdentifier: "boo.peekaboo",
                    bundleShortVersion: "4.2.0",
                    bundleVersion: "4.2.0",
                    sourceCommit: String(repeating: "b", count: 40)
                ),
                session: CertificationSessionReceipt(
                    id: "019c0000-0000-4000-8000-000000000003",
                    clientInstanceID: "019c0000-0000-4000-8000-000000000004",
                    maximumRequestCount: 16,
                    initialRemainingClaimCount: 16
                )
            ),
            target: CertificationWindowReceipt(
                target: CertificationControllerPlan.decode(ControllerPlanTests.validPlanData).target
            ),
            interval: interval,
            slots: []
        )
        let controllerObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(controller)) as? [String: Any]
        )
        #expect(Set(controllerObject.keys) == [
            "version", "result", "execution_nonce", "monitor_instance_id", "controller_id", "target_id",
            "controller", "build", "handshake", "target", "interval", "slots",
        ])
        #expect(controllerObject["build"] as? [String: String] == build as? [String: String])
    }

    @Test
    func `nullable receipt fields encode as canonical JSON nulls`() throws {
        var planObject = try #require(
            JSONSerialization.jsonObject(with: ControllerPlanTests.validPlanData) as? [String: Any]
        )
        var targetObject = try #require(planObject["target"] as? [String: Any])
        targetObject["is_minimized"] = NSNull()
        planObject["target"] = targetObject
        let plan = try CertificationControllerPlan.decode(
            JSONSerialization.data(withJSONObject: planObject)
        )
        let process = CertificationProcessReceipt(
            pid: 123,
            startIdentity: "12300",
            codeSignatureHash: String(repeating: "a", count: 40)
        )
        let handshake = CertificationHandshakeReceipt(
            socketPath: "/private/tmp/bridge.sock",
            negotiatedVersion: .init(major: 1, minor: 30),
            hostKind: "gui",
            build: nil,
            listenerInstanceID: "019c0000-0000-4000-8000-000000000002",
            host: CertificationHostReceipt(
                process: process,
                bundleIdentifier: nil,
                bundleShortVersion: nil,
                bundleVersion: nil,
                sourceCommit: String(repeating: "b", count: 40)
            ),
            session: CertificationSessionReceipt(
                id: "019c0000-0000-4000-8000-000000000003",
                clientInstanceID: "019c0000-0000-4000-8000-000000000004",
                maximumRequestCount: 16,
                initialRemainingClaimCount: 16
            )
        )
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode([
                "target": CertificationWindowReceipt(target: plan.target),
            ])) as? [String: Any]
        )
        let target = try #require(encoded["target"] as? [String: Any])
        #expect(Set(target.keys) == ["scope", "pid", "start_identity", "window_id", "bounds", "is_minimized"])
        #expect(target["is_minimized"] is NSNull)

        let handshakeObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(handshake)) as? [String: Any]
        )
        #expect(Set(handshakeObject.keys) == [
            "socket_path", "negotiated_version", "host_kind", "build", "listener_instance_id", "host", "session",
        ])
        #expect(handshakeObject["build"] is NSNull)
        let host = try #require(handshakeObject["host"] as? [String: Any])
        #expect(Set(host.keys) == [
            "process", "bundle_identifier", "bundle_short_version", "bundle_version", "source_commit",
        ])
        #expect(host["bundle_identifier"] is NSNull)
        #expect(host["bundle_short_version"] is NSNull)
        #expect(host["bundle_version"] is NSNull)
    }

    private static func expected() -> CertificationExpectedControllerBuild {
        CertificationExpectedControllerBuild(
            sourceCommit: String(repeating: "c", count: 40),
            executablePath: "/private/tmp/peekaboo-certification-controller",
            executableSHA256: String(repeating: "d", count: 64),
            teamID: "FWJYW4S8P8"
        )
    }

    private static func requirementText(_ requirement: SecRequirement) -> String {
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess else { return "" }
        return text as String? ?? ""
    }
}
