import CryptoKit
import Darwin
import Foundation
import Testing
@testable import PeekabooBridge

@Suite("Bridge Agent execution trace contract")
// swiftlint:disable:next type_body_length
struct AgentExecutionTraceContractTests {
    @Test
    func `Protocol and allowlists fail closed before 1.31`() {
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 30)
        #expect(PeekabooBridgeConstants.protocolVersion >= PeekabooBridgeConstants.agentExecutionTraceVersion)
        #expect(!PeekabooBridgeOperation.compatible([.agentExecutionTrace], with: previous)
            .contains(.agentExecutionTrace))
        #expect(PeekabooBridgeOperation.compatible(
            [.agentExecutionTrace],
            with: PeekabooBridgeConstants.agentExecutionTraceVersion).contains(.agentExecutionTrace))
        #expect(PeekabooBridgeOperation.remoteDefaultAllowlist.contains(.agentExecutionTrace))
        #expect(!PeekabooBridgeOperation.embeddedDefaultAllowlist.contains(.agentExecutionTrace))
    }

    @Test
    func `Aggregate process dispatch stays retry unsafe without owning the outer desktop lane`() {
        let request = PeekabooBridgeRequest.agentExecutionTrace(Self.request())
        let plan = PeekabooBridgeOperationResultSemantics.semanticPlan(for: request)
        #expect(request.minimumNegotiatedProtocolVersion == PeekabooBridgeConstants.agentExecutionTraceVersion)
        #expect(request.mayMutateDesktop)
        #expect(request.bypassesOuterDesktopMutationLane)
        #expect(plan.contract.targetPolicy == .responseResolved)
        guard case let .externalProcessDispatch(delivery) = plan.contract.completion else {
            Issue.record("Expected dedicated external-process aggregate completion")
            return
        }
        #expect(delivery.mode == .background)
    }

    @Test
    func `Wire request accepts no executable argv environment or caller-authored trace`() throws {
        let data = try JSONEncoder.peekabooBridgeEncoder().encode(Self.request())
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == [
            "task", "maxSteps", "runRootPath", "coordinationReceiptPath", "acknowledgementPath",
            "startTimeoutMilliseconds", "runTimeoutMilliseconds",
        ])
        #expect(object["executable"] == nil)
        #expect(object["arguments"] == nil)
        #expect(object["environment"] == nil)
        #expect(object["executionTrace"] == nil)
    }

    @Test
    func `Canonical task ceiling agrees across Bridge model and real spawn`() throws {
        let maximumTask = String(
            repeating: "x",
            count: PeekabooBridgeAgentExecutionPolicy.maximumTaskBytes)
        let runRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: runRoot) }

        let maximumRequest = Self.request(task: maximumTask, runRootPath: runRoot.path)
        var paths: PeekabooBridgeAgentExecutionPaths? = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(
            maximumRequest)
        #expect(!FileManager.default.fileExists(atPath: paths?.operationReceiptDirectory.path ?? ""))
        paths = nil
        let maximumFixture = try Self.fixture(task: maximumTask, runRootPath: runRoot.path)
        try maximumFixture.response.validate(request: maximumFixture.request)

        let oversizedTask = maximumTask + "x"
        let oversizedRequest = Self.request(task: oversizedTask, runRootPath: runRoot.path)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            _ = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(oversizedRequest)
        }
        let oversizedFixture = try Self.fixture(task: oversizedTask)
        #expect(throws: PeekabooBridgeAgentExecutionResponseValidationError.self) {
            try oversizedFixture.response.validate(request: oversizedFixture.request)
        }

        // Exercise the accepted task boundary with a substantial closed environment through
        // Darwin's actual posix_spawn path. This must remain well below E2BIG.
        let arguments = PeekabooBridgeAgentExecutionCoding.arguments(
            task: maximumTask,
            maxSteps: maximumRequest.maxSteps,
            socketPath: "/private/tmp/peekaboo-agent-task-limit.sock")
        let pipes = try PeekabooBridgeAgentExecutionPipes()
        let gate = try Self.releaseGate(for: pipes)
        defer {
            gate.closeAll()
            pipes.closeAll()
        }
        let processIdentifier = try PeekabooBridgeAgentExecutionSpawn.spawnSuspended(
            executablePath: "/usr/bin/true",
            arguments: arguments,
            environment: [
                "PATH": "/usr/bin:/bin",
                "X_AI_API_KEY": String(repeating: "k", count: 128 * 1024),
            ],
            pipes: pipes,
            releaseGate: gate)
        gate.closeAll()
        PeekabooBridgeAgentExecutionProcessWait.killSuspendedAndReap(processIdentifier)
        pipes.closeAll()
        Self.expectReaped(processIdentifier)

        try Self.expectLaunchPreflightRejection(
            arguments: arguments,
            environment: [
                "PATH": "/usr/bin:/bin",
                "X_AI_API_KEY": String(
                    repeating: "k",
                    count: PeekabooBridgeAgentExecutionPolicy.maximumArgumentEnvironmentBytes),
            ])
        try Self.expectLaunchPreflightRejection(
            arguments: ["visible\0hidden"],
            environment: ["PATH": "/usr/bin:/bin"])
        try Self.expectLaunchPreflightRejection(
            arguments: Array(
                repeating: "",
                count: PeekabooBridgeAgentExecutionPolicy.maximumArgumentEnvironmentBytes /
                    MemoryLayout<UnsafePointer<CChar>?>.stride),
            environment: ["PATH": "/usr/bin:/bin"])
    }

    @Test
    func `Preparation locks exact run root without creating receipts and releases for retry`() throws {
        let runRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: runRoot) }
        let request = Self.request(runRootPath: runRoot.path)

        try Self.expectExclusivePreparationThenReturn(request)
        let retry = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(request)
        #expect(!FileManager.default.fileExists(atPath: retry.operationReceiptDirectory.path))
    }

    @Test
    func `Acknowledged attempt provisions and revalidates exact receipt directory late`() throws {
        let runRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: runRoot) }
        let paths = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(
            Self.request(runRootPath: runRoot.path))

        #expect(!FileManager.default.fileExists(atPath: paths.operationReceiptDirectory.path))
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try paths.provisionOperationReceiptDirectoryBeforeRelease()
        }
        #expect(!FileManager.default.fileExists(atPath: paths.operationReceiptDirectory.path))

        try Self.publishCoordinationArtifacts(for: paths)
        try paths.provisionOperationReceiptDirectoryBeforeRelease()
        try paths.revalidateBeforeRelease()
        var info = stat()
        #expect(lstat(paths.operationReceiptDirectory.path, &info) == 0)
        #expect((info.st_mode & S_IFMT) == S_IFDIR)
        #expect((info.st_mode & 0o777) == 0o700)
        #expect(info.st_uid == geteuid())
    }

    @Test
    func `Late provision refuses replacement nonempty symlink and publish race without deletion`() throws {
        let replacementRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: replacementRoot) }
        let replacement = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(
            Self.request(runRootPath: replacementRoot.path))
        try Self.publishCoordinationArtifacts(for: replacement)
        try FileManager.default.createDirectory(
            at: replacement.operationReceiptDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try replacement.provisionOperationReceiptDirectoryBeforeRelease()
        }
        #expect(FileManager.default.fileExists(atPath: replacement.operationReceiptDirectory.path))

        let nonemptyRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: nonemptyRoot) }
        let nonempty = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(
            Self.request(runRootPath: nonemptyRoot.path))
        try Self.publishCoordinationArtifacts(for: nonempty)
        try FileManager.default.createDirectory(
            at: nonempty.operationReceiptDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let retained = nonempty.operationReceiptDirectory.appendingPathComponent("retained.json")
        try Data("retained".utf8).write(to: retained)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try nonempty.provisionOperationReceiptDirectoryBeforeRelease()
        }
        #expect(FileManager.default.fileExists(atPath: retained.path))

        let symlinkRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: symlinkRoot) }
        let symlink = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(
            Self.request(runRootPath: symlinkRoot.path))
        try Self.publishCoordinationArtifacts(for: symlink)
        let symlinkTarget = symlinkRoot.appendingPathComponent("foreign-target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: symlinkTarget,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(
            at: symlink.operationReceiptDirectory,
            withDestinationURL: symlinkTarget)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try symlink.provisionOperationReceiptDirectoryBeforeRelease()
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: symlink.operationReceiptDirectory.path) == symlinkTarget.path)

        let racedRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: racedRoot) }
        let raced = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(
            Self.request(runRootPath: racedRoot.path))
        try Self.publishCoordinationArtifacts(for: raced)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try raced.provisionOperationReceiptDirectoryBeforeRelease { _ in
                try FileManager.default.createDirectory(
                    at: raced.operationReceiptDirectory,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
            }
        }
        #expect(FileManager.default.fileExists(atPath: raced.operationReceiptDirectory.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: racedRoot.path)
            .contains(where: { $0.hasPrefix(".agent-operation-receipts.") && $0.hasSuffix(".staging") }))

        let stagingSubstitutionRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: stagingSubstitutionRoot) }
        let stagingSubstitution = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(
            Self.request(runRootPath: stagingSubstitutionRoot.path))
        try Self.publishCoordinationArtifacts(for: stagingSubstitution)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try stagingSubstitution.provisionOperationReceiptDirectoryBeforeRelease { stagingBasename in
                let staging = stagingSubstitutionRoot.appendingPathComponent(stagingBasename, isDirectory: true)
                try FileManager.default.removeItem(at: staging)
                try FileManager.default.createDirectory(
                    at: staging,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                try Data("foreign-staging".utf8).write(
                    to: staging.appendingPathComponent("foreign-staging.json"))
            }
        }
        #expect(FileManager.default.fileExists(
            atPath: stagingSubstitution.operationReceiptDirectory
                .appendingPathComponent("foreign-staging.json").path))

        let stagingContaminationRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: stagingContaminationRoot) }
        let stagingContamination = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(
            Self.request(runRootPath: stagingContaminationRoot.path))
        try Self.publishCoordinationArtifacts(for: stagingContamination)
        var contaminatedStaging: URL?
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try stagingContamination.provisionOperationReceiptDirectoryBeforeRelease { stagingBasename in
                let staging = stagingContaminationRoot.appendingPathComponent(stagingBasename, isDirectory: true)
                contaminatedStaging = staging
                try Data("foreign-same-inode".utf8).write(
                    to: staging.appendingPathComponent("foreign-same-inode.json"))
            }
        }
        let retainedStaging = try #require(contaminatedStaging)
        #expect(FileManager.default.fileExists(
            atPath: retainedStaging.appendingPathComponent("foreign-same-inode.json").path))
        #expect(!FileManager.default.fileExists(atPath: stagingContamination.operationReceiptDirectory.path))

        let substitutedRoot = try Self.makePrivateRunRoot()
        defer { try? FileManager.default.removeItem(at: substitutedRoot) }
        let substituted = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(
            Self.request(runRootPath: substitutedRoot.path))
        try Self.publishCoordinationArtifacts(for: substituted)
        try substituted.provisionOperationReceiptDirectoryBeforeRelease()
        try FileManager.default.removeItem(at: substituted.operationReceiptDirectory)
        try FileManager.default.createDirectory(
            at: substituted.operationReceiptDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let foreign = substituted.operationReceiptDirectory.appendingPathComponent("foreign.json")
        try Data("foreign".utf8).write(to: foreign)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try substituted.revalidateBeforeRelease()
        }
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test
    func `Closed environment preserves canonical and alias Grok keys in signed policy`() throws {
        let environment = try PeekabooBridgeAgentExecutionEnvironment.make(
            operationReceiptDirectoryPath: "/private/tmp/agent-operation-receipts",
            releaseGateDescriptor: 198,
            lockdownReadinessDescriptor: 199,
            releaseChallenge: String(repeating: "a", count: 64),
            source: [
                "X_AI_API_KEY": "canonical-placeholder",
                "XAI_API_KEY": "xai-alias-placeholder",
                "GROK_API_KEY": "grok-alias-placeholder",
            ])

        #expect(environment.policyVersion == 3)
        #expect(environment.values["X_AI_API_KEY"] == "canonical-placeholder")
        #expect(environment.values["XAI_API_KEY"] == "xai-alias-placeholder")
        #expect(environment.values["GROK_API_KEY"] == "grok-alias-placeholder")
        #expect(environment.keys.contains("X_AI_API_KEY"))
        #expect(environment.keys.contains("XAI_API_KEY"))
        #expect(environment.keys.contains("GROK_API_KEY"))

        let fixture = try Self.fixture()
        try fixture.response.validate(request: fixture.request)
        #expect(fixture.response.environmentPolicyVersion == environment.policyVersion)
        #expect(fixture.response.environmentKeys.contains("X_AI_API_KEY"))
    }

    @Test
    func `CString allocation failure cannot truncate mandatory closed environment`() throws {
        let strings = [
            "PATH=/usr/bin:/bin",
            "PEEKABOO_AGENT_EXECUTION_GATE_FD=198",
            "PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT=0",
        ]
        var duplicated: [String] = []
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            _ = try PeekabooBridgeAgentExecutionCStringVector.make(strings) { string in
                duplicated.append(string)
                guard string != "PEEKABOO_AGENT_EXECUTION_GATE_FD=198" else { return nil }
                return strdup(string)
            }
        }
        #expect(duplicated == Array(strings.prefix(2)))

        let complete = try PeekabooBridgeAgentExecutionCStringVector.make(strings)
        defer { PeekabooBridgeAgentExecutionCStringVector.free(complete) }
        #expect(complete.count == strings.count + 1)
        #expect(complete.dropLast().allSatisfy { $0 != nil })
        #expect(complete[complete.count - 1] == nil)
    }

    @Test
    func `Terminal response rederives exact request coordination output and exit commitments`() throws {
        let fixture = try Self.fixture()
        try fixture.response.validate(request: fixture.request)
        #expect(fixture.response.arguments == [
            "agent", "run", fixture.request.task, "--no-cache", "--max-steps", "40",
            "--bridge-socket", fixture.response.bridgeSocketPath, "--json",
        ])
        #expect(fixture.response.backgroundOnly)
        #expect(!fixture.response.allowForeground)
        #expect(!fixture.response.shellAvailable)
        #expect(fixture.response.executionTrace == .object([
            "entries": .array([]),
            "totalCallCount": .int(0),
            "truncated": .bool(false),
        ]))

        // Output evidence is independent from process cleanup. A complete valid trace must
        // remain deliverable when a deadline or cancellation owns the terminal disposition.
        let forcedAfterOutput = Self.copy(fixture.response, processDisposition: .timedOut)
        try forcedAfterOutput.validate(request: fixture.request)

        let ungated = Self.copy(
            fixture.response,
            environmentKeys: ["PATH", "PEEKABOO_OPERATION_RECEIPT_DIRECTORY"])
        #expect(throws: PeekabooBridgeAgentExecutionResponseValidationError.self) {
            try ungated.validate(request: fixture.request)
        }
    }

    @Test
    func `Canonical response rejects child CDHash substitution`() throws {
        let substitutedChildIdentity = try Self.fixture(
            childCodeSignatureHash: String(repeating: "a", count: 40))
        #expect(throws: PeekabooBridgeAgentExecutionResponseValidationError.self) {
            try substitutedChildIdentity.response.validate(request: substitutedChildIdentity.request)
        }
    }

    @Test
    func `Task response and acknowledgement substitution fail closed`() throws {
        let fixture = try Self.fixture()
        let differentRequest = PeekabooBridgeAgentExecutionTraceRequest(
            task: "different task",
            maxSteps: fixture.request.maxSteps,
            runRootPath: fixture.request.runRootPath,
            coordinationReceiptPath: fixture.request.coordinationReceiptPath,
            acknowledgementPath: fixture.request.acknowledgementPath,
            startTimeoutMilliseconds: fixture.request.startTimeoutMilliseconds,
            runTimeoutMilliseconds: fixture.request.runTimeoutMilliseconds)
        #expect(throws: PeekabooBridgeAgentExecutionResponseValidationError.self) {
            try fixture.response.validate(request: differentRequest)
        }

        var malformed = try #require(JSONSerialization.jsonObject(
            with: fixture.response.acknowledgement.bytes) as? [String: Any])
        malformed["challenge"] = String(repeating: "f", count: 64)
        let forgedBytes = try JSONSerialization.data(withJSONObject: malformed, options: [.sortedKeys])
        let forged = Self.copy(
            fixture.response,
            acknowledgement: .init(bytes: forgedBytes))
        #expect(throws: PeekabooBridgeAgentExecutionResponseValidationError.self) {
            try forged.validate(request: fixture.request)
        }

        let substitutedStdout = Data(
            #"{"success":true,"result":{"executionTrace":{"entries":[],"totalCallCount":1,"truncated":true}}}"#
                .utf8)
        let substituted = Self.copy(
            fixture.response,
            stdout: .init(bytes: substitutedStdout))
        #expect(throws: PeekabooBridgeAgentExecutionResponseValidationError.self) {
            try substituted.validate(request: fixture.request)
        }
    }

    @Test
    func `Forged and early acknowledgements are rejected before release`() throws {
        let fixture = try Self.fixture()
        let receipt = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeAgentExecutionCoordinationReceipt.self,
            from: fixture.response.coordinationReceipt.bytes)
        let valid = try JSONDecoder.peekabooBridgeDecoder().decode(
            PeekabooBridgeAgentExecutionAcknowledgement.self,
            from: fixture.response.acknowledgement.bytes)
        let forged = PeekabooBridgeAgentExecutionAcknowledgement(
            challenge: String(repeating: "f", count: 64),
            coordinationReceiptSHA256: valid.coordinationReceiptSHA256,
            requestingPeer: valid.requestingPeer,
            process: valid.process,
            taskSHA256: valid.taskSHA256,
            argumentsSHA256: valid.argumentsSHA256,
            environmentSHA256: valid.environmentSHA256,
            acknowledgedAt: valid.acknowledgedAt)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try PeekabooBridgeAgentExecutionAcknowledgementReader.validate(
                forged,
                bytes: Self.canonical(forged),
                receipt: receipt,
                receiptBytes: fixture.response.coordinationReceipt.bytes)
        }

        let early = PeekabooBridgeAgentExecutionAcknowledgement(
            challenge: valid.challenge,
            coordinationReceiptSHA256: valid.coordinationReceiptSHA256,
            requestingPeer: valid.requestingPeer,
            process: valid.process,
            taskSHA256: valid.taskSHA256,
            argumentsSHA256: valid.argumentsSHA256,
            environmentSHA256: valid.environmentSHA256,
            acknowledgedAt: receipt.publishedAt - 1)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try PeekabooBridgeAgentExecutionAcknowledgementReader.validate(
                early,
                bytes: Self.canonical(early),
                receipt: receipt,
                receiptBytes: fixture.response.coordinationReceipt.bytes)
        }
    }

    @Test
    func `Cancellation reaps the exact child without a zombie`() async throws {
        let execution = try Self.spawnSuspended(executable: "/bin/sleep", arguments: ["30"])
        let wait = Task {
            await PeekabooBridgeAgentExecutionProcessWait.wait(
                execution.pid,
                processCustody: execution.processCustody,
                timeoutMilliseconds: 30000,
                pipeControl: execution.control,
                terminationGraceMilliseconds: 50)
        }
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        try await Task.sleep(for: .milliseconds(30))
        wait.cancel()
        let terminal = await wait.value
        let captures = await Self.finish(execution)
        #expect(terminal.disposition == .cancelled)
        #expect(captures.stdout.readErrorCode == nil)
        #expect(captures.stderr.readErrorCode == nil)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Timeout owns TERM KILL and waitpid cleanup`() async throws {
        let execution = try Self.spawnSuspended(executable: "/bin/sleep", arguments: ["30"])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            execution.pid,
            processCustody: execution.processCustody,
            timeoutMilliseconds: 30,
            pipeControl: execution.control,
            terminationGraceMilliseconds: 50)
        _ = await Self.finish(execution)
        #expect(terminal.disposition == .timedOut)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Early SIGCONT cannot cross the anonymous release gate`() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-gate-\(UUID().uuidString).marker")
        defer { try? FileManager.default.removeItem(at: marker) }
        let challenge = String(repeating: "a", count: 64)
        let pipes = try PeekabooBridgeAgentExecutionPipes()
        let gate = try Self.releaseGate(for: pipes)
        let script = """
        token=$(/bin/dd bs=64 count=1 2>/dev/null <&\(gate.childDescriptor))
        [ "$token" = "\(challenge)" ] || exit 71
        : > "\(marker.path)"
        """
        let pid = try PeekabooBridgeAgentExecutionSpawn.spawnSuspended(
            executablePath: "/bin/sh",
            arguments: ["-c", script],
            environment: ["PATH": "/usr/bin:/bin"],
            pipes: pipes,
            releaseGate: gate)
        let execution = try Self.capture(pid: pid, pipes: pipes)
        #expect(getpgid(pid) == pid)
        #expect(getsid(pid) == pid)
        #expect(Darwin.kill(pid, SIGCONT) == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        try gate.release(challenge: challenge)
        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            pid,
            processCustody: execution.processCustody,
            timeoutMilliseconds: 2000,
            pipeControl: execution.control,
            terminationGraceMilliseconds: 50)
        _ = await Self.finish(execution)

        #expect(terminal.disposition == .exited)
        #expect(terminal.exitCode == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
        Self.expectReaped(pid)
    }

    @Test
    func `Lockdown readiness requires the exact challenge and EOF`() async throws {
        let challenge = String(repeating: "f", count: 64)
        let successPipes = try PeekabooBridgeAgentExecutionPipes()
        let success = try Self.releaseGate(for: successPipes)
        defer { success.closeAll(); successPipes.closeAll() }
        let challengeBytes = Data(challenge.utf8)
        #expect(challengeBytes.withUnsafeBytes {
            Darwin.write(success.readinessWriteDescriptor, $0.baseAddress, $0.count)
        } == 64)
        success.closeParentReadinessWrite()
        try await success.waitForLockdown(
            challenge: challenge,
            deadline: ContinuousClock.now.advanced(by: .seconds(1)))

        let missingPipes = try PeekabooBridgeAgentExecutionPipes()
        let missing = try Self.releaseGate(for: missingPipes)
        defer { missing.closeAll(); missingPipes.closeAll() }
        missing.closeParentReadinessWrite()
        await #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try await missing.waitForLockdown(
                challenge: challenge,
                deadline: ContinuousClock.now.advanced(by: .seconds(1)))
        }

        let trailingPipes = try PeekabooBridgeAgentExecutionPipes()
        let trailing = try Self.releaseGate(for: trailingPipes)
        defer { trailing.closeAll(); trailingPipes.closeAll() }
        let invalid = Data((challenge + "x").utf8)
        #expect(invalid.withUnsafeBytes {
            Darwin.write(trailing.readinessWriteDescriptor, $0.baseAddress, $0.count)
        } == 65)
        trailing.closeParentReadinessWrite()
        await #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try await trailing.waitForLockdown(
                challenge: challenge,
                deadline: ContinuousClock.now.advanced(by: .seconds(1)))
        }
    }

    @Test
    func `Dead child makes release fail with EPIPE without killing the host`() async throws {
        let challenge = String(repeating: "b", count: 64)
        let pipes = try PeekabooBridgeAgentExecutionPipes()
        let gate = try Self.releaseGate(for: pipes)
        let pid = try PeekabooBridgeAgentExecutionSpawn.spawnSuspended(
            executablePath: "/usr/bin/false",
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            pipes: pipes,
            releaseGate: gate)
        let execution = try Self.capture(pid: pid, pipes: pipes)
        #expect(Darwin.kill(pid, SIGCONT) == 0)
        try await Self.waitUntilExitedWithoutReaping(pid)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try gate.release(challenge: challenge)
        }

        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            pid,
            processCustody: execution.processCustody,
            timeoutMilliseconds: 1000,
            pipeControl: execution.control,
            terminationGraceMilliseconds: 50)
        _ = await Self.finish(execution)
        #expect(terminal.disposition == .exited)
        Self.expectReaped(pid)
    }

    @Test
    func `Wait failure cleanup kills and reaps the exact child`() async throws {
        let execution = try Self.spawnSuspended(executable: "/bin/sleep", arguments: ["30"])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        let terminal = PeekabooBridgeAgentExecutionProcessWait
            .terminateAfterWaitFailureForTesting(
                processCustody: execution.processCustody)
        _ = await Self.finish(execution)
        #expect(terminal.disposition == .waitFailed)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Retained exact reaper reaps a zombie without live proc identity`() async throws {
        let execution = try Self.spawnSuspended(executable: "/usr/bin/true", arguments: [])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        try await Self.waitUntilExitedWithoutReaping(execution.pid)

        PeekabooBridgeAgentExecutionProcessWait.retainExactReapForTesting(execution.processCustody)
        _ = await Self.finish(execution)
        try await Self.waitUntilReaped(execution.pid)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Actual ECHILD never signals an unanchored numeric process group`() async throws {
        let execution = try Self.spawnSuspended(executable: "/usr/bin/true", arguments: [])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        var waitStatus: Int32 = 0
        while Darwin.waitpid(execution.pid, &waitStatus, 0) < 0, errno == EINTR {}

        let terminal = PeekabooBridgeAgentExecutionProcessWait
            .terminateAfterWaitFailureForTesting(
                processCustody: execution.processCustody)
        _ = await Self.finish(execution)

        #expect(terminal.disposition == .waitFailed)
        Self.expectReaped(execution.pid)
        #expect(!PeekabooBridgeAgentExecutionProcessWait.waitFailureSignalsReusedPIDForTesting(
            4242,
            processIdentifierVersion: 77,
            observedProcessIdentifierVersion: 78))
        for processIdentifierVersion in [Int32.zero, Int32.min, -1, 77] {
            #expect(PeekabooBridgeAgentExecutionProcessWait.waitFailureUsesAuditTokenForTesting(
                4242,
                expectedProcessStartIdentity: 100,
                processIdentifierVersion: processIdentifierVersion))
        }
    }

    @Test
    func `Exited child wins a deadline-edge race`() async throws {
        let execution = try Self.spawnSuspended(executable: "/usr/bin/true", arguments: [])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        try await Self.waitUntilExitedWithoutReaping(execution.pid)

        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            execution.pid,
            processCustody: execution.processCustody,
            timeoutMilliseconds: 0,
            pipeControl: execution.control,
            terminationGraceMilliseconds: 50)
        _ = await Self.finish(execution)

        #expect(terminal.disposition == .exited)
        #expect(terminal.exitCode == 0)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Large output is bounded while both anonymous pipes drain`() async throws {
        let execution = try Self.spawnSuspended(executable: "/usr/bin/yes", arguments: ["trace"])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            execution.pid,
            processCustody: execution.processCustody,
            timeoutMilliseconds: 5000,
            pipeControl: execution.control,
            terminationGraceMilliseconds: 50)
        let captures = await Self.finish(execution)
        #expect(terminal.disposition == .outputOverflow)
        #expect(captures.stdout.bytes.count + captures.stderr.bytes.count <= 256 * 1024)
        #expect(captures.stdout.truncated || captures.stderr.truncated)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Executable and generation substitution fail exact child capture`() throws {
        let expectedPipes = try PeekabooBridgeAgentExecutionPipes()
        let expectedGate = try Self.releaseGate(for: expectedPipes)
        let expectedPID = try PeekabooBridgeAgentExecutionSpawn.spawnSuspended(
            executablePath: "/bin/sleep",
            arguments: ["30"],
            environment: ["PATH": "/usr/bin:/bin"],
            pipes: expectedPipes,
            releaseGate: expectedGate)
        expectedGate.closeAll()
        defer {
            PeekabooBridgeAgentExecutionProcessWait.killSuspendedAndReap(expectedPID)
            expectedPipes.closeAll()
        }
        let expected = try PeekabooBridgeAgentExecutionExecutable.captureProcessForTesting(expectedPID)

        let replacementPipes = try PeekabooBridgeAgentExecutionPipes()
        let replacementGate = try Self.releaseGate(for: replacementPipes)
        let replacementPID = try PeekabooBridgeAgentExecutionSpawn.spawnSuspended(
            executablePath: "/usr/bin/false",
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin"],
            pipes: replacementPipes,
            releaseGate: replacementGate)
        replacementGate.closeAll()
        defer {
            PeekabooBridgeAgentExecutionProcessWait.killSuspendedAndReap(replacementPID)
            replacementPipes.closeAll()
        }
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            _ = try PeekabooBridgeAgentExecutionExecutable.captureChild(
                replacementPID,
                expected: expected)
        }
    }

    private static func request(
        task: String = "Inspect two exact background windows",
        runRootPath: String = "/private/tmp/peekaboo-agent-trace-contract")
        -> PeekabooBridgeAgentExecutionTraceRequest
    {
        .init(
            task: task,
            maxSteps: 40,
            runRootPath: runRootPath,
            coordinationReceiptPath: runRootPath + "/agent-execution-coordination.json",
            acknowledgementPath: runRootPath + "/agent-execution-ack.json",
            startTimeoutMilliseconds: 30000,
            runTimeoutMilliseconds: 900_000)
    }

    private static func fixture(
        childCodeSignatureHash: String? = nil,
        task: String = "Inspect two exact background windows",
        runRootPath: String = "/private/tmp/peekaboo-agent-trace-contract") throws -> (
        request: PeekabooBridgeAgentExecutionTraceRequest,
        response: PeekabooBridgeAgentExecutionTraceResponse)
    {
        let request = self.request(task: task, runRootPath: runRootPath)
        let socket = "/private/tmp/peekaboo-agent-trace-contract.sock"
        let peerCodeSignatureHash = String(repeating: "c", count: 40)
        let processIdentity = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: 4242,
            processStartIdentity: 987_654,
            codeSignatureHash: childCodeSignatureHash ?? peerCodeSignatureHash)
        let process = PeekabooBridgeAgentExecutionProcessIdentity(
            processIdentity: processIdentity,
            executablePath: "/usr/local/bin/peekaboo",
            executableSHA256: String(repeating: "b", count: 64))
        let peer = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: 4241,
            processStartIdentity: 987_000,
            codeSignatureHash: peerCodeSignatureHash)
        let taskSHA256 = self.sha256(Data(request.task.utf8))
        let arguments = [
            "agent", "run", request.task, "--no-cache", "--max-steps", String(request.maxSteps),
            "--bridge-socket", socket, "--json",
        ]
        let argumentsSHA256 = try self.sha256(self.canonical(arguments))
        let environmentKeys = [
            "GROK_API_KEY", "PATH", "PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE",
            "PEEKABOO_AGENT_EXECUTION_GATE_FD",
            "PEEKABOO_AGENT_EXECUTION_LOCKDOWN_FD", "PEEKABOO_AGENT_EXECUTION_PROCESS_LIMIT",
            "PEEKABOO_OPERATION_RECEIPT_DIRECTORY", "XAI_API_KEY", "X_AI_API_KEY",
        ]
        let environmentSHA256 = String(repeating: "d", count: 64)
        let receipt = PeekabooBridgeAgentExecutionCoordinationReceipt(
            challenge: String(repeating: "e", count: 64),
            requestingPeer: peer,
            process: process,
            bridgeSocketPath: socket,
            runRootPath: request.runRootPath,
            coordinationReceiptPath: request.coordinationReceiptPath,
            acknowledgementPath: request.acknowledgementPath,
            operationReceiptDirectoryPath: request.runRootPath + "/agent-operation-receipts",
            taskSHA256: taskSHA256,
            maxSteps: request.maxSteps,
            startTimeoutMilliseconds: request.startTimeoutMilliseconds,
            runTimeoutMilliseconds: request.runTimeoutMilliseconds,
            arguments: arguments,
            argumentsSHA256: argumentsSHA256,
            backgroundOnly: true,
            allowForeground: false,
            shellAvailable: false,
            processCreationLimit: 0,
            environmentPolicyVersion: 3,
            environmentKeys: environmentKeys,
            environmentSHA256: environmentSHA256,
            spawnedAt: 1000,
            lockdownAcknowledgedAt: 1050,
            publishedAt: 1100)
        let receiptBytes = try self.canonical(receipt)
        let acknowledgement = PeekabooBridgeAgentExecutionAcknowledgement(
            challenge: receipt.challenge,
            coordinationReceiptSHA256: self.sha256(receiptBytes),
            requestingPeer: peer,
            process: process,
            taskSHA256: taskSHA256,
            argumentsSHA256: argumentsSHA256,
            environmentSHA256: environmentSHA256,
            acknowledgedAt: 1150)
        let acknowledgementBytes = try self.canonical(acknowledgement)
        let stdout = try JSONSerialization.data(withJSONObject: [
            "success": true,
            "result": [
                "executionTrace": [
                    "entries": [],
                    "totalCallCount": 0,
                    "truncated": false,
                ],
            ],
        ], options: [.sortedKeys, .withoutEscapingSlashes])
        let response = PeekabooBridgeAgentExecutionTraceResponse(
            process: process,
            requestingPeer: peer,
            bridgeSocketPath: socket,
            runRootPath: request.runRootPath,
            coordinationReceiptPath: request.coordinationReceiptPath,
            acknowledgementPath: request.acknowledgementPath,
            operationReceiptDirectoryPath: request.runRootPath + "/agent-operation-receipts",
            taskSHA256: taskSHA256,
            maxSteps: request.maxSteps,
            startTimeoutMilliseconds: request.startTimeoutMilliseconds,
            runTimeoutMilliseconds: request.runTimeoutMilliseconds,
            arguments: arguments,
            argumentsSHA256: argumentsSHA256,
            backgroundOnly: true,
            allowForeground: false,
            shellAvailable: false,
            processCreationLimit: 0,
            environmentPolicyVersion: 3,
            environmentKeys: environmentKeys,
            environmentSHA256: environmentSHA256,
            stdout: .init(bytes: stdout),
            stderr: .init(bytes: Data()),
            coordinationReceipt: .init(bytes: receiptBytes),
            acknowledgement: .init(bytes: acknowledgementBytes),
            processDisposition: .exited,
            outputDisposition: .validatedExecutionTrace,
            executionTrace: .object([
                "entries": .array([]),
                "totalCallCount": .int(0),
                "truncated": .bool(false),
            ]),
            exitCode: 0,
            terminationSignal: nil,
            spawnedAt: 1000,
            lockdownAcknowledgedAt: 1050,
            coordinationReceiptPublishedAt: 1100,
            acknowledgedAt: 1200,
            releasedAt: 1300,
            terminalObservationEndedAt: 1400)
        return (request, response)
    }

    private static func copy(
        _ value: PeekabooBridgeAgentExecutionTraceResponse,
        stdout: PeekabooBridgeAgentExecutionByteEvidence? = nil,
        acknowledgement: PeekabooBridgeAgentExecutionByteEvidence? = nil,
        processDisposition: PeekabooBridgeAgentExecutionProcessDisposition? = nil,
        environmentKeys: [String]? = nil)
        -> PeekabooBridgeAgentExecutionTraceResponse
    {
        .init(
            process: value.process,
            requestingPeer: value.requestingPeer,
            bridgeSocketPath: value.bridgeSocketPath,
            runRootPath: value.runRootPath,
            coordinationReceiptPath: value.coordinationReceiptPath,
            acknowledgementPath: value.acknowledgementPath,
            operationReceiptDirectoryPath: value.operationReceiptDirectoryPath,
            taskSHA256: value.taskSHA256,
            maxSteps: value.maxSteps,
            startTimeoutMilliseconds: value.startTimeoutMilliseconds,
            runTimeoutMilliseconds: value.runTimeoutMilliseconds,
            arguments: value.arguments,
            argumentsSHA256: value.argumentsSHA256,
            backgroundOnly: value.backgroundOnly,
            allowForeground: value.allowForeground,
            shellAvailable: value.shellAvailable,
            processCreationLimit: value.processCreationLimit,
            environmentPolicyVersion: value.environmentPolicyVersion,
            environmentKeys: environmentKeys ?? value.environmentKeys,
            environmentSHA256: value.environmentSHA256,
            stdout: stdout ?? value.stdout,
            stderr: value.stderr,
            coordinationReceipt: value.coordinationReceipt,
            acknowledgement: acknowledgement ?? value.acknowledgement,
            processDisposition: processDisposition ?? value.processDisposition,
            outputDisposition: value.outputDisposition,
            executionTrace: value.executionTrace,
            exitCode: value.exitCode,
            terminationSignal: value.terminationSignal,
            spawnedAt: value.spawnedAt,
            lockdownAcknowledgedAt: value.lockdownAcknowledgedAt,
            coordinationReceiptPublishedAt: value.coordinationReceiptPublishedAt,
            acknowledgedAt: value.acknowledgedAt,
            releasedAt: value.releasedAt,
            terminalObservationEndedAt: value.terminalObservationEndedAt)
    }

    private struct SuspendedExecution: Sendable {
        let pid: pid_t
        let processCustody: PeekabooBridgeAgentExecutionProcessCustody
        let control: PeekabooBridgeAgentExecutionPipeControl
        let stdout: Task<PeekabooBridgeAgentExecutionPipeCapture, Never>
        let stderr: Task<PeekabooBridgeAgentExecutionPipeCapture, Never>
    }

    private static func spawnSuspended(
        executable: String,
        arguments: [String]) throws -> SuspendedExecution
    {
        let pipes = try PeekabooBridgeAgentExecutionPipes()
        let gate = try Self.releaseGate(for: pipes)
        let pid = try PeekabooBridgeAgentExecutionSpawn.spawnSuspended(
            executablePath: executable,
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin"],
            pipes: pipes,
            releaseGate: gate)
        gate.closeAll()
        return try Self.capture(pid: pid, pipes: pipes)
    }

    private static func makePrivateRunRoot() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("peekaboo-agent-trace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func publishCoordinationArtifacts(for paths: PeekabooBridgeAgentExecutionPaths) throws {
        try PeekabooBridgePrivateReceiptArchive.writeAtomically(
            Data("coordination".utf8),
            to: paths.coordinationReceipt)
        try PeekabooBridgePrivateReceiptArchive.writeAtomically(
            Data("acknowledgement".utf8),
            to: paths.acknowledgement)
    }

    private static func expectExclusivePreparationThenReturn(
        _ request: PeekabooBridgeAgentExecutionTraceRequest) throws
    {
        let firstAttempt = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(request)
        #expect(!FileManager.default.fileExists(atPath: firstAttempt.operationReceiptDirectory.path))
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            _ = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(request)
        }
        firstAttempt.releaseRunRootCustodyForTesting()
        withExtendedLifetime(firstAttempt) {}
    }

    private static func expectLaunchPreflightRejection(
        arguments: [String],
        environment: [String: String]) throws
    {
        let pipes = try PeekabooBridgeAgentExecutionPipes()
        let gate = try self.releaseGate(for: pipes)
        defer {
            gate.closeAll()
            pipes.closeAll()
        }
        do {
            let processIdentifier = try PeekabooBridgeAgentExecutionSpawn.spawnSuspended(
                executablePath: "/usr/bin/true",
                arguments: arguments,
                environment: environment,
                pipes: pipes,
                releaseGate: gate)
            PeekabooBridgeAgentExecutionProcessWait.killSuspendedAndReap(processIdentifier)
            Issue.record("Expected aggregate launch payload preflight to reject before posix_spawn")
        } catch let error as PeekabooBridgeAgentExecutionPreReleaseError {
            guard case .invalidRequest = error else {
                Issue.record("Expected invalidRequest instead of a late spawn failure, got \(error)")
                return
            }
            #expect(!error.localizedDescription.contains("Argument list too long"))
        }
    }

    private static func capture(
        pid: pid_t,
        pipes: PeekabooBridgeAgentExecutionPipes) throws -> SuspendedExecution
    {
        let executable = try PeekabooBridgeAgentExecutionExecutable.captureProcessForTesting(pid)
        let processIdentity = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: pid,
            processStartIdentity: executable.processStartIdentity,
            codeSignatureHash: executable.codeSignatureHash)
        let processCustody = try PeekabooBridgeAgentExecutionProcessWait.captureProcessCustody(
            processIdentity: processIdentity)
        let control = PeekabooBridgeAgentExecutionPipeControl(maximumCombinedBytes: 256 * 1024)
        let stdout = Task.detached {
            PeekabooBridgeAgentExecutionPipeReader.read(pipes.stdoutRead, control: control)
        }
        let stderr = Task.detached {
            PeekabooBridgeAgentExecutionPipeReader.read(pipes.stderrRead, control: control)
        }
        return .init(
            pid: pid,
            processCustody: processCustody,
            control: control,
            stdout: stdout,
            stderr: stderr)
    }

    private static func releaseGate(
        for pipes: PeekabooBridgeAgentExecutionPipes) throws -> PeekabooBridgeAgentExecutionReleaseGate
    {
        try PeekabooBridgeAgentExecutionReleaseGate(excludingDescriptors: [
            pipes.stdoutRead,
            pipes.stdoutWrite,
            pipes.stderrRead,
            pipes.stderrWrite,
        ])
    }

    private static func finish(_ execution: SuspendedExecution) async -> (
        stdout: PeekabooBridgeAgentExecutionPipeCapture,
        stderr: PeekabooBridgeAgentExecutionPipeCapture)
    {
        let stdout = await execution.stdout.value
        let stderr = await execution.stderr.value
        execution.control.stop()
        return (stdout, stderr)
    }

    private static func expectReaped(_ pid: pid_t) {
        var status: Int32 = 0
        errno = 0
        #expect(Darwin.waitpid(pid, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }

    private static func waitUntilExitedWithoutReaping(_ pid: pid_t) async throws {
        for _ in 0..<100 {
            var info = siginfo_t()
            let result = Darwin.waitid(
                P_PID,
                id_t(pid),
                &info,
                WEXITED | WNOHANG | WNOWAIT)
            if result == 0, info.si_pid == pid {
                return
            }
            if result < 0, errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private static func waitUntilReaped(_ pid: pid_t) async throws {
        for _ in 0..<100 {
            var info = siginfo_t()
            errno = 0
            let result = Darwin.waitid(
                P_PID,
                id_t(pid),
                &info,
                WEXITED | WNOHANG | WNOWAIT)
            if result < 0, errno == ECHILD {
                return
            }
            if result < 0, errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECHILD)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.coderReadCorrupt)
    }

    private static func readProcessIdentifier(from file: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let value = try? String(contentsOf: file, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                let pid = pid_t(value),
                pid > 0
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadUnknown)
    }

    private static func waitUntilMissing(_ pid: pid_t) async throws {
        for _ in 0..<100 {
            if Darwin.kill(pid, 0) < 0, errno == ESRCH {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = Darwin.kill(pid, SIGKILL)
        throw CocoaError(.coderReadCorrupt)
    }

    private static func canonical(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder.peekabooBridgeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
