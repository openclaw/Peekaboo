import Darwin
import Foundation

// MARK: - Server execution seam

protocol PeekabooBridgeAgentExecutionRunning: Sendable {
    func run(
        request: PeekabooBridgeAgentExecutionTraceRequest,
        peer: PeekabooBridgePeer,
        servingSocketPath: String) async throws -> PeekabooBridgeAgentExecutionTraceResponse
}

struct PeekabooBridgeLiveAgentExecutionRunner: PeekabooBridgeAgentExecutionRunning {
    // The signed operation bundle also carries a base64 canonical response, so raw streams must leave room for both.
    private static let maximumCombinedOutputBytes = 16 * 1024 * 1024
    private static let terminationGraceMilliseconds = 500
    private static let pipeDrainMilliseconds = 500

    func run(
        request: PeekabooBridgeAgentExecutionTraceRequest,
        peer: PeekabooBridgePeer,
        servingSocketPath: String) async throws -> PeekabooBridgeAgentExecutionTraceResponse
    {
        let worker = Task.detached(priority: .userInitiated) {
            try await self.runDetached(
                request: request,
                peer: peer,
                servingSocketPath: servingSocketPath)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    // Keep hashing, signature checks, waitpid polling, and pipe ownership off the app's MainActor.
    // swiftlint:disable:next function_body_length
    private func runDetached(
        request: PeekabooBridgeAgentExecutionTraceRequest,
        peer: PeekabooBridgePeer,
        servingSocketPath: String) async throws -> PeekabooBridgeAgentExecutionTraceResponse
    {
        guard !servingSocketPath.isEmpty,
              servingSocketPath.first == "/",
              !servingSocketPath.utf8.contains(0)
        else {
            throw PeekabooBridgeAgentExecutionPreReleaseError.invalidRequest("Bridge socket path is invalid")
        }

        let executable = try PeekabooBridgeAgentExecutionExecutable.capturePeer(peer)
        let paths = try PeekabooBridgeAgentExecutionPaths.validateAndPrepare(request)
        let requestingPeer = PeekabooBridgeOperationProcessIdentity(
            processIdentifier: executable.processIdentifier,
            processStartIdentity: executable.processStartIdentity,
            codeSignatureHash: executable.codeSignatureHash)
        let challenge = try PeekabooBridgeAgentExecutionCoding.randomChallenge()
        let arguments = PeekabooBridgeAgentExecutionCoding.arguments(
            task: request.task,
            maxSteps: request.maxSteps,
            socketPath: servingSocketPath)
        let taskSHA256 = PeekabooBridgeAgentExecutionCoding.sha256(Data(request.task.utf8))
        let argumentsSHA256 = try PeekabooBridgeAgentExecutionCoding.sha256Canonical(arguments)
        let pipes = try PeekabooBridgeAgentExecutionPipes()
        let releaseGate: PeekabooBridgeAgentExecutionReleaseGate
        do {
            releaseGate = try PeekabooBridgeAgentExecutionReleaseGate(excludingDescriptors: [
                pipes.stdoutRead,
                pipes.stdoutWrite,
                pipes.stderrRead,
                pipes.stderrWrite,
            ])
        } catch {
            pipes.closeAll()
            throw error
        }
        let environment: PeekabooBridgeAgentExecutionEnvironment
        do {
            environment = try PeekabooBridgeAgentExecutionEnvironment.make(
                operationReceiptDirectoryPath: paths.operationReceiptDirectory.path,
                releaseGateDescriptor: releaseGate.childDescriptor,
                lockdownReadinessDescriptor: releaseGate.childReadinessDescriptor,
                releaseChallenge: challenge)
        } catch {
            pipes.closeAll()
            releaseGate.closeAll()
            throw error
        }

        let spawnedAt = PeekabooBridgeAgentExecutionCoding.nowMilliseconds()
        let processIdentifier: pid_t
        do {
            processIdentifier = try PeekabooBridgeAgentExecutionSpawn.spawnSuspended(
                executablePath: executable.path,
                arguments: arguments,
                environment: environment.values,
                pipes: pipes,
                releaseGate: releaseGate)
        } catch {
            pipes.closeAll()
            releaseGate.closeAll()
            if let error = error as? PeekabooBridgeAgentExecutionPreReleaseError {
                throw error
            }
            throw PeekabooBridgeAgentExecutionPreReleaseError.spawnFailed(error.localizedDescription)
        }
        let startDeadline = ContinuousClock.now.advanced(by: .milliseconds(request.startTimeoutMilliseconds))

        let pipeControl = PeekabooBridgeAgentExecutionPipeControl(
            maximumCombinedBytes: Self.maximumCombinedOutputBytes)
        let stdoutTask = Task.detached(priority: .userInitiated) {
            PeekabooBridgeAgentExecutionPipeReader.read(pipes.stdoutRead, control: pipeControl)
        }
        let stderrTask = Task.detached(priority: .userInitiated) {
            PeekabooBridgeAgentExecutionPipeReader.read(pipes.stderrRead, control: pipeControl)
        }

        let coordinationBytes: Data
        let acknowledgementBytes: Data
        let process: PeekabooBridgeAgentExecutionProcessIdentity
        let processCustody: PeekabooBridgeAgentExecutionProcessCustody
        let lockdownAcknowledgedAt: Int64
        let receiptPublishedAt: Int64
        let acknowledgedAt: Int64
        let releasedAt: Int64
        do {
            let child = try PeekabooBridgeAgentExecutionExecutable.captureChild(
                processIdentifier,
                expected: executable)
            process = PeekabooBridgeAgentExecutionProcessIdentity(
                processIdentity: .init(
                    processIdentifier: child.processIdentifier,
                    processStartIdentity: child.processStartIdentity,
                    codeSignatureHash: child.codeSignatureHash),
                executablePath: child.path,
                executableSHA256: child.sha256)
            processCustody = try PeekabooBridgeAgentExecutionProcessWait.captureProcessCustody(
                processIdentity: process.processIdentity)
            guard Darwin.kill(processIdentifier, SIGCONT) == 0 else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.releaseFailed(errno)
            }
            try await releaseGate.waitForLockdown(challenge: challenge, deadline: startDeadline)
            lockdownAcknowledgedAt = PeekabooBridgeAgentExecutionCoding.nowMilliseconds()
            _ = try PeekabooBridgeAgentExecutionExecutable.captureChild(
                processIdentifier,
                expected: executable)
            receiptPublishedAt = PeekabooBridgeAgentExecutionCoding.nowMilliseconds()
            let receipt = PeekabooBridgeAgentExecutionCoordinationReceipt(
                challenge: challenge,
                requestingPeer: requestingPeer,
                process: process,
                bridgeSocketPath: servingSocketPath,
                runRootPath: paths.runRoot.path,
                coordinationReceiptPath: paths.coordinationReceipt.path,
                acknowledgementPath: paths.acknowledgement.path,
                operationReceiptDirectoryPath: paths.operationReceiptDirectory.path,
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
                environmentPolicyVersion: environment.policyVersion,
                environmentKeys: environment.keys,
                environmentSHA256: environment.sha256,
                spawnedAt: spawnedAt,
                lockdownAcknowledgedAt: lockdownAcknowledgedAt,
                publishedAt: receiptPublishedAt)
            coordinationBytes = try PeekabooBridgeAgentExecutionCoding.canonicalData(receipt)
            do {
                try PeekabooBridgePrivateReceiptArchive.writeAtomically(
                    coordinationBytes,
                    to: paths.coordinationReceipt)
            } catch {
                throw PeekabooBridgeAgentExecutionPreReleaseError.receiptPublicationFailed(
                    error.localizedDescription)
            }

            let acknowledgement = try await PeekabooBridgeAgentExecutionAcknowledgementReader.wait(
                at: paths.acknowledgement,
                deadline: startDeadline)
            acknowledgementBytes = acknowledgement.bytes
            try PeekabooBridgeAgentExecutionAcknowledgementReader.validate(
                acknowledgement.value,
                bytes: acknowledgement.bytes,
                receipt: receipt,
                receiptBytes: coordinationBytes)
            acknowledgedAt = PeekabooBridgeAgentExecutionCoding.nowMilliseconds()

            guard try PeekabooBridgeAgentExecutionAcknowledgementReader.stableRead(paths.coordinationReceipt) ==
                coordinationBytes,
                try PeekabooBridgeAgentExecutionAcknowledgementReader.stableRead(paths.acknowledgement) ==
                acknowledgementBytes
            else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                    "coordination files changed before release")
            }
            try PeekabooBridgeAgentExecutionExecutable.revalidatePeer(peer, expected: executable)
            _ = try PeekabooBridgeAgentExecutionExecutable.captureChild(
                processIdentifier,
                expected: executable)
            try Task.checkCancellation()
            guard ContinuousClock.now < startDeadline else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.acknowledgementTimedOut
            }
            try paths.provisionOperationReceiptDirectoryBeforeRelease()
            try PeekabooBridgeAgentExecutionExecutable.revalidatePeer(peer, expected: executable)
            _ = try PeekabooBridgeAgentExecutionExecutable.captureChild(
                processIdentifier,
                expected: executable)
            guard try PeekabooBridgeAgentExecutionAcknowledgementReader.stableRead(paths.coordinationReceipt) ==
                coordinationBytes,
                try PeekabooBridgeAgentExecutionAcknowledgementReader.stableRead(paths.acknowledgement) ==
                acknowledgementBytes
            else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.invalidAcknowledgement(
                    "coordination files changed before release")
            }
            try paths.revalidateBeforeRelease()
            try Task.checkCancellation()
            guard ContinuousClock.now < startDeadline else {
                throw PeekabooBridgeAgentExecutionPreReleaseError.acknowledgementTimedOut
            }
            try releaseGate.release(challenge: challenge)
            releasedAt = PeekabooBridgeAgentExecutionCoding.nowMilliseconds()
        } catch {
            releaseGate.closeAll()
            PeekabooBridgeAgentExecutionProcessWait.killSuspendedAndReap(processIdentifier)
            pipeControl.stop()
            _ = await stdoutTask.value
            _ = await stderrTask.value
            if let error = error as? PeekabooBridgeAgentExecutionPreReleaseError {
                throw error
            }
            if error is CancellationError || Task.isCancelled {
                throw PeekabooBridgeAgentExecutionPreReleaseError.cancelledBeforeRelease
            }
            throw PeekabooBridgeAgentExecutionPreReleaseError.executableIdentityChanged
        }

        let terminal = await PeekabooBridgeAgentExecutionProcessWait.wait(
            processIdentifier,
            processCustody: processCustody,
            timeoutMilliseconds: request.runTimeoutMilliseconds,
            pipeControl: pipeControl,
            terminationGraceMilliseconds: Self.terminationGraceMilliseconds)
        await Self.finishPipeDrain(control: pipeControl)
        let stdoutCapture = await stdoutTask.value
        let stderrCapture = await stderrTask.value
        let stdout = PeekabooBridgeAgentExecutionByteEvidence(
            bytes: stdoutCapture.bytes,
            truncated: stdoutCapture.truncated,
            readErrorCode: stdoutCapture.readErrorCode)
        let stderr = PeekabooBridgeAgentExecutionByteEvidence(
            bytes: stderrCapture.bytes,
            truncated: stderrCapture.truncated,
            readErrorCode: stderrCapture.readErrorCode)
        let extracted = PeekabooBridgeAgentExecutionOutputExtractor.extract(
            stdout.bytes,
            outputOverflow: terminal.disposition == .outputOverflow,
            streamFailed: stdout.readErrorCode != nil || stdout.truncated || stderr.readErrorCode != nil ||
                stderr.truncated)

        return PeekabooBridgeAgentExecutionTraceResponse(
            process: process,
            requestingPeer: requestingPeer,
            bridgeSocketPath: servingSocketPath,
            runRootPath: paths.runRoot.path,
            coordinationReceiptPath: paths.coordinationReceipt.path,
            acknowledgementPath: paths.acknowledgement.path,
            operationReceiptDirectoryPath: paths.operationReceiptDirectory.path,
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
            environmentPolicyVersion: environment.policyVersion,
            environmentKeys: environment.keys,
            environmentSHA256: environment.sha256,
            stdout: stdout,
            stderr: stderr,
            coordinationReceipt: .init(bytes: coordinationBytes),
            acknowledgement: .init(bytes: acknowledgementBytes),
            processDisposition: terminal.disposition,
            outputDisposition: extracted.disposition,
            executionTrace: extracted.trace,
            exitCode: terminal.exitCode,
            terminationSignal: terminal.terminationSignal,
            spawnedAt: spawnedAt,
            lockdownAcknowledgedAt: lockdownAcknowledgedAt,
            coordinationReceiptPublishedAt: receiptPublishedAt,
            acknowledgedAt: acknowledgedAt,
            releasedAt: releasedAt,
            terminalObservationEndedAt: terminal.terminalObservationEndedAt)
    }

    private static func finishPipeDrain(control: PeekabooBridgeAgentExecutionPipeControl) async {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(self.pipeDrainMilliseconds))
        while ContinuousClock.now < deadline, !control.allReadersFinished {
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                control.stop()
                return
            }
        }
        control.stop(markTruncated: !control.allReadersFinished)
    }
}
