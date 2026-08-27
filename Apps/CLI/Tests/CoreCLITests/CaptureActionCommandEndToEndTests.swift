import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import PeekabooBridge
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized)
@MainActor
struct CaptureActionCommandEndToEndTests {
    @Test
    func `Capture action rejects the ad hoc test host identity`() {
        #expect(PeekabooBridgeAuthenticatedHostIdentity.current() == nil)
        let command = CaptureActionCommand()
        #expect(command.mapErrorToCode(CaptureActionHostProvenanceError(message: "unsigned")) == .CAPTURE_FAILED)
    }

    @Test
    func `Capture action composes actual foreground focus with child dispatch`() throws {
        let focusOutcome = DesktopActionOutcome.confirmedChange(
            route: .local,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one
        )
        var command = CaptureActionCommand()
        command.recordCaptureFocusOutcome(focusOutcome)
        #expect(command.captureFocusOutcome == focusOutcome)
        #expect(command.captureMutationDispatched)
        let aggregate = try #require(CaptureActionOutcomeSemantics.aggregate(
            focusOutcome: focusOutcome,
            childOutcome: CaptureActionOutcomeSemantics.completedChildOutcome
        ))

        #expect(aggregate.state == .dispatchedUnverified)
        #expect(aggregate.delivery?.mechanism == .composite)
        #expect(aggregate.delivery?.mode == .foreground)
        #expect(aggregate.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))

        let mixedRouteFocus = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: .one
        )
        let mixedRoute = CaptureActionOutcomeSemantics.aggregate(
            focusOutcome: mixedRouteFocus,
            childOutcome: CaptureActionOutcomeSemantics.completedChildOutcome
        )
        #expect(mixedRoute == nil)
        let mixedRouteFailure = CaptureActionOutcomeSemantics.failureAggregate(
            focusOutcome: mixedRouteFocus,
            childOutcome: CaptureActionOutcomeSemantics.completedChildOutcome
        )
        #expect(mixedRouteFailure.state == .indeterminate)
        #expect(mixedRouteFailure.route == .local)
        #expect(mixedRouteFailure.delivery == nil)
        #expect(mixedRouteFailure.dispatchState.unitCount == DesktopActionOutcome.DispatchUnitCount(2))

        let oversizedFocus = DesktopActionOutcome.confirmedChange(
            route: .bridge,
            delivery: .init(mechanism: .nativeFramework, mode: .foreground),
            unitCount: DesktopActionOutcome.DispatchUnitCount(Int.max)
        )
        let overflowFailure = CaptureActionOutcomeSemantics.failureAggregate(
            focusOutcome: oversizedFocus,
            childOutcome: CaptureActionOutcomeSemantics.completedChildOutcome
        )
        #expect(overflowFailure.state == .indeterminate)
        #expect(overflowFailure.dispatchState.unitCount == nil)
    }

    @Test
    func `Capture action runs child and publishes validated artifacts without live screen capture`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-e2e-\(UUID().uuidString)", isDirectory: true)
        let videoOutput = outputDirectory.appendingPathComponent("action.mp4")
        var needsCleanup = true
        defer {
            if needsCleanup {
                try? FileManager.default.removeItem(at: outputDirectory)
            }
        }

        let frameSource = DeterministicCaptureActionFrameSource()
        let processRecorder = CaptureActionProcessRecorder()
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "4s")
        command.preRoll = CLIDuration(argument: "300ms")
        command.postRoll = CLIDuration(argument: "400ms")
        command.idleFps = 5
        command.activeFps = 15
        command.threshold = 0
        command.heartbeat = CLIDuration(argument: "100ms")
        command.maxFrames = 20
        command.path = outputDirectory.path
        command.videoOut = videoOutput.path
        command.command = [
            "/bin/sh",
            "-c",
            "printf child-stdout; /bin/sleep 0.05; printf child-stderr >&2",
        ]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { scope in
                frameSource.resolvedScopes.append(scope)
                return frameSource
            },
            deadlineProcessRunner: { childCommand, timeoutSeconds, completionDeadlineNs, onLaunch in
                let startedAt = Date()
                let result = try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    completionDeadlineNanoseconds: completionDeadlineNs,
                    onLaunch: onLaunch
                )
                processRecorder.invocations.append(.init(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    startedAt: startedAt,
                    finishedAt: Date()
                ))
                return result
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )

        command.runtime = self.makeRuntime()
        let result = try await command.executeActionCapture()
        let encoded = try JSONEncoder().encode(command.jsonEnvelope(for: result))
        let envelope = try JSONDecoder().decode(
            ResultEnvelope<CaptureActionCommandResult>.self,
            from: encoded
        )

        #expect(envelope.success)
        #expect(envelope.effect == .unverifiable)
        #expect(envelope.outcome == envelope.data.outcome?.projection)
        #expect(envelope.outcome?.state == .dispatchedUnverified)
        #expect(envelope.outcome?.deliveryMechanism == .capturePipeline)
        #expect(envelope.outcome?.deliveryMode == .background)
        #expect(envelope.error == nil)
        #expect(envelope.data.success)
        #expect(envelope.data.action.command == command.command)
        #expect(envelope.data.action.exitCode == 0)
        #expect(!envelope.data.action.timedOut)
        #expect(envelope.data.action.processGroupCleaned)
        #expect(envelope.data.action.stdout == "child-stdout")
        #expect(envelope.data.action.stderr == "child-stderr")
        #expect(envelope.data.capture.frames.count >= 1)
        #expect(envelope.data.capture.stats.framesKept >= 1)
        #expect(envelope.data.validation.ok)
        #expect(envelope.data.validation.missing.isEmpty)
        #expect(envelope.data.validation.checked.contains(envelope.data.capture.contactSheet.path))
        #expect(envelope.data.validation.checked.contains(envelope.data.capture.metadataFile))
        #expect(envelope.data.capture.frames.allSatisfy { frame in
            envelope.data.validation.checked.contains(frame.path)
        })
        #expect(envelope.data.capture.videoOut == videoOutput.standardizedFileURL.path)
        #expect(envelope.data.capture.videoArtifactCustody?.path == videoOutput.standardizedFileURL.path)
        #expect(Self.isNonemptyFile(envelope.data.capture.contactSheet.path))
        #expect(Self.isNonemptyFile(envelope.data.capture.metadataFile))
        #expect(Self.isNonemptyFile(videoOutput.path))
        #expect(envelope.data.capture.frames.allSatisfy { Self.isNonemptyFile($0.path) })
        #expect(command.captureMutationDispatched)
        #expect(frameSource.captureCount >= 1)
        #expect(frameSource.resolvedScopes.map(\.kind) == [.frontmost])
        #expect(processRecorder.invocations.count == 1)
        #expect(processRecorder.invocations.first?.command == command.command)
        #expect((processRecorder.invocations.first?.timeoutSeconds ?? 0) > 0)
        let process = try #require(processRecorder.invocations.first)
        #expect(frameSource.captureDates.contains { $0 > process.finishedAt })

        try await Self.verifyVideoAliasValidation(command: command, capture: envelope.data.capture)

        try Self.verifyPublishedManifest(
            result: envelope.data,
            command: command.command,
            outputDirectory: outputDirectory
        )

        try FileManager.default.removeItem(at: outputDirectory)
        needsCleanup = false
        #expect(!FileManager.default.fileExists(atPath: outputDirectory.path))
    }

    @Test
    func `Capture action refuses child special-file replacement of capture-owned artifacts`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-tamper-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let frameSource = DeterministicCaptureActionFrameSource()
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.preRoll = CLIDuration(argument: "250ms")
        command.postRoll = CLIDuration(argument: "100ms")
        command.idleFps = 5
        command.activeFps = 15
        command.threshold = 0
        command.heartbeat = CLIDuration(argument: "100ms")
        command.maxFrames = 20
        command.path = outputDirectory.path
        command.command = [
            "/bin/sh",
            "-c",
            "for i in 1 2 3 4 5 6 7 8 9 10; do " +
                "test -f \"$1/keep-0001.png\" && break; /bin/sleep 0.01; done; " +
                "rm -f \"$1/keep-0001.png\"; mkfifo \"$1/keep-0001.png\"; " +
                "printf x > \"$1/contact.png\"; " +
                "printf x > \"$1/metadata.json\"",
            "sh",
            outputDirectory.path,
        ]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in frameSource },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    onLaunch: onLaunch
                )
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )

        command.runtime = self.makeRuntime()
        let thrown = await #expect(throws: (any Error).self) {
            _ = try await command.executeActionCapture()
        }

        #expect(try #require(thrown).localizedDescription.contains("Contact sheet source frame is unreadable"))
        #expect(command.captureMutationDispatched)
        var frameInfo = stat()
        let framePath = outputDirectory.appendingPathComponent("keep-0001.png").path
        #expect(framePath.withCString { lstat($0, &frameInfo) } == 0)
        #expect(frameInfo.st_mode & S_IFMT == S_IFIFO)
    }

    @Test
    func `Capture action preserves nonzero child result and dispatch semantics`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-nonzero-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let frameSource = DeterministicCaptureActionFrameSource()
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.preRoll = CLIDuration(argument: "150ms")
        command.postRoll = CLIDuration(argument: "100ms")
        command.idleFps = 5
        command.activeFps = 15
        command.threshold = 0
        command.maxFrames = 20
        command.path = outputDirectory.path
        command.command = ["/bin/sh", "-c", "printf child-failed; exit 7"]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in frameSource },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    onLaunch: onLaunch
                )
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )

        command.runtime = self.makeRuntime()
        let result = try await command.executeActionCapture()
        let encoded = try JSONEncoder().encode(command.jsonEnvelope(for: result))
        let envelope = try JSONDecoder().decode(
            ResultEnvelope<CaptureActionCommandResult>.self,
            from: encoded
        )

        #expect(!envelope.success)
        #expect(envelope.effect == .unverifiable)
        #expect(envelope.outcome == envelope.data.outcome?.projection)
        #expect(envelope.outcome?.state == .dispatchedUnverified)
        #expect(envelope.error?.code == "VALIDATION_ERROR")
        #expect(envelope.error?.retry_safe == false)
        #expect(envelope.error?.mutation_dispatched == true)
        #expect(!envelope.data.success)
        #expect(envelope.data.action.exitCode == 7)
        #expect(envelope.data.action.stdout == "child-failed")
        #expect(envelope.data.validation.ok)
        #expect(envelope.data.validation.missing.isEmpty)
        let manifestReceipt = try #require(envelope.data.manifest)
        let manifest = try JSONDecoder().decode(
            CaptureActionManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestReceipt.path))
        )
        #expect(!manifest.result.success)
        #expect(manifest.result.effect == .unverifiable)
        #expect(manifest.result.mutationDispatched)
        #expect(!manifest.result.retrySafe)
        #expect(manifest.result.outcome == envelope.outcome)
        let failedResultData = try JSONEncoder().encode(envelope.data)
        var contradictoryCommandResult = try #require(
            JSONSerialization.jsonObject(with: failedResultData) as? [String: Any]
        )
        contradictoryCommandResult["success"] = true
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CaptureActionCommandResult.self,
                from: JSONSerialization.data(withJSONObject: contradictoryCommandResult)
            )
        }
        #expect(command.captureMutationDispatched)
    }

    @Test
    func `Capture action reports when capture ends before action and post-roll`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-early-end-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let frameSource = DeterministicCaptureActionFrameSource()
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.preRoll = CLIDuration(argument: "60ms")
        command.postRoll = CLIDuration(argument: "100ms")
        command.idleFps = 5
        command.activeFps = 15
        command.threshold = 0
        command.maxFrames = 2
        command.path = outputDirectory.path
        command.command = ["/bin/sleep", "0.3"]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in frameSource },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    onLaunch: onLaunch
                )
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )
        command.runtime = self.makeRuntime()

        let result = try await command.executeActionCapture()
        #expect(!result.success)
        #expect(result.action.succeeded)
        #expect(result.validation.missing.contains(
            "capture ended before the action and requested post-roll completed"
        ))
        let receipt = try #require(result.manifest)
        let manifest = try JSONDecoder().decode(
            CaptureActionManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: receipt.path))
        )
        #expect(manifest.timeline.samplingCompletedMs < manifest.timeline.actionCompletedMs)
        #expect(manifest.timeline.samplingCompletedMs <= manifest.timeline.captureCompletedMs)
        #expect(!manifest.result.success)
        #expect(manifest.result.effect == .unverifiable)
    }

    @Test
    func `Capture action kills delayed descendant before publishing artifacts`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-descendant-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let ready = outputDirectory.appendingPathComponent("descendant-ready")
        let release = outputDirectory.appendingPathComponent("release-descendant")
        let marker = outputDirectory.appendingPathComponent("late-mutation")

        let frameSource = DeterministicCaptureActionFrameSource()
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.preRoll = CLIDuration(argument: "100ms")
        command.postRoll = CLIDuration(argument: "100ms")
        command.idleFps = 5
        command.activeFps = 15
        command.threshold = 0
        command.maxFrames = 30
        command.path = outputDirectory.path
        command.command = [
            "/usr/bin/perl",
            "-e",
            "if (fork() == 0) { $SIG{TERM} = 'IGNORE'; " +
                "open(my $ready, '>', $ARGV[0]) or die $!; close($ready); " +
                "while (!-e $ARGV[1]) { select undef, undef, undef, 0.01; } " +
                "open(my $marker, '>', $ARGV[2]) or die $!; close($marker); " +
                "for my $name ('keep-0001.png', 'contact.png', 'metadata.json', 'action.json') { " +
                "open(my $file, '>', \"$ARGV[3]/$name\") or next; print $file 'x'; close($file); } exit 0; } " +
                "while (!-e $ARGV[0]) { select undef, undef, undef, 0.01; } exit 0;",
            ready.path,
            release.path,
            marker.path,
            outputDirectory.path,
        ]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in frameSource },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    onLaunch: onLaunch
                )
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )
        command.runtime = self.makeRuntime()

        let result = try await command.executeActionCapture()
        #expect(result.success)
        #expect(result.action.processGroupCleaned)
        try Data().write(to: release)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        try CaptureArtifactIntegrityValidator.validate(result.capture)
        let manifestReceipt = try #require(result.manifest)
        let manifest = try JSONDecoder().decode(
            CaptureActionManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: manifestReceipt.path))
        )
        try CaptureActionManifestWriter.validateArtifacts(
            manifest.artifacts,
            outputRoot: outputDirectory
        )
    }

    @Test
    func `Capture action refuses a child-created manifest without overwriting it`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-manifest-race-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let frameSource = DeterministicCaptureActionFrameSource()
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.preRoll = CLIDuration(argument: "100ms")
        command.postRoll = CLIDuration(argument: "100ms")
        command.idleFps = 5
        command.activeFps = 15
        command.threshold = 0
        command.maxFrames = 20
        command.path = outputDirectory.path
        command.command = [
            "/bin/sh",
            "-c",
            "printf child-owned > \"$1/action.json\"",
            "sh",
            outputDirectory.path,
        ]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in frameSource },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    onLaunch: onLaunch
                )
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )
        command.runtime = self.makeRuntime()

        let thrown = await #expect(throws: (any Error).self) {
            _ = try await command.executeActionCapture()
        }
        #expect(try #require(thrown).localizedDescription.contains("Could not publish capture action manifest"))
        #expect(try Data(contentsOf: outputDirectory.appendingPathComponent("action.json")) ==
            Data("child-owned".utf8))
        #expect(command.captureMutationDispatched)
    }

    @Test
    func `Capture action keeps launch failures retry safe and undispatched`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-launch-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let frameSource = DeterministicCaptureActionFrameSource()
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.preRoll = CLIDuration(argument: "100ms")
        command.postRoll = CLIDuration(argument: "100ms")
        command.idleFps = 5
        command.activeFps = 15
        command.threshold = 0
        command.path = outputDirectory.path
        command.command = ["/definitely/missing/peekaboo-action-child"]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in frameSource },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    onLaunch: onLaunch
                )
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )
        command.runtime = self.makeRuntime()

        let thrown = await #expect(throws: (any Error).self) {
            _ = try await command.executeActionCapture()
        }
        #expect(try #require(thrown).localizedDescription.contains("posix_spawnp failed"))
        #expect(!command.captureMutationDispatched)
        #expect(!FileManager.default.fileExists(atPath: outputDirectory.appendingPathComponent("action.json").path))

        try? FileManager.default.removeItem(at: outputDirectory)
        command.captureMutationDispatched = true
        _ = await #expect(throws: (any Error).self) {
            _ = try await command.executeActionCapture()
        }
        #expect(command.captureMutationDispatched)
    }

    @Test
    func `Capture action refuses incomplete host provenance before child dispatch`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-host-refusal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let marker = outputDirectory.appendingPathComponent("child-ran")
        let frameSource = DeterministicCaptureActionFrameSource()
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.path = outputDirectory.path
        command.command = ["/usr/bin/touch", marker.path]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in frameSource },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    onLaunch: onLaunch
                )
            },
            hostIdentityProvider: {
                PeekabooBridgeAuthenticatedHostIdentity(
                    processIdentifier: getpid(),
                    processStartIdentity: SystemIdentityResolver.processStartIdentity(getpid()) ?? 1,
                    signingIdentifier: "boo.peekaboo.tests",
                    teamIdentifier: "Y5PE65HELJ",
                    codeSignatureHash: "",
                    sourceCommit: String(repeating: "b", count: 40),
                    bundleShortVersion: "4.2.3",
                    bundleVersion: "1"
                )
            }
        )
        command.runtime = self.makeRuntime()

        let thrown = await #expect(throws: (any Error).self) {
            _ = try await command.executeActionCapture()
        }

        #expect(try #require(thrown).localizedDescription ==
            "Capture action requires a source-stamped, signed host identity")
        #expect(!command.captureMutationDispatched)
        #expect(!FileManager.default.fileExists(atPath: marker.path))

        var cliCommand = command
        let output = try await Self.captureStandardOutput {
            _ = try? await cliCommand.run(using: self.makeRuntime())
        }
        let envelope = try JSONDecoder().decode(ResultEnvelope<Empty?>.self, from: output)
        #expect(!envelope.success)
        #expect(envelope.outcome?.state == .refused)
        #expect(envelope.outcome?.retrySafe == true)
        #expect(envelope.outcome?.mutationDispatched == false)
        #expect(envelope.error?.retry_safe == true)
        #expect(envelope.error?.mutation_dispatched == false)
    }

    private static func verifyPublishedManifest(
        result: CaptureActionCommandResult,
        command: [String],
        outputDirectory: URL
    ) throws {
        let manifestReceipt = try #require(result.manifest)
        let manifestURL = URL(fileURLWithPath: manifestReceipt.path)
        let manifestData = try Data(contentsOf: manifestURL)
        let manifestDigest = SHA256.hash(data: manifestData).map { String(format: "%02x", $0) }.joined()
        #expect(manifestDigest == manifestReceipt.sha256)
        let manifest = try JSONDecoder().decode(CaptureActionManifest.self, from: manifestData)
        #expect(manifest.schemaVersion == 1)
        #expect(manifest.request.commandArgumentCount == command.count)
        let commandSHA256 = try CaptureActionManifestWriter.commandSHA256(command)
        #expect(manifest.request.commandSHA256 == commandSHA256)
        #expect(manifest.action.containmentScope == .processGroup)
        #expect(manifest.action.processIdentifier > 0)
        #expect(manifest.action.processStartIdentityDecimal == String(manifest.action.processStartIdentity))
        #expect(manifest.timeline.actionStartedMs >= 250)
        #expect(manifest.timeline.actionStartedMs <= manifest.timeline.actionCompletedMs)
        #expect(manifest.timeline.actionCompletedMs < manifest.timeline.samplingCompletedMs)
        #expect(manifest.timeline.samplingCompletedMs <= manifest.timeline.captureCompletedMs)
        #expect(manifest.capture.executionRoute == .local)
        #expect(manifest.capture.observedCaptureEngines == ["deterministic-test"])
        #expect(manifest.capture.hostIdentity.processIdentifier > 0)
        #expect(manifest.capture.hostIdentity.processStartIdentity > 0)
        #expect(manifest.capture.hostIdentity.processStartIdentityDecimal ==
            String(manifest.capture.hostIdentity.processStartIdentity))
        #expect(manifest.capture.hostIdentity.signingIdentifier == "boo.peekaboo.tests")
        #expect(manifest.capture.hostIdentity.teamIdentifier == "Y5PE65HELJ")
        #expect(manifest.capture.hostIdentity.codeSignatureHash == String(repeating: "a", count: 40))
        #expect(manifest.capture.hostIdentity.sourceCommit == String(repeating: "b", count: 40))
        let videoArtifactCount = result.capture.videoOut == nil ? 0 : 1
        #expect(manifest.artifacts.count == result.capture.frames.count + 2 + videoArtifactCount)
        #expect(manifest.artifacts.contains { $0.role == .video } == (videoArtifactCount == 1))
        #expect(manifest.result.success)
        #expect(manifest.result.effect == .unverifiable)
        #expect(manifest.result.mutationDispatched)
        #expect(!manifest.result.retrySafe)
        #expect(manifest.result.outcome == result.outcome?.projection)
        try Self.verifyContradictoryResultsAreRejected(
            result: result,
            manifest: manifest,
            manifestData: manifestData
        )
        try CaptureActionManifestWriter.validateArtifacts(
            manifest.artifacts,
            outputRoot: outputDirectory
        )

        try Data([0x00]).write(to: manifestURL, options: .atomic)
        let changedManifestData = try Data(contentsOf: manifestURL)
        #expect(SHA256.hash(data: changedManifestData).map { String(format: "%02x", $0) }.joined() !=
            manifestReceipt.sha256)
        try manifestData.write(to: manifestURL, options: .atomic)

        let postPublicationTarget = try #require(result.capture.frames.first?.path)
        let postPublicationURL = URL(fileURLWithPath: postPublicationTarget)
        let postPublicationOriginal = try Data(contentsOf: postPublicationURL)
        try FileManager.default.removeItem(at: manifestURL)
        let postPublicationFailure = #expect(throws: (any Error).self) {
            _ = try CaptureActionManifestWriter.write(
                manifest,
                outputRoot: outputDirectory,
                beforePostPublicationValidation: {
                    try Data([0x00]).write(to: postPublicationURL, options: .atomic)
                }
            )
        }
        #expect(try #require(postPublicationFailure).localizedDescription.contains("published manifest quarantined"))
        #expect(!FileManager.default.fileExists(atPath: manifestReceipt.path))
        try postPublicationOriginal.write(to: postPublicationURL, options: .atomic)

        try Self.verifyManifestCancellationAndReplacementCleanup(
            manifest: manifest,
            manifestURL: manifestURL,
            outputDirectory: outputDirectory
        )

        let tamperTargets = try [
            #require(result.capture.frames.first?.path),
            result.capture.contactSheet.path,
            result.capture.metadataFile,
        ]
        let semanticReceipt = try CaptureArtifactIntegrityValidator.validate(result.capture)
        for path in tamperTargets {
            let url = URL(fileURLWithPath: path)
            let original = try Data(contentsOf: url)
            try Data([0x00]).write(to: url, options: .atomic)
            #expect(throws: CaptureArtifactIntegrityError.self) {
                try CaptureArtifactIntegrityValidator.validate(result.capture)
            }
            #expect(throws: (any Error).self) {
                try CaptureActionManifestWriter.validateArtifacts(
                    manifest.artifacts,
                    outputRoot: outputDirectory
                )
            }
            if path == result.capture.metadataFile {
                #expect(throws: (any Error).self) {
                    try CaptureActionManifestWriter.makeArtifacts(
                        capture: result.capture,
                        outputRoot: outputDirectory,
                        metadataSHA256: semanticReceipt.metadataSHA256
                    )
                }
            }
            try original.write(to: url, options: .atomic)
        }
        try CaptureArtifactIntegrityValidator.validate(result.capture)

        let videoURL = outputDirectory.appendingPathComponent("capture.mp4")
        try Data("video-bytes".utf8).write(to: videoURL)
        let videoCustody = try CaptureArtifactIntegrityValidator.videoCustody(path: videoURL.path)
        let captureWithVideo = CaptureSessionResult(
            source: result.capture.source,
            videoIn: result.capture.videoIn,
            videoOut: videoURL.path,
            videoArtifactCustody: videoCustody,
            frames: result.capture.frames,
            contactSheet: result.capture.contactSheet,
            metadataFile: result.capture.metadataFile,
            stats: result.capture.stats,
            scope: result.capture.scope,
            diffAlgorithm: result.capture.diffAlgorithm,
            diffScale: result.capture.diffScale,
            options: result.capture.options,
            warnings: result.capture.warnings
        )
        let artifactsWithVideo = try CaptureActionManifestWriter.makeArtifacts(
            capture: captureWithVideo,
            outputRoot: outputDirectory,
            metadataSHA256: semanticReceipt.metadataSHA256
        )
        #expect(artifactsWithVideo.last?.role == .video)
        try Data("changed-video".utf8).write(to: videoURL, options: .atomic)
        #expect(throws: (any Error).self) {
            try CaptureActionManifestWriter.validateArtifacts(
                artifactsWithVideo,
                outputRoot: outputDirectory
            )
        }
        try FileManager.default.removeItem(at: videoURL)
    }

    private static func verifyContradictoryResultsAreRejected(
        result: CaptureActionCommandResult,
        manifest: CaptureActionManifest,
        manifestData: Data
    ) throws {
        let processData = try JSONEncoder().encode(result.action)
        var contradictoryProcess = try #require(JSONSerialization.jsonObject(with: processData) as? [String: Any])
        contradictoryProcess["processStartIdentityDecimal"] = "1"
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CaptureActionProcessResult.self,
                from: JSONSerialization.data(withJSONObject: contradictoryProcess)
            )
        }
        let commandResultData = try JSONEncoder().encode(result)
        var invalidReceiptResult = try #require(
            JSONSerialization.jsonObject(with: commandResultData) as? [String: Any]
        )
        var invalidReceipt = try #require(invalidReceiptResult["manifest"] as? [String: Any])
        invalidReceipt["sha256"] = ""
        invalidReceiptResult["manifest"] = invalidReceipt
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CaptureActionCommandResult.self,
                from: JSONSerialization.data(withJSONObject: invalidReceiptResult)
            )
        }
        var invalidValidationResult = try #require(
            JSONSerialization.jsonObject(with: commandResultData) as? [String: Any]
        )
        invalidValidationResult["validation"] = ["ok": true, "checked": [], "missing": []]
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CaptureActionCommandResult.self,
                from: JSONSerialization.data(withJSONObject: invalidValidationResult)
            )
        }
        let resultData = try JSONEncoder().encode(manifest.result)
        var contradictoryResult = try #require(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
        contradictoryResult["effect"] = DesktopActionOutcome.Effect.confirmed.rawValue
        let contradictoryManifest = try JSONSerialization.data(withJSONObject: contradictoryResult)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(CaptureActionManifest.ResultSemantics.self, from: contradictoryManifest)
        }
        var contradictoryManifestObject = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        var contradictoryAction = try #require(contradictoryManifestObject["action"] as? [String: Any])
        contradictoryAction["exitCode"] = 7
        contradictoryManifestObject["action"] = contradictoryAction
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CaptureActionManifest.self,
                from: JSONSerialization.data(withJSONObject: contradictoryManifestObject)
            )
        }
        var falseFailureManifestObject = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        var falseFailureResult = try #require(falseFailureManifestObject["result"] as? [String: Any])
        falseFailureResult["success"] = false
        falseFailureManifestObject["result"] = falseFailureResult
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CaptureActionManifest.self,
                from: JSONSerialization.data(withJSONObject: falseFailureManifestObject)
            )
        }
        var overflowManifestObject = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        var overflowRequest = try #require(overflowManifestObject["request"] as? [String: Any])
        overflowRequest["postRollMs"] = Int.max
        overflowManifestObject["request"] = overflowRequest
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                CaptureActionManifest.self,
                from: JSONSerialization.data(withJSONObject: overflowManifestObject)
            )
        }
    }

    private func makeRuntime() -> CommandRuntime {
        CommandRuntime(
            configuration: .init(verbose: false, jsonOutput: true, logLevel: nil),
            services: PeekabooServices()
        )
    }

    private static func isNonemptyFile(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.intValue > 0
    }

    private static func authenticatedHostIdentity() -> PeekabooBridgeAuthenticatedHostIdentity {
        guard let processStartIdentity = SystemIdentityResolver.processStartIdentity(getpid()) else {
            preconditionFailure("Test process identity must be available")
        }
        return PeekabooBridgeAuthenticatedHostIdentity(
            processIdentifier: getpid(),
            processStartIdentity: processStartIdentity,
            signingIdentifier: "boo.peekaboo.tests",
            teamIdentifier: "Y5PE65HELJ",
            codeSignatureHash: String(repeating: "a", count: 40),
            sourceCommit: String(repeating: "b", count: 40),
            bundleShortVersion: "4.2.3",
            bundleVersion: "1"
        )
    }

    private static func captureStandardOutput(
        operation: () async -> Void
    ) async throws -> Data {
        let pipe = Pipe()
        let originalStandardOutput = dup(STDOUT_FILENO)
        guard originalStandardOutput >= 0,
              dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0
        else {
            throw POSIXError(.EIO)
        }
        await operation()
        fflush(stdout)
        _ = dup2(originalStandardOutput, STDOUT_FILENO)
        close(originalStandardOutput)
        try pipe.fileHandleForWriting.close()
        return try pipe.fileHandleForReading.readToEnd() ?? Data()
    }
}

extension CaptureActionCommandEndToEndTests {
    @Test
    func `Capture action cancellation with zero post roll cannot publish a manifest`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.preRoll = CLIDuration(argument: "100ms")
        command.postRoll = CLIDuration(argument: "0ms")
        command.path = outputDirectory.path
        command.command = ["/usr/bin/true"]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in DeterministicCaptureActionFrameSource() },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                onLaunch(DispatchTime.now().uptimeNanoseconds)
                withUnsafeCurrentTask { $0?.cancel() }
                return CaptureActionProcessResult(
                    command: childCommand,
                    processIdentifier: getpid(),
                    processStartIdentity: processStartIdentity,
                    exitCode: 0,
                    timedOut: false,
                    processGroupCleaned: true,
                    timeoutSeconds: timeoutSeconds,
                    durationMs: 0,
                    stdout: "",
                    stderr: "",
                    stdoutTruncated: false,
                    stderrTruncated: false
                )
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )
        command.runtime = self.makeRuntime()

        let execution = Task { @MainActor in
            try await command.executeActionCapture()
        }
        guard case let .failure(error) = await execution.result else {
            Issue.record("Expected cancellation after child admission")
            return
        }
        #expect(error is CancellationError)
        #expect(!FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent(CaptureActionManifestWriter.fileName).path
        ))
    }

    @Test
    func `Capture action timeline starts at release and permits omitted engine metadata`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-timeline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.preRoll = CLIDuration(argument: "100ms")
        command.postRoll = CLIDuration(argument: "100ms")
        command.path = outputDirectory.path
        command.command = ["/usr/bin/true"]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in DeterministicCaptureActionFrameSource(engine: nil) },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                try await Task.sleep(for: .milliseconds(200))
                onLaunch(DispatchTime.now().uptimeNanoseconds)
                return CaptureActionProcessResult(
                    command: childCommand,
                    processIdentifier: getpid(),
                    processStartIdentity: processStartIdentity,
                    exitCode: 0,
                    timedOut: false,
                    processGroupCleaned: true,
                    timeoutSeconds: timeoutSeconds,
                    durationMs: 0,
                    stdout: "",
                    stderr: "",
                    stdoutTruncated: false,
                    stderrTruncated: false
                )
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )
        command.runtime = self.makeRuntime()

        let result = try await command.executeActionCapture()
        let receipt = try #require(result.manifest)
        let data = try Data(contentsOf: URL(fileURLWithPath: receipt.path))
        let manifest = try JSONDecoder().decode(CaptureActionManifest.self, from: data)
        #expect(manifest.timeline.actionStartedMs >= 250)
        #expect(manifest.timeline.actionStartedMs <= manifest.timeline.actionCompletedMs)
        #expect(manifest.capture.observedCaptureEngines.isEmpty)
    }

    @Test
    func `Capture action admits post roll from the runner completion boundary`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "peekaboo-capture-action-post-roll-boundary-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let processStartIdentity = try #require(SystemIdentityResolver.processStartIdentity(getpid()))
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "2500ms")
        command.preRoll = CLIDuration(argument: "100ms")
        command.postRoll = CLIDuration(argument: "100ms")
        command.path = outputDirectory.path
        command.command = ["/usr/bin/true"]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in DeterministicCaptureActionFrameSource() },
            deadlineProcessRunner: { childCommand, timeoutSeconds, completionDeadlineNs, onLaunch in
                let actionStartedNs = DispatchTime.now().uptimeNanoseconds
                onLaunch(actionStartedNs)
                let completedAtNs = completionDeadlineNs - 50_000_000
                let delayedReturnNs = completionDeadlineNs + 20_000_000
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if delayedReturnNs > nowNs {
                    try await Task.sleep(nanoseconds: delayedReturnNs - nowNs)
                }
                return CaptureActionProcessResult(
                    command: childCommand,
                    processIdentifier: getpid(),
                    processStartIdentity: processStartIdentity,
                    exitCode: 0,
                    timedOut: false,
                    processGroupCleaned: true,
                    timeoutSeconds: timeoutSeconds,
                    durationMs: Int((completedAtNs - actionStartedNs) / 1_000_000),
                    stdout: "",
                    stderr: "",
                    stdoutTruncated: false,
                    stderrTruncated: false,
                    completedAtMonotonicNanoseconds: completedAtNs
                )
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )
        command.runtime = self.makeRuntime()

        let result = try await command.executeActionCapture()
        let receipt = try #require(result.manifest)
        let manifest = try JSONDecoder().decode(
            CaptureActionManifest.self,
            from: Data(contentsOf: URL(fileURLWithPath: receipt.path))
        )

        #expect(result.success)
        #expect(manifest.timeline.samplingCompletedMs >= manifest.timeline.actionCompletedMs + 100)
    }

    @Test
    func `Capture action refuses host provenance drift before publication`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-host-drift-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        var identityCallCount: UInt64 = 0
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "3s")
        command.preRoll = CLIDuration(argument: "100ms")
        command.postRoll = CLIDuration(argument: "100ms")
        command.path = outputDirectory.path
        command.command = ["/usr/bin/true"]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in DeterministicCaptureActionFrameSource() },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    onLaunch: onLaunch
                )
            },
            hostIdentityProvider: {
                let base = Self.authenticatedHostIdentity()
                defer { identityCallCount += 1 }
                return PeekabooBridgeAuthenticatedHostIdentity(
                    processIdentifier: base.processIdentifier,
                    processStartIdentity: base.processStartIdentity + identityCallCount,
                    signingIdentifier: base.signingIdentifier,
                    teamIdentifier: base.teamIdentifier,
                    codeSignatureHash: base.codeSignatureHash,
                    sourceCommit: base.sourceCommit,
                    bundleShortVersion: base.bundleShortVersion,
                    bundleVersion: base.bundleVersion
                )
            }
        )
        command.runtime = self.makeRuntime()

        let thrown = await #expect(throws: (any Error).self) {
            _ = try await command.executeActionCapture()
        }
        #expect(try #require(thrown).localizedDescription.contains("host identity changed"))
        #expect(command.captureMutationDispatched)
        #expect(!FileManager.default.fileExists(
            atPath: outputDirectory.appendingPathComponent(CaptureActionManifestWriter.fileName).path
        ))
    }

    private static func verifyManifestCancellationAndReplacementCleanup(
        manifest: CaptureActionManifest,
        manifestURL: URL,
        outputDirectory: URL
    ) throws {
        let cancellationFailure = #expect(throws: CancellationError.self) {
            _ = try CaptureActionManifestWriter.write(
                manifest,
                outputRoot: outputDirectory,
                beforePostPublicationValidation: {
                    throw CancellationError()
                }
            )
        }
        #expect(cancellationFailure != nil)
        #expect(!FileManager.default.fileExists(atPath: manifestURL.path))

        let replacementFailure = #expect(throws: (any Error).self) {
            _ = try CaptureActionManifestWriter.write(
                manifest,
                outputRoot: outputDirectory,
                beforePostPublicationValidation: {
                    try FileManager.default.removeItem(at: manifestURL)
                    guard manifestURL.path.withCString({ mkfifo($0, 0o600) }) == 0 else {
                        throw POSIXError(.EIO)
                    }
                }
            )
        }
        #expect(try #require(replacementFailure).localizedDescription.contains(
            "published manifest cleanup could not be verified"
        ))
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        try FileManager.default.removeItem(at: manifestURL)
    }

    private static func verifyVideoAliasValidation(
        command: CaptureActionCommand,
        capture: CaptureSessionResult
    ) async throws {
        let cancellationPreserved = await Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try command.validateArtifacts(capture)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value
        #expect(cancellationPreserved)

        let aliasedVideoCapture = CaptureSessionResult(
            source: capture.source,
            videoIn: capture.videoIn,
            videoOut: capture.contactSheet.path,
            frames: capture.frames,
            contactSheet: capture.contactSheet,
            metadataFile: capture.metadataFile,
            stats: capture.stats,
            scope: capture.scope,
            diffAlgorithm: capture.diffAlgorithm,
            diffScale: capture.diffScale,
            options: capture.options,
            warnings: capture.warnings
        )
        let validation = try command.validateArtifacts(aliasedVideoCapture)
        #expect(!validation.ok)
        #expect(validation.missing.contains {
            $0.contains("video output aliases a capture-owned artifact")
        })
        #expect(Set(validation.checked).count == validation.checked.count)
    }
}

extension CaptureActionCommandEndToEndTests {
    @Test
    func `Capture action timing reserves startup and descendant drain before post roll`() throws {
        let timing = try CaptureActionTiming.resolve(
            durationLimit: 2.5,
            preRollMs: 0,
            postRollMs: 200,
            requestedActionTimeout: 2.5
        )

        #expect(timing.startupGateMs == 100)
        #expect(abs(timing.actionTimeout - 0.2) < 0.0001)
        let captureStartedNs: UInt64 = 1_000_000_000
        let captureDeadlineNs = try CaptureActionTiming.captureDeadline(
            captureStartedNs: captureStartedNs,
            durationLimit: 2.5
        )
        let actionCompletionDeadlineNs = try timing.actionCompletionDeadline(
            captureDeadlineNs: captureDeadlineNs
        )
        #expect(actionCompletionDeadlineNs == captureStartedNs + 2_300_000_000)
        #expect(timing.postRollFits(
            startingAtNs: actionCompletionDeadlineNs,
            captureDeadlineNs: captureDeadlineNs
        ))
        #expect(!timing.postRollFits(
            startingAtNs: actionCompletionDeadlineNs + 1,
            captureDeadlineNs: captureDeadlineNs
        ))
        #expect(throws: (any Error).self) {
            _ = try CaptureActionTiming.resolve(
                durationLimit: 1.7,
                preRollMs: 100,
                postRollMs: 100,
                requestedActionTimeout: nil
            )
        }
    }

    @Test
    func `Capture action rejects reserved video output before child dispatch`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-video-conflict-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let reservedOutputs = [
            outputDirectory,
            outputDirectory.appendingPathComponent(CaptureActionManifestWriter.fileName),
            outputDirectory.appendingPathComponent("contact.png"),
            outputDirectory.appendingPathComponent("CONTACT.PNG"),
            outputDirectory.appendingPathComponent("metadata.json"),
            outputDirectory.appendingPathComponent("Metadata.JSON"),
            outputDirectory.appendingPathComponent("keep-0001.png"),
            outputDirectory.appendingPathComponent("KEEP-0002.PNG"),
        ]

        for reservedOutput in reservedOutputs {
            let childMarker = outputDirectory.appendingPathComponent("child-ran")
            let processRecorder = CaptureActionProcessRecorder()
            var command = CaptureActionCommand()
            command.mode = "frontmost"
            command.path = outputDirectory.path
            command.videoOut = reservedOutput.path
            command.command = ["/usr/bin/touch", childMarker.path]
            command.executionDependencies = CaptureActionExecutionDependencies(
                frameSourceFactory: { _ in DeterministicCaptureActionFrameSource() },
                processRunner: { childCommand, timeoutSeconds, onLaunch in
                    let startedAt = Date()
                    let result = try await CaptureActionProcessRunner.run(
                        command: childCommand,
                        timeoutSeconds: timeoutSeconds,
                        onLaunch: onLaunch
                    )
                    processRecorder.invocations.append(.init(
                        command: childCommand,
                        timeoutSeconds: timeoutSeconds,
                        startedAt: startedAt,
                        finishedAt: Date()
                    ))
                    return result
                },
                hostIdentityProvider: { Self.authenticatedHostIdentity() }
            )
            command.runtime = self.makeRuntime()

            let thrown = await #expect(throws: (any Error).self) {
                _ = try await command.executeActionCapture()
            }

            #expect(try #require(thrown).localizedDescription.contains(
                "--video-out must not resolve to a capture-owned artifact"
            ))
            #expect(processRecorder.invocations.isEmpty)
            #expect(!command.captureMutationDispatched)
            #expect(!FileManager.default.fileExists(atPath: childMarker.path))
        }
    }

    @Test
    func `Capture action rejects existing video output before child dispatch`() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-existing-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let videoOutput = outputDirectory.appendingPathComponent("action.mp4")
        let retained = Data("existing-video".utf8)
        try retained.write(to: videoOutput)
        let childMarker = outputDirectory.appendingPathComponent("child-ran")
        let processRecorder = CaptureActionProcessRecorder()
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.path = outputDirectory.path
        command.videoOut = videoOutput.path
        command.command = ["/usr/bin/touch", childMarker.path]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in DeterministicCaptureActionFrameSource() },
            processRunner: { childCommand, timeoutSeconds, onLaunch in
                let startedAt = Date()
                let result = try await CaptureActionProcessRunner.run(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    onLaunch: onLaunch
                )
                processRecorder.invocations.append(.init(
                    command: childCommand,
                    timeoutSeconds: timeoutSeconds,
                    startedAt: startedAt,
                    finishedAt: Date()
                ))
                return result
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )
        command.runtime = self.makeRuntime()

        let thrown = await #expect(throws: (any Error).self) {
            _ = try await command.executeActionCapture()
        }

        #expect(try #require(thrown).localizedDescription.contains("--video-out must not already exist"))
        #expect(processRecorder.invocations.isEmpty)
        #expect(!command.captureMutationDispatched)
        #expect(!FileManager.default.fileExists(atPath: childMarker.path))
        #expect(try Data(contentsOf: videoOutput) == retained)
    }

    @Test
    func `Capture action preflights atomic no-replace publication`() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-rename-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let thrown = #expect(throws: (any Error).self) {
            try CaptureActionCommand.validateExclusiveRenameSupport(
                in: outputDirectory,
                renameExclusively: { _, _ in
                    errno = ENOTSUP
                    return -1
                }
            )
        }
        #expect(try #require(thrown).localizedDescription.contains("atomic no-replace publication"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outputDirectory.path).isEmpty)
    }

    @Test
    func `Capture action preflight preserves a failed-rename destination`() throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-capture-action-rename-race-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let replacement = Data("replacement".utf8)

        _ = #expect(throws: (any Error).self) {
            try CaptureActionCommand.validateExclusiveRenameSupport(
                in: outputDirectory,
                renameExclusively: { _, destination in
                    try? replacement.write(to: destination, options: .withoutOverwriting)
                    errno = EEXIST
                    return -1
                }
            )
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        )
        #expect(entries.count == 1)
        let probeDirectory = try #require(entries.first)
        let preserved = probeDirectory.appendingPathComponent("destination")
        var directoryInformation = stat()
        #expect(probeDirectory.path.withCString { lstat($0, &directoryInformation) } == 0)
        #expect((directoryInformation.st_mode & 0o777) == S_IRWXU)
        #expect(try Data(contentsOf: preserved) == replacement)
    }
}

@MainActor
private final class DeterministicCaptureActionFrameSource: CaptureFrameSource {
    private let engine: String?
    private(set) var captureCount = 0
    var resolvedScopes: [CaptureScope] = []
    var captureDates: [Date] = []

    init(engine: String? = "deterministic-test") {
        self.engine = engine
    }

    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        try await Task.sleep(for: .milliseconds(50))
        self.captureCount += 1
        self.captureDates.append(Date())
        let size = CGSize(width: 64, height: 48)
        let color = CGFloat((self.captureCount % 8) + 1) / 9
        var pixels = [UInt8](repeating: UInt8(color * 255), count: Int(size.width * size.height * 4))
        let context = CGContext(
            data: &pixels,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return (
            context?.makeImage(),
            CaptureMetadata(
                size: size,
                mode: .screen,
                timestamp: Date(),
                diagnostics: CaptureDiagnostics(
                    requestedScale: .logical1x,
                    nativeScale: 1,
                    outputScale: 1,
                    scaleSource: "deterministic-test",
                    finalPixelSize: size,
                    engine: self.engine
                )
            )
        )
    }
}

@MainActor
private final class CaptureActionProcessRecorder {
    struct Invocation {
        let command: [String]
        let timeoutSeconds: TimeInterval
        let startedAt: Date
        let finishedAt: Date
    }

    var invocations: [Invocation] = []
}
