import Foundation
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

    private static func expected() -> CertificationExpectedControllerBuild {
        CertificationExpectedControllerBuild(
            sourceCommit: String(repeating: "c", count: 40),
            executablePath: "/private/tmp/peekaboo-certification-controller",
            executableSHA256: String(repeating: "d", count: 64),
            teamID: "FWJYW4S8P8"
        )
    }
}
