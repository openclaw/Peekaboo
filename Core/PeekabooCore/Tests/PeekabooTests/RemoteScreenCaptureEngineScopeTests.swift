import CoreGraphics
import Darwin
import Foundation
import PeekabooAutomationKit
import PeekabooBridgeTestSupport
import PeekabooFoundation
import Testing
@testable import PeekabooBridge
@testable import PeekabooCore

@MainActor
struct RemoteScreenCaptureEngineScopeTests {
    @Test(arguments: Target.allCases, [CaptureScalePreference.logical1x, .native])
    func `scoped captures forward targets and options without artifacts or snapshot calls`(
        target: Target,
        scale: CaptureScalePreference) async throws
    {
        let result = Self.observationResult()
        let peer = try ScriptedBridgePeer(responses: [Self.handshake, .desktopObservation(result)])
        let client = try await Self.negotiate(socketPath: peer.socketPath)
        let service = Self.service(client: client)

        let capture = try await service.withCaptureEngine(.modern) {
            try await target.capture(using: service, visualizerMode: .watchCapture, scale: scale)
        }
        await peer.waitUntilFinished()

        #expect(capture.imageData == result.capture.imageData)
        #expect(capture.savedPath == nil)
        let requests = try await Self.requests(from: peer)
        #expect(requests.count == 1)
        let request = try Self.observationRequest(#require(requests.first))
        #expect(request.target == target.request)
        #expect(request.capture.engine == .modern)
        #expect(request.capture.scale == scale)
        #expect(request.capture.visualizerMode == .watchCapture)
        #expect(request.capture.focus == .background)
        #expect(request.detection.mode == .none)
        #expect(request.output.includeImageData)
        #expect(!request.output.saveRawScreenshot)
        #expect(!request.output.saveAnnotatedScreenshot)
        #expect(!request.output.saveSnapshot)
        #expect(request.output.path == nil)
        #expect(request.output.snapshotID == nil)
    }

    @Test
    func `unscoped captures retain the five raw Bridge operations`() async throws {
        let capture = Self.observationResult().capture
        let peer = try ScriptedBridgePeer(responses: [Self.handshake] + Array(repeating: .capture(capture), count: 5))
        let client = try await Self.negotiate(socketPath: peer.socketPath)
        let service = Self.service(client: client)

        for target in [Target.screen, .app, .windowID, .frontmost, .area] {
            _ = try await target.capture(using: service, visualizerMode: .none, scale: .logical1x)
        }
        await peer.waitUntilFinished()

        #expect(try await Self.requests(from: peer).map(\.operation) == [
            .captureScreen, .captureWindow, .captureWindow, .captureFrontmost, .captureArea,
        ])
    }

    @Test
    func `nested scopes inherit restore after errors and distinguish explicit auto`() async throws {
        let result = Self.observationResult()
        let peer = try ScriptedBridgePeer(responses: [Self.handshake] +
            Array(repeating: .desktopObservation(result), count: 5) + [.capture(result.capture)])
        let client = try await Self.negotiate(socketPath: peer.socketPath)
        let service = Self.service(client: client)

        try await service.withCaptureEngine(.modern) {
            _ = try await Task { try await service.captureScreen(displayIndex: nil) }.value
            await #expect(throws: ScopeFailure.self) {
                try await service.withCaptureEngine(.legacy) {
                    _ = try await service.captureScreen(displayIndex: nil)
                    throw ScopeFailure()
                }
            }
            _ = try await service.captureScreen(displayIndex: nil)
            await #expect(throws: CancellationError.self) {
                try await service.withCaptureEngine(.auto) {
                    _ = try await service.captureScreen(displayIndex: nil)
                    throw CancellationError()
                }
            }
            _ = try await service.captureScreen(displayIndex: nil)
        }
        _ = try await service.captureScreen(displayIndex: nil)
        await peer.waitUntilFinished()

        let requests = try await Self.requests(from: peer)
        #expect(try requests.dropLast().map { try Self.observationRequest($0).capture.engine } == [
            .modern, .legacy, .modern, .auto, .modern,
        ])
        #expect(requests.last?.operation == .captureScreen)
    }

    @Test
    func `overlapping engine scopes remain isolated when responses arrive in reverse order`() async throws {
        let peer = try ConcurrentGatedBridgePeer()
        defer { Task { await peer.stop() } }
        let negotiation = Task { try await Self.negotiate(socketPath: peer.socketPath) }
        let handshakeRequest = try await peer.nextRequest()
        guard case .handshake = try handshakeRequest.decode() else {
            Issue.record("Expected the initial Bridge handshake")
            throw ScopeFailure()
        }
        try await peer.respond(Self.handshake, to: handshakeRequest)
        let service = try await Self.service(client: negotiation.value)

        let modern = Task {
            try await service.withCaptureEngine(.modern) { try await service.captureScreen(displayIndex: nil) }
        }
        let classic = Task {
            try await service.withCaptureEngine(.legacy) { try await service.captureScreen(displayIndex: nil) }
        }
        let first = try await peer.nextRequest()
        let second = try await peer.nextRequest()
        let firstEngine = try Self.observationRequest(first.decode()).capture.engine
        let secondEngine = try Self.observationRequest(second.decode()).capture.engine
        #expect(Set([firstEngine.rawValue, secondEngine.rawValue]) == ["modern", "legacy"])
        try await peer.respond(.desktopObservation(Self.observationResult(bytes: secondEngine.rawValue)), to: second)
        try await peer.respond(.desktopObservation(Self.observationResult(bytes: firstEngine.rawValue)), to: first)

        #expect(try await modern.value.imageData == Data("modern".utf8))
        #expect(try await classic.value.imageData == Data("legacy".utf8))
        let unscoped = Task { try await service.captureScreen(displayIndex: nil) }
        let unscopedRequest = try await peer.nextRequest()
        #expect(try unscopedRequest.decode().operation == .captureScreen)
        try await peer.respond(.capture(Self.observationResult().capture), to: unscopedRequest)
        _ = try await unscoped.value
        #expect(await peer.acceptedConnectionCount == 4)
        await peer.stop()
    }

    @Test
    func `a cancelled scoped task does not alter the parent capture route`() async throws {
        let capture = Self.observationResult().capture
        let peer = try ScriptedBridgePeer(responses: [Self.handshake, .capture(capture)])
        let client = try await Self.negotiate(socketPath: peer.socketPath)
        let service = Self.service(client: client)
        let entered = AsyncStream.makeStream(of: Void.self)
        let suspension = AsyncStream.makeStream(of: Void.self)
        defer {
            entered.continuation.finish()
            suspension.continuation.finish()
        }
        let cancelled = Task {
            try await service.withCaptureEngine(.legacy) {
                entered.continuation.yield(())
                for await _ in suspension.stream {}
                try Task.checkCancellation()
            }
        }
        var entry = entered.stream.makeAsyncIterator()
        _ = await entry.next()
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }

        _ = try await service.captureScreen(displayIndex: nil)
        await peer.waitUntilFinished()
        #expect(try await Self.requests(from: peer).map(\.operation) == [.captureScreen])
    }

    @Test
    func `remote service graph enables scoped capture with the same observation policy`() async throws {
        let peer = try ScriptedBridgePeer(responses: [Self.handshake, .desktopObservation(Self.observationResult())])
        let client = try await Self.negotiate(socketPath: peer.socketPath)
        let services = RemotePeekabooServices(
            client: client,
            capturePolicy: .classicOnly(.preDispatchRefusal(
                reason: .runtimeIncompatible,
                message: "Fixture only permits classic capture")),
            supportsDesktopObservation: true,
            supportsDesktopObservationCaptureEngine: true,
            supportsDesktopObservationInlinePixels: true)
        let capture = try #require(services.screenCapture as? any EngineAwareScreenCaptureServiceProtocol)

        _ = try await capture.withCaptureEngine(.auto) { try await capture.captureScreen(displayIndex: nil) }
        await peer.waitUntilFinished()
        let requests = try await Self.requests(from: peer)
        #expect(requests.count == 1)
        #expect(try Self.observationRequest(#require(requests.first)).capture.engine == .legacy)
    }

    @Test
    func `legacy auto observation stays raw while explicit engine scopes refuse the old host`() async throws {
        let rawHandshake = BridgeTestFixtures.handshake(
            negotiatedVersion: Self.version,
            supportedOperations: [.captureScreen])
        let capture = Self.observationResult().capture
        let peer = try ScriptedBridgePeer(responses: [.handshake(rawHandshake), .capture(capture)])
        let client = try await Self.negotiate(socketPath: peer.socketPath)
        let services = RemotePeekabooServices(client: client, supportsDesktopObservation: false)
        let scopedCapture = try #require(services.screenCapture as? any EngineAwareScreenCaptureServiceProtocol)
        #expect(scopedCapture.captureTransactionGateOwner == .service)

        let result = try await services.desktopObservation.observe(DesktopObservationRequest(
            target: .screen(index: 0),
            capture: DesktopCaptureOptions(engine: .auto),
            detection: DesktopDetectionOptions(mode: .none)))
        #expect(result.capture.imageData == capture.imageData)
        for engine in [CaptureEnginePreference.auto, .modern, .legacy] {
            let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
                try await scopedCapture.withCaptureEngine(engine) {
                    try await scopedCapture.captureScreen(displayIndex: 0)
                }
            }
            #expect(error?.code == .operationNotSupported)
            #expect(error?.message.contains("desktopObservationInlinePixels") == true)
        }
        await peer.waitUntilFinished()
        #expect(try await Self.requests(from: peer).map(\.operation) == [.captureScreen])
    }

    @Test(arguments: [CaptureEnginePreference.auto, .modern, .legacy])
    func `unsupported inline capability refuses before connection`(engine: CaptureEnginePreference) async throws {
        let peer = try ConcurrentGatedBridgePeer()
        defer { Task { await peer.stop() } }
        let client = PeekabooBridgeClient(socketPath: peer.socketPath, requestTimeoutSec: 1)
        let observation = RemoteDesktopObservationService(
            client: client,
            supportsDesktopObservationCaptureEngine: true)
        let service = RemoteScreenCaptureService(client: client, desktopObservation: observation)

        let error = await #expect(throws: PeekabooBridgeErrorEnvelope.self) {
            try await service.withCaptureEngine(engine) { try await service.captureScreen(displayIndex: nil) }
        }

        #expect(error?.code == .operationNotSupported)
        #expect(error?.message.contains("desktopObservationInlinePixels") == true)
        #expect(await peer.acceptedConnectionCount == 0)
        await peer.stop()
    }

    @Test
    func `classic-only route applies the shared observation policy`() async throws {
        let result = Self.observationResult()
        let peer = try ScriptedBridgePeer(responses: [Self.handshake, .desktopObservation(result)])
        let client = try await Self.negotiate(socketPath: peer.socketPath)
        let policy = RemoteCapturePolicy.classicOnly(.preDispatchRefusal(
            reason: .runtimeIncompatible,
            message: "Fixture only permits classic capture"))
        let service = Self.service(client: client, capturePolicy: policy)

        await #expect(throws: DesktopActionFailure.self) {
            _ = try await service.captureScreen(displayIndex: nil)
        }
        await #expect(throws: DesktopActionFailure.self) {
            try await service.withCaptureEngine(.modern) { try await service.captureScreen(displayIndex: nil) }
        }
        _ = try await service.withCaptureEngine(.auto) { try await service.captureScreen(displayIndex: nil) }
        await peer.waitUntilFinished()

        let requests = try await Self.requests(from: peer)
        #expect(requests.count == 1)
        #expect(try Self.observationRequest(#require(requests.first)).capture.engine == .legacy)
    }

    @Test(arguments: [false, true])
    func `empty or tampered inline pixels cannot escape the adapter`(tampered: Bool) async throws {
        let original = Self.observationResult(bytes: tampered ? "original" : "")
        let result = DesktopObservationResult(
            target: original.target,
            capture: CaptureResult(
                imageData: tampered ? Data("changed".utf8) : Data(),
                metadata: original.capture.metadata),
            elements: nil,
            captureContentDigest: original.captureContentDigest)
        let peer = try ScriptedBridgePeer(responses: [Self.handshake, .desktopObservation(result)])
        let client = try await Self.negotiate(socketPath: peer.socketPath)
        let service = Self.service(client: client)

        await #expect(throws: (any Error).self) {
            try await service.withCaptureEngine(.modern) { try await service.captureScreen(displayIndex: nil) }
        }
        await peer.waitUntilFinished()
        #expect(try await Self.requests(from: peer).map(\.operation) == [.desktopObservation])
    }
}

extension RemoteScreenCaptureEngineScopeTests {
    private static let version = PeekabooBridgeProtocolVersion(major: 1, minor: 28)

    private static var handshake: PeekabooBridgeResponse {
        .handshake(BridgeTestFixtures.handshake(
            negotiatedVersion: self.version,
            supportedOperations: [.desktopObservation, .captureScreen, .captureWindow, .captureFrontmost, .captureArea],
            hostCapabilities: [
                PeekabooBridgeHostCapability.desktopObservationCaptureEngine,
                PeekabooBridgeHostCapability.desktopObservationInlinePixels,
            ]))
    }

    private static func negotiate(socketPath: String) async throws -> PeekabooBridgeClient {
        let client = PeekabooBridgeClient(socketPath: socketPath, requestTimeoutSec: 2)
        _ = try await client.handshake(
            client: .init(
                bundleIdentifier: "dev.peekaboo.remote-engine-scope-tests",
                teamIdentifier: nil,
                processIdentifier: getpid()),
            protocolVersion: self.version)
        return client
    }

    private static func service(
        client: PeekabooBridgeClient,
        capturePolicy: RemoteCapturePolicy = .unrestricted) -> RemoteScreenCaptureService
    {
        let observation = RemoteDesktopObservationService(
            client: client,
            capturePolicy: capturePolicy,
            supportsDesktopObservationCaptureEngine: true,
            supportsDesktopObservationInlinePixels: true,
            supportsExactWindowROIObservation: false,
            artifactInstallationPreflight: { Issue.record("Pixel-only capture must not install artifacts") })
        return RemoteScreenCaptureService(
            client: client,
            capturePolicy: capturePolicy,
            desktopObservation: observation)
    }

    private static func observationResult(bytes: String = "fixture-pixels") -> DesktopObservationResult {
        DesktopObservationResult(
            target: ResolvedObservationTarget(kind: .screen(index: 0)),
            capture: CaptureResult(
                imageData: Data(bytes.utf8),
                metadata: CaptureMetadata(size: CGSize(width: 1, height: 1), mode: .screen)),
            elements: nil)
            .withCaptureContentDigest(rawScreenshotData: nil, annotatedScreenshotData: nil)
    }

    private static func observationRequest(_ request: PeekabooBridgeRequest) throws -> DesktopObservationRequest {
        guard case let .desktopObservation(request) = request else {
            Issue.record("Expected desktop observation, got \(request.operation.rawValue)")
            throw ScopeFailure()
        }
        return request
    }

    private static func requests(from peer: ScriptedBridgePeer) async throws -> [PeekabooBridgeRequest] {
        try await peer.requests.dropFirst().map {
            try JSONDecoder.peekabooBridgeDecoder().decode(PeekabooBridgeRequest.self, from: $0)
        }
    }

    enum Target: CaseIterable, Sendable {
        case screen, defaultScreen, app, automaticWindow, windowID, frontmost, area

        var request: DesktopObservationTargetRequest {
            switch self {
            case .screen: .screen(index: 2)
            case .defaultScreen: .screen(index: nil)
            case .app: .app(identifier: "Fixture", window: .index(3))
            case .automaticWindow: .app(identifier: "Fixture", window: nil)
            case .windowID: .windowID(42)
            case .frontmost: .frontmost
            case .area: .area(CGRect(x: 11, y: 22, width: 33, height: 44))
            }
        }

        @MainActor
        func capture(
            using service: RemoteScreenCaptureService,
            visualizerMode: CaptureVisualizerMode,
            scale: CaptureScalePreference) async throws -> CaptureResult
        {
            switch self {
            case .screen, .defaultScreen:
                try await service.captureScreen(
                    displayIndex: self == .screen ? 2 : nil, visualizerMode: visualizerMode, scale: scale)
            case .app, .automaticWindow:
                try await service.captureWindow(
                    appIdentifier: "Fixture",
                    windowIndex: self == .app ? 3 : nil,
                    visualizerMode: visualizerMode,
                    scale: scale)
            case .windowID:
                try await service.captureWindow(windowID: 42, visualizerMode: visualizerMode, scale: scale)
            case .frontmost:
                try await service.captureFrontmost(visualizerMode: visualizerMode, scale: scale)
            case .area:
                try await service.captureArea(
                    CGRect(x: 11, y: 22, width: 33, height: 44), visualizerMode: visualizerMode, scale: scale)
            }
        }
    }

    private struct ScopeFailure: Error {}
}
