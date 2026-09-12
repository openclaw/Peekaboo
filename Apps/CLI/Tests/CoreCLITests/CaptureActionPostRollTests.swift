import CoreGraphics
import Foundation
import PeekabooCore
import Testing
@testable import PeekabooCLI

extension CaptureActionCommandEndToEndTests {
    @Test(.timeLimit(.minutes(1)), arguments: [
        (maxFrames: 20, postRollMs: 100, succeeds: true, samplesAfterAction: true),
        (maxFrames: 2, postRollMs: 100, succeeds: false, samplesAfterAction: false),
        (maxFrames: 20, postRollMs: 0, succeeds: true, samplesAfterAction: false),
    ])
    func `post roll samples after a slow earlier frame while honoring caps and explicit zero`(
        maxFrames: Int, postRollMs: Int, succeeds: Bool, samplesAfterAction: Bool
    ) async throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-post-roll-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: output) }
        let source = SlowPostActionFrameSource()
        defer { source.finish() }
        var childCompletedNs: UInt64?
        var command = CaptureActionCommand()
        command.mode = "frontmost"
        command.durationLimit = CLIDuration(argument: "20s")
        command.preRoll = CLIDuration(argument: "100ms")
        command.postRoll = CLIDuration(argument: "\(postRollMs)ms")
        command.threshold = 0
        command.maxFrames = maxFrames
        command.path = output.path
        command.command = ["/usr/bin/true"]
        command.executionDependencies = CaptureActionExecutionDependencies(
            frameSourceFactory: { _ in source },
            deadlineProcessRunner: { arguments, timeout, deadline, onLaunch in
                var started = source.secondFrameStarted.makeAsyncIterator()
                guard await started.next() != nil else { throw CancellationError() }
                let result = try await CaptureActionProcessRunner.run(
                    command: arguments,
                    timeoutSeconds: timeout,
                    completionDeadlineNanoseconds: deadline,
                    onLaunch: onLaunch
                )
                childCompletedNs = result.completedAtMonotonicNanoseconds
                return result
            },
            hostIdentityProvider: { Self.authenticatedHostIdentity() }
        )
        command.runtime = self.makeRuntime()

        let result = try await command.executeActionCapture()
        let completion = try #require(childCompletedNs)
        #expect(result.success == succeeds)
        #expect(result.action.exitCode == 0)
        #expect(source.sampleStarts.contains { $0 >= completion } == samplesAfterAction)
        let receipt = try #require(result.manifest)
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: receipt.path))
        let manifest = try JSONDecoder().decode(CaptureActionManifest.self, from: manifestData)
        let sample = try #require(manifest.timeline.sampleBoundary)
        #expect(manifest.provesPostActionSample == samplesAfterAction)
        #expect(sample.actionCompletedOffsetNs / 1_000_000 == UInt64(manifest.timeline.actionCompletedMs))
        if postRollMs > 0, succeeds {
            var object = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
            var timeline = try #require(object["timeline"] as? [String: Any])
            timeline["sampleBoundary"] = [
                "actionCompletedOffsetNs": String(sample.actionCompletedOffsetNs),
                "lastSampleStartedOffsetNs": String(sample.actionCompletedOffsetNs - 1),
            ]
            object["timeline"] = timeline
            let forged = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                try JSONDecoder().decode(CaptureActionManifest.self, from: forged)
            }

            timeline.removeValue(forKey: "sampleBoundary")
            object["timeline"] = timeline
            let legacy = try JSONDecoder().decode(
                CaptureActionManifest.self, from: JSONSerialization.data(withJSONObject: object)
            )
            #expect(legacy.timeline.sampleBoundary == nil)
            #expect(!legacy.provesPostActionSample)
        }
        if !succeeds {
            #expect(result.validation.missing.contains(
                "capture ended without a valid sample begun after the action completed"
            ))
        }
    }
}

@MainActor
private final class SlowPostActionFrameSource: CaptureFrameSource {
    private let source = DeterministicCaptureActionFrameSource()
    let secondFrameStarted: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private(set) var sampleStarts: [UInt64] = []

    init() {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        self.secondFrameStarted = stream
        self.continuation = continuation
    }

    func nextFrame() async throws -> (cgImage: CGImage?, metadata: CaptureMetadata)? {
        self.sampleStarts.append(DispatchTime.now().uptimeNanoseconds)
        if self.sampleStarts.count == 2 {
            self.continuation.yield(())
            try await Task.sleep(for: .milliseconds(700))
        }
        return try await self.source.nextFrame()
    }

    func finish() {
        self.continuation.finish()
    }
}
