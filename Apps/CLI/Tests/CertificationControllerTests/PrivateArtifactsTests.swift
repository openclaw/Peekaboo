import Darwin
import Foundation
import Testing
@testable import PeekabooCertificationController

@Suite("Certification controller private artifacts")
struct PrivateArtifactsTests {
    @Test
    func `plan reader accepts owner-only file and rejects widened permissions`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(chmod(directory.path, S_IRWXU) == 0)
        let plan = directory.appendingPathComponent("plan.json")
        try ControllerPlanTests.validPlanData.write(to: plan)
        #expect(chmod(plan.path, S_IRUSR | S_IWUSR) == 0)

        #expect(try CertificationPrivateArtifacts.readPlan(at: plan) == ControllerPlanTests.validPlanData)

        #expect(chmod(plan.path, S_IRUSR | S_IWUSR | S_IRGRP) == 0)
        #expect(throws: CertificationControllerError.self) {
            try CertificationPrivateArtifacts.readPlan(at: plan)
        }
    }

    @Test
    func `receipt publication is owner-only and exclusive`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(chmod(directory.path, S_IRWXU) == 0)
        let receipt = directory.appendingPathComponent("receipt.json")

        try CertificationPrivateArtifacts.writeReceipt(Data("{}\n".utf8), to: receipt)
        try CertificationPrivateArtifacts.requireOwnerPrivateRegularFile(receipt)
        #expect(throws: CertificationControllerError.self) {
            try CertificationPrivateArtifacts.writeReceipt(Data("replacement\n".utf8), to: receipt)
        }
        #expect(try Data(contentsOf: receipt) == Data("{}\n".utf8))
    }

    @Test
    func `mutation synchronization marker has one closed run binding`() throws {
        let plan = try CertificationControllerPlan.decode(ControllerPlanTests.validPlanData)
        let marker = CertificationMutationSynchronizationMarker(
            version: 1,
            phase: "mutation-started",
            executionNonce: plan.executionNonce,
            controllerID: plan.controllerID,
            targetID: plan.targetID,
            target: CertificationWindowReceipt(target: plan.target),
            timestampMilliseconds: 1_900_000_000_000
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(marker)) as? [String: Any]
        )
        #expect(Set(object.keys) == [
            "version", "phase", "execution_nonce", "controller_id", "target_id", "target",
            "timestamp_milliseconds",
        ])
        #expect(object["execution_nonce"] as? String == plan.executionNonce)
        #expect(object["controller_id"] as? String == "controller-a")
        #expect(object["target_id"] as? String == "target-a")
    }

    @Test
    func `controller release marker is closed and nonce bound`() throws {
        let nonce = String(repeating: "9", count: 64)
        let marker = CertificationControllerReleaseMarker(
            version: 1,
            executionNonce: nonce,
            phase: .release
        )

        try marker.validate(executionNonce: nonce)
        #expect(throws: CertificationControllerError.self) {
            try marker.validate(executionNonce: String(repeating: "8", count: 64))
        }
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(marker)) as? [String: Any]
        )
        #expect(Set(object.keys) == ["version", "execution_nonce", "phase"])
        #expect(object["phase"] as? String == "release")
    }

    @Test
    func `controller ready receipt and start marker are closed and run bound`() throws {
        let plan = try CertificationControllerPlan.decode(ControllerPlanTests.validPlanData)
        let process = CertificationProcessReceipt(
            pid: 4101,
            startIdentity: "410100",
            codeSignatureHash: String(repeating: "a", count: 40)
        )
        let build = CertificationControllerBuildReceipt(
            sourceCommit: plan.expectedControllerBuild.sourceCommit,
            executablePath: plan.expectedControllerBuild.executablePath,
            executableSHA256: plan.expectedControllerBuild.executableSHA256,
            teamID: plan.expectedControllerBuild.teamID
        )
        let ready = CertificationControllerReadyReceipt(
            version: 1,
            executionNonce: plan.executionNonce,
            controllerID: plan.controllerID,
            targetID: plan.targetID,
            controller: process,
            build: build,
            readyAtMilliseconds: 100
        )
        let start = CertificationControllerStartMarker(
            version: 1,
            executionNonce: plan.executionNonce,
            controllerID: plan.controllerID,
            phase: .start
        )

        try start.validate(executionNonce: plan.executionNonce, controllerID: plan.controllerID)
        #expect(throws: CertificationControllerError.self) {
            try start.validate(executionNonce: plan.executionNonce, controllerID: "controller-b")
        }
        #expect(try Self.keys(ready) == [
            "version", "execution_nonce", "controller_id", "target_id", "controller", "build",
            "ready_at_milliseconds",
        ])
        #expect(try Self.keys(start) == ["version", "execution_nonce", "controller_id", "phase"])
    }

    @Test
    func `controller lifecycle gate accepts an owner-private exact start marker`() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(chmod(directory.path, S_IRWXU) == 0)
        let nonce = String(repeating: "9", count: 64)
        let marker = CertificationControllerStartMarker(
            version: 1,
            executionNonce: nonce,
            controllerID: "controller-a",
            phase: .start
        )
        let encoder = JSONEncoder()
        var data = try encoder.encode(marker)
        data.append(0x0A)
        let url = directory.appendingPathComponent("start.json")
        try CertificationPrivateArtifacts.writeReceipt(data, to: url)

        try await CertificationControllerLifecycleGate.waitForStart(
            at: url,
            executionNonce: nonce,
            controllerID: "controller-a"
        )
    }

    @Test
    func `final bounds barrier is closed and bound to the controller generation`() async throws {
        let plan = try CertificationControllerPlan.decode(ControllerPlanTests.validPlanData)
        let process = CertificationProcessReceipt(
            pid: 4101,
            startIdentity: "410100",
            codeSignatureHash: String(repeating: "a", count: 40)
        )
        let ready = CertificationFinalBoundsReadyReceipt(
            version: 1,
            executionNonce: plan.executionNonce,
            monitorInstanceID: plan.monitorInstanceID,
            controllerID: plan.controllerID,
            targetID: plan.targetID,
            controller: process,
            completedSlotIDs: Array(plan.slots.dropLast().map(\.id)),
            readyAtMilliseconds: 1_900_000_000_000
        )
        #expect(try Self.keys(ready) == [
            "version", "execution_nonce", "monitor_instance_id", "controller_id", "target_id",
            "controller", "completed_slot_ids", "ready_at_milliseconds",
        ])

        let marker = CertificationFinalBoundsStartMarker(
            version: 1,
            executionNonce: plan.executionNonce,
            monitorInstanceID: plan.monitorInstanceID,
            controllerID: plan.controllerID,
            phase: .finalBounds
        )
        #expect(throws: CertificationControllerError.self) {
            try marker.validate(
                executionNonce: plan.executionNonce,
                monitorInstanceID: plan.monitorInstanceID,
                controllerID: "controller-b"
            )
        }

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(chmod(directory.path, S_IRWXU) == 0)
        let encoder = JSONEncoder()
        var data = try encoder.encode(marker)
        data.append(0x0A)
        let url = directory.appendingPathComponent("final-bounds-start.json")
        try CertificationPrivateArtifacts.writeReceipt(data, to: url)

        try await CertificationControllerLifecycleGate.waitForFinalBoundsStart(
            at: url,
            executionNonce: plan.executionNonce,
            monitorInstanceID: plan.monitorInstanceID,
            controllerID: plan.controllerID
        )
    }

    private static func keys(_ value: some Encodable) throws -> Set<String> {
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        )
        return Set(object.keys)
    }
}
