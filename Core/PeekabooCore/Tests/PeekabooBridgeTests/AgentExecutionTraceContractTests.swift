import CryptoKit
import Darwin
import Foundation
import Testing
@testable import PeekabooBridge

@Suite("Bridge Agent execution trace contract")
struct AgentExecutionTraceContractTests {
    @Test
    func `Protocol and allowlists fail closed before 1.31`() {
        let previous = PeekabooBridgeProtocolVersion(major: 1, minor: 30)
        #expect(PeekabooBridgeConstants.protocolVersion == .init(major: 1, minor: 31))
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
        let execution = Self.capture(pid: pid, pipes: pipes)
        #expect(Darwin.kill(pid, SIGCONT) == 0)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        try gate.release(challenge: challenge)
        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            pid,
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
        let execution = Self.capture(pid: pid, pipes: pipes)
        #expect(Darwin.kill(pid, SIGCONT) == 0)
        try await Self.waitUntilExitedWithoutReaping(pid)
        #expect(throws: PeekabooBridgeAgentExecutionPreReleaseError.self) {
            try gate.release(challenge: challenge)
        }

        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            pid,
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
            .terminateAfterWaitFailureForTesting(execution.pid)
        _ = await Self.finish(execution)
        #expect(terminal.disposition == .waitFailed)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Exited child wins a deadline-edge race`() async throws {
        let execution = try Self.spawnSuspended(executable: "/usr/bin/true", arguments: [])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        try await Self.waitUntilExitedWithoutReaping(execution.pid)

        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            execution.pid,
            timeoutMilliseconds: 0,
            pipeControl: execution.control,
            terminationGraceMilliseconds: 50)
        _ = await Self.finish(execution)

        #expect(terminal.disposition == .exited)
        #expect(terminal.exitCode == 0)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Forced termination kills descendants after the leader exits`() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
        trap 'exit 0' TERM
        /bin/sh -c 'trap "" TERM; exec /bin/sleep 30' &
        echo $! > '\(pidFile.path)'
        while :; do /bin/sleep 1; done
        """
        let execution = try Self.spawnSuspended(executable: "/bin/sh", arguments: ["-c", script])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        let descendant = try await Self.readProcessIdentifier(from: pidFile)

        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            execution.pid,
            timeoutMilliseconds: 0,
            pipeControl: execution.control,
            terminationGraceMilliseconds: 250)
        _ = await Self.finish(execution)

        #expect(terminal.disposition == .timedOut)
        try await Self.waitUntilMissing(descendant)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Daemonized native code is outside the exact shell-disabled Agent contract`() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-setsid-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let python = """
        import os, time
        os.setsid()
        os.close(1)
        os.close(2)
        with open('\(pidFile.path)', 'w') as stream:
            stream.write(str(os.getpid()))
            stream.flush()
        time.sleep(30)
        """
        let script = """
        /usr/bin/python3 -c "\(python.replacingOccurrences(of: "\"", with: "\\\""))" &
        while [ ! -s '\(pidFile.path)' ]; do /bin/sleep 0.01; done
        """
        let execution = try Self.spawnSuspended(executable: "/bin/sh", arguments: ["-c", script])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        let detachedPID = try await Self.readProcessIdentifier(from: pidFile)

        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            execution.pid,
            timeoutMilliseconds: 2000,
            pipeControl: execution.control,
            terminationGraceMilliseconds: 50)
        _ = await Self.finish(execution)

        #expect(terminal.disposition == .exited)
        // macOS process groups are not cgroups: arbitrary native code can call setsid. The
        // production contract prevents prompt-level access to this path by fixing the exact
        // signed CLI/argv and omitting Shell; do not broaden the PGID cleanup claim.
        #expect(Darwin.kill(detachedPID, 0) == 0)
        let fixture = try Self.fixture()
        #expect(!fixture.response.shellAvailable)
        _ = Darwin.kill(detachedPID, SIGKILL)
        try await Self.waitUntilMissing(detachedPID)
        Self.expectReaped(execution.pid)
    }

    @Test
    func `Large output is bounded while both anonymous pipes drain`() async throws {
        let execution = try Self.spawnSuspended(executable: "/usr/bin/yes", arguments: ["trace"])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            execution.pid,
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
    func `Output overflow kills descendants after SIGPIPE reaps the leader`() async throws {
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-agent-overflow-descendant-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = """
        /bin/sh -c 'trap "" TERM PIPE; exec >/dev/null 2>&1; exec /bin/sleep 30' &
        echo $! > '\(pidFile.path)'
        exec /usr/bin/yes trace
        """
        let execution = try Self.spawnSuspended(executable: "/bin/sh", arguments: ["-c", script])
        #expect(Darwin.kill(execution.pid, SIGCONT) == 0)
        let descendant = try await Self.readProcessIdentifier(from: pidFile)

        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            execution.pid,
            timeoutMilliseconds: 5000,
            pipeControl: execution.control,
            terminationGraceMilliseconds: 50)
        _ = await Self.finish(execution)

        #expect(terminal.disposition == .outputOverflow)
        try await Self.waitUntilMissing(descendant)
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

    private static func request() -> PeekabooBridgeAgentExecutionTraceRequest {
        let root = "/private/tmp/peekaboo-agent-trace-contract"
        return .init(
            task: "Inspect two exact background windows",
            maxSteps: 40,
            runRootPath: root,
            coordinationReceiptPath: root + "/agent-execution-coordination.json",
            acknowledgementPath: root + "/agent-execution-ack.json",
            startTimeoutMilliseconds: 30000,
            runTimeoutMilliseconds: 900_000)
    }

    private static func fixture() throws -> (
        request: PeekabooBridgeAgentExecutionTraceRequest,
        response: PeekabooBridgeAgentExecutionTraceResponse)
    {
        let request = self.request()
        let socket = "/private/tmp/peekaboo-agent-trace-contract.sock"
        let processIdentity = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: 4242,
            processStartIdentity: 987_654,
            codeSignatureHash: String(repeating: "a", count: 40))
        let process = PeekabooBridgeAgentExecutionProcessIdentity(
            processIdentity: processIdentity,
            executablePath: "/usr/local/bin/peekaboo",
            executableSHA256: String(repeating: "b", count: 64))
        let peer = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: 4241,
            processStartIdentity: 987_000,
            codeSignatureHash: String(repeating: "c", count: 40))
        let taskSHA256 = self.sha256(Data(request.task.utf8))
        let arguments = [
            "agent", "run", request.task, "--no-cache", "--max-steps", String(request.maxSteps),
            "--bridge-socket", socket, "--json",
        ]
        let argumentsSHA256 = try self.sha256(self.canonical(arguments))
        let environmentKeys = [
            "PATH", "PEEKABOO_AGENT_EXECUTION_GATE_CHALLENGE", "PEEKABOO_AGENT_EXECUTION_GATE_FD",
            "PEEKABOO_OPERATION_RECEIPT_DIRECTORY",
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
            environmentPolicyVersion: 1,
            environmentKeys: environmentKeys,
            environmentSHA256: environmentSHA256,
            spawnedAt: 1000,
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
            environmentPolicyVersion: 1,
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
            coordinationReceiptPublishedAt: 1100,
            acknowledgedAt: 1200,
            releasedAt: 1300,
            terminatedAt: 1400)
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
            coordinationReceiptPublishedAt: value.coordinationReceiptPublishedAt,
            acknowledgedAt: value.acknowledgedAt,
            releasedAt: value.releasedAt,
            terminatedAt: value.terminatedAt)
    }

    private struct SuspendedExecution: Sendable {
        let pid: pid_t
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
        return Self.capture(pid: pid, pipes: pipes)
    }

    private static func capture(
        pid: pid_t,
        pipes: PeekabooBridgeAgentExecutionPipes) -> SuspendedExecution
    {
        let control = PeekabooBridgeAgentExecutionPipeControl(maximumCombinedBytes: 256 * 1024)
        let stdout = Task.detached {
            PeekabooBridgeAgentExecutionPipeReader.read(pipes.stdoutRead, control: control)
        }
        let stderr = Task.detached {
            PeekabooBridgeAgentExecutionPipeReader.read(pipes.stderrRead, control: control)
        }
        return .init(pid: pid, control: control, stdout: stdout, stderr: stderr)
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
