import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

@Suite(.tags(.safe))
struct CleanCommandSimpleTests {
    @Test
    func `Clean command parses all-sessions flag`() throws {
        let command = try CleanCommand.parse(["--all-snapshots"])
        #expect(command.allSnapshots == true)
        #expect(command.olderThan == nil)
        #expect(command.snapshot == nil)
        #expect(command.dryRun == false)
        #expect(command.jsonOutput == false)
    }

    @Test
    func `Clean command parses older-than option`() throws {
        let command = try CleanCommand.parse(["--older-than", "24"])
        #expect(command.allSnapshots == false)
        #expect(command.olderThan == 24)
        #expect(command.snapshot == nil)
    }

    @Test
    func `Clean command parses snapshot option`() throws {
        let command = try CleanCommand.parse(["--snapshot", "12345"])
        #expect(command.allSnapshots == false)
        #expect(command.olderThan == nil)
        #expect(command.snapshot == "12345")
    }

    @Test
    func `Clean command parses dry-run flag`() throws {
        let command = try CleanCommand.parse(["--all-snapshots", "--dry-run"])
        #expect(command.allSnapshots == true)
        #expect(command.dryRun == true)
    }

    @Test
    func `Clean dry-run alone previews default older-than cleanup`() throws {
        let command = try CleanCommand.parse(["--dry-run"])

        #expect(command.allSnapshots == false)
        #expect(command.olderThan == nil)
        #expect(command.snapshot == nil)
        #expect(command.dryRun == true)
        #expect(command.effectiveOlderThan == 24)
    }

    @Test
    func `Clean dry-run keeps explicit cleanup target`() throws {
        let olderThan = try CleanCommand.parse(["--older-than", "48", "--dry-run"])
        let snapshot = try CleanCommand.parse(["--snapshot", "abc", "--dry-run"])

        #expect(olderThan.effectiveOlderThan == 48)
        #expect(snapshot.effectiveOlderThan == nil)
    }

    @Test
    func `Clean command parses json-output flag`() throws {
        let command = try CleanCommand.parse(["--all-snapshots", "--json"])
        #expect(command.allSnapshots == true)
        #expect(command.jsonOutput == true)
    }

    @Test
    func `Clean command parses multiple options`() throws {
        let command = try CleanCommand.parse([
            "--older-than", "48",
            "--dry-run",
            "--json",
        ])
        #expect(command.olderThan == 48)
        #expect(command.dryRun == true)
        #expect(command.jsonOutput == true)
    }

    @Test
    func `Clean result structure`() {
        let snapshotDetails = [
            SnapshotDetail(snapshotId: "123", path: "/tmp/123", size: 1024, creationDate: Date()),
            SnapshotDetail(snapshotId: "456", path: "/tmp/456", size: 2048, creationDate: Date()),
        ]

        let result = SnapshotCleanResult(
            snapshotsRemoved: 2,
            bytesFreed: 3072,
            snapshotDetails: snapshotDetails,
            dryRun: false,
            executionTime: 1.5
        )

        #expect(result.snapshotsRemoved == 2)
        #expect(result.bytesFreed == 3072)
        #expect(result.snapshotDetails.count == 2)
        #expect(result.dryRun == false)
    }

    @Test
    @MainActor
    func `Clean snapshot miss reports disk not found in JSON and text`() async throws {
        let services = TestServicesFactory.makePeekabooServices(files: StubFileService())

        let jsonResult = try await InProcessCommandRunner.run(
            ["clean", "--snapshot", "memory-only", "--json"],
            services: services
        )

        #expect(jsonResult.exitStatus == 0)
        let jsonData = try #require(jsonResult.stdout.data(using: .utf8))
        let json = try #require(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
        let payloadData = try #require(json["data"] as? [String: Any])
        #expect(payloadData["snapshotsRemoved"] as? Int == 0)
        #expect(payloadData["not_found"] as? Bool == true)

        let textResult = try await InProcessCommandRunner.run(
            ["clean", "--snapshot", "memory-only"],
            services: services
        )

        #expect(textResult.exitStatus == 0)
        #expect(textResult.stdout.contains("was not found on disk"))
        #expect(textResult.stdout.contains("Daemon-memory snapshots are not pruned"))
    }

    @Test
    @MainActor
    func `Clean invalid snapshot ID reports validation error`() async throws {
        let services = TestServicesFactory.makePeekabooServices(
            files: StubFileService(cleanSpecificError: .invalidSnapshotID)
        )

        let result = try await InProcessCommandRunner.run(
            ["clean", "--snapshot", "../outside", "--json"],
            services: services
        )

        #expect(result.exitStatus == 1)
        let response = try JSONDecoder().decode(
            JSONResponse.self,
            from: Data(result.combinedOutput.utf8)
        )
        #expect(response.success == false)
        #expect(response.error?.code == ErrorCode.VALIDATION_ERROR.rawValue)
        #expect(response.error?.message == "Invalid snapshot ID: expected one folder name")
    }
}
