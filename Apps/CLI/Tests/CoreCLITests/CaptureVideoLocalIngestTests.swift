@preconcurrency import AVFoundation
import Commander
import CoreGraphics
import CoreVideo
import Foundation
import PeekabooAutomationKit
import PeekabooCore
import PeekabooFoundation
import Testing
@testable import PeekabooCLI

@Suite(.serialized, .tags(.safe))
@MainActor
struct CaptureVideoLocalIngestTests {
    @Test
    func `valid MP4 ingestion bypasses an old ScreenCaptureKit owner`() async throws {
        let fixture = try await Self.makeVideoFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolution = try await Self.resolveLocalVideoRuntime(input: fixture.media)
        let result = try await Self.runVideoIngest(
            input: fixture.media,
            outputRoot: fixture.root.appendingPathComponent("valid-output", isDirectory: true),
            services: resolution.services
        )

        #expect(result.source == .video)
        #expect(result.stats.framesKept > 0)
        #expect(result.frames.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    @Test
    func `audio-only ingestion reaches a typed media failure under an old ScreenCaptureKit owner`() async throws {
        let fixture = try Self.makeAudioOnlyFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let resolution = try await Self.resolveLocalVideoRuntime(input: fixture.media)

        let source = try await VideoFrameSource(
            url: fixture.media,
            sampleFps: 2,
            everyMs: nil,
            startMs: nil,
            endMs: nil,
            resolutionCap: 64
        )
        let session = WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: resolution.services.screenCapture,
                screenService: resolution.services.screens,
                frameSource: source
            ),
            configuration: Self.videoConfiguration(
                input: fixture.media,
                outputRoot: fixture.root.appendingPathComponent("audio-output", isDirectory: true)
            )
        )

        let error = await #expect(throws: CaptureNoValidFramesError.self) {
            _ = try await session.run()
        }
        #expect(error?.source == .video)
        #expect(error?.decodeFailures ?? 0 > 0)
        #expect(error?.framesDropped ?? 0 > 0)
        #expect(error?.localizedDescription.contains("no decodable frames") == true)
    }

    private static func resolveLocalVideoRuntime(input: URL) async throws -> RuntimeHostResolver.Resolution {
        let options = try CommanderCLIBinder.makeRuntimeOptions(
            from: ParsedValues(
                positional: [input.path],
                options: [:],
                flags: []
            ),
            commandType: CaptureVideoCommand.self
        )
        #expect(!options.preferRemote)
        #expect(!options.remoteIsolationRequested)
        #expect(!options.requiresScreenCapturePermission)
        #expect(!options.requiresSilentCapture)
        #expect(!options.requiresDesktopObservation)
        #expect(!options.requiresScreenCaptureKitOwnerCapability)
        #expect(!RuntimeHostResolver.shouldResolveKnownRemoteEndpoints(
            options: options,
            environment: [:],
            configurationInput: nil
        ))

        var claimCalls = 0
        var inspectOwnerCalls = 0
        var inspectSafetyCalls = 0
        var remoteCandidatePlanCalls = 0
        var localFactoryCalls = 0
        let resolution = try await RuntimeHostResolver.resolveServices(
            options: options,
            environment: [:],
            configurationInput: nil,
            dependencies: .init(
                makeLocalServices: { _ in
                    localFactoryCalls += 1
                    return PeekabooServices()
                },
                claimScreenCaptureKitOwner: {
                    claimCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitOwner: {
                    inspectOwnerCalls += 1
                    return Self.ownerReceipt()
                },
                inspectScreenCaptureKitSafety: { _, _, _, _ in
                    inspectSafetyCalls += 1
                    return RuntimeHostResolver.ScreenCaptureKitOwnerUnawareHost(
                        socketPath: "/tmp/old-owner.sock",
                        processIdentifier: 3131,
                        processStartIdentity: 4141
                    )
                },
                remoteCandidatePlan: { _, _ in
                    remoteCandidatePlanCalls += 1
                    return RuntimeHostResolver.RemoteCandidatePlan(
                        explicitSocket: nil,
                        daemonSocketPath: "/tmp/peekaboo-video-ingest-daemon.sock",
                        runtimeBuildIdentity: "video-ingest-test",
                        buildScopedDaemonSocketPath: "/tmp/peekaboo-video-ingest-current.sock",
                        historicalBuildScopedDaemonTargets: [],
                        historicalBuildScopedDaemonSocketPaths: [],
                        candidates: []
                    )
                }
            )
        )

        #expect(claimCalls == 0)
        #expect(inspectOwnerCalls == 0)
        #expect(inspectSafetyCalls == 0)
        #expect(remoteCandidatePlanCalls == 0)
        #expect(localFactoryCalls == 1)
        #expect(resolution.selectedRemoteSocketPath == nil)
        return resolution
    }

    private static func runVideoIngest(
        input: URL,
        outputRoot: URL,
        services: any PeekabooServiceProviding
    ) async throws -> CaptureSessionResult {
        let source = try await VideoFrameSource(
            url: input,
            sampleFps: 2,
            everyMs: nil,
            startMs: nil,
            endMs: nil,
            resolutionCap: 64
        )
        return try await WatchCaptureSession(
            dependencies: WatchCaptureDependencies(
                screenCapture: services.screenCapture,
                screenService: services.screens,
                frameSource: source
            ),
            configuration: self.videoConfiguration(input: input, outputRoot: outputRoot)
        ).run()
    }

    private static func videoConfiguration(input: URL, outputRoot: URL) -> WatchCaptureConfiguration {
        WatchCaptureConfiguration(
            scope: CaptureScope(kind: .frontmost),
            options: CaptureOptions(
                duration: 5,
                idleFps: 1,
                activeFps: 2,
                changeThresholdPercent: 0,
                heartbeatSeconds: 0,
                quietMsToIdle: 0,
                maxFrames: 4,
                maxMegabytes: nil,
                highlightChanges: false,
                captureFocus: .background,
                resolutionCap: 64,
                diffStrategy: .fast,
                diffBudgetMs: nil
            ),
            outputRoot: outputRoot,
            autoclean: WatchAutocleanConfig(minutes: 120, managed: false),
            sourceKind: .video,
            videoIn: input.path,
            keepAllFrames: true
        )
    }

    private static func makeVideoFixture() async throws -> (root: URL, media: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-video-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 64,
                AVVideoHeightKey: 64,
            ]
        )
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64,
                kCVPixelBufferHeightKey as String: 64,
            ]
        )
        guard writer.canAdd(input) else {
            throw PeekabooError.captureFailed("Test writer rejected its video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? PeekabooError.captureFailed("Test video writer failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        for (index, time) in [CMTime.zero, CMTime(seconds: 0.5, preferredTimescale: 600)].enumerated() {
            let buffer = try Self.makePixelBuffer(component: UInt8(48 + index * 96))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw writer.error ?? PeekabooError.captureFailed("Test video writer rejected a frame")
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? PeekabooError.captureFailed("Test video writer failed to finish")
        }
        return (root, url)
    }

    private static func makeAudioOnlyFixture() throws -> (root: URL, media: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("peekaboo-audio-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("fixture.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        buffer.frameLength = 44100
        if let channel = buffer.floatChannelData?[0] {
            channel.initialize(repeating: 0, count: Int(buffer.frameLength))
        }
        try file.write(from: buffer)
        return (root, url)
    }

    private static func makePixelBuffer(component: UInt8) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            64,
            64,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &buffer
        )
        guard result == kCVReturnSuccess, let buffer else {
            throw PeekabooError.captureFailed("Test pixel-buffer allocation failed")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else {
            throw PeekabooError.captureFailed("Test pixel buffer has no base address")
        }
        memset(baseAddress, Int32(component), CVPixelBufferGetDataSize(buffer))
        return buffer
    }

    private static func ownerReceipt() -> ScreenCaptureKitOwnerLease.OwnerReceipt {
        ScreenCaptureKitOwnerLease.OwnerReceipt(
            processIdentifier: 4242,
            processStartIdentity: 9001,
            codeSignatureHash: "old-owner-build"
        )
    }
}
